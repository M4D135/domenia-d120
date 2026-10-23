using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Explicit bounded LDAP reads, held in a verified local spool until the operator confirms their local storage plan.</summary>
public sealed partial class AdSyncReader(AdDirectorySource source) : ISyncReader
{
    private ISyncLocalStore Store => source.LocalStore as ISyncLocalStore ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Stockage de synchronisation indisponible.");
    private AdSyncState State => AdSyncState.For(source);
    private static void Scope(SyncScope scope, string domain)
    {
        if (!SyncLocations.InScope(scope.Dn, domain) || scope.IsDomain != DistinguishedName.AreEqual(scope.Dn, domain))
        { throw new DomeniaOperationException(SyncErrors.OutsideDomain, "Périmètre de synchronisation hors domaine ou ambigu."); }
    }
    private SyncCoverage Coverage(SyncLocalState local, SyncScope scope) => SyncCoverageRules.Coverage(scope.Dn, local.DomainDn, local.Scopes, source.Clock.GetUtcNow(), source.Zone, scope.Subtree);
    private SyncBackupInfo Backup(SyncLocalState local)
    {
        var decision = SyncCoverageRules.Backup(local.BackupAt, source.Clock.GetUtcNow());
        return new(local.BackupAt, decision.Due, SyncCoverageRules.BackupNotice(decision, source.Zone));
    }

    public async Task<SyncOverview> OverviewAsync(SyncScope scope, SyncSettings settings, CancellationToken cancellationToken)
    {
        var local = await Store.ReadSyncStateAsync(cancellationToken).ConfigureAwait(false); Scope(scope, local.DomainDn);
        var now = source.Clock.GetUtcNow(); var coverage = Coverage(local, scope);
        var checkpoint = LocalCheckpoint(local);
        var census = SyncCoverageRules.Census(coverage, local.Gaps.Length, settings.FullRebuildDays, now, scope.IsDomain);
        var rows = local.Rows; var users = rows.Count(r => r.Type == IndexObjectType.User); var enabled = rows.Count(r => r.Type == IndexObjectType.User && r.Enabled);
        var computers = rows.Count(r => r.Type == IndexObjectType.Computer); var active = rows.Count(r => r.Type == IndexObjectType.Computer && r.Enabled);
        // Relation totals remain explicitly unknown until their independent store has been read.
        var tiles = SyncCoverageRules.Tiles(new(enabled, users - enabled, active, computers - active, 0, 0), coverage.At, now, source.Zone, settings.FullRebuildDays)
            .Select(t => t.Key is "links" or "associations" ? t with { Number = null, Value = "Non mesuré", Detail = "Consultez Utilisateurs et postes pour les associations enregistrées." } : t).ToImmutableArray();
        var limits = SyncCoverageRules.Limits(settings.MaxObjects, settings.BudgetMs);
        var storage = SyncCoverageRules.Storage(false, 0, null, null, 0, now, source.Zone);
        var scopes = SyncCoverageRules.ScopeStates(local.Scopes, local.DomainDn, source.KnownDomain?.DnsName, now, source.Zone, settings.FullRebuildDays);
        SyncRunInfo? running; SyncPendingBatch? pending;
        lock (State.Gate)
        {
            State.Purge(); running = State.Running;
            pending = State.Batches.Values.Select(x => x.Header).OrderByDescending(x => x.At).Select(x => new SyncPendingBatch(x.Id, "index", x.Label, x.Rows, x.At, x.Expires)).FirstOrDefault();
        }
        var park = await ParkAsync(cancellationToken).ConfigureAwait(false);
        return new(scope, "Base SQLite locale", false, local.Revision, rows.Length, tiles, coverage,
            SyncCoverageRules.Freshness(rows.Length, coverage, null, census, now, source.Zone), census, checkpoint, scopes,
            LegacyNotices(local, SyncCoverageRules.Notices(rows.Length, checkpoint, null, now, settings.StartupDeltaMaxAgeMinutes)), null,
            new(limits.MaxObjects, limits.BudgetMs, SyncText.Duration(limits.BudgetMs), limits.TimeoutSeconds, settings.FullRebuildDays, settings.StartupDeltaMaxAgeMinutes,
                SyncIndex.DefaultPageSize, SyncIndex.MaxPageSize, SyncAbsences.CheckLimit, SyncSnapshots.MaxPerDomain, SyncSnapshots.MaxObjects, settings.Source),
            SyncCoverageRules.Readiness(running is not null, false, storage.Refusal), running, pending, local.Receipts, Backup(local), park.Coverage,
            "Index Domenia 1/2 lu dans une transaction locale. Aucun accès à l’annuaire à l’ouverture.",
            "Les lectures réseau restent à confirmer ; leurs résultats attendent ensuite un plan d’enregistrement.", now,
            new(rows.Length, scopes.Length, local.Absences.Length, SyncAbsences.SelectToCheck(local.Absences).Length, local.Gaps.Length, local.Snapshots.Length, park.Rows.Length), storage, SyncIndex.LapsSchemaUnknown);
    }
    public async Task<ImmutableArray<SyncNotice>> StartupNoticesAsync(SyncSettings settings, CancellationToken cancellationToken)
    {
        var local = await Store.ReadSyncStateAsync(cancellationToken).ConfigureAwait(false);
        return LegacyNotices(local, SyncCoverageRules.Notices(local.Rows.Length, LocalCheckpoint(local), null, source.Clock.GetUtcNow(), settings.StartupDeltaMaxAgeMinutes));
    }
    private static ImmutableArray<SyncNotice> LegacyNotices(SyncLocalState local, ImmutableArray<SyncNotice> notices) => local.UnidentifiedLegacyObjects == 0 ? notices
        : notices.Add(new(Tone.Warn, FrenchText.Integer(local.UnidentifiedLegacyObjects) + " objets historiques conservés sans GUID : absents des totaux tant que leurs identités n’ont pas été relues dans l’annuaire. Aucun GUID inventé."));

