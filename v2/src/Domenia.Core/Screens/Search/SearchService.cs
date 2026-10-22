using System.Collections.Concurrent;
using System.Collections.Immutable;
using System.Security.Cryptography;

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
    public const string NotWorkstation = "search.notWorkstation";
    public const string NotWorkstationMessage = "Cette ligne n’est pas un poste actif" + FrenchText.Colon + "aucune sonde n’est envoyée.";
}

/// <summary>Reverse DNS lookup on an explicit gesture (R40).</summary>
public sealed record SearchDnsResult(string Ip, string? Name, string Message);

/// <summary>Objects of a list read again (RCH-073): fresh rows, those no longer found (never a proof of deletion).</summary>
public sealed record SearchRevalidation(ImmutableArray<SearchRow> Rows, ImmutableArray<string> Missing, DateTimeOffset CheckedAt, string Summary);

/// <summary>Answer of search.survey.stop.</summary>
public sealed record SurveyStop(bool Stopped, string Message);

/// <summary>Context of a survey sent by the page: what list the targets come from (Domenia 1 Get-DomeniaParkListContext).</summary>
public sealed record SurveyContext(SurveyScope Scope, bool Global, bool HasSearchTerm, bool WholeDomain, bool HasFilter, bool SelectionCoversList, string? ScopeLabel, bool Subtree, int ListLimit);

/// <summary>
/// Engine service of the search screen, shared by its module: runs the reads through the reader of the mode, keeps the lists
/// for the explicit continuation (« Charger la suite »: only the following rows, never read twice), and the survey in progress
/// (one per screen, stoppable). Nothing is ever read without a call of the page, nothing is replayed.
/// </summary>
public sealed class SearchService : IDisposable
{
    private const int MaxLists = 24;
    private const int PingBatch = 32;
    private const int Concurrency = 4;

    private readonly EngineContext context;
    private readonly Lock gate = new();
    private readonly Dictionary<string, ListState> lists = new(StringComparer.Ordinal);
    private readonly Queue<string> order = new();
    private readonly ConcurrentDictionary<string, CancellationTokenSource> runs = new(StringComparer.Ordinal);
    private int surveyCount;
    private int surveyRunning;

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

    private TimeZoneInfo Zone => context.Clock.LocalTimeZone;

