using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Store;

public static class BoardLayoutDefaultsFile
{
    public static BoardLayoutDefault Delivered(string board, string source = "livrée")
    {
        var items = board == "Fleet" ? FleetCatalog.DefaultLayout() : PosteBoardLayouts.Defaults(board);
        return new(board, Hash("absent:" + board), source, "Disposition livrée de " + Name(board) + ".", items);
    }
    private static string Name(string board) => board switch { "Fleet" => "l’Accueil", "Computer" => "Poste", "Software" => "Logiciels", _ => throw new InvalidDataException("Tableau inconnu.") };
    private static string Hash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    public static BoardLayoutDefault Read(string folder, string board, CancellationToken token)
    {
        var delivered = Delivered(board);
        var path = Path.Combine(folder, LegacyConfiguration.FileName);
        var bytes = LegacyBoardLayoutFile.ReadBounded(path, LegacyConfiguration.MaxBytes, token);
        if (bytes is null) return delivered;
        var sha = Convert.ToHexStringLower(SHA256.HashData(bytes));
        var content = bytes.AsSpan();
        if (content.StartsWith(new byte[] { 0xef, 0xbb, 0xbf })) content = content[3..];
        using (var document = JsonDocument.Parse(content.ToArray(), new JsonDocumentOptions { MaxDepth = 32 }))
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Configuration d’équipe illisible.");
            CheckObject(document.RootElement);
            if (document.RootElement.EnumerateObject().Any(p => string.Equals(p.Name, "Dashboard", StringComparison.OrdinalIgnoreCase) && p.Value.ValueKind != JsonValueKind.Object))
                throw new InvalidDataException("Section Dashboard d’équipe illisible.");
        }
        var team = TeamLayouts.Parse(bytes, board);
        if (team.Problem is not null) throw new InvalidDataException("Disposition d’équipe illisible : " + team.Problem);
        if (string.IsNullOrWhiteSpace(team.Text)) return delivered with { SourceSha256 = sha };
        var parsed = BoardLayoutTransfer.Examine(board, team.Text);
        if (parsed.Items.IsEmpty) return delivered with { SourceSha256 = sha, Summary = "Disposition d’équipe vide ; le défaut livré s’applique, comme dans D1." };
        if (parsed.Items.Any(i => i.Source == FleetWidgetSource.Query)) throw new InvalidDataException("Une disposition d’équipe ne peut pas imposer de requête personnelle.");
        return new(board, sha, "équipe", "Disposition d’équipe locale de " + Name(board) + ". " + parsed.Summary, parsed.Items);
    }

    public static IDisposable Hold(string folder, string board, string sha, CancellationToken token)
    {
        var current = Read(folder, board, token);
        if (current.SourceSha256 != sha) throw new InvalidDataException("La disposition d’équipe a changé depuis son aperçu ; aucun choix remplacé.");
        if (sha == Delivered(board).SourceSha256) return new EmptyLease();
        return LegacyBoardLayoutFile.HoldSources(new LegacyBoardPreview(Path.Combine(folder, LegacyConfiguration.FileName), sha,
            [new(board, null, "ready", current.Summary, current.Items.Length, current.Items, null)], []) { SourceKind = "configuration" }, board, token);
    }
    private static void CheckObject(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var keys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var property in value.EnumerateObject())
            {
                if (!keys.Add(property.Name)) throw new InvalidDataException("Configuration d’équipe ambiguë : champ dupliqué.");
                CheckObject(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array) foreach (var item in value.EnumerateArray()) CheckObject(item);
    }
    private sealed class EmptyLease : IDisposable { public void Dispose() { } }
}
