using System.Text.Json;

namespace Domenia.App;

/// <summary>Read-only startup advice. Never follows a location supplied by a marker, restores or removes anything.</summary>
internal static class PendingRecoveryHint
{
    internal static string Describe(string root, string marker)
    {
        const string refusal = "Une mise à jour interrompue est signalée. Aucun composant applicatif n’est lancé. ";
        var storage = Path.Combine(Path.GetDirectoryName(root)!, "." + Path.GetFileName(root) + ".domenia-lifecycle");
        var id = Transaction(marker);
        var target = Quote(root);
        var transaction = id ?? "IDENTIFIANT_TRANSACTION";
        return refusal + "Conservez le marqueur et le dossier de sauvegarde « " + storage + " ». "
            + (id is null ? "Marqueur non lisible ou ancien : retrouvez l’identifiant dans ce dossier, sans supprimer de fichier. "
                : "Transaction indiquée : " + id + " ; sauvegarde attendue dans « " + Path.Combine(storage, id, "old") + " » (à vérifier par l’aperçu). ")
            + "Depuis un pack complet vérifié, extrait dans un dossier distinct : Domenia.exe livraison apercu-restauration "
            + target + " " + transaction + ". Après lecture de cet aperçu : Domenia.exe livraison restaurer "
            + target + " " + transaction + " CONFIRMATION_DE_L_APERCU. Aucun rétablissement automatique.";
    }

    private static string Quote(string path) => "\"" + string.Concat(path.Where(c => !char.IsControl(c) && c != '"')) + "\"";
    private static string? Transaction(string path)
    {
        try
        {
            for (var current = path; !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) return null;
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length is <= 0 or > 4096) return null;
            using var doc = JsonDocument.Parse(file, new JsonDocumentOptions { MaxDepth = 4 });
            var value = doc.RootElement;
            if (value.ValueKind != JsonValueKind.Object) return null;
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
                if (property.Name is not ("format" or "transaction" or "journalSha256") || !names.Add(property.Name)) return null;
            if (names.Count != 3 || !value.GetProperty("format").TryGetInt32(out var format) || format != 1) return null;
            var id = value.GetProperty("transaction").GetString(); var hash = value.GetProperty("journalSha256").GetString();
            return id is { Length: 32 } && Guid.TryParseExact(id, "N", out _) && hash is { Length: 64 } && hash.All(char.IsAsciiHexDigit) ? id : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or ArgumentException) { return null; }
    }
}
