using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Bounded LDAP lists and local, dated projections of the search screen. Construction performs no I/O.</summary>
public sealed partial class AdSearchReader : ISearchReader
{
    private const string LocalLabel = "Base locale";
    private readonly AdDirectorySource source;

    public AdSearchReader(AdDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public async Task<SearchPage> FindAsync(SearchQuery query, CancellationToken cancellationToken)
    {
        using (OperationPhases.Measure(OperationPhase.Validation)) ValidateQuery(query);
        var global = query.Kind == SearchListKind.Search;
        var configuration = source.AccountContext?.Configuration ?? RuntimeConfiguration.Default;
        var duration = TimeSpan.FromSeconds(global ? configuration.Integer("Async", "SearchTimeoutSeconds", 120) : configuration.Integer("Async", "TreeTimeoutSeconds", 30));
        var serverTime = TimeSpan.FromSeconds(Math.Min(duration.TotalSeconds, configuration.Integer("Browser", "SearchServerTimeLimitSeconds", 60)));
        var pageSize = configuration.Integer("Browser", "SearchPageSize", 250);
        using var deadline = new ReadProgressDeadline(source.Clock, duration, global ? TimeSpan.FromSeconds(900) : duration);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        try
        {
            var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
            EnsureBase(query.BaseDn, domain.RootDn);
            if (query.Kind == SearchListKind.Browse && SearchLists.IsRoot(query.BaseDn, domain.RootDn))
            { throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, "Choisissez une OU pour lister ses objets."); }
            var generation = source.Epoch;
            if (source.CanPrepareDirectoryRefresh) { await source.PrepareDirectoryRefreshAsync(budget.Token).ConfigureAwait(false); }
            var at = source.Clock.GetUtcNow();
            var stages = Stages(query, at);
            var session = query.Reconcile ? await source.GetSessionAsync(budget.Token).ConfigureAwait(false) : null;
            var stamp = query.Reconcile ? await ReadControllerStampAsync(domain.RootDn, budget.Token).ConfigureAwait(false) : null;
            var fingerprint = QueryFingerprint(query, stages);
            var incremental = session is not null && CanReadIncremental(query, fingerprint, ReaderFingerprint(session), generation, at, stamp);
            var resume = query.After;
            var firstStage = resume is null ? stages[0].Key : resume[..1];
            var start = stages.FindIndex(p => p.Key == firstStage);
            if (start < 0) { throw Invalid("Point de reprise incompatible avec cette recherche."); }
            var rows = ImmutableArray.CreateBuilder<SearchRow>();
            var accepted = new List<AdEntry>();
            var given = new HashSet<Guid>();
            var known = query.Known.ToHashSet(StringComparer.OrdinalIgnoreCase);
            var more = false;
            var interrupted = false;
            string? interruption = null;
            string? cursor = null;
            for (var n = start; n < stages.Count; n++)
            {
                var stage = stages[n];
                var after = n == start && resume is not null ? resume[2..] : "";
                var filter = after.Length == 0 ? stage.Filter : "(&" + stage.Filter + "(name>=" + SearchText.LdapLiteral(after) + "))";
                if (incremental)
                {
                    var lower = (query.Checkpoint!.HighestCommittedUsn!.Value + 1).ToString(System.Globalization.CultureInfo.InvariantCulture);
                    filter = "(&" + filter + "(uSNChanged>=" + lower + "))";
                }
                // LDAP Subtree includes its base; the UI lists descendants only. Keep room for that valid base
                // without spending the extra child which proves that a continuation is needed.
                var count = query.Take - rows.Count + known.Count + given.Count + 1 + (query.Subtree ? 1 : 0);
                var completed = new List<AdEntry>();
                IReadOnlyList<AdEntry> entries;
                void Received(AdEntry entry)
                {
                    if (completed.Count >= count || !WithinLdapScope(query, entry.DistinguishedName)
                        || entry.Guid("objectGUID") is not { } id || id == Guid.Empty || string.IsNullOrWhiteSpace(entry.String("name")))
                    { throw Invalid("Entrée LDAP hors limites ou sans identité ; aucun résultat partiel qualifié."); }
                    deadline.Progress(1); // Only a fully received, qualified row can reset inactivity.
                    completed.Add(entry);
                }
                try
                {
                    using (OperationPhases.Measure(OperationPhase.Collection))
                    entries = await source.Connection.SearchAsync(new(query.BaseDn, filter, query.Subtree ? AdSearchScope.Subtree : AdSearchScope.OneLevel, AdObjectAccess.Attributes)
                    { PageSize = pageSize, SizeLimit = count, Timeout = serverTime, Budget = global ? TimeSpan.FromSeconds(900) : duration,
                        SortAttribute = incremental ? null : "name", EntryReceived = Received }, budget.Token).ConfigureAwait(false);
                    // Alternative readers may materialize all rows at once. Count their actual result, never the request itself.
                    if (completed.Count == 0) { foreach (var entry in entries) { Received(entry); } }
                    budget.Token.ThrowIfCancellationRequested();
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && deadline.Token.IsCancellationRequested)
                { entries = completed; interrupted = true; }
                catch (DomeniaOperationException ex) when (!cancellationToken.IsCancellationRequested && ex.Code == AdErrors.Timeout)
                { entries = completed; interrupted = true; }
                if (interrupted)
                {
                    var timed = deadline.Snapshot();
                    interruption = (timed.StopReason ?? "Délai de réponse LDAP atteint") + " : "
                        + FrenchText.Integer((long)Math.Ceiling(timed.Elapsed.TotalSeconds)) + " s écoulées, "
                        + FrenchText.Integer((long)Math.Ceiling(timed.Idle.TotalSeconds)) + " s sans nouvelle ligne, "
                        + FrenchText.Integer(timed.Received) + " lignes reçues. Résultats partiels conservés ; relance explicite requise.";
                }
                using (OperationPhases.Measure(OperationPhase.Validation))
                {
                    var responseIds = new HashSet<Guid>();
                    var responseDns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    if (entries.Count > count || entries.Any(e => !WithinLdapScope(query, e.DistinguishedName)
                        || e.Guid("objectGUID") is not { } id || id == Guid.Empty || !responseIds.Add(id)
                        || string.IsNullOrWhiteSpace(e.String("name"))
                        || !responseDns.Add(DistinguishedName.Format(DistinguishedName.Parse(e.DistinguishedName)))))
                    { throw Invalid("Réponse LDAP hors des limites, du périmètre ou sans identité unique."); }
                }
                // The base is a valid LDAP response, not one of its own children. This also keeps a domain root
                // out of the object projector, whose supported identities belong below that root.
                var descendants = entries.Where(entry => !SearchLists.IsRoot(entry.DistinguishedName, query.BaseDn)).ToArray();
                var projected = AdObjectAccess.Project(descendants, domain, at);
                var candidates = SearchRowFactory.Candidates(projected).ToDictionary(c => c.Id);
                var factory = new SearchRowFactory(projected, source.CurrentObservations.Workstations, new Enrichment(source.CurrentDirectory ?? projected, source.FleetDetails), at);
                var lastInStage = after;
                foreach (var entry in descendants)
                {
                    var id = entry.Guid("objectGUID")!.Value;
                    if (known.Contains(id.ToString("D")) || given.Contains(id)) { continue; }
                    if (rows.Count == query.Take)
                    {
                        more = true;
                        cursor = stage.Key + ":" + lastInStage;
                        break;
                    }
                    given.Add(id);
                    accepted.Add(entry);
                    rows.Add(factory.Row(candidates[id].Source));
                    // The server's raw name is the continuation key; French display folding is not an AD collation.
                    lastInStage = entry.String("name") ?? throw Invalid("Clé de tri LDAP absente.");
                    cursor = stage.Key + ":" + lastInStage;
                }
                OperationPhases.Progress(rows.Count);
                if (more || interrupted) { break; }
            }
            if (source.Epoch != generation) { throw Invalid("Session modifiée pendant la recherche."); }
            SearchReadQualification? qualification = null;
            if (query.Reconcile)
            {
                // A timeout cannot spend another network budget certifying its partial rows.
                var after = stamp is not null && !interrupted
                    ? await ReadControllerStampAsync(domain.RootDn, budget.Token).ConfigureAwait(false) : null;
                var current = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                if (source.Epoch != generation || ReaderFingerprint(current) != ReaderFingerprint(session!))
                { throw Invalid("Identité modifiée pendant la revérification ; résultat écarté."); }
                qualification = interrupted && stamp is not null
                    ? QualifyCheckpoint(query, fingerprint, ReaderFingerprint(current), generation, at, rows.Count, true, stamp, stamp, incremental)
                    : QualifyCheckpoint(query, fingerprint, ReaderFingerprint(current), generation, at, rows.Count, more, stamp, after, incremental);
            }
            if (qualification is not null) { qualification = qualification with { Incremental = incremental }; }
            if (accepted.Count > 0)
            {
                await source.RememberObjectsAsync(AdObjectAccess.Project(accepted, domain, at), generation, cancellationToken).ConfigureAwait(false);
            }
            cancellationToken.ThrowIfCancellationRequested();
            return new(rows.ToImmutable(), interrupted ? false : more, interrupted || incremental ? null : cursor, at, "Annuaire · " + (source.ControllerName ?? domain.DnsName))
            { Interrupted = interrupted, Interruption = interruption, Qualification = qualification };
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && deadline.Token.IsCancellationRequested)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Budget de recherche atteint : résultat incomplet non publié. Affinez le texte ou le périmètre."); }
    }

