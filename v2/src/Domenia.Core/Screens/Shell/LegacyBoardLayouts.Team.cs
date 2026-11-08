using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Domenia.Core;

/// <summary>A separately qualified, bounded configuration read; its bytes never come from the browser.</summary>
public sealed record LegacyBoardConfiguration(string Path, string Sha256, JsonElement Values);
public sealed record LegacyBoardTeamSource(string Path, string Sha256, string Setting, [property: JsonIgnore] string OriginalLayout);

public static partial class LegacyBoardLayouts
{
    /// <summary>Team defaults precede old probe additions only when no personal Dashboard layout exists.</summary>
    private static LegacyBoardProposal? TeamProposal(JsonElement settings, string board, LegacyBoardConfiguration configuration)
    {
        var teamKey = "Dashboard.DefaultLayout" + board;
        LegacyBoardTeamSource? source = null;
        try
        {
            var dashboard = Property(configuration.Values, "Dashboard");
            if (dashboard is null or { ValueKind: JsonValueKind.Null }) { return null; }
            var value = Property(dashboard.Value, "DefaultLayout" + board);
            if (value is null or { ValueKind: JsonValueKind.Null }) { return null; }
            // Preserve the exact selected value, not unrelated configuration fields (which may contain credentials).
            var original = value.Value.GetRawText();
            var text = value.Value.ValueKind switch
            {
                JsonValueKind.String => value.Value.GetString()!,
                JsonValueKind.Array or JsonValueKind.Object => original,
                _ => throw new InvalidDataException("Disposition d’équipe ni texte JSON, ni liste, ni document exporté."),
            };
            if (string.IsNullOrWhiteSpace(text)) { return null; }
            if (Encoding.UTF8.GetByteCount(text) > MaxLayoutBytes || Encoding.UTF8.GetByteCount(original) > MaxLayoutBytes * 2)
            { throw new InvalidDataException("Disposition d’équipe au-delà de la limite de 64 Kio ; aucune importation."); }
            source = new(configuration.Path, configuration.Sha256, teamKey, original);
            using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 16 });
            var rows = document.RootElement;
            if (rows.ValueKind == JsonValueKind.Object)
            {
                var format = Text(rows, "Format", 80);
                var owner = Text(rows, "Board", 32);
                if (format is { Length: > 0 } && format != "Domenia.BoardLayout.1")
                { throw new InvalidDataException("Format du document d’équipe inconnu."); }
                if (owner is { Length: > 0 } && !owner.Equals(board, StringComparison.OrdinalIgnoreCase))
                { throw new InvalidDataException("Le document d’équipe appartient à un autre tableau."); }
                rows = Property(rows, "Layout") ?? throw new InvalidDataException("Liste Layout absente du document d’équipe.");
            }
            if (rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > 64)
            { throw new InvalidDataException("La disposition d’équipe doit contenir au plus 64 widgets."); }
            // D1 does not let an empty team layout empty the board. A personal "[]" still wins before this function.
            if (rows.GetArrayLength() == 0) { return null; }
            var combined = rows.EnumerateArray().Select(row => row.Clone()).ToList();
            foreach (var row in combined)
            {
                if (Text(row, "Source", 16)?.Equals("Query", StringComparison.OrdinalIgnoreCase) == true)
                { throw new InvalidDataException("Une requête personnelle ne constitue pas une disposition d’équipe partageable ; aucune importation partielle."); }
            }
            var legacyKey = "Widgets." + board;
            var legacyValue = board is "Computer" or "Fleet" ? Property(settings, legacyKey) : null;
            string? legacyOriginal = null;
            if (!Absent(legacyValue))
            {
                if (legacyValue is not { ValueKind: JsonValueKind.String } legacyText)
                { throw new InvalidDataException("Les anciennes sondes doivent être un texte JSON."); }
                legacyOriginal = legacyText.GetString()!;
                if (Encoding.UTF8.GetByteCount(legacyOriginal) > MaxLayoutBytes)
                { throw new InvalidDataException("Anciennes sondes au-delà de la limite de 64 Kio."); }
                using var legacyDocument = JsonDocument.Parse(legacyOriginal, new JsonDocumentOptions { MaxDepth = 16 });
                if (legacyDocument.RootElement.ValueKind != JsonValueKind.Array || legacyDocument.RootElement.GetArrayLength() > 64)
                { throw new InvalidDataException("Liste historique de sondes attendue, 64 éléments au plus."); }
                foreach (var row in legacyDocument.RootElement.EnumerateArray())
                {
                    var id = Text(row, "Id", 64);
                    var paused = Property(row, "Paused");
                    if (paused is { ValueKind: not (JsonValueKind.True or JsonValueKind.False or JsonValueKind.Null) })
                    { throw new InvalidDataException("État Paused D1 non booléen."); }
                    combined.Add(JsonSerializer.SerializeToElement(new
                    {
                        Source = "Probe", Key = Text(row, "ProbeId", 80) ?? "", Id = string.IsNullOrEmpty(id) ? "" : "p-" + id,
                        Visual = Text(row, "Visual", 32), Title = Text(row, "Title", 80), Size = Text(row, "Size", 8),
                        Group = Text(row, "Group", 80), Paused = paused is { ValueKind: JsonValueKind.True },
                    }));
                }
            }
            if (combined.Count > 64) { throw new InvalidDataException("Disposition d’équipe et anciennes sondes dépassent ensemble 64 widgets ; aucun élément tronqué."); }
            var merged = JsonSerializer.Serialize(combined);
            var synthetic = JsonSerializer.SerializeToElement(new Dictionary<string, string> { ["Dashboard." + board + ".Layout"] = merged });
            // The same closed catalogs and actual consumers decide compatibility. Never drop one unsupported item.
            var converted = Proposal(synthetic, board, recognizeDelivered: false);
            return converted with
            {
                Setting = legacyOriginal is null ? teamKey : legacyKey,
                OriginalLayout = converted.State == "ready" ? legacyOriginal ?? text : null,
                TeamSource = source,
                Summary = converted.State == "ready" ? "Disposition d’équipe locale reprise avant les anciennes sondes. " + converted.Summary
                    + " Les deux sources sont revérifiées et conservées avec leurs empreintes." : converted.Summary,
            };
        }
        catch (Exception ex) when (ex is JsonException or InvalidDataException)
        {
            return new(board, teamKey, "incompatible", ex is JsonException ? "Disposition d’équipe JSON illisible ; aucune importation partielle." : ex.Message,
                0, [], null) { TeamSource = source };
        }
    }
}
