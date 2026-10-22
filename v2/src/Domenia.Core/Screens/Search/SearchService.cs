using System.Collections.Concurrent;
using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>Error codes of the search screen (docs/ops/rechercher.md § 4).</summary>
public static class SearchErrors
{
    public const string TextInvalid = "search.textInvalid";
    public const string ListUnknown = "search.listUnknown";
    public const string ListUnknownMessage = "Liste inconnue ou trop ancienne" + FrenchText.Colon + "relancez la recherche.";
    public const string ListComplete = "search.listComplete";
    public const string ListBusy = "search.listBusy";
    public const string ListBusyMessage = "Lecture en cours" + FrenchText.Colon + "attendez la fin du chargement.";
    public const string ViewUnknown = "search.viewUnknown";
    public const string ViewUnknownMessage = "Vue inconnue" + FrenchText.Colon + "rien n’a été lu.";
    public const string ObjectUnknown = "search.objectUnknown";
    public const string ObjectUnknownMessage = "Objet inconnu de la base locale" + FrenchText.Colon + "rien n’est affiché.";
    public const string CompareInvalid = "search.compareInvalid";
    public const string SurveyRefused = "search.surveyRefused";
    public const string SurveyBusy = "search.surveyBusy";
    public const string SurveyBusyMessage = "Un relevé de la liste est déjà en cours" + FrenchText.Colon + "arrêtez-le ou attendez sa fin.";
    public const string SurveyPlanUnknown = "search.surveyPlanUnknown";
    public const string SurveyPlanUnknownMessage = "Plan de relevé inconnu, déjà utilisé ou expiré" + FrenchText.Colon + "rien n’est lu. Relancez la confirmation.";
    public const string SurveyTypedCount = "search.surveyTypedCount";
    public const string ChecksSuspended = "search.checksSuspended";
    public const string NotWorkstation = "search.notWorkstation";
    public const string NotWorkstationMessage = "Cette ligne n’est pas un poste actif" + FrenchText.Colon + "aucune sonde n’est envoyée.";
}

/// <summary>Reverse DNS lookup on an explicit gesture (R40).</summary>
public sealed record SearchDnsResult(string Ip, string? Name, string Message);

/// <summary>Objects of a list read again (RCH-073): fresh rows, those no longer found (never a proof of deletion).</summary>
public sealed record SearchRevalidation(ImmutableArray<SearchRow> Rows, ImmutableArray<string> Missing, DateTimeOffset CheckedAt, string Summary);

/// <summary>Answer of search.survey.stop.</summary>
public sealed record SurveyStop(bool Stopped, string Message);

/// <summary>Surveys of the session: the resume plan of an interrupted survey and the suspension of the selection checks (RCH-082).</summary>
public sealed record SearchSurveyState(SurveyResume? Resume, bool ChecksSuspended, string SuspendedReason);

/// <summary>Rows of the local base shown while the directory read of a simple search goes on (event « search.run:cached », RCH-055).</summary>
public sealed record SearchCached(string Text, ImmutableArray<SearchRow> Rows, string SourceLabel, DateTimeOffset ReadAt);

/// <summary>
/// Engine service of the search screen, shared by its module: runs the reads through the reader of the mode, keeps the lists
/// for the explicit continuation (« Charger la suite »: only the following rows, never read twice), and the survey in progress
/// (one per screen, stoppable). Nothing is ever read without a call of the page, nothing is replayed.
/// </summary>
public sealed class SearchService : IDisposable
{
    private const int MaxLists = 24;
    private const int MaxPlans = 16;
    private const int MeasuresPage = 250;
    /// <summary>Preference of Paramètres that holds the survey budgets (concurrency, maxTargets): read here, never written.</summary>
    private const string CollectionSettingsKey = "settings.collection";
    private const string ProfileKey = "collection.profile";
    private static readonly TimeSpan PlanLifetime = TimeSpan.FromMinutes(10);

    private readonly EngineContext context;
    private readonly Lock gate = new();
    private readonly Dictionary<string, ListState> lists = new(StringComparer.Ordinal);
    private readonly Queue<string> order = new();
    private readonly ConcurrentDictionary<string, CancellationTokenSource> runs = new(StringComparer.Ordinal);
    private readonly Dictionary<string, PendingSurvey> plans = new(StringComparer.Ordinal);
    private ResumeState? resumeState;
    private string? checksSuspended;
    private int surveyCount;
    private int surveyRunning;
    private Func<JsonElement?> configuration = static () => null;

    public SearchService(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        this.context = context;
    }

