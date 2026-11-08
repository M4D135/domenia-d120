using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;

namespace Domenia.Core;

public sealed record BoardLayoutImport(string Board, string Format, string Sha256, ImmutableArray<FleetLayoutItem> Items,
    string Summary, bool NeedsQueryConsent, string? QueryBindingsSha256 = null, string? SessionStamp = null);

/// <summary>Bounded explicit board documents; no file access, no permission grant and no partial import.</summary>
public static class BoardLayoutTransfer
{
    public const string Format = "Domenia.BoardLayout.2";
    public const int MaxBytes = 65_536;
    private static readonly JsonSerializerOptions Json = CreateJson();
    private sealed record Document(string Format, string Board, DateTimeOffset ExportedUtc, ImmutableArray<FleetLayoutItem> Items);

    public static bool RequiresLibrary(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) > MaxBytes) throw new InvalidDataException("Disposition supérieure à 64 Kio.");
        using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 20 });
        var rows = document.RootElement;
        if (rows.ValueKind == JsonValueKind.Object) rows = LegacyBoardLayouts.Property(rows, "Items") ?? LegacyBoardLayouts.Property(rows, "Layout") ?? rows;
        return rows.ValueKind == JsonValueKind.Array && rows.EnumerateArray().Any(row =>
            LegacyBoardLayouts.Property(row, "Source") is { ValueKind: JsonValueKind.String } source && string.Equals(source.GetString(), "Query", StringComparison.OrdinalIgnoreCase));
    }

    public static string Export(string board, IReadOnlyList<FleetLayoutItem> items, DateTimeOffset at)
    {
        var clean = Normalize(board, items);
        if (!clean.SequenceEqual(items)) throw new InvalidDataException("Disposition inconnue ou non représentable ; aucun export transformé.");
        var text = JsonSerializer.Serialize(new Document(Format, board, at.ToUniversalTime(), clean), Json);
        if (Encoding.UTF8.GetByteCount(text) > MaxBytes) throw new InvalidDataException("Disposition supérieure à 64 Kio ; aucun export tronqué.");
        return text;
    }

    public static BoardLayoutImport Examine(string board, string text, QueryLibraryContent? library = null, string? rootDn = null)
    {
        if (board is not ("Fleet" or "Computer" or "Software")) throw new InvalidDataException("Tableau inconnu.");
        if (string.IsNullOrWhiteSpace(text) || Encoding.UTF8.GetByteCount(text) > MaxBytes)
            throw new InvalidDataException("Un document JSON de disposition de 64 Kio au plus est attendu.");
        var sha = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
        using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 20 });
        CheckDuplicates(document.RootElement);
        var root = document.RootElement;
        var format = root.ValueKind == JsonValueKind.Object ? LegacyBoardLayouts.Property(root, "Format") : null;
        if (format is not null)
        {
            var admission = ContractCatalog.Decide("board", format.Value.ValueKind == JsonValueKind.String ? format.Value.GetString() : null);
            if (!admission.Allowed) throw new InvalidDataException(admission.Message);
        }
        ImmutableArray<FleetLayoutItem> items;
        var summary = "Disposition D2 complète ; ordre, sections, tailles, visibilité, pauses et liaisons de révision conservés.";
        string? bindings = null;
        if (format is { ValueKind: JsonValueKind.String } value && value.GetString() == Format)
        {
            var parsed = root.Deserialize<Document>(Json) ?? throw new InvalidDataException("Document de disposition absent.");
            if (parsed.Board != board || parsed.Items.IsDefault || parsed.ExportedUtc == default)
                throw new InvalidDataException("Document d’un autre tableau ou incomplet.");
            items = Normalize(board, parsed.Items);
            if (!items.SequenceEqual(parsed.Items)) throw new InvalidDataException("Présentation D2 inconnue ou non représentable ; aucun import partiel.");
        }
        else
        {
            if (root.ValueKind == JsonValueKind.Object)
            {
                foreach (var property in root.EnumerateObject())
                    if (!new[] { "Format", "Board", "ExportedUtc", "Layout" }.Contains(property.Name, StringComparer.OrdinalIgnoreCase))
                        throw new InvalidDataException("Champ de document historique inconnu ; original conservé.");
                if (format is not null && (format.Value.ValueKind != JsonValueKind.String || format.Value.GetString() != "Domenia.BoardLayout.1"))
                    throw new InvalidDataException("Version de disposition inconnue.");
                var owner = LegacyBoardLayouts.Property(root, "Board");
                if (owner is not null && (owner.Value.ValueKind != JsonValueKind.String || !string.Equals(owner.Value.GetString(), board, StringComparison.OrdinalIgnoreCase)))
                    throw new InvalidDataException("Disposition historique d’un autre tableau.");
                root = LegacyBoardLayouts.Property(root, "Layout") ?? throw new InvalidDataException("Liste Layout absente.");
            }
            if (root.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Liste de widgets attendue.");
            var proposal = LegacyBoardLayouts.ParseExplicitLayout(board, root);
            if (proposal.State == "needsQueryBinding")
            {
                if (library is null || rootDn is null) throw new InvalidDataException("Bibliothèque locale nécessaire pour qualifier les requêtes demandées.");
                var preview = new LegacyBoardPreview(null, sha, [proposal], []);
                proposal = LegacyBoardLayouts.BindQueries(preview, library, rootDn).Boards.Single();
            }
            if (proposal.State != "ready") throw new InvalidDataException(proposal.Summary);
            items = Normalize(board, proposal.Items);
            summary = proposal.Summary;
            bindings = proposal.QueryBindingsSha256;
        }
        foreach (var item in items.Where(i => i.Source == FleetWidgetSource.Query))
        {
            if (library is null || rootDn is null || item.QueryBinding is null) throw new InvalidDataException("Bibliothèque locale absente ; aucune liaison supposée.");
            _ = BoardQueryBindings.Resolve(item.QueryBinding, item.Key, library, rootDn, board);
        }
        return new(board, format is { ValueKind: JsonValueKind.String } f ? f.GetString()! : "Domenia.BoardLayout.1", sha, items,
            summary, items.Any(i => i.QueryBinding?.CurrentRevisionProposed == true), bindings);
    }

    public static ImmutableArray<FleetLayoutItem> Normalize(string board, IReadOnlyList<FleetLayoutItem> items)
    {
        if (board != "Fleet") return PosteBoardLayouts.Normalize(board, items);
        if (items.Count > FleetCatalog.MaxItems || items.Any(i => i is null || i.Key is null || i.Id is not { Length: > 0 and <= 64 }
            || i.Title is { Length: > 80 } || i.Title?.Any(char.IsControl) == true || i.Group is { Length: > 80 } || i.Group?.Any(char.IsControl) == true
            || i.Height is not (null or "S" or "M" or "L")
            || i.Source == FleetWidgetSource.Query && !BoardQueryBindings.Valid(i.QueryBinding, i.Key)))
            throw new InvalidDataException("Disposition de parc invalide ; aucun élément tronqué.");
        var clean = AccueilService.Clean(items);
        if (clean.Length != items.Count) throw new InvalidDataException("Carte sans représentation ; aucun import partiel.");
        return clean;
    }

    private static void CheckDuplicates(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in value.EnumerateObject())
            { if (!names.Add(property.Name)) throw new InvalidDataException("Champ JSON dupliqué."); CheckDuplicates(property.Value); }
        }
        else if (value.ValueKind == JsonValueKind.Array) foreach (var child in value.EnumerateArray()) CheckDuplicates(child);
    }
    private static JsonSerializerOptions CreateJson()
    {
        var result = new JsonSerializerOptions(JsonSerializerDefaults.Web) { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, WriteIndented = true };
        result.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return result;
    }
}
