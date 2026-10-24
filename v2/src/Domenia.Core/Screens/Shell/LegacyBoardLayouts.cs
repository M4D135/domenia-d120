using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domenia.Core.Accueil;

namespace Domenia.Core;

/// <summary>Conditional local preference write, rechecked against the latest disk document under its interprocess lock.</summary>
public interface IConditionalPreferenceStore
{
    Task<bool> TryAddWithEvidenceAsync(string key, JsonElement value, string evidenceKey, JsonElement evidence, CancellationToken token);
}

public sealed record LegacyBoardProposal(string Board, string? Setting, string State, string Summary, int Count,
    ImmutableArray<FleetLayoutItem> Items, [property: JsonIgnore] string? OriginalLayout);

public sealed record LegacyBoardPreview(string? SourcePath, string? SourceSha256, ImmutableArray<LegacyBoardProposal> Boards,
    ImmutableArray<string> Warnings, bool FleetChoiceExists = false, bool Available = true, string? Reason = null);

/// <summary>D1 settings, not a SQLite table. Pure conversion; no source is rewritten and no query library implies a layout.</summary>
public static class LegacyBoardLayouts
{
    public const string EvidenceKey = "accueil.layoutMigration";
    public const int MaxLayoutBytes = 65_536;
    private static readonly JsonSerializerOptions Json = CreateJson();