    /// <summary>The search service shared by the modules of the context.</summary>
    public static SearchService From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new SearchService(c));
    }

    /// <summary>
    /// The host hands the reading of Domenia.config.json (its root, or null without a file): the settings an administrator
    /// gives to this screen (revalidation of the listed objects, hidden or greyed actions). Read on demand, never written.
    /// </summary>
    public void UseConfiguration(Func<JsonElement?> read)
    {
        ArgumentNullException.ThrowIfNull(read);
        configuration = read;
    }

    /// <summary>search.policy: settings of the administrator and survey budgets of Paramètres (RCH-067, RCH-073, RCH-090, RCH-093).</summary>
    public SearchPolicy Policy()
    {
        JsonElement? config;
        try
        {
            config = configuration();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            context.Log.Warning("search.policy : Domenia.config.json illisible (" + ex.GetType().Name + ") : réglages par défaut.");
            config = null;
        }
        JsonElement? settings = context.Preferences.TryGet(CollectionSettingsKey, out var value) ? value : null;
        return SearchPolicyRules.Read(config, settings);
    }

    private TimeZoneInfo Zone => context.Clock.LocalTimeZone;

    /// <summary>search.run: the bar (global, or one OU chosen by its chip), or an address of the local readings.</summary>
    public async Task<SearchResult> RunAsync(string text, string? scopeDn, SearchTypeFilter type, int limit, SearchMatchMode match, CancellationToken cancellationToken,
        Action<SearchCached>? onCached = null)
    {
        var (root, dns) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var plan = SearchText.Plan(text, type, match);
        if (!plan.Valid)
        {
            throw new DomeniaOperationException(SearchErrors.TextInvalid, plan.Reason);
        }
        var reader = context.Readers.Require<ISearchReader>();
        if (plan.Kind == SearchPlanKind.Address && plan.Address is SearchAddress address)
        {
            var page = await reader.FindAddressAsync(address, limit, cancellationToken).ConfigureAwait(false);
            var scopeAll = SearchLists.Scope(true, root, root, dns, true);
            var state = Register(new ListState(SearchListKind.Address, plan, type, root, true, null, text.Trim(), match, scopeAll, null) { Address = address });
            var result = Complete(state, page, limit, appended: false);
            if (result.Rows.IsEmpty && address.Kind == "ipv4")
            {
                result = result with
                {
                    Dns = new SearchDnsOffer(address.Value, "Chercher dans le DNS",
                        "Résolution inverse de " + address.Value + " (15" + FrenchText.Nbsp + "s au plus), puis recherche normale du nom trouvé. Aucun paquet ne part avant ce clic."),
                };
            }
            Journal("Recherche par " + address.Label + " " + FrenchText.Quote(address.Value) + FrenchText.Colon + FrenchText.Count(result.Loaded, "poste", "postes"), Tone.Info);
            return result;
        }
        var baseDn = root;
        if (scopeDn is not null && !SearchLists.IsRoot(scopeDn, root))
        {
            baseDn = await RequireBaseAsync(reader, scopeDn, root, cancellationToken).ConfigureAwait(false);
        }
        var scope = SearchLists.Scope(true, baseDn, root, dns, true);
        var list = Register(new ListState(SearchListKind.Search, plan, type, baseDn, true, null, text.Trim(), match, scope, null));
        if (onCached is not null && SearchText.IsSimple(plan))
        {
            // A simple search shows the rows of the local base at once, marked with their date; the directory rows replace them.
            var cached = await reader.CachedAsync(new SearchQuery(SearchListKind.Search, plan, type, baseDn, true, null, null, new HashSet<string>(StringComparer.Ordinal), limit), cancellationToken)
                .ConfigureAwait(false);
            if (!cached.Rows.IsEmpty)
            {
                onCached(new SearchCached(text.Trim(), cached.Rows, cached.SourceLabel, cached.ReadAt));
            }
        }
        var found = await ReadAsync(list, reader, limit, appended: false, cancellationToken).ConfigureAwait(false);
        Journal("Recherche " + FrenchText.Quote(SearchMemoryRules.Flat(text, 60)) + FrenchText.Colon + FrenchText.Count(found.Loaded, "résultat", "résultats") + (found.LimitReached ? " (liste limitée)" : ""), Tone.Info);
        return found;
    }

    /// <summary>search.browse: content of an OU (or of the whole domain, listed only: never surveyed), own empty filter.</summary>
    public async Task<SearchResult> BrowseAsync(string dn, bool subtree, SearchTypeFilter type, int limit, CancellationToken cancellationToken)
    {
        var (root, dns) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var reader = context.Readers.Require<ISearchReader>();
        var baseDn = SearchLists.IsRoot(dn, root) ? root : await RequireBaseAsync(reader, dn, root, cancellationToken).ConfigureAwait(false);
        var whole = SearchLists.IsRoot(baseDn, root);
        var scope = SearchLists.Scope(false, baseDn, root, dns, whole || subtree);
        var list = Register(new ListState(SearchListKind.Browse, SearchText.BrowsePlan(type), type, baseDn, whole || subtree, null, "", SearchMatchMode.Prefix, scope, null));
        return await ReadAsync(list, reader, limit, appended: false, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>search.view: a ready-made view on the OU (or, explicitly, on the whole domain: then no survey is offered).</summary>
    public async Task<SearchResult> ViewAsync(string viewId, string? dn, bool subtree, bool wholeDomain, int limit, CancellationToken cancellationToken)
    {
        var (root, dns) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var reader = context.Readers.Require<ISearchReader>();
        var view = SearchViews.All(context.Clock.GetUtcNow()).FirstOrDefault(v => v.Id == viewId)
            ?? throw new DomeniaOperationException(SearchErrors.ViewUnknown, SearchErrors.ViewUnknownMessage);
        if (!wholeDomain && (dn is null || SearchLists.IsRoot(dn, root)))
        {
            // The whole domain is an explicit choice (wholeDomain), never the silent fallback of a missing OU.
            throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Arguments invalides" + FrenchText.Colon + "choisissez une OU, ou demandez explicitement tout le domaine.");
        }
        var baseDn = wholeDomain || SearchLists.IsRoot(dn!, root) ? root : await RequireBaseAsync(reader, dn!, root, cancellationToken).ConfigureAwait(false);
        var whole = SearchLists.IsRoot(baseDn, root);
        var depth = whole || subtree;
        const string survey = "Vue sur tout le domaine" + FrenchText.Colon + "aucun relevé des postes (ping, détection, analyse) n’est proposé sur cette liste.";
        var info = new SearchViewInfo(view.Id, view.Name, view.Note, whole, !whole, whole ? survey : "");
        var plan = new SearchPlan(SearchPlanKind.View, true, "", view.Note, [], [], null, null, view.LdapFilter, view.Cost.StartsWith("Filtre bit", StringComparison.Ordinal), "");
        var scope = SearchLists.Scope(false, baseDn, root, dns, depth);
        var list = Register(new ListState(SearchListKind.View, plan, view.Type, baseDn, depth, view.Id, "", SearchMatchMode.Prefix, scope, info));
        var result = await ReadAsync(list, reader, limit, appended: false, cancellationToken).ConfigureAwait(false);
        Journal("Vue " + FrenchText.Quote(view.Name) + FrenchText.Colon + FrenchText.Count(result.Loaded, "résultat", "résultats"), Tone.Info);
        return result;
    }

    /// <summary>search.localQuery: a delivered local query on the workstations of an OU (local base only).</summary>
    public async Task<SearchResult> LocalQueryAsync(string queryId, string dn, bool subtree, string verdict, int limit, CancellationToken cancellationToken)
    {
        var (root, dns) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var reader = context.Readers.Require<ISearchReader>();
        var query = SearchViews.LocalQueries.FirstOrDefault(q => q.Id == queryId)
            ?? throw new DomeniaOperationException(SearchErrors.ViewUnknown, SearchErrors.ViewUnknownMessage);
        var baseDn = SearchLists.IsRoot(dn, root) ? root : await RequireBaseAsync(reader, dn, root, cancellationToken).ConfigureAwait(false);
        var whole = SearchLists.IsRoot(baseDn, root);
        var scope = SearchLists.Scope(false, baseDn, root, dns, whole || subtree);
        var plan = new SearchPlan(SearchPlanKind.LocalQuery, true, "", query.Description, [], [], null, null, "", false, "");
        var info = new SearchViewInfo(query.Id, query.Name, query.Description, whole, !whole,
            whole ? "Requête sur tout le domaine" + FrenchText.Colon + "aucun relevé des postes n’est proposé sur cette liste." : "");
        var state = Register(new ListState(SearchListKind.LocalQuery, plan, SearchTypeFilter.Computers, baseDn, whole || subtree, query.Id, "", SearchMatchMode.Prefix, scope, info) { Verdict = verdict });
        var (page, totals) = await reader.LocalQueryAsync(query.Id, baseDn, whole || subtree, verdict, limit, cancellationToken).ConfigureAwait(false);
        return Complete(state, page, limit, appended: false) with { Verdicts = totals };
    }

    /// <summary>
    /// search.selection (REQ-048, Domenia 1 « Appliquer aux résultats de Recherche »): the objects frozen by the query workshop,
    /// read from the local data by GUID (never the network), in the order of the selection, unknown GUIDs left out and counted.
    /// The list is complete at once (5 000 objects at most): it is never continued.
    /// </summary>
    public async Task<SearchResult> SelectionAsync(IReadOnlyList<Guid> ids, string label, DateTimeOffset frozenAt, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(ids);
        ArgumentNullException.ThrowIfNull(label);
        var (root, dns) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var reader = context.Readers.Require<ISearchReader>();
        var distinct = ids.Distinct().Take(SearchLimits.MaxLimit).ToArray();
        var rows = await reader.LocalRowsAsync(distinct, cancellationToken).ConfigureAwait(false);
        var byId = new Dictionary<Guid, SearchRow>();
        foreach (var row in rows)
        {
            if (Guid.TryParse(row.Id, out var guid))
            {
                byId.TryAdd(guid, row);
            }
        }
        var ordered = distinct.Where(byId.ContainsKey).Select(id => byId[id]).ToImmutableArray();
        var missing = distinct.Length - ordered.Length;
        var stamp = FrenchText.Quote(label) + " · figée le " + frozenAt.ToOffset(context.Clock.LocalTimeZone.GetUtcOffset(frozenAt)).ToString("dd/MM/yyyy HH:mm", CultureInfo.InvariantCulture);
        var note = missing > 0 ? stamp + " · " + FrenchText.Count(missing, "objet absent des données locales", "objets absents des données locales") : stamp;
        var plan = new SearchPlan(SearchPlanKind.Selection, true, "", note, [], [], null, null, "", false, "");
        var info = new SearchViewInfo("selection", "Sélection de l’atelier de requêtes", note, false, true, "");
        var scope = SearchLists.Scope(true, root, root, dns, true);
        var state = Register(new ListState(SearchListKind.Selection, plan, SearchTypeFilter.All, root, true, "selection", "", SearchMatchMode.Prefix, scope, info));
        return Complete(state, new SearchPage(ordered, false, null, context.Clock.GetUtcNow(), "Données locales"), Math.Max(1, ordered.Length), appended: false);
    }

    /// <summary>search.more: the following rows of a list only (MO-07), up to <paramref name="target"/> rows in all.</summary>
    public async Task<SearchResult> MoreAsync(string listId, int target, CancellationToken cancellationToken)
    {
        var state = RequireList(listId);
        if (!state.LimitReached)
        {
            throw new DomeniaOperationException(SearchErrors.ListComplete, "Liste complète" + FrenchText.Colon + "aucune suite à charger.");
        }
        if (target <= state.Loaded || target > SearchLimits.MaxLimit)
        {
            throw new DomeniaOperationException(SearchErrors.ListComplete, "Taille demandée hors des bornes" + FrenchText.Colon + "de " + FrenchText.Integer(state.Loaded + 1) + " à " + FrenchText.Integer(SearchLimits.MaxLimit) + " lignes.");
        }
        var reader = context.Readers.Require<ISearchReader>();
        // Every kind of list takes the same busy mark: two « Charger la suite » close together never read twice.
        return await WithBusyAsync(state, async () =>
        {
            switch (state.Kind)
            {
                case SearchListKind.Address when state.Address is SearchAddress address:
                    {
                        var page = await reader.FindAddressAsync(address, target, cancellationToken).ConfigureAwait(false);
                        var known = KnownOf(state);
                        return Complete(state, page with { Rows = [.. page.Rows.Where(r => !known.Contains(r.Id))] }, target, appended: true);
                    }
                case SearchListKind.LocalQuery:
                    {
                        var (page, totals) = await reader.LocalQueryAsync(state.ViewId!, state.BaseDn, state.Subtree, state.Verdict ?? "match", target, cancellationToken).ConfigureAwait(false);
                        var known = KnownOf(state);
                        return Complete(state, page with { Rows = [.. page.Rows.Where(r => !known.Contains(r.Id))] }, target, appended: true) with { Verdicts = totals };
                    }
                default:
                    return await ReadCoreAsync(state, reader, target, appended: true, cancellationToken).ConfigureAwait(false);
            }
        }).ConfigureAwait(false);
    }

    /// <summary>
    /// search.reconcile: the list read again with its own filter, perimeter, type and size (RCH-047). New objects of the
    /// perimeter are added, objects moved out of it keep their row (followed by their GUID), objects not found again are
    /// to be checked again: never removed, never a proof of deletion (RCH-048). A checkpoint of the read is kept.
    /// </summary>
    public async Task<SearchReconcile> ReconcileAsync(string listId, CancellationToken cancellationToken)
    {
        var state = RequireList(listId);
        var reader = context.Readers.Require<ISearchReader>();
        return await WithBusyAsync(state, async () =>
        {
            var known = KnownOf(state);
            var take = Math.Clamp(Math.Max(state.Loaded, state.Limit), 1, SearchLimits.MaxLimit);
            SearchPage page;
            switch (state.Kind)
            {
                case SearchListKind.Address when state.Address is SearchAddress address:
                    page = await reader.FindAddressAsync(address, take, cancellationToken).ConfigureAwait(false);
                    break;
                case SearchListKind.LocalQuery:
                    (page, _) = await reader.LocalQueryAsync(state.ViewId!, state.BaseDn, state.Subtree, state.Verdict ?? "match", take, cancellationToken).ConfigureAwait(false);
                    break;
                case SearchListKind.Selection:
                    {
                        // The frozen selection is read again from the local data, same objects, same order (REQ-048).
                        Guid[] frozen;
                        lock (gate)
                        {
                            frozen = [.. state.Order.Select(id => Guid.TryParse(id, out var g) ? g : Guid.Empty).Where(g => g != Guid.Empty)];
                        }
                        page = new SearchPage(await reader.LocalRowsAsync(frozen, cancellationToken).ConfigureAwait(false), false, null, context.Clock.GetUtcNow(), "Données locales");
                        break;
                    }
                default:
                    page = await reader.FindAsync(new SearchQuery(state.Kind, state.Plan, state.Type, state.BaseDn, state.Subtree, state.ViewId, null,
                        new HashSet<string>(StringComparer.Ordinal), take), cancellationToken).ConfigureAwait(false);
                    break;
            }
            var fresh = state.Kind == SearchListKind.Search
                ? [.. page.Rows.Select(r => r with { Rank = SearchMatcher.Rank(r, state.Text) })]
                : page.Rows;
            var freshIds = fresh.Select(r => r.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var added = fresh.Where(r => !known.Contains(r.Id)).Select(r => r.Id).ToImmutableArray();
            var gone = known.Where(id => !freshIds.Contains(id)).ToList();
            ImmutableArray<SearchRow> moved = [];
            ImmutableArray<string> missing = [];
            // Only a read that came back complete can say an object left the perimeter; beyond its size nothing is judged.
            if (!page.More && gone.Count > 0)
            {
                moved = await reader.RereadAsync([.. gone.Take(500).Select(Guid.Parse)], cancellationToken).ConfigureAwait(false);
                var found = moved.Select(r => r.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
                missing = [.. gone.Take(500).Where(id => !found.Contains(id))];
            }
            int sequence;
            int loaded;
            lock (gate)
            {
                foreach (var id in added)
                {
                    if (state.Known.Add(id))
                    {
                        state.Order.Add(id);
                    }
                }
                state.Loaded += added.Length;
                state.Checkpoint++;
                sequence = state.Checkpoint;
                loaded = state.Loaded;
            }
            var checkpoint = "Point de reprise" + FrenchText.Colon + page.SourceLabel + ", lecture n°" + FrenchText.Nbsp + FrenchText.Integer(sequence) + " du " + SearchDetails.When(page.ReadAt, Zone);
            var parts = new List<string> { FrenchText.Count(fresh.Length, "objet relu", "objets relus") };
            if (!added.IsEmpty)
            {
                parts.Add(FrenchText.Count(added.Length, "nouvel objet", "nouveaux objets") + " dans le périmètre");
            }
            if (!moved.IsEmpty)
            {
                parts.Add(FrenchText.Count(moved.Length, "objet sorti", "objets sortis") + " du périmètre ou du filtre, " + (moved.Length > 1 ? "suivis" : "suivi") + " par " + (moved.Length > 1 ? "leur" : "son") + " identifiant");
            }
            if (!missing.IsEmpty)
            {
                parts.Add(FrenchText.Count(missing.Length, "objet à revérifier", "objets à revérifier") + " (une absence ne prouve pas une suppression)");
            }
            var summary = "Liste revérifiée à " + SearchDetails.When(page.ReadAt, Zone)[11..] + FrenchText.Colon + string.Join(" · ", parts) + ".";
            Journal("Revérification de la liste" + FrenchText.Colon + string.Join(" · ", parts), added.IsEmpty && missing.IsEmpty ? Tone.Info : Tone.Warn);
            return new SearchReconcile(state.Id, [.. fresh, .. moved], added, [.. moved.Select(r => r.Id)], missing, loaded, checkpoint, page.ReadAt, summary);
        }).ConfigureAwait(false);
    }

    /// <summary>search.measures: stored measures of the rows of a list, from the local base, by pages of 250 (RCH-083).</summary>
    public async Task<SearchMeasures> MeasuresAsync(string listId, int offset, CancellationToken cancellationToken)
    {
        var state = RequireList(listId);
        List<string> order;
        lock (gate)
        {
            order = [.. state.Order];
        }
        var ids = order.Skip(Math.Max(0, offset)).Take(MeasuresPage).Select(Guid.Parse).ToList();
        var rows = ids.Count == 0 ? [] : await context.Readers.Require<ISearchReader>().LocalRowsAsync(ids, cancellationToken).ConfigureAwait(false);
        var next = offset + MeasuresPage < order.Count ? offset + MeasuresPage : (int?)null;
        return new SearchMeasures(rows, offset, next, order.Count, context.Clock.GetUtcNow());
    }

    /// <summary>search.preload: the fiche of the single row selected read again (RCH-129), to refresh its row (RCH-077).</summary>
    public async Task<SearchPreload> PreloadAsync(Guid id, CancellationToken cancellationToken)
    {
        var rows = await context.Readers.Require<ISearchReader>().RereadAsync([id], cancellationToken).ConfigureAwait(false);
        if (rows.Length != 1)
        {
            throw new DomeniaOperationException(SearchErrors.ObjectUnknown, "Objet introuvable à la relecture" + FrenchText.Colon + "il a pu être déplacé, supprimé ou masqué pour ce compte.");
        }
        return new SearchPreload(rows[0], context.Mode == AppMode.Simulation ? "Annuaire fictif" : "Annuaire en direct", context.Clock.GetUtcNow());
    }

    /// <summary>search.containers: containers of the domain root for the tree (Users, Computers, system containers folded apart).</summary>
    public Task<ImmutableArray<SearchContainer>> ContainersAsync(bool counts, CancellationToken cancellationToken) =>
        context.Readers.Require<ISearchReader>().ContainersAsync(counts, cancellationToken);

    /// <summary>search.suggest: objects of the local base for the field (8 at most), never a directory request.</summary>
    public Task<ImmutableArray<SearchSuggestion>> SuggestAsync(string text, SearchTypeFilter type, CancellationToken cancellationToken) =>
        context.Readers.Require<ISearchReader>().SuggestAsync(text.Trim(), type, SearchLimits.Suggestions, cancellationToken);

    /// <summary>search.preview: stored fiche of one object (local base).</summary>
    public async Task<SearchPreview> PreviewAsync(Guid id, CancellationToken cancellationToken) =>
        await context.Readers.Require<ISearchReader>().PreviewAsync(id, cancellationToken).ConfigureAwait(false)
        ?? throw new DomeniaOperationException(SearchErrors.ObjectUnknown, SearchErrors.ObjectUnknownMessage);

    /// <summary>search.compare: two to eight objects of one kind (local base).</summary>
    public async Task<SearchComparison> CompareAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(ids);
        var distinct = ids.Distinct().ToList();
        if (distinct.Count is < SearchDetails.MinCompared or > SearchDetails.MaxCompared)
        {
            throw new DomeniaOperationException(SearchErrors.CompareInvalid, "Comparez de deux à huit objets.");
        }
        var reader = context.Readers.Require<ISearchReader>();
        var rows = await reader.LocalRowsAsync(distinct, cancellationToken).ConfigureAwait(false);
        if (rows.Length != distinct.Count)
        {
            throw new DomeniaOperationException(SearchErrors.CompareInvalid, "Un objet n’est pas connu de la base locale" + FrenchText.Colon + "rien n’est comparé.");
        }
        if (rows.Select(r => r.Kind).Distinct().Count() != 1 || rows[0].Kind is not (SearchObjectKind.Computer or SearchObjectKind.User))
        {
            throw new DomeniaOperationException(SearchErrors.CompareInvalid, "Comparez des objets d’un même type" + FrenchText.Colon + "des postes entre eux, ou des comptes utilisateurs entre eux.");
        }
        return await reader.CompareAsync(distinct, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>search.dns.reverse: reverse lookup of an IPv4 on the operator’s click (R40); never automatic.</summary>
    public async Task<SearchDnsResult> ReverseDnsAsync(string ip, CancellationToken cancellationToken)
    {
        var address = SearchText.ParseAddress(ip);
        if (address?.Kind != "ipv4")
        {
            throw new DomeniaOperationException(SearchErrors.TextInvalid, "Saisissez une adresse IPv4 complète pour la résolution inverse.");
        }
        var name = await context.Readers.Require<ISearchReader>().ReverseDnsAsync(address.Value, cancellationToken).ConfigureAwait(false);
        Journal("Résolution DNS inverse de " + address.Value + FrenchText.Colon + (name ?? "aucun nom"), name is null ? Tone.Warn : Tone.Info);
        return new SearchDnsResult(address.Value, name, name is null
            ? "Aucun nom trouvé dans le DNS pour " + address.Value + FrenchText.Colon + "une absence de réponse ne prouve pas qu’aucun poste n’utilise cette adresse."
            : "Nom trouvé" + FrenchText.Colon + name + ". La recherche normale de ce nom part maintenant.");
    }

    /// <summary>search.revalidate: the listed objects read again in their own perimeter (RCH-073); an absence proves nothing.</summary>
    public async Task<SearchRevalidation> RevalidateAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(ids);
        var distinct = ids.Distinct().ToList();
        var rows = await context.Readers.Require<ISearchReader>().RereadAsync(distinct, cancellationToken).ConfigureAwait(false);
        var found = rows.Select(r => r.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var missing = distinct.Select(i => i.ToString("D")).Where(i => !found.Contains(i)).ToImmutableArray();
        var at = context.Clock.GetUtcNow();
        var summary = "Liste vérifiée à " + SearchDetails.When(at, Zone)[11..] + FrenchText.Colon + FrenchText.Count(rows.Length, "objet relu", "objets relus")
            + (missing.IsEmpty ? "" : " · " + FrenchText.Count(missing.Length, "objet à revérifier", "objets à revérifier") + " (une absence ne prouve pas une suppression)");
        return new SearchRevalidation(rows, missing, at, summary);
    }

    /// <summary>
    /// search.survey.plan: the exact targets and the confirmation, before anything is read. The context is derived by the
    /// engine from the list itself (kind, perimeter, text, view, rows given), never taken from the page: every target must be
    /// a row of the list, a view or query listed on the whole domain is never surveyed (RCH-117), the whole root list or a
    /// global search without a term is refused (RCH-090). The plan is kept ten minutes for one run.
    /// </summary>
    public async Task<SurveyPlan> SurveyPlanAsync(SurveyMode mode, string listId, IReadOnlyList<Guid> ids, SurveyScope scope, bool resuming, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(ids);
        var state = RequireList(listId);
        ResumeState? pending;
        lock (gate)
        {
            pending = resumeState;
        }
        IReadOnlyList<Guid> chosen = ids;
        if (resuming)
        {
            if (pending is null || !string.Equals(pending.ListId, listId, StringComparison.Ordinal))
            {
                throw new DomeniaOperationException(SearchErrors.SurveyRefused, "Aucun relevé interrompu à reprendre sur cette liste" + FrenchText.Colon + "rien n’est lu.");
            }
            mode = pending.Mode;
            chosen = [.. pending.Remaining.Select(t => Guid.Parse(t.Id))];
        }
        var distinct = chosen.Distinct().ToList();
        var known = KnownOf(state);
        var outside = distinct.Count(i => !known.Contains(i.ToString("D")));
        if (outside > 0)
        {
            throw new DomeniaOperationException(SearchErrors.SurveyRefused, FrenchText.Count(outside, "ligne demandée n’appartient", "lignes demandées n’appartiennent")
                + " pas à la liste affichée" + FrenchText.Colon + "rien n’est relevé.");
        }
        var (targets, excluded) = await TargetsAsync(mode, distinct, cancellationToken).ConfigureAwait(false);
        var covers = distinct.Count >= known.Count;
        var policy = Policy();
        var admission = state.View is { SurveyAllowed: false } view
            ? new SurveyAdmission(false, "wholeDomainView", view.Reason, policy.MaxTargets)
            : SearchSurvey.Admit(targets.Length, policy.MaxTargets, state.Scope.Mode == "global", !string.IsNullOrWhiteSpace(state.Text), state.Scope.WholeDomain,
                hasFilter: !covers, scope == SurveyScope.Selection, covers);
        var scopeLabel = state.Scope.Mode == "global" ? state.Scope.Chip : state.Scope.WholeDomain ? "tout le domaine" : SearchTexts.Leaf(state.BaseDn);
        var (title, target, lines, confirm, seconds) = SearchSurvey.Confirmation(mode, targets.Length, resuming ? SurveyScope.Selection : scope, scopeLabel, state.Subtree, excluded.Length,
            state.LimitReached ? state.Limit : 0, policy.Concurrency);
        var profile = ProfileOf();
        var now = context.Clock.GetUtcNow();
        var open = SearchSurvey.WindowOpen(profile, TimeZoneInfo.ConvertTime(now, Zone).DateTime);
        var details = SearchSurvey.Details(mode, profile, open, pending is null ? null : Resume(pending), resuming, policy.Concurrency);
        if (resuming)
        {
            title = "Reprendre le relevé" + FrenchText.Colon + SearchSurvey.ModeLabel(mode);
        }
        var planId = NewId();
        var expires = now + PlanLifetime;
        var typed = targets.Length > SearchSurvey.TypedCountThreshold;
        lock (gate)
        {
            foreach (var old in plans.Where(p => p.Value.ExpiresAt <= now).Select(p => p.Key).ToList())
            {
                plans.Remove(old);
            }
            while (plans.Count >= MaxPlans)
            {
                plans.Remove(plans.MinBy(p => p.Value.ExpiresAt).Key);
            }
            plans[planId] = new PendingSurvey(planId, mode, listId, targets, typed, admission, expires, profile);
        }
        return new SurveyPlan(planId, mode, SearchSurvey.ModeLabel(mode), admission, title, target, lines, details, !open, confirm, seconds, SearchSurvey.Duration(seconds),
            targets, excluded, typed, resuming, expires);
    }

    /// <summary>
    /// search.survey.run: runs a plan once (it is consumed, valid ten minutes; above 100 workstations the typed count is checked
    /// again here). Echoes go by batches of 32, other reads four workstations at a time; the progress and the detailed state
    /// are published after each batch; the operator may stop it: what was read is kept, the rest becomes the resume plan,
    /// nothing is replayed.
    /// </summary>
    public async Task<SurveyResult> SurveyRunAsync(string planId, int? typedCount, Action<SurveyProgress> publish, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(planId);
        ArgumentNullException.ThrowIfNull(publish);
        PendingSurvey? taken;
        var opened = context.Clock.GetUtcNow();
        lock (gate)
        {
            taken = plans.Remove(planId, out var found) && found.ExpiresAt > opened ? found : null;
        }
        if (taken is null)
        {
            throw new DomeniaOperationException(SearchErrors.SurveyPlanUnknown, SearchErrors.SurveyPlanUnknownMessage);
        }
        PendingSurvey plan = taken;
        if (!plan.Admission.Allowed)
        {
            throw new DomeniaOperationException(SearchErrors.SurveyRefused, plan.Admission.Reason);
        }
        var targets = plan.Targets;
        if (plan.TypedRequired && typedCount != targets.Length)
        {
            throw new DomeniaOperationException(SearchErrors.SurveyTypedCount, "Nombre saisi différent du nombre de postes (" + FrenchText.Integer(targets.Length) + ")"
                + FrenchText.Colon + "rien n’est lu. Confirmez de nouveau.");
        }
        // The reader is required before the « survey running » marker is taken: a refusal here (source.unavailable) never
        // leaves the marker set, which would refuse every later survey (search.surveyBusy).
        var mode = plan.Mode;
        var reader = context.Readers.Require<ISearchReader>();
        if (Interlocked.CompareExchange(ref surveyRunning, 1, 0) != 0)
        {
            throw new DomeniaOperationException(SearchErrors.SurveyBusy, SearchErrors.SurveyBusyMessage);
        }
        var runId = NewId();
        var run = Interlocked.Increment(ref surveyCount);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        runs[runId] = stop;
        lock (gate)
        {
            // A new survey replaces the resume plan of the interrupted one (Domenia 1: one resume plan at a time).
            resumeState = null;
        }
        var started = context.Clock.GetUtcNow();
        var clock = context.Clock.GetTimestamp();
        int done = 0, online = 0, noReply = 0, errors = 0, slow = 0, suspended = 0, reachable = 0, avoided = 0;
        var stopped = false;
        var read = new List<Guid>(targets.Length);
        int Elapsed() => (int)context.Clock.GetElapsedTime(clock).TotalSeconds;
        SurveyStatus StatusOf(bool finished, int remaining) => SearchSurvey.Status(mode, done, targets.Length, Elapsed(), slow, suspended, reachable, avoided, remaining, plan.Profile, finished);
        async Task<(SurveyOutcome Outcome, bool Slow)> ProbeOneAsync(SurveyTarget target)
        {
            var at = context.Clock.GetTimestamp();
            var outcome = await reader.ProbeAsync(Guid.Parse(target.Id), mode, run, TimeSpan.FromSeconds(plan.Profile.InventorySeconds), stop.Token).ConfigureAwait(false);
            return (outcome, context.Clock.GetElapsedTime(at) > TimeSpan.FromSeconds(SearchSurvey.SlowProbeSeconds));
        }
        try
        {
            publish(new SurveyProgress(runId, 0, targets.Length, 0, 0, 0, SearchSurvey.Progress(0, targets.Length, 0, 0, 0, false, false), [], StatusOf(false, targets.Length)));
            // Budgets read when the survey starts (Paramètres may have changed them since the plan): echoes by batches of 192,
            // the other modes as many workstations at a time as Paramètres allows (4 by default, 1 to 8).
            var budgets = Policy();
            var size = mode == SurveyMode.Ping ? budgets.PingBatch : budgets.Concurrency;
            foreach (var batch in targets.Chunk(size))
            {
                stop.Token.ThrowIfCancellationRequested();
                var results = await Task.WhenAll(batch.Select(ProbeOneAsync)).ConfigureAwait(false);
                foreach (var (outcome, late) in results)
                {
                    done++;
                    read.Add(Guid.Parse(outcome.Id));
                    slow += late ? 1 : 0;
                    avoided += outcome.InventoryReused ? 1 : 0;
                    reachable += outcome.Console is { State: "seen" or "none" } ? 1 : 0;
                    if (outcome.Denied)
                    {
                        suspended++;
                        Suspend(outcome.Name);
                    }
                    switch (outcome.Kind)
                    {
                        case "online":
                            online++;
                            break;
                        case "noReply":
                            noReply++;
                            break;
                        default:
                            errors++;
                            break;
                    }
                }
                publish(new SurveyProgress(runId, done, targets.Length, online, noReply, errors, SearchSurvey.Progress(done, targets.Length, online, noReply, errors, false, false),
                    [.. results.Select(r => r.Outcome)], StatusOf(false, targets.Length - done)));
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // Stopped by the operator: the readings already received are kept, the rest is not read.
            stopped = true;
        }
        finally
        {
            runs.TryRemove(runId, out _);
            Volatile.Write(ref surveyRunning, 0);
        }
        SurveyResume? resume = null;
        if (stopped)
        {
            var seen = read.Select(g => g.ToString("D")).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var remaining = targets.Where(t => !seen.Contains(t.Id)).ToImmutableArray();
            if (!remaining.IsEmpty)
            {
                var kept = new ResumeState(plan.ListId, mode, remaining, targets.Length, context.Clock.GetUtcNow());
                lock (gate)
                {
                    resumeState = kept;
                }
                resume = Resume(kept);
            }
        }
        var rows = read.Count > 0 ? await reader.RereadAsync(read, cancellationToken).ConfigureAwait(false) : [];
        var text = SearchSurvey.Progress(done, targets.Length, online, noReply, errors, completed: true, stopped);
        var detail = "Relevé " + FrenchText.Quote(SearchSurvey.ModeLabel(mode)) + FrenchText.Colon + text + ". "
            + (stopped ? "Arrêté par l’opérateur" + FrenchText.Colon + "les mesures reçues sont enregistrées, les autres postes ne sont pas lus. " : "")
            + "Une absence de réponse au ping ne prouve pas qu’un poste est éteint.";
        Journal("Relevé de la liste (" + SearchSurvey.ModeLabel(mode) + ")" + FrenchText.Colon + text, stopped || errors > 0 ? Tone.Warn : Tone.Ok);
        context.Log.Info($"Relevé de la liste terminé : {done}/{targets.Length} postes, {online} en ligne, {noReply} sans réponse, {errors} erreurs{(stopped ? ", arrêté" : "")}.");
        return new SurveyResult(runId, mode, done, targets.Length, online, noReply, errors, stopped, text, detail, rows, started, context.Clock.GetUtcNow(),
            StatusOf(true, resume?.Remaining ?? 0), resume);
    }

    /// <summary>search.survey.stop: asks the survey to stop after the batch in progress.</summary>
    public SurveyStop Stop(string runId)
    {
        if (runs.TryGetValue(runId, out var source))
        {
            try
            {
                source.Cancel();
            }
            catch (ObjectDisposedException)
            {
                return new SurveyStop(false, "Le relevé était déjà terminé.");
            }
            return new SurveyStop(true, "Arrêt demandé" + FrenchText.Colon + "le lot en cours se termine, les mesures reçues sont enregistrées.");
        }
        return new SurveyStop(false, "Aucun relevé en cours sous cet identifiant.");
    }

    /// <summary>search.survey.state: resume plan of the session and suspension of the selection checks.</summary>
    public SearchSurveyState SurveyState()
    {
        lock (gate)
        {
            return new SearchSurveyState(resumeState is null ? null : Resume(resumeState), checksSuspended is not null, checksSuspended ?? "");
        }
    }

    /// <summary>search.survey.forget: abandons the resume plan; the measures already validated stay.</summary>
    public SearchSurveyState ForgetResume()
    {
        lock (gate)
        {
            resumeState = null;
        }
        Journal("Plan de reprise abandonné" + FrenchText.Colon + "les mesures déjà validées restent.", Tone.Info);
        return SurveyState();
    }

    /// <summary>search.checks.resume: the operator lifts the suspension of the selection checks (RCH-082).</summary>
    public SearchSurveyState ResumeChecks()
    {
        lock (gate)
        {
            checksSuspended = null;
        }
        Journal("Vérifications sur sélection reprises", Tone.Info);
        return SurveyState();
    }

    /// <summary>
    /// search.recheck: one ping (and the console user unless <paramref name="mode"/> is a ping) of the single workstation
    /// selected (RCH-079, RCH-078), one attempt. A row of a list listed on the whole domain is never probed; a check started
    /// by a click is refused while the selection checks are suspended after a rejected account (RCH-082).
    /// </summary>
    public async Task<SearchRow> RecheckAsync(Guid id, SurveyMode mode, string listId, bool onClick, CancellationToken cancellationToken)
    {
        // The engine judges on the list shown: a row of a whole domain view, or a row that is not in the list, is never probed.
        var state = RequireList(listId);
        if (state.View is { SurveyAllowed: false } view)
        {
            throw new DomeniaOperationException(SearchErrors.SurveyRefused, view.Reason);
        }
        if (!KnownOf(state).Contains(id.ToString("D")))
        {
            throw new DomeniaOperationException(SearchErrors.SurveyRefused, "Cette ligne n’appartient pas à la liste affichée" + FrenchText.Colon + "aucune sonde n’est envoyée.");
        }
        if (onClick)
        {
            string? reason;
            lock (gate)
            {
                reason = checksSuspended;
            }
            if (reason is not null)
            {
                throw new DomeniaOperationException(SearchErrors.ChecksSuspended, reason);
            }
        }
        var reader = context.Readers.Require<ISearchReader>();
        var rows = await reader.LocalRowsAsync([id], cancellationToken).ConfigureAwait(false);
        if (rows.Length != 1 || rows[0].Kind != SearchObjectKind.Computer || rows[0].Flags.Disabled)
        {
            throw new DomeniaOperationException(SearchErrors.NotWorkstation, SearchErrors.NotWorkstationMessage);
        }
        var outcome = await reader.ProbeAsync(id, mode == SurveyMode.Ping ? SurveyMode.Ping : SurveyMode.Console, Interlocked.Increment(ref surveyCount), TimeSpan.Zero, cancellationToken).ConfigureAwait(false);
        if (outcome.Denied)
        {
            Suspend(outcome.Name);
        }
        Journal("Revérification de " + rows[0].Name + FrenchText.Colon + outcome.Presence.Label, outcome.Kind == "online" ? Tone.Ok : Tone.Warn);
        var reread = await reader.RereadAsync([id], cancellationToken).ConfigureAwait(false);
        return reread.Length == 1 ? reread[0] : rows[0];
    }

    /// <summary>
    /// search.netdiag: echo then four TCP ports, workstation after workstation, 50 at most (RCH-131); no account sent. Rows of
    /// the list only, never on a list listed on the whole domain.
    /// </summary>
    public async Task<NetworkDiagnostic> DiagnoseAsync(string listId, IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(ids);
        var state = RequireList(listId);
        if (state.View is { SurveyAllowed: false } view)
        {
            throw new DomeniaOperationException(SearchErrors.SurveyRefused, view.Reason);
        }
        var known = KnownOf(state);
        var distinct = ids.Distinct().ToList();
        if (distinct.Any(i => !known.Contains(i.ToString("D"))))
        {
            throw new DomeniaOperationException(SearchErrors.SurveyRefused, "Des lignes demandées n’appartiennent pas à la liste affichée" + FrenchText.Colon + "rien n’est envoyé.");
        }
        var reader = context.Readers.Require<ISearchReader>();
        var rows = await reader.LocalRowsAsync(distinct, cancellationToken).ConfigureAwait(false);
        var excluded = new List<SurveyExcluded>();
        var targets = new List<SearchRow>();
        foreach (var row in rows)
        {
            if (row.Kind != SearchObjectKind.Computer)
            {
                excluded.Add(new SurveyExcluded(row.Name, "pas un poste"));
            }
            else if (row.Flags.Disabled)
            {
                excluded.Add(new SurveyExcluded(row.Name, "compte ordinateur désactivé"));
            }
            else if (targets.Count >= SearchSurvey.MaxDiagnostic)
            {
                excluded.Add(new SurveyExcluded(row.Name, "au-delà de " + FrenchText.Integer(SearchSurvey.MaxDiagnostic) + " postes"));
            }
            else
            {
                targets.Add(row);
            }
        }
        var unknown = distinct.Count - rows.Length;
        if (unknown > 0)
        {
            excluded.Add(new SurveyExcluded(FrenchText.Count(unknown, "ligne", "lignes"), "sans identifiant connu de la base locale"));
        }
        if (targets.Count == 0)
        {
            throw new DomeniaOperationException(SearchErrors.SurveyRefused, "Aucun poste actif dans la sélection" + FrenchText.Colon + "rien n’est envoyé.");
        }
        var lines = ImmutableArray.CreateBuilder<NetworkDiagnosticLine>(targets.Count);
        foreach (var target in targets)
        {
            lines.Add(await reader.DiagnoseAsync(Guid.Parse(target.Id), cancellationToken).ConfigureAwait(false));
        }
        var built = lines.ToImmutable();
        var reachable = built.Count(l => l.Ping.State == SearchPresenceState.Online);
        var summary = FrenchText.Count(built.Length, "poste diagnostiqué", "postes diagnostiqués") + " · " + FrenchText.Integer(reachable) + " répondent au ping · "
            + FrenchText.Integer(built.Count(l => l.Ports.Any(p => p.Port == 445 && p.State == "open"))) + " avec le partage SMB ouvert · aucun compte envoyé, rien modifié.";
        Journal("Diagnostic réseau groupé" + FrenchText.Colon + summary, Tone.Info);
        return new NetworkDiagnostic(built, [.. excluded], summary, SearchSurvey.Report(built), context.Clock.GetUtcNow());
    }

    /// <summary>Catalog of the views and local queries, with the query favourites of the operator.</summary>
    public SearchCatalog Catalog(ImmutableArray<string> favorites, string sourceLabel)
    {
        var set = favorites.ToHashSet(StringComparer.Ordinal);
        var views = SearchViews.All(context.Clock.GetUtcNow()).Select(v => new SearchCatalogEntry("ad:" + v.Id, v.Name, v.Category, sourceLabel,
            SearchText.TypeLabel(v.Type), v.Note, v.Cost, v.LdapFilter, set.Contains("ad:" + v.Id), false));
        var local = SearchViews.LocalQueries.Select(q => new SearchCatalogEntry("local:" + q.Id[6..], q.Name, q.Category, "Base locale et relevés datés", "Postes", q.Description,
            "Calcul local sur les relevés enregistrés" + FrenchText.Colon + "aucune lecture de l’annuaire ni des postes.", "", set.Contains("local:" + q.Id[6..]), true));
        var entries = views.Concat(local).ToImmutableArray();
        return new SearchCatalog(entries, entries.Count(e => e.Favorite),
            "Choisir une requête ne lance rien" + FrenchText.Colon + "elle part sur votre clic, sur l’OU choisie dans l’arbre.");
    }

    public void Dispose()
    {
        foreach (var source in runs.Values)
        {
            source.Dispose();
        }
        runs.Clear();
    }

    private async Task<(ImmutableArray<SurveyTarget> Targets, ImmutableArray<SurveyExcluded> Excluded)> TargetsAsync(SurveyMode mode, IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        var reader = context.Readers.Require<ISearchReader>();
        var distinct = ids.Distinct().ToList();
        var rows = await reader.LocalRowsAsync(distinct, cancellationToken).ConfigureAwait(false);
        var targets = ImmutableArray.CreateBuilder<SurveyTarget>();
        var excluded = ImmutableArray.CreateBuilder<SurveyExcluded>();
        foreach (var row in rows)
        {
            if (row.Kind != SearchObjectKind.Computer)
            {
                excluded.Add(new SurveyExcluded(row.Name, "pas un poste"));
            }
            else if (row.Flags.Disabled)
            {
                excluded.Add(new SurveyExcluded(row.Name, "compte ordinateur désactivé"));
            }
            else if (mode == SurveyMode.Unaddressed && row.Address?.Ip is not null)
            {
                excluded.Add(new SurveyExcluded(row.Name, "adresse déjà connue"));
            }
            else
            {
                targets.Add(new SurveyTarget(row.Id, row.Name, row.Dn, row.Address?.Ip));
            }
        }
        var unknown = distinct.Count - rows.Length;
        if (unknown > 0)
        {
            excluded.Add(new SurveyExcluded(FrenchText.Count(unknown, "ligne", "lignes"), "sans identifiant AD connu de la base locale"));
        }
        return (targets.ToImmutable(), excluded.ToImmutable());
    }

    private Task<SearchResult> ReadAsync(ListState state, ISearchReader reader, int target, bool appended, CancellationToken cancellationToken) =>
        WithBusyAsync(state, () => ReadCoreAsync(state, reader, target, appended, cancellationToken));

    private async Task<SearchResult> ReadCoreAsync(ListState state, ISearchReader reader, int target, bool appended, CancellationToken cancellationToken)
    {
        var take = Math.Max(1, target - state.Loaded);
        var query = new SearchQuery(state.Kind, state.Plan, state.Type, state.BaseDn, state.Subtree, state.ViewId, state.LastKey, KnownOf(state), take);
        var page = await reader.FindAsync(query, cancellationToken).ConfigureAwait(false);
        return Complete(state, page, target, appended);
    }

    /// <summary>One read at a time per list (« Charger la suite », revérification): a second one is refused, never queued.</summary>
    private static async Task<T> WithBusyAsync<T>(ListState state, Func<Task<T>> read)
    {
        if (Interlocked.CompareExchange(ref state.Busy, 1, 0) != 0)
        {
            throw new DomeniaOperationException(SearchErrors.ListBusy, SearchErrors.ListBusyMessage);
        }
        try
        {
            return await read().ConfigureAwait(false);
        }
        finally
        {
            Volatile.Write(ref state.Busy, 0);
        }
    }

    /// <summary>Copy of the identifiers already given by a list, taken under the lock (Complete adds to it).</summary>
    private HashSet<string> KnownOf(ListState state)
    {
        lock (gate)
        {
            return state.Known.ToHashSet(StringComparer.OrdinalIgnoreCase);
        }
    }

    private ListState RequireList(string listId)
    {
        lock (gate)
        {
            return lists.TryGetValue(listId, out var state)
                ? state
                : throw new DomeniaOperationException(SearchErrors.ListUnknown, SearchErrors.ListUnknownMessage);
        }
    }

    /// <summary>A remote account rejected by a workstation suspends the checks started by a click on a row (RCH-082).</summary>
    private void Suspend(string workstation)
    {
        var reason = "Vérifications sur sélection suspendues" + FrenchText.Colon + "le poste " + workstation + " a rejeté le compte distant. Reprenez-les après vérification du compte.";
        lock (gate)
        {
            if (checksSuspended is not null)
            {
                return;
            }
            checksSuspended = reason;
        }
        Journal(reason, Tone.Warn);
    }

    /// <summary>Collection profile chosen in the preferences (« collection.profile »), Standard otherwise.</summary>
    private SurveyProfile ProfileOf()
    {
        if (context.Preferences.TryGet(ProfileKey, out var value) && value.ValueKind == System.Text.Json.JsonValueKind.String)
        {
            return SearchSurvey.Profile(value.GetString());
        }
        return SearchSurvey.Profile(null);
    }

    private static SurveyResume Resume(ResumeState state) => new(state.ListId, state.Mode, SearchSurvey.ModeLabel(state.Mode), state.Remaining.Length, state.Total, state.StoppedAt,
        "Relevé " + FrenchText.Quote(SearchSurvey.ModeLabel(state.Mode)) + " interrompu" + FrenchText.Colon + FrenchText.Count(state.Remaining.Length, "poste restant", "postes restants")
        + " sur " + FrenchText.Integer(state.Total) + ".");

    /// <summary>Records a page in its list and builds the answer (rows of this page only when appended).</summary>
    private SearchResult Complete(ListState state, SearchPage page, int target, bool appended)
    {
        List<SearchRow> rows;
        lock (gate)
        {
            rows = [.. page.Rows.Where(r => !state.Known.Contains(r.Id))];
        }
        var ranked = state.Kind == SearchListKind.Search
            ? rows.Select(r => r with { Rank = SearchMatcher.Rank(r, state.Text) }).OrderBy(r => r.Rank).ThenBy(r => FrenchText.Fold(r.Name), StringComparer.Ordinal).ToImmutableArray()
            : [.. rows];
        lock (gate)
        {
            foreach (var row in ranked)
            {
                if (state.Known.Add(row.Id))
                {
                    state.Order.Add(row.Id);
                }
            }
            state.Loaded += ranked.Length;
            state.Limit = Math.Max(state.Limit, target);
            state.LimitReached = page.More;
            state.LastKey = page.LastKey ?? state.LastKey;
        }
        var limitReached = page.More;
        var continuation = SearchLists.Continuation(limitReached, state.Limit, state.Loaded);
        var offer = appended ? null : SearchLists.ContainsOffer(state.Text, state.Kind, state.Plan.Kind, state.Match, state.Loaded, limitReached);
        return new SearchResult(state.Id, state.Kind, state.Scope, state.Type, state.Text, state.Match, state.Plan, ranked, state.Loaded, state.Limit, !limitReached, limitReached,
            continuation, SearchLists.Counter(state.Loaded, state.Limit, !limitReached), SearchLists.Absence(state.Scope.Label, state.Type, limitReached, state.Limit),
            offer, null, state.View, null, page.SourceLabel, page.ReadAt, appended);
    }

    private ListState Register(ListState state)
    {
        lock (gate)
        {
            lists[state.Id] = state;
            order.Enqueue(state.Id);
            while (order.Count > MaxLists && order.TryDequeue(out var old))
            {
                lists.Remove(old);
            }
        }
        return state;
    }

    private async Task<(string Root, string Dns)> DomainAsync(CancellationToken cancellationToken)
    {
        var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        if (session.Domain?.RootDn is not string root || session.Domain.DnsName is not string dns)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        }
        return (root, dns);
    }

    /// <summary>
    /// Base of a list (search, browse, view, local query): a container of the domain root (CN=Users, CN=Computers: the tree
    /// offers them, the index of the OU leaves them out) or an OU known by the local index; never the network. ou.unknown
    /// otherwise.
    /// </summary>
    private async Task<string> RequireBaseAsync(ISearchReader reader, string dn, string root, CancellationToken cancellationToken)
    {
        var containers = await reader.ContainersAsync(false, cancellationToken).ConfigureAwait(false);
        var container = containers.FirstOrDefault(c => SearchLists.IsRoot(c.Dn, dn));
        return container?.Dn ?? await RequireOuAsync(dn, root, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>An OU of the session domain known by the local index (never the network); ou.unknown otherwise.</summary>
    private async Task<string> RequireOuAsync(string dn, string root, CancellationToken cancellationToken)
    {
        if (!SearchMemoryRules.Within(dn, root))
        {
            throw new DomeniaOperationException(DomeniaErrors.OuUnknown, DomeniaErrors.OuUnknownMessage);
        }
        var index = context.Readers.Find<IOrganizationalUnitIndex>();
        if (index is null)
        {
            return dn;
        }
        var entry = await index.FindLocalAsync(dn, cancellationToken).ConfigureAwait(false);
        return entry?.Dn ?? throw new DomeniaOperationException(DomeniaErrors.OuUnknown, DomeniaErrors.OuUnknownMessage);
    }

    private void Journal(string label, Tone tone) => context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), label, tone));

    /// <summary>A survey planned and not yet run: its targets, admission and profile, valid until <see cref="ExpiresAt"/>.</summary>
    private sealed record PendingSurvey(string PlanId, SurveyMode Mode, string ListId, ImmutableArray<SurveyTarget> Targets, bool TypedRequired, SurveyAdmission Admission,
        DateTimeOffset ExpiresAt, SurveyProfile Profile);

    /// <summary>Remaining targets of the survey stopped by the operator (plan de reprise of the session).</summary>
    private sealed record ResumeState(string ListId, SurveyMode Mode, ImmutableArray<SurveyTarget> Remaining, int Total, DateTimeOffset StoppedAt);

    private static string NewId() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));

    /// <summary>A list kept for its continuation: what produced it, what was given, where the next page starts.</summary>
    private sealed class ListState(SearchListKind kind, SearchPlan plan, SearchTypeFilter type, string baseDn, bool subtree, string? viewId, string text,
        SearchMatchMode match, SearchScopeInfo scope, SearchViewInfo? view)
    {
        public int Busy;

        public string Id { get; } = NewId();
        public SearchListKind Kind { get; } = kind;
        public SearchPlan Plan { get; } = plan;
        public SearchTypeFilter Type { get; } = type;
        public string BaseDn { get; } = baseDn;
        public bool Subtree { get; } = subtree;
        public string? ViewId { get; } = viewId;
        public string Text { get; } = text;
        public SearchMatchMode Match { get; } = match;
        public SearchScopeInfo Scope { get; } = scope;
        public SearchViewInfo? View { get; } = view;
        public SearchAddress? Address { get; init; }
        public string? Verdict { get; init; }
        public HashSet<string> Known { get; } = new(StringComparer.OrdinalIgnoreCase);
        public List<string> Order { get; } = [];
        public int Checkpoint { get; set; }
        public int Loaded { get; set; }
        public int Limit { get; set; }
        public bool LimitReached { get; set; }
        public string? LastKey { get; set; }
    }
}