    public Task<IndexSearchPage> SearchAsync(IndexQuery query, CancellationToken cancellationToken) => Store.SearchSyncIndexAsync(query, cancellationToken);
    public async Task<ImmutableArray<IndexHit>> ExportRowsAsync(IndexQuery query, int max, CancellationToken cancellationToken)
    {
        var local = await Store.ReadSyncStateAsync(cancellationToken).ConfigureAwait(false); Scope(query.Scope, local.DomainDn);
        var browse = SyncIndex.Normalize(query.Term).Length == 0;
        return [.. SyncIndex.Matches(local.Rows, query).Take(Math.Clamp(max, 1, SyncIndex.ExportLimit)).Select(x => SyncIndex.Hit(x.Record, x.Score, browse, null))];
    }
    public async Task<SyncControls> ControlsAsync(SyncScope scope, SyncSettings settings, CancellationToken cancellationToken)
    {
        var local = await Store.ReadSyncStateAsync(cancellationToken).ConfigureAwait(false); Scope(scope, local.DomainDn);
        bool ready; lock (State.Gate) { ready = State.Running is null; }
        return new(scope, SyncCoverageRules.Census(Coverage(local, scope), local.Gaps.Length, settings.FullRebuildDays, source.Clock.GetUtcNow(), scope.IsDomain),
            SyncAbsences.Gaps(local.Gaps, ready), SyncAbsences.List(local.Absences, source.Zone, ready, SyncAbsences.ShownLimit, scope.IsDomain ? null : scope.Dn),
            SyncSnapshots.List(local.Snapshots, source.Zone), local.Revision, source.Clock.GetUtcNow());
    }
    public async Task<SyncSnapshotComparison> CompareSnapshotsAsync(string beforeId, string afterId, CancellationToken cancellationToken)
    {
        var local = await Store.ReadSyncStateAsync(cancellationToken).ConfigureAwait(false);
        var before = local.Snapshots.FirstOrDefault(x => x.Id == beforeId); var after = local.Snapshots.FirstOrDefault(x => x.Id == afterId);
        if (before is null || after is null) { throw new DomeniaOperationException(SyncErrors.SnapshotUnknown, SyncErrors.SnapshotUnknownMessage); }
        return SyncSnapshots.Compare(before, after, source.Zone);
    }
    public async Task<ParkState> ParkAsync(CancellationToken cancellationToken)
    {
        if (source.LocalStore is not IRelationSweepCache reader) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Relevé du parc indisponible."); }
        var stored = await reader.ReadRelationSweepsAsync(cancellationToken).ConfigureAwait(false);
        if (stored.Truncated || stored.Rejected > 0 || stored.UncertainDates > 0) { throw new InvalidDataException(stored.Notice); }
        var rows = stored.Rows.Select(x => new ParkEntry(x.Computer, x.At ?? DateTimeOffset.MinValue, x.Status.ToLowerInvariant() switch
        { "confirmed" or "session" => ParkStatus.Session, "empty" => ParkStatus.Empty, "unreachable" => ParkStatus.Unreachable, "refused" => ParkStatus.Refused, _ => ParkStatus.Error }, x.UserLogin, x.Attempts, null)).ToImmutableArray();
        return new(SyncPark.Coverage(rows, -1, -1, source.Clock.GetUtcNow()), [.. rows.Select(SyncPark.Row)],
            new(false, null, null, "Aucun fichier partagé configuré dans ce lecteur ; relevé local conservé.", false), stored.Generation, 0, null, source.Clock.GetUtcNow());
    }
    public Task<ParkSharedRead> ReadSharedParkAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        throw new DomeniaOperationException(SyncErrors.SharedNotConfigured, SyncErrors.SharedNotConfiguredMessage);
    }

    public async Task<SyncEstimate> EstimateAsync(SyncEstimateRequest request, CancellationToken cancellationToken)
    {
        var local = await Store.ReadSyncStateAsync(cancellationToken).ConfigureAwait(false); Scope(request.Scope, local.DomainDn);
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var scope = request.Target == SyncTarget.Domain ? new SyncScope(local.DomainDn, "Domaine entier", "Domaine entier", true, true, "Choix explicite") : request.Scope;
        if (request.Target == SyncTarget.Ou && scope.IsDomain) { throw new DomeniaOperationException(SyncErrors.OutsideDomain, "Choisissez une OU pour cette lecture."); }
        var limits = SyncCoverageRules.Limits(request.MaxObjects ?? request.Settings.MaxObjects, request.BudgetSeconds is { } seconds ? checked(seconds * 1000) : request.Settings.BudgetMs);
        var known = local.Rows.Count(x => ScopeRules.Contains(new(scope.Dn, scope.Label, scope.Subtree), x.Dn));
        var checkpoint = LocalCheckpoint(local);
        var mode = request.Target == SyncTarget.Ou ? SyncReadMode.Ou : !request.Rebuild && checkpoint is not null ? SyncReadMode.Incremental : SyncReadMode.Full;
        var ready = session.Connection == ConnectionState.Connected && source.LocalStore is IPreparedDirectoryCache and ISyncBatchSpool;
        var estimate = new SyncEstimate(WritePlans.NewId(), request.Target, scope, mode, ModeLabel(mode),
            mode == SyncReadMode.Incremental ? "Repère local disponible ; contrôleur, instance, compte et USN seront vérifiés pendant le geste. Au moindre doute, lecture complète dans le même budget confirmé."
                : "Lecture complète explicitement confirmée ; un nouveau repère ne sera conservé qu’avec une instance de contrôleur certifiée.", known, known, 0,
            "Durée non estimée sans mesure antérieure ; aucune lecture réseau pour cette estimation.", limits.MaxObjects, Math.Min(limits.BudgetMs, 7_200_000), limits.TimeoutSeconds,
            Backup(local), ["Lecture bornée à 300 000 objets au maximum. Un arrêt conserve seulement un lot incomplet.", "Les changements du domaine incluent un recensement des GUID ; une identité absente de la base impose une lecture complète dans ce budget.", "Les objets non revus sont signalés, jamais déclarés supprimés."],
            "Lire " + scope.Label, "Lire l’annuaire", "Lecture réseau explicite, puis aperçu avant toute écriture locale.", ready,
            ready ? null : "Connexion au domaine et stockage sauvegardable requis.", source.Clock.GetUtcNow().AddMinutes(15), request.Rebuild, request.Target == SyncTarget.Domain);
        lock (State.Gate) { State.Purge(); if (State.Estimates.Count >= 32) { throw new DomeniaOperationException("sync.estimateCapacity", "Trop d’estimations en attente."); } State.Estimates.Add(estimate.Id, (estimate, source.Epoch)); }
        return estimate;
    }

    internal static IndexRecord? Project(AdEntry entry, IndexObjectType type, DateTimeOffset at)
    {
        if (entry.Guid("objectGUID") is not { } id || id == Guid.Empty || entry.Sid("objectSid") is null || entry.Int("userAccountControl") is not { } uac) { return null; }
        var windows = AdValues.FromFileTime(entry.Long("msLAPS-PasswordExpirationTime") ?? 0); var legacy = AdValues.FromFileTime(entry.Long("ms-Mcs-AdmPwdExpirationTime") ?? 0);
        return new(id, type, entry.String("name") ?? entry.String("cn") ?? "", entry.String("sAMAccountName"), entry.String(type == IndexObjectType.Computer ? "dNSHostName" : "userPrincipalName"),
            type == IndexObjectType.Computer ? null : entry.String("displayName"), entry.String("description"),
            string.Join(" / ", (type == IndexObjectType.Computer ? new[] { entry.String("operatingSystem"), entry.String("location") } : new[] { entry.String("department"), entry.String("title") }).Where(x => !string.IsNullOrWhiteSpace(x))),
            !AdValues.IsDisabled(uac), entry.DistinguishedName, entry.Time("whenChanged"), entry.Long("uSNChanged") ?? 0, AdValues.FromFileTime(entry.Long("lastLogonTimestamp") ?? 0),
            windows is not null ? LapsKind.Windows : legacy is not null ? LapsKind.Legacy : LapsKind.None, windows ?? legacy, at);
    }
    private (string Id, CancellationTokenSource Stop) Start(SyncTarget target, string label)
    {
        lock (State.Gate)
        {
            State.Purge(); if (State.Running is not null) { throw new DomeniaOperationException(SyncErrors.Busy, SyncErrors.BusyMessage); }
            var id = WritePlans.NewId(); var stop = new CancellationTokenSource(); State.Stop = stop;
            State.Running = new(id, target == SyncTarget.Domain ? "domain" : "ou", label, "reading", "Lecture", source.Clock.GetUtcNow(), false);
            return (id, stop);
        }
    }
    private void Finish(CancellationTokenSource stop) { lock (State.Gate) { if (ReferenceEquals(State.Stop, stop)) { State.Stop = null; State.Running = null; } } stop.Dispose(); }
    public SyncStop StopRead(string runId)
    {
        lock (State.Gate) { if (State.Running?.RunId != runId || State.Stop is null) { return new(false, "Aucune lecture correspondante en cours."); } State.Stop.Cancel(); State.Running = State.Running with { Stopping = true }; return new(true, "Arrêt demandé ; le résultat confirmera la portée réellement lue."); }
    }
    public SyncDiscard DiscardRead(string batchId) { lock (State.Gate) { var removed = State.Remove(batchId); return new(removed, removed ? "Lecture ignorée ; base inchangée." : "Lecture déjà absente."); } }
}