    public static LegacyBoardPreview Parse(JsonElement settings, string path, string sha256)
    {
        if (settings.ValueKind != JsonValueKind.Object) { throw new InvalidDataException("Les préférences D1 doivent être une table JSON."); }
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in settings.EnumerateObject())
        {
            if (names.Count >= 4096 || !names.Add(property.Name)) { throw new InvalidDataException("Préférences D1 trop nombreuses ou dupliquées."); }
        }
        return new(path, sha256, [.. new[] { "Fleet", "Computer", "Software" }.Select(board => Proposal(settings, board))], []);
    }

    public static bool HasFleetChoice(IPreferenceStore store) => store.TryGet(AccueilService.LayoutPreference, out _) || store.TryGet(EvidenceKey, out _);

    public static async Task<bool> ApplyFleetAsync(LegacyBoardPreview preview, string expectedSha256,
        IConditionalPreferenceStore store, DateTimeOffset now, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (expectedSha256 is not { Length: 64 } || !expectedSha256.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'))
            || !string.Equals(preview.SourceSha256, expectedSha256, StringComparison.Ordinal))
        { throw new InvalidDataException("Les préférences D1 ont changé depuis l’aperçu ; relisez-les avant d’importer."); }
        var fleet = preview.Boards.Single(p => p.Board == "Fleet");
        if (fleet.State != "ready" || fleet.OriginalLayout is null || preview.SourcePath is null)
        { throw new InvalidDataException("Aucune disposition du parc compatible à importer."); }
        var layout = JsonSerializer.SerializeToElement(new { version = 1, items = fleet.Items }, Json);
        var evidence = JsonSerializer.SerializeToElement(new
        {
            version = 1, sourcePath = preview.SourcePath, sourceSha256 = expectedSha256, setting = fleet.Setting,
            originalLayout = fleet.OriginalLayout, importedAt = now, board = "Fleet", destination = AccueilService.LayoutPreference,
        }, Json);
        return await store.TryAddWithEvidenceAsync(AccueilService.LayoutPreference, layout, EvidenceKey, evidence, token).ConfigureAwait(false);
    }

    private static LegacyBoardProposal Proposal(JsonElement settings, string board)
    {
        var key = "Dashboard." + board + ".Layout";
        var value = Property(settings, key);
        var legacy = false;
        // D1 ships the empty string as its unset value. A stored "[]" is present and never falls back to Widgets.*.
        if (Absent(value) && board is "Fleet" or "Computer")
        {
            key = "Widgets." + board;
            value = Property(settings, key);
            legacy = true;
        }
        if (Absent(value)) { return new(board, null, "absent", "Aucune disposition D1 enregistrée.", 0, [], null); }
        try
        {
            if (value is not { ValueKind: JsonValueKind.String } text) { throw new InvalidDataException("La disposition D1 doit être un texte JSON."); }
            var original = text.GetString()!;
            if (Encoding.UTF8.GetByteCount(original) > MaxLayoutBytes) { throw new InvalidDataException("Disposition D1 supérieure à 64 Kio."); }
            using var document = JsonDocument.Parse(original, new JsonDocumentOptions { MaxDepth = 16 });
            var rows = document.RootElement;
            if (rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > FleetCatalog.MaxItems)
            { throw new InvalidDataException("La disposition D1 doit être une liste de 64 widgets au plus."); }
            if (board != "Fleet")
            { return new(board, key, "unsupported", "Conservée dans D1 ; cet écran D2 ne consomme pas encore cette disposition. Aucune importation appliquée.", rows.GetArrayLength(), [], original); }
            var items = new List<FleetLayoutItem>();
            if (legacy) { items.AddRange(FleetCatalog.DefaultLayout()); }
            var ids = items.Select(i => i.Id).ToHashSet(StringComparer.Ordinal);
            var given = rows.EnumerateArray().Select(r => Text(r, "Id", 64)).Where(id => id is { Length: > 0 }).ToHashSet(StringComparer.Ordinal);
            var adjusted = false;
            var position = 0;
            foreach (var row in rows.EnumerateArray())
            {
                var sourceText = legacy ? "Probe" : Text(row, "Source", 16);
                var source = sourceText?.ToLowerInvariant() switch
                {
                    "builtin" => FleetWidgetSource.Builtin, "probe" => FleetWidgetSource.Probe, "query" => FleetWidgetSource.Query,
                    _ => throw new InvalidDataException("Source de widget D1 inconnue ; disposition entière conservée sans importation partielle."),
                };
                var itemKey = Text(row, legacy ? "ProbeId" : "Key", 80) ?? "";
                var id = Text(row, "Id", 64) ?? "";
                if (legacy && id.Length > 0) { id = "p-" + id; }
                if (id.Length is 0 or > 64 || !id.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.') || !ids.Add(id))
                {
                    var seed = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(itemKey)))[..12];
                    var stem = "w-" + seed + "-" + position.ToString(System.Globalization.CultureInfo.InvariantCulture);
                    id = stem;
                    var suffix = 2;
                    while (given.Contains(id) || !ids.Add(id)) { id = stem + "-" + (suffix++).ToString(System.Globalization.CultureInfo.InvariantCulture); }
                    adjusted = true;
                }
                var paused = Property(row, "Paused");
                if (paused is { ValueKind: not (JsonValueKind.True or JsonValueKind.False or JsonValueKind.Null) })
                { throw new InvalidDataException("État Paused D1 non booléen."); }
                var input = new FleetLayoutItem(id, source, itemKey, Text(row, "Visual", 32) ?? "", Text(row, "Size", 8) ?? "M",
                    Text(row, "Title", FleetCatalog.MaxTitleLength), paused is { ValueKind: JsonValueKind.True }, Text(row, "Group", 80) ?? "");
                var converted = AccueilService.Clean([input]);
                if (converted.Length != 1) { throw new InvalidDataException("Widget absent du catalogue D2 ; disposition entière conservée sans importation partielle."); }
                adjusted |= converted[0] != input;
                items.Add(converted[0]);
                position++;
            }
            if (items.Count > FleetCatalog.MaxItems) { throw new InvalidDataException("La disposition avec ses widgets historiques dépasse 64 éléments."); }
            var summary = items.Count == 0 ? "Tableau du parc volontairement vide ; il restera vide dans Accueil."
                : "Ordre, identifiants valides et pauses repris dans le tableau du parc d’Accueil."
                    + (legacy ? " Les sondes historiques complètent la disposition livrée, comme dans D1." : "")
                    + (adjusted ? " Présentations et groupes adaptés au catalogue D2 ; le texte D1 original reste conservé." : "");
            return new(board, key, "ready", summary, items.Count, [.. items], original);
        }
        catch (Exception ex) when (ex is JsonException or InvalidDataException)
        {
            return new(board, key, "incompatible", ex is JsonException ? "JSON de disposition illisible ; original conservé, aucune importation." : ex.Message, 0, [], null);
        }
    }

    private static bool Absent(JsonElement? value) => value is null or { ValueKind: JsonValueKind.Null }
        || value is { ValueKind: JsonValueKind.String } text && text.GetString() == "";

    internal static JsonElement? Property(JsonElement value, string name)
    {
        if (value.ValueKind != JsonValueKind.Object) { throw new InvalidDataException("Objet JSON historique attendu."); }
        JsonElement? found = null;
        foreach (var property in value.EnumerateObject())
        {
            if (!property.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) { continue; }
            if (found is not null) { throw new InvalidDataException("Champ historique dupliqué."); }
            found = property.Value;
        }
        return found;
    }

    private static string? Text(JsonElement row, string key, int max)
    {
        var value = Property(row, key);
        if (value is null or { ValueKind: JsonValueKind.Null }) { return null; }
        if (value is not { ValueKind: JsonValueKind.String } text) { throw new InvalidDataException("Champ historique non textuel."); }
        var result = text.GetString()!;
        if (result.Length > max || result.Any(char.IsControl)) { throw new InvalidDataException("Champ historique hors limites."); }
        return result;
    }

    private static JsonSerializerOptions CreateJson()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return options;
    }
}
