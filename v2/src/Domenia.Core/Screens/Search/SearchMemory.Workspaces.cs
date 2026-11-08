using System.Text.Json;

namespace Domenia.Core;

public sealed partial class SearchMemory
{
    private static string? WorkspaceId(JsonElement raw)
    {
        try { return LegacySearchWorkspaces.Property(raw, "Id") is { ValueKind: JsonValueKind.String } value
            && Guid.TryParse(value.GetString(), out var id) ? id.ToString("N") : null; }
        catch (InvalidDataException) { return null; }
    }

    private SearchWorkspaceStore WorkspaceStore(string domainKey) => SearchWorkspaceStore.Read(
        preferences.TryGet(Key("workspaces", domainKey), out var value) ? value : null);

    private static IReadOnlyList<(int Index, SearchWorkspace View)> ReadableWorkspaces(SearchWorkspaceStore store, string root, string dns)
    {
        var result = new List<(int, SearchWorkspace)>(); var ids = new HashSet<string>(StringComparer.Ordinal);
        for (var i = 0; i < store.Entries.Length; i++)
        {
            var raw = store.Entries[i]; SearchWorkspace? view = null;
            try
            {
                if (raw.ValueKind != JsonValueKind.Object) continue;
                if (raw.EnumerateObject().Select(p => p.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != raw.EnumerateObject().Count()) continue;
                if (LegacySearchWorkspaces.Property(raw, "Version") is not null) view = LegacySearchWorkspaces.Read(raw, root, dns);
                else if (raw.Deserialize<SearchWorkspace>(Json) is { } stored && stored.Id is { Length: 32 }
                    && Guid.TryParseExact(stored.Id, "N", out var id) && id != Guid.Empty && Enum.IsDefined(stored.Type))
                {
                    var draft = new SearchWorkspaceDraft(stored.Name, stored.OuDn, stored.Subtree, stored.Type, stored.Presence,
                        stored.Filter, stored.Limit, stored.ColumnSet, stored.Layout);
                    view = SearchMemoryRules.Workspace(draft, root, dns, stored.Id, stored.SavedAt).Workspace;
                }
            }
            catch (Exception ex) when (ex is JsonException or InvalidDataException or InvalidOperationException or ArgumentException) { }
            if (view is not null && ids.Add(view.Id)) result.Add((i, view));
        }
        return result;
    }

    private async Task<string?> ImportWorkspacesAsync(string key, Func<CancellationToken, Task<JsonElement?>> read, CancellationToken token)
    {
        try
        {
            if (WorkspaceStore(key).LegacyImported) return null;
            var raw = await read(token).ConfigureAwait(false);
            if (raw is null) return null; // Source may appear later; absence is never a permanent receipt.
            var incoming = SearchWorkspaceStore.Read(raw);
            if (preferences is not IAtomicPreferenceStore atomic)
                return "Vues D1 conservées dans leur fichier : ce magasin ne permet pas une reprise atomique.";
            _ = await atomic.UpdateAsync(Key("workspaces", key), current =>
            {
                var existing = SearchWorkspaceStore.Read(current);
                if (existing.LegacyImported) return current;
                // Raw foreign/malformed records count toward 100 and survive all future modifications.
                return new SearchWorkspaceStore([.. existing.Entries, .. incoming.Entries], true).Encode();
            }, token).ConfigureAwait(false);
            return "Vues D1 reprises dans les préférences locales ; fichier d’origine conservé. Les dispositions sans équivalent restent conservées et ne sont pas proposées.";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidDataException or DomeniaOperationException)
        {
            log.Warning("Reprise des vues D1 non appliquée : " + ex.GetType().Name + ". Source conservée.");
            return "Reprise des vues D1 non appliquée ; source conservée. Vérifiez son format, sa taille et l’accès aux préférences.";
        }
    }
}