    private static bool WithinLdapScope(SearchQuery query, string dn) =>
        ScopeRules.Contains(new(query.BaseDn, "", query.Subtree), dn)
        || query.Subtree && SearchLists.IsRoot(dn, query.BaseDn);

    private static void ValidateQuery(SearchQuery query)
    {
        ArgumentNullException.ThrowIfNull(query);
        if (query.Take is < 1 or > SearchLimits.MaxLimit || query.Known.Count > SearchLimits.MaxLimit
            || !query.Plan.Valid || query.Plan.Kind == SearchPlanKind.Address || string.IsNullOrWhiteSpace(query.Plan.LdapFilter)
            || query.After is { } key && (key.Length is < 2 or > 1026 || key[1] != ':'))
        { throw Invalid("Recherche invalide ou hors des limites : aucun objet lu."); }
        if (query.Reconcile && (query.After is not null || query.Known.Count != 0))
        { throw Invalid("La revérification relit la liste complète dans sa limite, sans curseur de pagination."); }
    }

    private static List<(string Key, string Filter)> Stages(SearchQuery query, DateTimeOffset at)
    {
        if (query.Kind == SearchListKind.View)
        {
            var view = SearchViews.All(at).FirstOrDefault(v => v.Id == query.ViewId)
                ?? throw new DomeniaOperationException(SearchErrors.ViewUnknown, SearchErrors.ViewUnknownMessage);
            return [("p", view.LdapFilter)];
        }
        if (query.Kind != SearchListKind.Search || query.Plan.Kind != SearchPlanKind.Default || !query.Plan.Tokens.IsEmpty)
        { return [("p", query.Plan.LdapFilter)]; }
        var words = SearchText.Words(query.Plan.FreeText);
        if (words.IsEmpty || words.Any(w => w.Contains('*', StringComparison.Ordinal))) { return [("p", query.Plan.LdapFilter)]; }
        var type = SearchText.TypeLdapFilter(query.Type);
        var stages = new List<(string Key, string Filter)>();
        if (words.Length == 1)
        {
            var literal = SearchText.LdapLiteral(words[0]);
            var exact = "(|" + string.Concat(new[] { "name", "sAMAccountName", "userPrincipalName", "mail", "dNSHostName" }.Select(a => "(" + a + "=" + literal + ")")) + ")";
            stages.Add(("e", "(&" + type + exact + ")"));
        }
        stages.Add(("p", query.Plan.LdapFilter));
        stages.Add(("a", "(&" + type + string.Concat(words.Select(w => "(anr=" + SearchText.LdapLiteral(w) + ")")) + "(!" + query.Plan.LdapFilter + "))"));
        return stages;
    }

