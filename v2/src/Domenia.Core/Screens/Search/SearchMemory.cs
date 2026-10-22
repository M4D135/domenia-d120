using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>A recent search or object (FO-03, UX-09): « search » or « object », newest first.</summary>
public sealed record SearchRecent(string Kind, string Text, string? Type, string? Dn, DateTimeOffset At);

/// <summary>An OU pinned above the tree (FO-04): a perimeter only, never a result, an account, a right or a write mode.</summary>
public sealed record SearchFavorite(string Dn, string Name, string Label, string Path, bool Subtree, SearchTypeFilter Type, string Term);

/// <summary>One sort criterion of a saved layout.</summary>
public sealed record SearchSortKey(string Id, int Dir);

/// <summary>Layout of the grid kept by a personal view: column keys and sizes only, never a row.</summary>
public sealed record SearchLayout(ImmutableArray<string> Order, ImmutableArray<string> Hidden, ImmutableDictionary<string, int> Widths, ImmutableArray<SearchSortKey> Sort, string Density);

/// <summary>Personal view (points 56 to 60): OU, depth, type, presence, local filter, limit, columns and sort, per domain.</summary>
public sealed record SearchWorkspace(
    string Id,
    string Name,
    string Label,
    string OuDn,
    bool Subtree,
    SearchTypeFilter Type,
    string Presence,
    string Filter,
    int Limit,
    string ColumnSet,
    SearchLayout? Layout,
    DateTimeOffset SavedAt);

/// <summary>Everything the search screen remembers for the domain of the session (result of search.memory).</summary>
public sealed record SearchMemoryState(
    ImmutableArray<SearchRecent> Recents,
    ImmutableArray<SearchFavorite> Favorites,
    ImmutableArray<SearchWorkspace> Workspaces,
    ImmutableArray<string> QueryFavorites,
    SearchWorkspace? Undo,
    int MaxFavorites,
    int MaxWorkspaces,
    bool Persistent,
    string? Warning,
    int Imported = 0);

/// <summary>Request to save a personal view, as the page sends it (validated by <see cref="SearchMemoryRules.Workspace"/>).</summary>
public sealed record SearchWorkspaceDraft(string Name, string OuDn, bool Subtree, SearchTypeFilter Type, string Presence, string Filter, int Limit, string ColumnSet, SearchLayout? Layout);

/// <summary>
/// Pure rules of what the search screen remembers, ported from Domenia 1 (Domenia-Shell.Model.ps1 recent entries,
/// Domenia-Search.Model.ps1 OU favourites, Domenia-SearchWorkspace.Model.ps1 personal views). Bounded, validated, flat.
/// </summary>
public static partial class SearchMemoryRules
{
    public const int MaxRecentsPerKind = 8;
    public const int MaxFavorites = 50;
    public const int MaxWorkspaces = 100;
    public const int MaxQueryFavorites = 200;
    public const int MaxStoreBytes = 1_048_576;

    public static readonly ImmutableArray<string> PresenceFilters = ["all", "online", "noReply", "error", "unknown"];
    public static readonly ImmutableArray<string> ColumnSets = ["mixed", "users", "computers"];