    /// <summary>search.run: the bar (global, or one OU chosen by its chip), or an address of the local readings.</summary>
    public async Task<SearchResult> RunAsync(string text, string? scopeDn, SearchTypeFilter type, int limit, SearchMatchMode match, CancellationToken cancellationToken)
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
            baseDn = await RequireOuAsync(scopeDn, root, cancellationToken).ConfigureAwait(false);
        }
        var scope = SearchLists.Scope(true, baseDn, root, dns, true);
        var list = Register(new ListState(SearchListKind.Search, plan, type, baseDn, true, null, text.Trim(), match, scope, null));
        var found = await ReadAsync(list, reader, limit, appended: false, cancellationToken).ConfigureAwait(false);
        Journal("Recherche " + FrenchText.Quote(SearchMemoryRules.Flat(text, 60)) + FrenchText.Colon + FrenchText.Count(found.Loaded, "résultat", "résultats") + (found.LimitReached ? " (liste limitée)" : ""), Tone.Info);
        return found;
    }

    /// <summary>search.browse: content of an OU (or of the whole domain, listed only: never surveyed), own empty filter.</summary>
    public async Task<SearchResult> BrowseAsync(string dn, bool subtree, SearchTypeFilter type, int limit, CancellationToken cancellationToken)
    {
        var (root, dns) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var reader = context.Readers.Require<ISearchReader>();
        var containers = await reader.ContainersAsync(cancellationToken).ConfigureAwait(false);
        var container = containers.FirstOrDefault(c => SearchLists.IsRoot(c.Dn, dn));
        var baseDn = SearchLists.IsRoot(dn, root) ? root : container?.Dn ?? await RequireOuAsync(dn, root, cancellationToken).ConfigureAwait(false);
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
        var baseDn = wholeDomain || dn is null || SearchLists.IsRoot(dn, root) ? root : await RequireOuAsync(dn, root, cancellationToken).ConfigureAwait(false);
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
        var baseDn = SearchLists.IsRoot(dn, root) ? root : await RequireOuAsync(dn, root, cancellationToken).ConfigureAwait(false);
        var whole = SearchLists.IsRoot(baseDn, root);
        var scope = SearchLists.Scope(false, baseDn, root, dns, whole || subtree);
        var plan = new SearchPlan(SearchPlanKind.LocalQuery, true, "", query.Description, [], [], null, null, "", false, "");
        var info = new SearchViewInfo(query.Id, query.Name, query.Description, whole, !whole,
            whole ? "Requête sur tout le domaine" + FrenchText.Colon + "aucun relevé des postes n’est proposé sur cette liste." : "");
        var state = Register(new ListState(SearchListKind.LocalQuery, plan, SearchTypeFilter.Computers, baseDn, whole || subtree, query.Id, "", SearchMatchMode.Prefix, scope, info) { Verdict = verdict });
        var (page, totals) = await reader.LocalQueryAsync(query.Id, baseDn, whole || subtree, verdict, limit, cancellationToken).ConfigureAwait(false);
        return Complete(state, page, limit, appended: false) with { Verdicts = totals };
    }

    /// <summary>search.more: the following rows of a list only (MO-07), up to <paramref name="target"/> rows in all.</summary>
    public async Task<SearchResult> MoreAsync(string listId, int target, CancellationToken cancellationToken)
    {
        ListState? state;
        lock (gate)
        {
            lists.TryGetValue(listId, out state);
        }
        if (state is null)
        {
            throw new DomeniaOperationException(SearchErrors.ListUnknown, SearchErrors.ListUnknownMessage);
        }
        if (!state.LimitReached)
        {
            throw new DomeniaOperationException(SearchErrors.ListComplete, "Liste complète" + FrenchText.Colon + "aucune suite à charger.");
        }
        if (target <= state.Loaded || target > SearchLimits.MaxLimit)
        {
            throw new DomeniaOperationException(SearchErrors.ListComplete, "Taille demandée hors des bornes" + FrenchText.Colon + "de " + FrenchText.Integer(state.Loaded + 1) + " à " + FrenchText.Integer(SearchLimits.MaxLimit) + " lignes.");
        }
        var reader = context.Readers.Require<ISearchReader>();
        switch (state.Kind)
        {
            case SearchListKind.Address when state.Address is SearchAddress address:
                {
                    var page = await reader.FindAddressAsync(address, target, cancellationToken).ConfigureAwait(false);
                    return Complete(state, page with { Rows = [.. page.Rows.Where(r => !state.Known.Contains(r.Id))] }, target, appended: true);
                }
            case SearchListKind.LocalQuery:
                {
                    var (page, totals) = await reader.LocalQueryAsync(state.ViewId!, state.BaseDn, state.Subtree, state.Verdict ?? "match", target, cancellationToken).ConfigureAwait(false);
                    return Complete(state, page with { Rows = [.. page.Rows.Where(r => !state.Known.Contains(r.Id))] }, target, appended: true) with { Verdicts = totals };
                }
            default:
                return await ReadAsync(state, reader, target, appended: true, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>search.containers: containers of the domain root for the tree (Users, Computers, system containers folded apart).</summary>
    public Task<ImmutableArray<SearchContainer>> ContainersAsync(CancellationToken cancellationToken) =>
        context.Readers.Require<ISearchReader>().ContainersAsync(cancellationToken);

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

    /// <summary>search.survey.plan: the exact targets and the three-line confirmation, before anything is read.</summary>
    public async Task<SurveyPlan> SurveyPlanAsync(SurveyMode mode, IReadOnlyList<Guid> ids, SurveyContext survey, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(ids);
        ArgumentNullException.ThrowIfNull(survey);
        var (targets, excluded) = await TargetsAsync(mode, ids, cancellationToken).ConfigureAwait(false);
        var admission = SearchSurvey.Admit(targets.Length, SearchSurvey.MaxTargets, survey.Global, survey.HasSearchTerm, survey.WholeDomain, survey.HasFilter,
            survey.Scope == SurveyScope.Selection, survey.SelectionCoversList);
        var (title, target, lines, confirm, seconds) = SearchSurvey.Confirmation(mode, targets.Length, survey.Scope, survey.ScopeLabel, survey.Subtree, excluded.Length, survey.ListLimit);
        return new SurveyPlan(mode, SearchSurvey.ModeLabel(mode), admission, title, target, lines, confirm, seconds, SearchSurvey.Duration(seconds), targets, excluded,
            targets.Length > SearchSurvey.TypedCountThreshold);
    }

    /// <summary>
    /// search.survey.run: reads the targets once each (echoes by batches of 32, other reads four workstations at a time),
    /// publishes the progress after each batch, and stops at the operator’s request: what was read is kept, nothing is replayed.
    /// </summary>
    public async Task<SurveyResult> SurveyRunAsync(SurveyMode mode, IReadOnlyList<Guid> ids, SurveyContext survey, Action<SurveyProgress> publish, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(ids);
        ArgumentNullException.ThrowIfNull(survey);
        ArgumentNullException.ThrowIfNull(publish);
        var (targets, _) = await TargetsAsync(mode, ids, cancellationToken).ConfigureAwait(false);
        var admission = SearchSurvey.Admit(targets.Length, SearchSurvey.MaxTargets, survey.Global, survey.HasSearchTerm, survey.WholeDomain, survey.HasFilter,
            survey.Scope == SurveyScope.Selection, survey.SelectionCoversList);
        if (!admission.Allowed)
        {
            throw new DomeniaOperationException(SearchErrors.SurveyRefused, admission.Reason);
        }
        if (Interlocked.CompareExchange(ref surveyRunning, 1, 0) != 0)
        {
            throw new DomeniaOperationException(SearchErrors.SurveyBusy, SearchErrors.SurveyBusyMessage);
        }
        var reader = context.Readers.Require<ISearchReader>();
        var runId = NewId();
        var run = Interlocked.Increment(ref surveyCount);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        runs[runId] = stop;
        var started = context.Clock.GetUtcNow();
        int done = 0, online = 0, noReply = 0, errors = 0;
        var stopped = false;
        var read = new List<Guid>(targets.Length);
        try
        {
            publish(new SurveyProgress(runId, 0, targets.Length, 0, 0, 0, SearchSurvey.Progress(0, targets.Length, 0, 0, 0, false, false), []));
            var size = mode == SurveyMode.Ping ? PingBatch : Concurrency;
            foreach (var batch in targets.Chunk(size))
            {
                stop.Token.ThrowIfCancellationRequested();
                var outcomes = await Task.WhenAll(batch.Select(t => reader.ProbeAsync(Guid.Parse(t.Id), mode, run, stop.Token))).ConfigureAwait(false);
                foreach (var outcome in outcomes)
                {
                    done++;
                    read.Add(Guid.Parse(outcome.Id));
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
                publish(new SurveyProgress(runId, done, targets.Length, online, noReply, errors, SearchSurvey.Progress(done, targets.Length, online, noReply, errors, false, false), [.. outcomes]));
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
        var rows = read.Count > 0 ? await reader.RereadAsync(read, cancellationToken).ConfigureAwait(false) : [];
        var text = SearchSurvey.Progress(done, targets.Length, online, noReply, errors, completed: true, stopped);
        var detail = "Relevé " + FrenchText.Quote(SearchSurvey.ModeLabel(mode)) + FrenchText.Colon + text + ". "
            + (stopped ? "Arrêté par l’opérateur" + FrenchText.Colon + "les mesures reçues sont enregistrées, les autres postes ne sont pas lus. " : "")
            + "Une absence de réponse au ping ne prouve pas qu’un poste est éteint.";
        Journal("Relevé de la liste (" + SearchSurvey.ModeLabel(mode) + ")" + FrenchText.Colon + text, stopped || errors > 0 ? Tone.Warn : Tone.Ok);
        context.Log.Info($"Relevé de la liste terminé : {done}/{targets.Length} postes, {online} en ligne, {noReply} sans réponse, {errors} erreurs{(stopped ? ", arrêté" : "")}.");
        return new SurveyResult(runId, mode, done, targets.Length, online, noReply, errors, stopped, text, detail, rows, started, context.Clock.GetUtcNow());
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

    /// <summary>search.recheck: one ping and the console user of the single workstation selected (RCH-079), one attempt.</summary>
    public async Task<SearchRow> RecheckAsync(Guid id, CancellationToken cancellationToken)
    {
        var reader = context.Readers.Require<ISearchReader>();
        var rows = await reader.LocalRowsAsync([id], cancellationToken).ConfigureAwait(false);
        if (rows.Length != 1 || rows[0].Kind != SearchObjectKind.Computer || rows[0].Flags.Disabled)
        {
            throw new DomeniaOperationException(SearchErrors.NotWorkstation, SearchErrors.NotWorkstationMessage);
        }
        var outcome = await reader.ProbeAsync(id, SurveyMode.Console, Interlocked.Increment(ref surveyCount), cancellationToken).ConfigureAwait(false);
        Journal("Revérification de " + rows[0].Name + FrenchText.Colon + outcome.Presence.Label, outcome.Kind == "online" ? Tone.Ok : Tone.Warn);
        var reread = await reader.RereadAsync([id], cancellationToken).ConfigureAwait(false);
        return reread.Length == 1 ? reread[0] : rows[0];
    }

    /// <summary>search.netdiag: echo then four TCP ports, workstation after workstation, 50 at most (RCH-131); no account sent.</summary>
    public async Task<NetworkDiagnostic> DiagnoseAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(ids);
        var reader = context.Readers.Require<ISearchReader>();
        var distinct = ids.Distinct().ToList();
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

    private async Task<SearchResult> ReadAsync(ListState state, ISearchReader reader, int target, bool appended, CancellationToken cancellationToken)
    {
        if (Interlocked.CompareExchange(ref state.Busy, 1, 0) != 0)
        {
            throw new DomeniaOperationException(SearchErrors.ListBusy, SearchErrors.ListBusyMessage);
        }
        try
        {
            var take = Math.Max(1, target - state.Loaded);
            var query = new SearchQuery(state.Kind, state.Plan, state.Type, state.BaseDn, state.Subtree, state.ViewId, state.LastKey, state.Known.ToHashSet(StringComparer.OrdinalIgnoreCase), take);
            var page = await reader.FindAsync(query, cancellationToken).ConfigureAwait(false);
            return Complete(state, page, target, appended);
        }
        finally
        {
            Volatile.Write(ref state.Busy, 0);
        }
    }

    /// <summary>Records a page in its list and builds the answer (rows of this page only when appended).</summary>
    private SearchResult Complete(ListState state, SearchPage page, int target, bool appended)
    {
        var rows = page.Rows.Where(r => !state.Known.Contains(r.Id)).ToList();
        var ranked = state.Kind == SearchListKind.Search
            ? rows.Select(r => r with { Rank = SearchMatcher.Rank(r, state.Text) }).OrderBy(r => r.Rank).ThenBy(r => FrenchText.Fold(r.Name), StringComparer.Ordinal).ToImmutableArray()
            : [.. rows];
        lock (gate)
        {
            foreach (var row in ranked)
            {
                state.Known.Add(row.Id);
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
        public int Loaded { get; set; }
        public int Limit { get; set; }
        public bool LimitReached { get; set; }
        public string? LastKey { get; set; }
    }
}
