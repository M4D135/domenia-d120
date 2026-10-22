using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

internal static class LegacySearchFile
{
    internal static ImmutableArray<SearchLegacySaved> Read(IEnumerable<string> paths, string domainDn, CancellationToken token)
    {
        foreach (var path in paths.SelectMany(p => new[] { p, p + ".bak" }))
        {
            token.ThrowIfCancellationRequested();
            CompatibleDirectoryCache.ValidateLocalPath(path);
            if (!File.Exists(path)) { continue; }
            if (new FileInfo(path).Length > 4_194_304) { throw new InvalidDataException("Préférences historiques trop volumineuses."); }
            using var json = JsonDocument.Parse(File.ReadAllBytes(path));
            var saved = Value(json.RootElement, "SavedSearches");
            if (saved is null) { return []; }
            if (saved.Value.ValueKind != JsonValueKind.Array || saved.Value.GetArrayLength() > 5000) { throw new InvalidDataException("Recherches historiques illisibles."); }
            var result = ImmutableArray.CreateBuilder<SearchLegacySaved>();
            foreach (var row in saved.Value.EnumerateArray())
            {
                var dn = Text(row, "DN");
                if (dn is null || !ScopeRules.Contains(new(domainDn, "", true), dn)) { continue; }
                var mode = Text(row, "SearchMode") ?? "OU";
                if (mode.Equals("Global", StringComparison.OrdinalIgnoreCase)) { continue; }
                var subtree = Value(row, "Subtree");
                if (subtree is { } depth && depth.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) { throw new InvalidDataException("Profondeur historique illisible."); }
                var type = Text(row, "Type")?.ToLowerInvariant() switch
                {
                    "utilisateur" or "utilisateurs" or "personnes" => SearchTypeFilter.Users,
                    "machine" or "machines" or "ordinateurs" or "postes" => SearchTypeFilter.Computers,
                    "groupe" or "groupes" => SearchTypeFilter.Groups,
                    "ou" => SearchTypeFilter.Ous,
                    _ => SearchTypeFilter.All,
                };
                result.Add(new(mode, dn, Text(row, "Name"), subtree?.GetBoolean() ?? true, type, Text(row, "Query")));
            }
            return result.ToImmutable();
        }
        return [];
    }

    private static string? Text(JsonElement row, string key) => Value(row, key) is { } value
        ? value.ValueKind == JsonValueKind.Null ? null : value.ValueKind == JsonValueKind.String ? value.GetString() : throw new InvalidDataException("Préférence historique non textuelle.") : null;

    private static JsonElement? Value(JsonElement row, string key)
    {
        if (row.ValueKind != JsonValueKind.Object) { throw new InvalidDataException("Préférence historique invalide."); }
        var found = row.EnumerateObject().Where(p => p.Name.Equals(key, StringComparison.OrdinalIgnoreCase)).ToArray();
        if (found.Length > 1) { throw new InvalidDataException("Préférence historique dupliquée."); }
        return found.Length == 0 ? null : found[0].Value;
    }
}
