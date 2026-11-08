using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Core;

/// <summary>Conditional local preference write, rechecked against the latest disk document under its interprocess lock.</summary>
public interface IConditionalPreferenceStore
{
    Task<bool> TryAddWithEvidenceAsync(string key, JsonElement value, string evidenceKey, JsonElement evidence, CancellationToken token,
        Func<CancellationToken, IDisposable>? qualifySources = null);
}

public sealed record LegacyBoardProposal(string Board, string? Setting, string State, string Summary, int Count,
    ImmutableArray<FleetLayoutItem> Items, [property: JsonIgnore] string? OriginalLayout, bool ChoiceExists = false)
{
    public LegacyBoardTeamSource? TeamSource { get; init; }
    public string? QueryBindingsSha256 { get; init; }
}

public sealed record LegacyBoardPreview(string? SourcePath, string? SourceSha256, ImmutableArray<LegacyBoardProposal> Boards,
    ImmutableArray<string> Warnings, bool FleetChoiceExists = false, bool Available = true, string? Reason = null)
{
    public string SourceKind { get; init; } = "settings";
}

/// <summary>D1 settings, not a SQLite table. Pure conversion; no source is rewritten and no query library implies a layout.</summary>
public static partial class LegacyBoardLayouts
{
    public const string EvidenceKey = "accueil.layoutMigration";
    public const int MaxLayoutBytes = 65_536;
    private static readonly JsonSerializerOptions Json = CreateJson();

    public static LegacyBoardPreview Parse(JsonElement settings, string path, string sha256, LegacyBoardConfiguration? configuration = null)
    {
        if (settings.ValueKind != JsonValueKind.Object) { throw new InvalidDataException("Les préférences D1 doivent être une table JSON."); }
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in settings.EnumerateObject())
        {
            if (names.Count >= 4096 || !names.Add(property.Name)) { throw new InvalidDataException("Préférences D1 trop nombreuses ou dupliquées."); }
        }
        return new(path, sha256, [.. new[] { "Fleet", "Computer", "Software" }.Select(board => Proposal(settings, board, configuration))], []);
    }

    /// <summary>Explicit file import: keeps its rows, never upgrades a historical delivered default implicitly.</summary>
    public static LegacyBoardProposal ParseExplicitLayout(string board, JsonElement rows)
    {
        if (board is not ("Fleet" or "Computer" or "Software")) throw new InvalidDataException("Tableau inconnu.");
        var settings = JsonSerializer.SerializeToElement(new Dictionary<string, string> { ["Dashboard." + board + ".Layout"] = rows.GetRawText() });
        return Proposal(settings, board, recognizeDelivered: false);
    }

    public static bool HasFleetChoice(IPreferenceStore store) => store.TryGet(AccueilService.LayoutPreference, out _) || store.TryGet(EvidenceKey, out _);

    public static Task<bool> ApplyFleetAsync(LegacyBoardPreview preview, string expectedSha256,
        IConditionalPreferenceStore store, DateTimeOffset now, CancellationToken token)
        => ApplyAsync(preview, "Fleet", expectedSha256, store, now, token);

    public static async Task<bool> ApplyAsync(LegacyBoardPreview preview, string board, string expectedSha256,
        IConditionalPreferenceStore store, DateTimeOffset now, CancellationToken token, string? expectedConfigurationSha256 = null,
        Func<CancellationToken, IDisposable>? qualifySources = null, string? expectedQueryBindingsSha256 = null)
    {
        token.ThrowIfCancellationRequested();
        if (expectedSha256 is not { Length: 64 } || !expectedSha256.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'))
            || !string.Equals(preview.SourceSha256, expectedSha256, StringComparison.Ordinal))
        { throw new InvalidDataException("Les préférences D1 ont changé depuis l’aperçu ; relisez-les avant d’importer."); }
        if (board is not ("Fleet" or "Computer" or "Software")) { throw new InvalidDataException("Tableau historique inconnu."); }
        var fleet = preview.Boards.Single(p => p.Board == board);
        if (!string.Equals(fleet.TeamSource?.Sha256, expectedConfigurationSha256, StringComparison.Ordinal))
        { throw new InvalidDataException("La disposition d’équipe D1 a changé depuis l’aperçu ; relisez les sources avant d’importer."); }
        if (fleet.QueryBindingsSha256 != expectedQueryBindingsSha256)
        { throw new InvalidDataException("Liaisons de requêtes modifiées ou non confirmées ; relisez l’aperçu."); }
        if (fleet.State != "ready" || fleet.OriginalLayout is null || preview.SourcePath is null)
        { throw new InvalidDataException("Aucune disposition compatible à importer pour ce tableau."); }
        var personal = fleet.Items.Where(item => item.Source == FleetWidgetSource.Probe && PersonalProbeCatalog.IsKey(item.Key))
            .Select(item => item.Key).Distinct(StringComparer.Ordinal).ToArray();
        if (personal.Length > 0)
        {
            if (store is not IPreferenceStore preferences) { throw new InvalidDataException("Catalogue personnel du profil indisponible ; aucune disposition importée."); }
            _ = await ProfileProbeCatalog.ResolveAsync(preferences, personal, token).ConfigureAwait(false);
        }
        var destination = board == "Fleet" ? AccueilService.LayoutPreference : PosteBoardLayouts.PreferenceKey(board);
        var evidenceKey = board == "Fleet" ? EvidenceKey : PosteBoardLayouts.EvidenceKey(board);
        var layout = JsonSerializer.SerializeToElement(new { version = 1, items = fleet.Items }, Json);
        var evidence = JsonSerializer.SerializeToElement(new
        {
            version = 1, sourcePath = preview.SourcePath, sourceSha256 = expectedSha256, setting = fleet.Setting,
            originalLayout = fleet.OriginalLayout, importedAt = now, board, destination, sourceKind = preview.SourceKind,
            queryBindingsSha256 = fleet.QueryBindingsSha256, queryBindings = fleet.Items.Where(i => i.QueryBinding is not null).Select(i => new { i.Id, i.QueryBinding }),
            configuration = fleet.TeamSource is { } team ? new
            { sourcePath = team.Path, sourceSha256 = team.Sha256, setting = team.Setting, originalLayout = team.OriginalLayout } : null,
        }, Json);
        return await store.TryAddWithEvidenceAsync(destination, layout, evidenceKey, evidence, token, qualifySources).ConfigureAwait(false);
    }

    private static LegacyBoardProposal Proposal(JsonElement settings, string board, LegacyBoardConfiguration? configuration = null, bool recognizeDelivered = true)
    {
        var key = "Dashboard." + board + ".Layout";
        var value = Property(settings, key);
        var legacy = false;
        if (Absent(value) && configuration is not null && TeamProposal(settings, board, configuration) is { } team)
        { return team; }
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
            if (!legacy && recognizeDelivered && DeliveredProposal(board, key, original, rows, configuration) is { } delivered)
            { return delivered; }
            if (board != "Fleet")
            { return PosteBoardLayouts.ConvertLegacy(board, key, legacy, original, rows); }
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
            return new(board, key, items.Any(i => i.Source == FleetWidgetSource.Query) ? "needsQueryBinding" : "ready", summary, items.Count, [.. items], original);
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
