using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private LocalStoreScope ReadCatalogScope(Dictionary<string, object?> row)
    {
        var key = row["scope"] as string ?? "";
        var raw = row["details"] as string ?? "";
        var reader = "Non conservé dans ce repère";
        bool? complete = key.StartsWith("attempt:", StringComparison.Ordinal) ? false : null;
        string? depth = null;
        try
        {
            var details = ReadDirectoryDetails(raw);
            complete = key.StartsWith("attempt:", StringComparison.Ordinal) ? false : details.Complete;
            depth = details.Depth;
            if (details.Reader is { Length: > 0 } login) { reader = login; }
        }
        catch (Exception error) when (error is JsonException or InvalidDataException)
        { reader = "Repère illisible : compte inconnu"; complete = null; depth = null; }
        return new((string?)row["base_dn"] ?? "", "Lecture de l’annuaire", (string?)row["server"] ?? "inconnu", reader,
            (long?)row["item_count"] ?? 0, ParseStoredDate(row["last_sync"] as string))
        { Complete = complete, Depth = depth is "Subtree" ? "sous-OU incluses" : depth is "OneLevel" ? "niveau direct" : null };
    }
}