    /// <summary>One line, no control character, bounded (Domenia 1 ConvertTo-DomeniaFlatText).</summary>
    public static string Flat(string? text, int max)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }
        var builder = new StringBuilder(Math.Min(text.Length, max + 1));
        var space = false;
        foreach (var c in text)
        {
            if (char.IsControl(c) || char.IsWhiteSpace(c))
            {
                space = builder.Length > 0;
                continue;
            }
            if (space)
            {
                builder.Append(' ');
                space = false;
            }
            builder.Append(c);
            if (builder.Length >= max)
            {
                break;
            }
        }
        return builder.ToString().Trim();
    }

    /// <summary>
    /// Newest first, one entry per kind and text (per DN for an object), at most eight of each kind; a search of less than
    /// two characters is not kept (Domenia 1 Add-DomeniaRecentEntry).
    /// </summary>
    public static ImmutableArray<SearchRecent> AddRecent(IEnumerable<SearchRecent> entries, string kind, string? text, string? type, string? dn, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(entries);
        var clean = Flat(text, 80);
        var list = new List<SearchRecent>();
        if (clean.Length >= (kind == "search" ? SearchLimits.MinChars : 1))
        {
            list.Add(new SearchRecent(kind, clean, NullIfEmpty(Flat(type, 20)), NullIfEmpty(Flat(dn, 400)), at));
        }
        var count = list.Count;
        foreach (var entry in entries)
        {
            if (entry.Kind == kind)
            {
                var same = string.Equals(entry.Text, clean, StringComparison.OrdinalIgnoreCase);
                if (kind == "object" && !string.IsNullOrWhiteSpace(dn) && !string.IsNullOrWhiteSpace(entry.Dn))
                {
                    same = string.Equals(entry.Dn, dn, StringComparison.OrdinalIgnoreCase);
                }
                if (same || count >= MaxRecentsPerKind)
                {
                    continue;
                }
                count++;
            }
            list.Add(entry);
        }
        return [.. list];
    }

    /// <summary>
    /// An OU favourite of the session domain (FO-04): DN inside the domain, never the domain itself; short name; depth;
    /// type; optional term of the visible local filter. Null when refused (the reason is given).
    /// </summary>
    public static (SearchFavorite? Favorite, string Reason) Favorite(string dn, string? name, bool subtree, SearchTypeFilter type, string? term, string rootDn, string dnsName)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(rootDn);
        var value = dn.Trim();
        if (value.Length is 0 or > 2048 || !Within(value, rootDn))
        {
            return (null, "OU invalide ou hors du domaine de cette session.");
        }
        if (SearchLists.IsRoot(value, rootDn))
        {
            return (null, "Le domaine entier ne s’épingle pas" + FrenchText.Colon + "choisissez une OU.");
        }
        var label = Flat(name, 80);
        if (label.Length == 0)
        {
            label = Flat(SearchTexts.Leaf(value), 80);
        }
        if (label.Length == 0)
        {
            return (null, "OU invalide ou hors du domaine de cette session.");
        }
        return (new SearchFavorite(value, label, label, SearchTexts.Path(value, dnsName), subtree, type, Flat(term, 120)), "");
    }

    /// <summary>
    /// Two OUs of the same name are told apart by their nearest differing parents: « Commercial (Lyon) » and « Commercial
    /// (Paris) » (Domenia 1 Get-DomeniaOuDistinctLabels). Display only: the DN stays the identity.
    /// </summary>
    public static ImmutableArray<SearchFavorite> DistinctLabels(IReadOnlyList<SearchFavorite> favorites)
    {
        ArgumentNullException.ThrowIfNull(favorites);
        var names = favorites.Select(f => OuNames(f.Dn)).ToList();
        var labels = favorites.Select(f => f.Name).ToArray();
        foreach (var group in Enumerable.Range(0, favorites.Count).GroupBy(i => favorites[i].Name, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1))
        {
            var members = group.ToList();
            var unique = false;
            for (var depth = 1; depth <= 64 && !unique; depth++)
            {
                var exhausted = true;
                foreach (var i in members)
                {
                    var parents = names[i];
                    var take = Math.Min(depth, parents.Count - 1);
                    var qualifier = take > 0 ? string.Join(" / ", parents.Skip(1).Take(take).Reverse()) : "racine du domaine";
                    if (parents.Count - 1 > depth)
                    {
                        exhausted = false;
                    }
                    labels[i] = favorites[i].Name + " (" + qualifier + ")";
                }
                unique = members.Select(i => labels[i]).Distinct(StringComparer.OrdinalIgnoreCase).Count() == members.Count;
                if (exhausted)
                {
                    break;
                }
            }
            if (!unique)
            {
                foreach (var i in members)
                {
                    labels[i] = favorites[i].Name + " (" + favorites[i].Path + ")";
                }
            }
        }
        return [.. favorites.Select((f, i) => f with { Label = labels[i] })];
    }

    /// <summary>
    /// A personal view checked strictly (Domenia 1 ConvertTo-DomeniaSearchWorkspace): name of 1 to 80 characters, an OU or a
    /// container of the domain (never the bare root), limit of 1 to 20 000, known type and presence, local filter of 120
    /// characters at most, layout bounded. Nothing else is kept: no row, no account, no right.
    /// </summary>
    public static (SearchWorkspace? Workspace, string Reason) Workspace(SearchWorkspaceDraft draft, string rootDn, string dnsName, string id, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(draft);
        ArgumentNullException.ThrowIfNull(rootDn);
        var name = (draft.Name ?? "").Trim();
        if (name.Length is 0 or > 80 || name.Any(char.IsControl))
        {
            return (null, "Nom de vue invalide" + FrenchText.Colon + "de 1 à 80 caractères, sur une ligne.");
        }
        var dn = (draft.OuDn ?? "").Trim();
        if (dn.Length is 0 or > 2048 || !Within(dn, rootDn) || SearchLists.IsRoot(dn, rootDn))
        {
            return (null, "Une OU ou un conteneur du domaine est requis" + FrenchText.Colon + "une vue ne porte jamais sur la racine seule.");
        }
        if (draft.Limit is < 1 or > SearchLimits.MaxLimit)
        {
            return (null, "Limite de vue invalide" + FrenchText.Colon + "de 1 à 20 000 lignes.");
        }
        if (!PresenceFilters.Contains(draft.Presence) || !ColumnSets.Contains(draft.ColumnSet))
        {
            return (null, "Filtre de présence ou jeu de colonnes inconnu.");
        }
        var filter = draft.Filter ?? "";
        if (filter.Length > 120)
        {
            return (null, "Filtre de vue trop long (120 caractères au plus).");
        }
        SearchLayout? layout = null;
        if (draft.Layout is SearchLayout given)
        {
            if (!ValidLayout(given))
            {
                return (null, "Disposition des colonnes invalide.");
            }
            layout = given;
        }
        var workspace = new SearchWorkspace(id, name, "", dn, draft.Subtree, draft.Type, draft.Presence, filter, draft.Limit, draft.ColumnSet, layout, at);
        return (workspace with { Label = WorkspaceLabel(workspace, dnsName) }, "");
    }

    /// <summary>« nom · OU et sous-OU · type » (Domenia 1 Get-DomeniaSearchWorkspaceLabel).</summary>
    public static string WorkspaceLabel(SearchWorkspace workspace, string dnsName)
    {
        ArgumentNullException.ThrowIfNull(workspace);
        var names = OuNames(workspace.OuDn);
        var place = names.Count > 0 ? names[0] : SearchTexts.Path(workspace.OuDn, dnsName);
        var parts = new List<string> { workspace.Name, place + (workspace.Subtree ? " et sous-OU" : " seulement") };
        if (workspace.Type != SearchTypeFilter.All)
        {
            parts.Add(SearchText.TypeLabel(workspace.Type));
        }
        return string.Join(" · ", parts);
    }

    /// <summary>
    /// Name proposed for a saved search from what is visible: « Vue : … », « Domaine entier : … », « OU : texte »
    /// (Domenia 1 Get-DomeniaFavouriteName, RCH-137): flat, 80 characters at most.
    /// </summary>
    public static string ProposedName(bool global, string? text, string? ouName, string? viewName)
    {
        var query = (text ?? "").Trim();
        string name;
        if (!string.IsNullOrWhiteSpace(viewName))
        {
            name = "Vue" + FrenchText.Colon + viewName;
        }
        else if (global)
        {
            name = "Domaine entier" + FrenchText.Colon + (query.Length > 0 ? query : "tout");
        }
        else
        {
            var ou = string.IsNullOrWhiteSpace(ouName) ? "OU" : ouName;
            name = ou + (query.Length > 0 ? FrenchText.Colon + query : "");
        }
        return Flat(name, 80);
    }

    /// <summary>
    /// One-time takeover of the saved searches of Domenia 1 (FO-04, RCH-004): only an OU search becomes a favourite (its text
    /// goes to the visible local filter); a whole-domain text search has no OU to pin. The existing favourite wins on the same
    /// DN; at most <see cref="MaxFavorites"/>. The source list is never modified.
    /// </summary>
    public static (ImmutableArray<SearchFavorite> Favorites, int Imported) ImportLegacy(IReadOnlyList<SearchFavorite> existing,
        IEnumerable<(string Mode, string Dn, string? Name, bool Subtree, SearchTypeFilter Type, string? Query)> saved, string rootDn, string dnsName)
    {
        ArgumentNullException.ThrowIfNull(existing);
        ArgumentNullException.ThrowIfNull(saved);
        var list = existing.Take(MaxFavorites).ToList();
        var seen = new HashSet<string>(list.Select(f => f.Dn), StringComparer.OrdinalIgnoreCase);
        var imported = 0;
        foreach (var item in saved)
        {
            if (item.Mode == "global" || list.Count >= MaxFavorites)
            {
                continue;
            }
            var (favorite, _) = Favorite(item.Dn, item.Name, item.Subtree, item.Type, item.Query, rootDn, dnsName);
            if (favorite is null || !seen.Add(favorite.Dn))
            {
                continue;
            }
            list.Add(favorite);
            imported++;
        }
        return ([.. list], imported);
    }

    /// <summary>A query favourite identifier: « ad:&lt;view&gt; » or « local:&lt;query&gt; ».</summary>
    public static bool IsQueryId(string? id) => id is not null && QueryIdPattern().IsMatch(id);

    /// <summary>Domain part of the preference keys: SHA-256 of the canonical root DN (as the working OU, OPERATIONS.md § 11).</summary>
    public static string DomainKey(string rootDn)
    {
        ArgumentNullException.ThrowIfNull(rootDn);
        var canonical = DistinguishedName.Format(DistinguishedName.Parse(rootDn)).ToUpperInvariant();
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
    }

    /// <summary>True when the DN lies inside the domain (sub-OUs included); a malformed DN never does.</summary>
    public static bool Within(string dn, string rootDn)
    {
        try
        {
            return SearchLists.IsRoot(dn, rootDn) || DistinguishedName.IsWithin(dn, rootDn, subtree: true);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    /// <summary>OU and container names of a DN from the leaf upward, DC components left out.</summary>
    public static IReadOnlyList<string> OuNames(string dn)
    {
        try
        {
            return [.. DistinguishedName.Parse(dn).Where(n => !string.Equals(n.Type, "DC", StringComparison.OrdinalIgnoreCase)).Select(n => n.Value)];
        }
        catch (FormatException)
        {
            return [];
        }
    }

    private static bool ValidLayout(SearchLayout layout)
    {
        bool Key(string id) => ColumnKeyPattern().IsMatch(id);
        return layout.Order.Length <= 100 && layout.Order.All(Key)
            && layout.Hidden.Length <= 100 && layout.Hidden.All(Key)
            && layout.Widths.Count <= 100 && layout.Widths.All(p => Key(p.Key) && p.Value is >= 40 and <= 1600)
            && layout.Sort.Length <= 4 && layout.Sort.All(s => Key(s.Id) && s.Dir is 1 or -1)
            && layout.Density is "compact" or "normal" or "comfortable";
    }

    private static string? NullIfEmpty(string text) => text.Length == 0 ? null : text;

    [GeneratedRegex("^[A-Za-z][A-Za-z0-9_]{0,79}$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex ColumnKeyPattern();

    [GeneratedRegex(@"^(ad|local):[a-z][a-z0-9.]{0,60}$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex QueryIdPattern();
}

/// <summary>
/// What the search screen remembers in the local preferences (LocalWrite, never the directory): recent searches and objects,
/// OU favourites and personal views per domain, query favourites. A write that fails never fails the operation: the value
/// stays for the session and the result says so (PLATFORM.md § 5).
/// </summary>
public sealed class SearchMemory : IDisposable
{
    private const string Prefix = "search.";

    private static readonly JsonSerializerOptions Json = CreateJson();

    private readonly IPreferenceStore preferences;
    private readonly OperationJournal journal;
    private readonly TimeProvider clock;
    private readonly ITechnicalJournal log;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<string, SearchWorkspace> undo = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> versions = new(StringComparer.Ordinal);

    public SearchMemory(IPreferenceStore preferences, OperationJournal journal, TimeProvider clock, ITechnicalJournal log)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        ArgumentNullException.ThrowIfNull(journal);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        this.preferences = preferences;
        this.journal = journal;
        this.clock = clock;
        this.log = log;
    }

    /// <summary>The memory shared by the modules of the context.</summary>
    public static SearchMemory From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new SearchMemory(c.Preferences, c.Journal, c.Clock, c.Log));
    }

    public async Task<SearchMemoryState> StateAsync(DomainIdentity domain, CancellationToken cancellationToken,
        Func<CancellationToken, Task<ImmutableArray<SearchLegacySaved>>>? legacy = null)
    {
        var (root, dns, key) = Domain(domain);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var imported = legacy is null ? 0 : await ImportLegacyOnceAsync(key, root, dns, legacy, cancellationToken).ConfigureAwait(false);
            return State(key, root, dns, null) with { Imported = imported };
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// First display of a domain: the saved searches of Domenia 1 become OU favourites once (RCH-004). A read that fails is
    /// traced and tried again next time; once done, the flag of the domain stops any further takeover. The source list is
    /// never modified.
    /// </summary>
    private async Task<int> ImportLegacyOnceAsync(string key, string root, string dns, Func<CancellationToken, Task<ImmutableArray<SearchLegacySaved>>> legacy,
        CancellationToken cancellationToken)
    {
        var flag = Key("legacyImported", key);
        if (preferences.TryGet(flag, out _))
        {
            return 0;
        }
        ImmutableArray<SearchLegacySaved> saved;
        try
        {
            saved = await legacy(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or DomeniaOperationException)
        {
            log.Warning($"Recherches enregistrées de Domenia 1 non lues : {ex.GetType().Name}.");
            return 0;
        }
        var existing = Read<SearchFavorite>(Key("favorites", key));
        var (favorites, imported) = SearchMemoryRules.ImportLegacy(existing, [.. saved.Select(s => (s.Mode, s.Dn, s.Name, s.Subtree, s.Type, s.Query))], root, dns);
        try
        {
            if (imported > 0)
            {
                await preferences.SetAsync(Key("favorites", key), Element(favorites), cancellationToken).ConfigureAwait(false);
            }
            await preferences.SetAsync(flag, JsonSerializer.SerializeToElement(true), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Préférences non enregistrées (Rechercher, reprise des recherches de Domenia 1) : {ex.GetType().Name}.");
        }
        if (imported > 0)
        {
            journal.Add(new JournalEntry(clock.GetUtcNow(), "Recherches enregistrées de Domenia 1 reprises" + FrenchText.Colon + FrenchText.Count(imported, "OU en favori", "OU en favoris")
                + " (une seule fois ; la liste d’origine est conservée)", Tone.Info));
        }
        return imported;
    }

    public Task<SearchMemoryState> AddRecentAsync(DomainIdentity domain, string kind, string text, string? type, string? dn, CancellationToken cancellationToken) =>
        ChangeAsync(domain, (key, root, dns) =>
        {
            var recents = SearchMemoryRules.AddRecent(Read<SearchRecent>(Key("recents", key)), kind, text, type, dn, clock.GetUtcNow());
            return [(Key("recents", key), Element(recents))];
        }, "recherches récentes", cancellationToken);

    public Task<SearchMemoryState> ClearRecentsAsync(DomainIdentity domain, CancellationToken cancellationToken) =>
        ChangeAsync(domain, (key, _, _) => [(Key("recents", key), null)], "recherches récentes", cancellationToken);

    /// <summary>Pins an OU (FO-04). <paramref name="exists"/> confirms the OU in the local index first (null: no index).</summary>
    public Task<SearchMemoryState> PinAsync(DomainIdentity domain, string dn, string? name, bool subtree, SearchTypeFilter type, string? term, bool? exists, CancellationToken cancellationToken) =>
        ChangeAsync(domain, (key, root, dns) =>
        {
            if (exists == false)
            {
                throw new DomeniaOperationException("search.favoriteRefused", "Cette OU n’est pas connue localement" + FrenchText.Colon + "elle n’a pas été épinglée.");
            }
            var (favorite, reason) = SearchMemoryRules.Favorite(dn, name, subtree, type, term, root, dns);
            if (favorite is null)
            {
                throw new DomeniaOperationException("search.favoriteRefused", reason);
            }
            var list = Read<SearchFavorite>(Key("favorites", key)).ToList();
            var at = list.FindIndex(f => string.Equals(f.Dn, favorite.Dn, StringComparison.OrdinalIgnoreCase));
            if (at >= 0)
            {
                // Pinning again keeps the place and updates depth, type and term.
                list[at] = favorite;
            }
            else
            {
                if (list.Count >= SearchMemoryRules.MaxFavorites)
                {
                    throw new DomeniaOperationException("search.favoriteRefused", FrenchText.Integer(SearchMemoryRules.MaxFavorites) + " favoris au maximum" + FrenchText.Colon + "retirez un favori avant d’en ajouter un.");
                }
                list.Add(favorite);
            }
            return [(Key("favorites", key), Element(list))];
        }, "favoris d’OU", cancellationToken);

    public Task<SearchMemoryState> UnpinAsync(DomainIdentity domain, string dn, CancellationToken cancellationToken) =>
        ChangeAsync(domain, (key, _, _) =>
        {
            var list = Read<SearchFavorite>(Key("favorites", key)).ToList();
            if (list.RemoveAll(f => SameDn(f.Dn, dn)) == 0)
            {
                throw new DomeniaOperationException("search.favoriteRefused", "Cette OU n’est pas dans les favoris.");
            }
            return [(Key("favorites", key), Element(list))];
        }, "favoris d’OU", cancellationToken);

    /// <summary>Moves a favourite to a new place (improvement of FO-04: the operator orders the favourites).</summary>
    public Task<SearchMemoryState> MoveAsync(DomainIdentity domain, string dn, int index, CancellationToken cancellationToken) =>
        ChangeAsync(domain, (key, _, _) =>
        {
            var list = Read<SearchFavorite>(Key("favorites", key)).ToList();
            var at = list.FindIndex(f => SameDn(f.Dn, dn));
            if (at < 0)
            {
                throw new DomeniaOperationException("search.favoriteRefused", "Cette OU n’est pas dans les favoris.");
            }
            var item = list[at];
            list.RemoveAt(at);
            list.Insert(Math.Clamp(index, 0, list.Count), item);
            return [(Key("favorites", key), Element(list))];
        }, "favoris d’OU", cancellationToken);

    public Task<SearchMemoryState> SaveWorkspaceAsync(DomainIdentity domain, SearchWorkspaceDraft draft, CancellationToken cancellationToken) =>
        ChangeAsync(domain, (key, root, dns) =>
        {
            var list = Read<SearchWorkspace>(Key("workspaces", key)).ToList();
            if (list.Count >= SearchMemoryRules.MaxWorkspaces)
            {
                throw new DomeniaOperationException("search.workspaceRefused", "Cent vues sont déjà enregistrées. Retirez une vue devenue inutile.");
            }
            var id = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
            var (workspace, reason) = SearchMemoryRules.Workspace(draft, root, dns, id, clock.GetUtcNow());
            if (workspace is null)
            {
                throw new DomeniaOperationException("search.workspaceRefused", reason);
            }
            if (list.Any(w => string.Equals(w.Name.Trim(), workspace.Name, StringComparison.OrdinalIgnoreCase)))
            {
                throw new DomeniaOperationException("search.workspaceRefused", "Une vue porte déjà ce nom dans ce domaine. Choisissez un autre nom ou retirez l’ancienne vue.");
            }
            list.Add(workspace);
            var element = Element(list);
            if (Encoding.UTF8.GetByteCount(element.GetRawText()) > SearchMemoryRules.MaxStoreBytes)
            {
                throw new DomeniaOperationException("search.workspaceRefused", "Bibliothèque de vues trop volumineuse.");
            }
            undo.Remove(key);
            return [(Key("workspaces", key), element)];
        }, "vues personnelles", cancellationToken);

    /// <summary>Removes a view of this domain; « Annuler » restores it while the views did not change since (Domenia 1 Undo-DomeniaSearchWorkspace).</summary>
    public Task<SearchMemoryState> RemoveWorkspaceAsync(DomainIdentity domain, string id, CancellationToken cancellationToken) =>
        ChangeAsync(domain, (key, _, _) =>
        {
            var list = Read<SearchWorkspace>(Key("workspaces", key)).ToList();
            var at = list.FindIndex(w => string.Equals(w.Id, id, StringComparison.Ordinal));
            if (at < 0)
            {
                throw new DomeniaOperationException("search.workspaceUnknown", "Vue introuvable dans ce domaine" + FrenchText.Colon + "rien n’a été retiré.");
            }
            undo[key] = list[at];
            list.RemoveAt(at);
            return [(Key("workspaces", key), Element(list))];
        }, "vues personnelles", cancellationToken, keepUndo: true);

    public Task<SearchMemoryState> UndoRemoveAsync(DomainIdentity domain, CancellationToken cancellationToken) =>
        ChangeAsync(domain, (key, _, _) =>
        {
            if (!undo.Remove(key, out var removed))
            {
                throw new DomeniaOperationException("search.workspaceUnknown", "Aucun retrait à annuler" + FrenchText.Colon + "les vues ont changé depuis.");
            }
            var list = Read<SearchWorkspace>(Key("workspaces", key)).ToList();
            if (list.Count >= SearchMemoryRules.MaxWorkspaces || list.Any(w => string.Equals(w.Name, removed.Name, StringComparison.OrdinalIgnoreCase)))
            {
                throw new DomeniaOperationException("search.workspaceRefused", "Le retrait ne peut plus être annulé" + FrenchText.Colon + "une vue porte déjà ce nom.");
            }
            list.Add(removed);
            return [(Key("workspaces", key), Element(list))];
        }, "vues personnelles", cancellationToken);

    public Task<SearchMemoryState> SetQueryFavoriteAsync(DomainIdentity domain, string id, bool favorite, CancellationToken cancellationToken) =>
        ChangeAsync(domain, (_, _, _) =>
        {
            if (!SearchMemoryRules.IsQueryId(id))
            {
                throw new DomeniaOperationException("search.queryUnknown", "Requête inconnue" + FrenchText.Colon + "rien n’a été changé.");
            }
            var list = Read<string>(Prefix + "queryFavorites").Where(SearchMemoryRules.IsQueryId).ToList();
            list.RemoveAll(x => string.Equals(x, id, StringComparison.Ordinal));
            if (favorite)
            {
                if (list.Count >= SearchMemoryRules.MaxQueryFavorites)
                {
                    throw new DomeniaOperationException("search.queryRefused", FrenchText.Integer(SearchMemoryRules.MaxQueryFavorites) + " favoris de requête au maximum.");
                }
                list.Add(id);
            }
            return [(Prefix + "queryFavorites", Element(list))];
        }, "favoris de requête", cancellationToken);

    /// <summary>Query favourites (shared by every domain, as Search.QueryFavorites in Domenia 1).</summary>
    public ImmutableArray<string> QueryFavorites() => [.. Read<string>(Prefix + "queryFavorites").Where(SearchMemoryRules.IsQueryId)];

    public void Dispose() => gate.Dispose();

    private async Task<SearchMemoryState> ChangeAsync(DomainIdentity domain, Func<string, string, string, IReadOnlyList<(string Key, JsonElement? Value)>> change, string what,
        CancellationToken cancellationToken, bool keepUndo = false)
    {
        var (root, dns, key) = Domain(domain);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var writes = change(key, root, dns);
            if (!keepUndo && writes.Any(w => w.Key == Key("workspaces", key)))
            {
                undo.Remove(key);
            }
            string? warning = null;
            foreach (var (preference, value) in writes)
            {
                try
                {
                    await preferences.SetAsync(preference, value, cancellationToken).ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    log.Warning($"Préférences non enregistrées (Rechercher, {what}) : {ex.GetType().Name}.");
                    warning = "Préférences non enregistrées" + FrenchText.Colon + "les " + what + " valent pour cette session.";
                    journal.Add(new JournalEntry(clock.GetUtcNow(), warning, Tone.Warn));
                }
            }
            versions[key] = versions.GetValueOrDefault(key) + 1;
            return State(key, root, dns, warning);
        }
        finally
        {
            gate.Release();
        }
    }

    private SearchMemoryState State(string key, string root, string dns, string? warning)
    {
        var favorites = Read<SearchFavorite>(Key("favorites", key))
            .Select(f => SearchMemoryRules.Favorite(f.Dn, f.Name, f.Subtree, f.Type, f.Term, root, dns).Favorite)
            .OfType<SearchFavorite>().Take(SearchMemoryRules.MaxFavorites).ToList();
        var workspaces = Read<SearchWorkspace>(Key("workspaces", key))
            .Where(w => w.Id.Length == 32 && SearchMemoryRules.Within(w.OuDn, root))
            .Select(w => w with { Label = SearchMemoryRules.WorkspaceLabel(w, dns) })
            .OrderBy(w => w.Name, StringComparer.OrdinalIgnoreCase).Take(SearchMemoryRules.MaxWorkspaces);
        var recents = Read<SearchRecent>(Key("recents", key)).Where(r => r.Kind is "search" or "object" && r.Text.Length > 0).Take(2 * SearchMemoryRules.MaxRecentsPerKind);
        return new SearchMemoryState([.. recents], SearchMemoryRules.DistinctLabels(favorites), [.. workspaces], QueryFavorites(),
            undo.GetValueOrDefault(key), SearchMemoryRules.MaxFavorites, SearchMemoryRules.MaxWorkspaces, preferences.Persistent, warning);
    }

    private IReadOnlyList<T> Read<T>(string key)
    {
        if (!preferences.TryGet(key, out var value) || value.ValueKind != JsonValueKind.Array)
        {
            return [];
        }
        var list = new List<T>();
        foreach (var item in value.EnumerateArray())
        {
            try
            {
                if (item.Deserialize<T>(Json) is T read)
                {
                    list.Add(read);
                }
            }
            catch (JsonException)
            {
                // An unreadable entry is left out; the next write keeps only the readable ones.
                log.Warning("Préférence de Rechercher illisible ignorée (" + key.Split('.')[1] + ").");
            }
        }
        return list;
    }

    private static JsonElement Element<T>(IEnumerable<T> values) => JsonSerializer.SerializeToElement(values.ToList(), Json);

    private static string Key(string what, string domainKey) => Prefix + what + "." + domainKey;

    private static (string Root, string Dns, string Key) Domain(DomainIdentity domain)
    {
        ArgumentNullException.ThrowIfNull(domain);
        if (domain.RootDn is not string root || domain.DnsName is not string dns)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        }
        try
        {
            return (root, dns, SearchMemoryRules.DomainKey(root));
        }
        catch (FormatException)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        }
    }

    private static bool SameDn(string left, string right)
    {
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
        }
    }

    private static JsonSerializerOptions CreateJson()
    {
        var options = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return options;
    }
}