    private static void EnsureBase(string dn, string root)
    {
        if (!SearchLists.IsRoot(dn, root) && !ScopeRules.Contains(new(root, "", true), dn))
        { throw new DomeniaOperationException(DomeniaErrors.ScopeOutsideDomain, DomeniaErrors.ScopeOutsideDomainMessage); }
    }

    public async Task<ImmutableArray<SearchContainer>> ContainersAsync(bool counts, CancellationToken cancellationToken)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(60), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
        var epoch = source.Epoch;
        var found = await source.Connection.SearchAsync(new(domain.RootDn, "(objectClass=container)", AdSearchScope.OneLevel, ["distinguishedName", "name"])
        { PageSize = 500, SizeLimit = 501, Timeout = TimeSpan.FromSeconds(15) }, budget.Token).ConfigureAwait(false);
        if (found.Count > 500) { throw Invalid("Plus de 500 conteneurs : liste tronquée, affinez le périmètre."); }
        var result = ImmutableArray.CreateBuilder<SearchContainer>();
        foreach (var entry in found)
        {
            if (!ScopeRules.Contains(new(domain.RootDn, "", false), entry.DistinguishedName)) { throw Invalid("Conteneur hors domaine."); }
            var total = -1;
            if (counts)
            {
                var children = await source.Connection.SearchAsync(new(entry.DistinguishedName, SearchText.TypeLdapFilter(SearchTypeFilter.All), AdSearchScope.OneLevel, ["objectGUID"])
                { PageSize = 500, SizeLimit = 10_001, Timeout = TimeSpan.FromSeconds(15) }, budget.Token).ConfigureAwait(false);
                if (children.Count <= 10_000) { total = children.Count; }
            }
            result.Add(new(entry.DistinguishedName, entry.String("name") ?? SearchTexts.Leaf(entry.DistinguishedName), SearchContainers.IsSystem(entry.DistinguishedName, domain.RootDn), total));
        }
        if (source.Epoch != epoch) { throw Invalid("Session modifiée pendant la lecture des conteneurs."); }
        return [.. result.OrderBy(c => c.System).ThenBy(c => c.Name, StringComparer.OrdinalIgnoreCase)];
    }

    public async Task<ImmutableArray<SearchRow>> RereadAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        if (ids.Count == 0) { return []; }
        if (ids.Count > 500 || ids.Any(id => id == Guid.Empty)) { throw Invalid("Relecture limitée à 500 identités valides."); }
        await source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var epoch = source.Epoch;
        var objects = await new AdObjectAccess(source).ReadAsync(ids.ToArray(), cancellationToken).ConfigureAwait(false);
        await source.RememberObjectsAsync(objects, epoch, cancellationToken).ConfigureAwait(false);
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var factory = new SearchRowFactory(objects, state.Observations.Workstations, new Enrichment(state.Directory, source.FleetDetails), source.Clock.GetUtcNow());
        var found = SearchRowFactory.Candidates(objects).ToDictionary(c => c.Id);
        return [.. ids.Where(found.ContainsKey).Select(id => factory.Row(found[id].Source))];
    }

    private static DomeniaOperationException Invalid(string message) => new(DomeniaErrors.ArgumentsInvalid, message);
}
