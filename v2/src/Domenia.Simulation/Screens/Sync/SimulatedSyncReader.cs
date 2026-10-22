using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// « Synchronisation et base autonome » in simulation (docs/ops/synchro.md): the local base is derived from the fictitious
/// directory (<see cref="SimulatedSyncSeed"/>) and kept in memory for the session (<see cref="SimulatedSyncState"/>); the
/// « directory reads » read the fictitious directory as the session sees it (<see cref="SimulatedDirectorySource.CurrentDirectory"/>),
/// with realistic, cancellable delays and progress, and keep their result as a batch: only the storage plan (write.execute) changes
/// the base. No network, no disk.
/// </summary>
public sealed class SimulatedSyncReader : ISyncReader
{
    private const string OuSuffixHint = " et ses sous-OU";
    private readonly SimulatedDirectorySource source;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is read here.</summary>
    public SimulatedSyncReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    private SimulatedSyncState State => SimulatedSyncState.For(source);

    // ---------------------------------------------------------------- records of the fictitious directory

    /// <summary>Index row of a user, as the index read of Domenia 1 keeps it (department and title in « extra »).</summary>
    internal static IndexRecord ToRecord(DirectoryUser user, DateTimeOffset observed)
    {
        var extra = string.Join(" / ", new[] { user.Department, user.Title }.Where(s => !string.IsNullOrWhiteSpace(s)));
        return new IndexRecord(user.ObjectGuid, IndexObjectType.User, user.Cn, user.SamAccountName, user.UserPrincipalName, user.DisplayName, user.Description,
            extra.Length == 0 ? null : extra, !AdValues.IsDisabled(user.UserAccountControl), user.DistinguishedName, user.WhenChanged, user.UsnChanged,
            AdValues.FromFileTime(user.LastLogonTimestamp), LapsKind.None, null, observed);
    }

    /// <summary>Index row of a computer (system and location in « extra », the LAPS expiration date, never a password).</summary>
    internal static IndexRecord ToRecord(DirectoryComputer computer, DateTimeOffset observed)
    {
        var extra = string.Join(" / ", new[] { computer.OperatingSystem, computer.Location }.Where(s => !string.IsNullOrWhiteSpace(s)));
        return new IndexRecord(computer.ObjectGuid, IndexObjectType.Computer, computer.Name, computer.SamAccountName, computer.DnsHostName, null, computer.Description,
            extra.Length == 0 ? null : extra, !AdValues.IsDisabled(computer.UserAccountControl), computer.DistinguishedName, computer.WhenChanged, computer.UsnChanged,
            AdValues.FromFileTime(computer.LastLogonTimestamp), computer.Laps, AdValues.FromFileTime(computer.LapsExpiration), observed);
    }

    /// <summary>The users and computers of the fictitious directory as a read now would return them (computers first, like Domenia 1).</summary>
    private List<IndexRecord> Truth(DateTimeOffset observed)
    {
        var directory = source.CurrentDirectory;
        var rows = new List<IndexRecord>(directory.Users.Length + directory.Computers.Length);
        rows.AddRange(directory.Computers.Select(c => ToRecord(c, observed)));
        rows.AddRange(directory.Users.Select(u => ToRecord(u, observed)));
        return rows;
    }

    // ---------------------------------------------------------------- local reads

    public async Task<SyncOverview> OverviewAsync(SyncScope scope, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scope);
        await source.SimulateScreenLatencyAsync("synchro/overview", 80, 160, cancellationToken).ConfigureAwait(false);
        var now = source.Clock.GetUtcNow();
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            state.Purge(now);
            var zone = state.Zone;
            var coverage = SyncCoverageRules.Coverage(scope.IsDomain ? null : scope.Dn, state.DomainDn, state.SyncStates, now, zone);
            var census = SyncCoverageRules.Census(coverage, state.OpenGaps().Count, SyncCoverageRules.DefaultFullRebuildDays, now, scope.IsDomain);
            var rows = state.Rows.Values;
            var users = rows.Count(r => r.Type == IndexObjectType.User);
            var computers = rows.Count(r => r.Type == IndexObjectType.Computer);
            var active = rows.Count(r => r.Type == IndexObjectType.Computer && r.Enabled);
            var partial = state.Partial is { } marker ? SyncCoverageRules.PartialText(marker.At, marker.Count, marker.Reason, marker.Limit, zone) : null;
            var tiles = SyncCoverageRules.Tiles(users, computers, active, computers - active, state.LinkCount, coverage.At, now, zone);
            var freshness = SyncCoverageRules.Freshness(rows.Count, coverage, scope.IsDomain ? partial : null, census, now, zone);
            var scopes = SyncCoverageRules.ScopeStates(state.SyncStates, state.DomainDn, state.DomainName, now, zone);
            var notices = SyncCoverageRules.Notices(rows.Count, state.Checkpoint, partial, now);
            var limits = SyncCoverageRules.Limits(null, null);
            var syncLimits = new SyncLimits(limits.MaxObjects, limits.BudgetMs, SyncText.Duration(limits.BudgetMs), limits.TimeoutSeconds, SyncCoverageRules.DefaultFullRebuildDays,
                SyncCoverageRules.DefaultStartupDeltaMaxAgeMinutes, SyncIndex.DefaultPageSize, SyncIndex.MaxPageSize, SyncAbsences.CheckLimit, SyncSnapshots.MaxPerDomain, SyncSnapshots.MaxObjects);
            var readiness = SyncCoverageRules.Readiness(state.Run is not null, state.Committing, null);
            var running = state.Run is { } run
                ? new SyncRunInfo(run.RunId, run.Target == SyncTarget.Domain ? "domain" : "ou", run.ScopeLabel, Phase(run.Phase), PhaseLabel(run.Phase), run.StartedAt, run.Stop.IsCancellationRequested)
                : null;
            var pending = state.Batches.Values.OfType<IndexBatch>().OrderByDescending(b => b.CreatedAt).Select(b => new SyncPendingBatch(b.Id, b.Kind, b.Label, b.Count, b.CreatedAt, b.ExpiresAt)).FirstOrDefault();
            var decision = SyncCoverageRules.Backup(state.LastBackupAt, now);
            var backup = new SyncBackupInfo(state.LastBackupAt, decision.Due, SyncCoverageRules.BackupNotice(decision, zone));
            var park = SyncPark.Coverage(state.Park.Values, active, state.Dormants, now);
            var c = SyncText.C;
            var details = "Contrôleur de la dernière lecture" + c + (state.Checkpoint?.Controller ?? "inconnu") + ". Objets enregistrés" + c + FrenchText.Integer(rows.Count)
                + ". Associations utilisateur-poste" + c + FrenchText.Integer(state.LinkCount) + ". Génération de la base" + c + FrenchText.Integer(state.Generation) + ".";
            var lead = "Copie locale de " + FrenchText.Count(users, "compte", "comptes") + " et " + FrenchText.Count(computers, "poste", "postes") + ", consultable sans réseau. "
                + (coverage.At is { } at
                    ? "Périmètre " + FrenchText.Quote(scope.Label) + " couvert par une lecture complète " + SyncText.Elapsed(at, now) + "."
                    : "Périmètre " + FrenchText.Quote(scope.Label) + " jamais lu en entier.")
                + (state.Checkpoint is { } checkpoint ? " Changements du domaine lus " + SyncText.Elapsed(checkpoint.At, now) + "." : "");
            return new SyncOverview(scope, "Base locale de la simulation (en mémoire)", true, state.Generation, rows.Count, tiles, coverage, freshness, census, state.Checkpoint,
                scopes, notices, partial, syncLimits, readiness, running, pending, [.. state.StorageReceipts.Take(6)], backup, park, details, lead);
        }
    }

    public async Task<IndexSearchPage> SearchAsync(IndexQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        await source.SimulateScreenLatencyAsync("synchro/search", 40, 120, cancellationToken).ConfigureAwait(false);
        var state = State;
        if (state.Committing)
        {
            // A commit holds the base: one short wait (Domenia 1 BusyTimeoutMs 50), then « busy », never an empty result.
            await Task.Delay(TimeSpan.FromMilliseconds(50), source.Clock, cancellationToken).ConfigureAwait(false);
        }
        lock (state.Gate)
        {
            state.EnsureSeeded();
            return state.Committing
                ? SyncIndex.Busy(query, state.Generation)
                : SyncIndex.Page(state.Rows.Values, query, state.Association, state.Generation);
        }
    }

    public async Task<ImmutableArray<IndexHit>> ExportRowsAsync(IndexQuery query, int max, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        await source.SimulateScreenLatencyAsync("synchro/search", 40, 120, cancellationToken).ConfigureAwait(false);
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            var browse = SyncIndex.Normalize(query.Term).Length == 0;
            return [.. SyncIndex.Matches(state.Rows.Values, query).Take(Math.Max(1, max)).Select(m => SyncIndex.Hit(m.Record, m.Score, browse, state.Association(m.Record)))];
        }
    }

    public async Task<SyncControls> ControlsAsync(SyncScope scope, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scope);
        await source.SimulateScreenLatencyAsync("synchro/controls", 80, 180, cancellationToken).ConfigureAwait(false);
        var now = source.Clock.GetUtcNow();
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            var coverage = SyncCoverageRules.Coverage(scope.IsDomain ? null : scope.Dn, state.DomainDn, state.SyncStates, now, state.Zone);
            var census = SyncCoverageRules.Census(coverage, state.OpenGaps().Count, SyncCoverageRules.DefaultFullRebuildDays, now, scope.IsDomain);
            return new SyncControls(scope, census, SyncAbsences.Gaps(state.OpenGaps(), state.Run is null), SyncAbsences.List(state.Absences, state.Zone, state.Run is null),
                SyncSnapshots.List(state.Snapshots, state.Zone), state.Generation);
        }
    }

    public async Task<SnapshotComparison> CompareSnapshotsAsync(string beforeId, string afterId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(beforeId);
        ArgumentNullException.ThrowIfNull(afterId);
        await source.SimulateScreenLatencyAsync("synchro/compare", 200, 420, cancellationToken).ConfigureAwait(false);
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            var before = state.Snapshots.FirstOrDefault(s => s.Id == beforeId);
            var after = state.Snapshots.FirstOrDefault(s => s.Id == afterId);
            if (before is null || after is null)
            {
                throw new DomeniaOperationException(SyncErrors.SnapshotUnknown, SyncErrors.SnapshotUnknownMessage);
            }
            return SyncSnapshots.Compare(before, after, state.Zone);
        }
    }

    public async Task<ParkState> ParkAsync(CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("synchro/park", 60, 140, cancellationToken).ConfigureAwait(false);
        var now = source.Clock.GetUtcNow();
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            var active = state.Rows.Values.Count(r => r.Type == IndexObjectType.Computer && r.Enabled);
            var coverage = SyncPark.Coverage(state.Park.Values, active, state.Dormants, now);
            var rows = state.Park.Values.OrderByDescending(e => e.LastProbe).ThenBy(e => e.Computer, StringComparer.Ordinal).Select(SyncPark.Row).ToImmutableArray();
            var c = SyncText.C;
            var text = "Relevé partagé entre consoles" + c + state.SharedPath + (state.SharedLastSync is { } at ? ", dernière synchronisation le " + SyncText.LocalDateTime(at, state.Zone) : ", jamais synchronisé")
                + ". Lecture et fusion sous verrou (fichier .lock, " + FrenchText.Integer(SyncPark.LockAttempts) + " essais), écriture après votre confirmation.";
            return new ParkState(coverage, rows, new ParkShared(true, state.SharedPath, state.SharedLastSync, text, state.Run is null), state.Generation);
        }
    }

    // ---------------------------------------------------------------- estimate and directory reads

    public async Task<SyncEstimate> EstimateAsync(SyncEstimateRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        await source.SimulateScreenLatencyAsync("synchro/estimate", 60, 140, cancellationToken).ConfigureAwait(false);
        if (request.Target == SyncTarget.Ou && request.Scope.IsDomain)
        {
            throw new DomeniaOperationException(SyncErrors.ScopeRoot, SyncErrors.ScopeRootMessage);
        }
        var now = source.Clock.GetUtcNow();
        var truth = Truth(now);
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            state.Purge(now);
            var zone = state.Zone;
            var c = SyncText.C;
            var limits = SyncCoverageRules.Limits(request.MaxObjects, request.BudgetSeconds is { } seconds ? checked(seconds * 1000) : null);
            var readiness = SyncCoverageRules.Readiness(state.Run is not null, state.Committing, null);
            SyncReadMode mode;
            string? reason = null;
            int expected;
            int known;
            int estimatedMs;
            string title;
            string confirm;
            var warnings = ImmutableArray.CreateBuilder<string>();
            if (request.Target == SyncTarget.Ou)
            {
                mode = SyncReadMode.Ou;
                expected = truth.Count(t => SyncLocations.InScope(t.Dn, request.Scope.Dn));
                known = state.Rows.Values.Count(r => SyncLocations.InScope(r.Dn, request.Scope.Dn));
                estimatedMs = 600 + 18 * expected;
                title = "Mettre à jour l’OU " + FrenchText.Quote(request.Scope.Label);
                confirm = "Lancer la lecture";
            }
            else
            {
                var check = SyncCoverageRules.CheckCheckpoint(state.Checkpoint, state.Controller, state.DomainDn, state.Rows.Count, truth.Count == 0 ? 0 : truth.Max(t => t.Usn), now);
                known = state.Rows.Count;
                if (check.Usable)
                {
                    mode = SyncReadMode.Incremental;
                    expected = truth.Count(t => t.Usn > state.Checkpoint!.Usn);
                    estimatedMs = 900 + 12 * expected + 2 * truth.Count;
                    title = "Mettre à jour les changements du domaine";
                    confirm = "Lire les changements";
                }
                else
                {
                    mode = SyncReadMode.Full;
                    reason = check.Reason;
                    expected = truth.Count;
                    estimatedMs = 1500 + 22 * expected;
                    title = "Relecture complète du domaine" + c + check.Reason.Replace(" : lecture complète.", "", StringComparison.Ordinal).TrimEnd('.');
                    confirm = "Relire tout le domaine";
                    warnings.Add("Domaine complet" + c + "opération longue et occasionnelle, selon le volume et le réseau. Privilégiez l’OU choisie au quotidien.");
                }
            }
            if (state.Batches.Values.OfType<IndexBatch>().FirstOrDefault() is { } pending)
            {
                warnings.Add("La lecture non enregistrée " + FrenchText.Quote(pending.Label) + " sera remplacée par celle-ci.");
            }
            if (limits.MaxObjects > 0 && expected > limits.MaxObjects)
            {
                warnings.Add("La passe sera coupée à " + FrenchText.Count(limits.MaxObjects, "objet", "objets") + c + "aucune disparition ne sera déduite et la date de couverture ne bougera pas.");
            }
            if (estimatedMs > limits.BudgetMs)
            {
                warnings.Add("Durée estimée au-delà du budget de " + SyncText.Duration(limits.BudgetMs) + c + "la passe sera coupée par la limite de temps, ce qu’elle aura lu restera une lecture partielle.");
            }
            var decision = SyncCoverageRules.Backup(state.LastBackupAt, now);
            var backup = new SyncBackupInfo(state.LastBackupAt, decision.Due, SyncCoverageRules.BackupNotice(decision, zone));
            var where = request.Target == SyncTarget.Ou ? "l’OU " + FrenchText.Quote(request.Scope.Label) + OuSuffixHint : "le domaine " + state.DomainName;
            var what = mode == SyncReadMode.Incremental
                ? "Lecture des " + FrenchText.Count(expected, "objet modifié", "objets modifiés") + " depuis le repère (USN " + FrenchText.Integer(state.Checkpoint!.Usn) + ") et recensement de "
                    + FrenchText.Count(truth.Count, "identité", "identités")
                : "Lecture d’environ " + FrenchText.Count(expected, "objet", "objets") + " dans " + where;
            var text = what + ", sur " + state.Controller + " (environ " + SyncText.Duration(estimatedMs) + "). Lecture seule de l’annuaire" + SyncText.Semi
                + " la base locale n’est modifiée qu’après votre confirmation de l’enregistrement. " + backup.Text;
            var id = WritePlans.NewId();
            var estimate = new SyncEstimate(id, request.Target, request.Scope, mode, ModeLabel(mode), reason, expected, known, estimatedMs, "environ " + SyncText.Duration(estimatedMs),
                limits.MaxObjects, limits.BudgetMs, limits.TimeoutSeconds, backup, warnings.ToImmutable(), title, confirm, text, readiness.Ready, readiness.Reason, now + SimulatedSyncState.BatchLifetime);
            if (readiness.Ready)
            {
                state.Estimates[id] = new EstimateRecord(estimate, request, limits.MaxObjects, limits.BudgetMs);
            }
            return estimate;
        }
    }

    public async Task<SyncReadResult> RunReadAsync(string estimateId, Action<SyncProgress> progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(estimateId);
        ArgumentNullException.ThrowIfNull(progress);
        var state = State;
        var started = source.Clock.GetUtcNow();
        EstimateRecord record;
        RunState run;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            state.Purge(started);
            if (!state.Estimates.Remove(estimateId, out var found))
            {
                throw new DomeniaOperationException(SyncErrors.EstimateUnknown, SyncErrors.EstimateUnknownMessage);
            }
            if (state.Run is not null)
            {
                throw new DomeniaOperationException(SyncErrors.Busy, SyncErrors.BusyMessage);
            }
            var readiness = SyncCoverageRules.Readiness(false, state.Committing, null);
            if (!readiness.Ready)
            {
                throw new DomeniaOperationException(SyncErrors.NotReady, readiness.Reason!);
            }
            record = found;
            run = new RunState(WritePlans.NewId(), record.Request.Target, record.Request.Target == SyncTarget.Ou ? record.Request.Scope.Label : state.DomainName, started);
            state.Run = run;
            // A new read replaces a read not stored yet (the operator was told by the estimate).
            foreach (var key in state.Batches.Values.OfType<IndexBatch>().Select(b => b.Id).ToList())
            {
                state.Batches.Remove(key);
            }
        }
        try
        {
            return await ReadAsync(state, record, run, progress, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            lock (state.Gate)
            {
                if (ReferenceEquals(state.Run, run))
                {
                    state.Run = null;
                }
            }
            run.Dispose();
        }
    }

    private async Task<SyncReadResult> ReadAsync(SimulatedSyncState state, EstimateRecord record, RunState run, Action<SyncProgress> progress, CancellationToken cancellationToken)
    {
        var estimate = record.Estimate;
        var request = record.Request;
        var c = SyncText.C;
        var random = source.ScreenStream("synchro").Fork("run/" + run.RunId);

        // 1. Verified backup of the base first (Domenia 1 FI-13), unless a recent one is the point of return.
        Report(state, run, progress, SyncPhase.Backup, 0, null, 0, estimate.Backup.Due ? "Sauvegarde vérifiée de la base avant la lecture…" : estimate.Backup.Text);
        if (estimate.Backup.Due)
        {
            await source.SimulateScreenLatencyAsync("synchro/read/backup", 300, 550, cancellationToken).ConfigureAwait(false);
            lock (state.Gate)
            {
                state.LastBackupAt = source.Clock.GetUtcNow();
            }
        }

        // 2. Read of the directory (fictitious): computers first, then users.
        var now = source.Clock.GetUtcNow();
        var truth = Truth(now);
        long checkpointUsn;
        SyncCheckpoint? checkpoint;
        lock (state.Gate)
        {
            checkpoint = state.Checkpoint;
            checkpointUsn = checkpoint?.Usn ?? 0;
        }
        var all = estimate.Mode switch
        {
            SyncReadMode.Ou => truth.Where(t => SyncLocations.InScope(t.Dn, request.Scope.Dn)).ToList(),
            SyncReadMode.Incremental => truth.Where(t => t.Usn > checkpointUsn).ToList(),
            _ => truth,
        };
        var msPerObject = estimate.Mode == SyncReadMode.Ou ? 18 : estimate.Mode == SyncReadMode.Incremental ? 12 : 22;
        var overhead = estimate.Mode == SyncReadMode.Ou ? 600 : estimate.Mode == SyncReadMode.Incremental ? 900 + 2 * truth.Count : 1500;
        var target = all.Count;
        SyncCut? cut = null;
        if (record.MaxObjects > 0 && target > record.MaxObjects)
        {
            target = (int)record.MaxObjects;
            cut = SyncCoverageRules.Cut("volume", record.MaxObjects, target);
        }
        if (overhead + msPerObject * target > record.BudgetMs)
        {
            target = Math.Max(0, Math.Min(target, (record.BudgetMs - overhead) / msPerObject));
            cut = SyncCoverageRules.Cut("temps", record.BudgetMs, target);
        }
        var ticks = source.Options.Latency == SimulationLatency.None ? 3 : 8 + random.Next(0, 6);
        var count = 0;
        var stopped = false;
        for (var i = 1; i <= ticks; i++)
        {
            await source.SimulateScreenLatencyAsync("synchro/read/tick", 110, 210, cancellationToken).ConfigureAwait(false);
            if (run.Stop.IsCancellationRequested)
            {
                stopped = true;
                break;
            }
            count = target * i / ticks;
            var elapsed = overhead + msPerObject * count;
            Report(state, run, progress, SyncPhase.Reading, count, null, elapsed,
                "Lecture AD" + c + FrenchText.Count(count, "objet reçu", "objets reçus") + " · " + FrenchText.Integer(elapsed <= 0 ? 0 : (long)(count * 1000.0 / elapsed)) + " objets/s · "
                + SyncText.Duration(elapsed) + ". Total inconnu avant la fin.", count * 1000.0 / Math.Max(1, elapsed));
        }
        if (stopped)
        {
            target = count;
            cut = SyncCoverageRules.Cut("arret", 0, count);
        }
        var rows = all.Take(target).ToImmutableArray();
        var complete = cut is null;
        var durationMs = overhead + msPerObject * rows.Length;

        // 3. Census of the identities (domain passes): every user and computer GUID, to find the gaps of the base.
        var census = ImmutableArray<CensusGapRecord>.Empty;
        if (estimate.Mode != SyncReadMode.Ou && complete)
        {
            Report(state, run, progress, SyncPhase.Census, truth.Count, truth.Count, durationMs,
                "Vérification des identités" + c + FrenchText.Count(truth.Count, "GUID reçu", "GUID reçus") + SyncText.Semi + " aucune absence validée pendant la lecture.");
            await source.SimulateScreenLatencyAsync("synchro/read/census", 250, 450, cancellationToken).ConfigureAwait(false);
            census = [.. truth.Select(t => new CensusGapRecord(t.ObjectGuid, t.Dn, now))];
            durationMs += 2 * truth.Count;
        }

        // 4. Transfer fingerprint (the « .jsonl haché » of Domenia 1), then 5. validation before it is kept.
        Report(state, run, progress, SyncPhase.Fingerprint, rows.Length, rows.Length, durationMs, "Lecture terminée" + c + FrenchText.Count(rows.Length, "objet", "objets") + ". Vérification du transfert…");
        await source.SimulateScreenLatencyAsync("synchro/read/fingerprint", 200, 380, cancellationToken).ConfigureAwait(false);
        var sha = SyncReconcile.Fingerprint(rows);
        Report(state, run, progress, SyncPhase.Validation, rows.Length, rows.Length, durationMs, "Validation de l’empreinte du lot et calcul de l’aperçu…");
        await source.SimulateScreenLatencyAsync("synchro/read/validation", 150, 260, cancellationToken).ConfigureAwait(false);

        var readAt = source.Clock.GetUtcNow();
        var scopeDn = estimate.Mode == SyncReadMode.Ou ? request.Scope.Dn : null;
        var maxUsn = truth.Count == 0 ? 0 : truth.Max(t => t.Usn);
        SyncReadResult result;
        lock (state.Gate)
        {
            var reconciliation = SyncReconcile.Reconcile(state.Rows, rows, scopeDn, complete && estimate.Mode != SyncReadMode.Incremental);
            var notes = ImmutableArray.CreateBuilder<string>();
            var advances = false;
            string checkpointText;
            if (estimate.Mode == SyncReadMode.Ou)
            {
                checkpointText = "Lecture d’OU" + c + "elle a sa propre date de couverture et ne déplace pas le repère du domaine.";
            }
            else
            {
                var incremental = SyncReconcile.Incremental(checkpoint, state.Controller, complete ? state.InvocationId : null, maxUsn, state.DomainDn, !complete, false, complete, state.Rows.Count, readAt);
                notes.AddRange(incremental.Notes.Where(n => estimate.Mode != SyncReadMode.Incremental || !n.StartsWith("Contrôleur", StringComparison.Ordinal)));
                advances = incremental.Advances;
                checkpointText = advances
                    ? "Le repère avancera à l’USN " + FrenchText.Integer(maxUsn) + " sur " + state.Controller + " avec cet enregistrement."
                    : "Le repère de synchronisation reste à l’USN " + FrenchText.Integer(checkpointUsn) + c + "lecture incomplète.";
            }
            if (estimate.Mode == SyncReadMode.Incremental)
            {
                notes.Add("Une absence dans une réponse différentielle ne devient jamais une suppression" + c + "seule une lecture complète repère les disparitions.");
            }
            if (cut is not null)
            {
                notes.Add(cut.Text);
            }
            var readIds = rows.Select(r => r.ObjectGuid).ToHashSet();
            var censusGaps = census.IsEmpty ? 0 : census.Count(g => !state.Rows.ContainsKey(g.ObjectGuid) && !readIds.Contains(g.ObjectGuid));
            var computers = rows.Count(r => r.Type == IndexObjectType.Computer);
            var laps = rows.Any(r => r.Laps != LapsKind.None);
            var label = estimate.Mode switch
            {
                SyncReadMode.Ou => "Lecture de l’OU " + request.Scope.Label + " du " + SyncText.ShortDateTime(readAt, readAt, state.Zone),
                SyncReadMode.Incremental => "Changements du domaine du " + SyncText.ShortDateTime(readAt, readAt, state.Zone),
                _ => "Relecture complète du domaine du " + SyncText.ShortDateTime(readAt, readAt, state.Zone),
            };
            var batch = new IndexBatch(WritePlans.NewId(), label, readAt, readAt + SimulatedSyncState.BatchLifetime, request.Target, request.Scope, estimate.Mode, complete, cut,
                state.Controller, complete ? state.InvocationId : null, maxUsn, rows, census, sha);
            state.Batches[batch.Id] = batch;
            var counts = reconciliation.Counts;
            var summary = (complete ? "Lecture terminée" : "Lecture partielle") + c + ReadText(computers, rows.Length - computers) + ". " + StoreText(counts) + " Rien n’est écrit avant votre confirmation.";
            result = new SyncReadResult(run.RunId, batch.Id, request.Target, request.Scope, estimate.Mode, ModeLabel(estimate.Mode), complete, cut, state.Controller, batch.InvocationId,
                maxUsn, readAt, durationMs, rows.Length, rows.Length - computers, computers, counts, reconciliation.Samples, laps ? "present" : "absent",
                laps ? "Expiration LAPS lue avec les postes (Windows LAPS et LAPS hérité)" + c + "dates seulement, jamais le mot de passe." : "Aucune expiration LAPS lue dans ce périmètre.",
                advances, checkpointText, censusGaps, sha, rows.Length, summary, notes.ToImmutable(), true, batch.ExpiresAt);
        }
        Report(state, run, progress, SyncPhase.Done, rows.Length, rows.Length, durationMs, result.Summary);
        return result;
    }

    public SyncStop StopRead(string runId)
    {
        ArgumentNullException.ThrowIfNull(runId);
        var state = State;
        lock (state.Gate)
        {
            if (state.Run is { } run && string.Equals(run.RunId, runId, StringComparison.Ordinal))
            {
                run.Stop.Cancel();
                return new SyncStop(true, "Arrêt demandé" + SyncText.C + "la lecture s’arrête au prochain lot" + SyncText.Semi + " les objets déjà lus restent une lecture partielle, à enregistrer ou non.");
            }
            return new SyncStop(false, "Aucune lecture en cours avec cet identifiant" + SyncText.C + "rien n’a été arrêté.");
        }
    }

    public async Task<AbsenceCheckResult> CheckAbsencesAsync(Action<SyncProgress> progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(progress);
        var state = State;
        var started = source.Clock.GetUtcNow();
        ImmutableArray<AbsenceRecord> selection;
        RunState run;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            if (state.Run is not null)
            {
                throw new DomeniaOperationException(SyncErrors.Busy, SyncErrors.BusyMessage);
            }
            selection = SyncAbsences.SelectToCheck(state.Absences);
            if (selection.IsEmpty)
            {
                throw new DomeniaOperationException(SyncErrors.NothingToCheck, SyncErrors.NothingToCheckMessage);
            }
            run = new RunState(WritePlans.NewId(), SyncTarget.Domain, "Vérification des disparitions", started);
            state.Run = run;
        }
        try
        {
            var c = SyncText.C;
            var truth = Truth(started).ToDictionary(t => t.ObjectGuid);
            var done = 0;
            for (var offset = 0; offset < selection.Length; offset += SyncAbsences.BatchSize)
            {
                await source.SimulateScreenLatencyAsync("synchro/check/batch", 180, 320, cancellationToken).ConfigureAwait(false);
                done = Math.Min(selection.Length, offset + SyncAbsences.BatchSize);
                Report(state, run, progress, SyncPhase.Reading, done, selection.Length, done * 40,
                    "Lecture par GUID dans le domaine" + c + FrenchText.Integer(done) + " sur " + FrenchText.Integer(selection.Length) + " (lots de " + FrenchText.Integer(SyncAbsences.BatchSize) + ").");
            }
            Report(state, run, progress, SyncPhase.Census, done, selection.Length, done * 40, "Recherche parmi les objets supprimés visibles par ce compte…");
            await source.SimulateScreenLatencyAsync("synchro/check/deleted", 200, 380, cancellationToken).ConfigureAwait(false);
            var observed = source.Clock.GetUtcNow();
            AbsenceCheckResult result;
            lock (state.Gate)
            {
                var outcomes = ImmutableDictionary.CreateBuilder<Guid, AbsenceOutcome>();
                foreach (var absence in selection)
                {
                    AbsenceCheck check;
                    if (truth.TryGetValue(absence.ObjectGuid, out var found))
                    {
                        check = new AbsenceCheck(DomainRead.Read, found.Dn, DeletedProbe.NotRequested, false, null, null, false, found with { ObservedAt = observed });
                    }
                    else if (state.Tombstones.TryGetValue(absence.ObjectGuid, out var tomb))
                    {
                        check = new AbsenceCheck(DomainRead.Read, null, DeletedProbe.Read, true, tomb.DeletedAt, tomb.LastKnownParent, tomb.Recycled, null);
                    }
                    else
                    {
                        check = new AbsenceCheck(DomainRead.Read, null, DeletedProbe.Read, false, null, null, false, null);
                    }
                    outcomes[absence.ObjectGuid] = SyncAbsences.Resolve(absence, check, state.Zone);
                }
                var built = outcomes.ToImmutable();
                var sha = SyncReconcile.IdentityFingerprint(built.Keys);
                var batch = new AbsenceBatch(WritePlans.NewId(), "Vérification de " + FrenchText.Count(built.Count, "disparition", "disparitions") + " du " + SyncText.ShortDateTime(observed, observed, state.Zone),
                    observed, observed + SimulatedSyncState.BatchLifetime, state.Controller, built, sha);
                state.Batches.Remove(state.Batches.Values.OfType<AbsenceBatch>().FirstOrDefault()?.Id ?? "");
                state.Batches[batch.Id] = batch;
                var rows = selection.Select(a => built[a.ObjectGuid].Resolution).ToImmutableArray();
                var counts = SyncAbsences.Counts(rows);
                var summary = "Vérification terminée" + c + string.Join(", ", counts.Select(x => SyncAbsences.CountText(x.Status, x.Count))) + ". Enregistrez les résultats pour les garder"
                    + SyncText.Semi + " un objet retrouvé reprend alors sa place dans la base, sous le même GUID.";
                result = new AbsenceCheckResult(batch.Id, rows.Length, counts, DeletedProbe.Read, SyncAbsences.ProbeText(DeletedProbe.Read), state.Controller, observed, rows, summary, true, batch.ExpiresAt);
            }
            Report(state, run, progress, SyncPhase.Done, selection.Length, selection.Length, selection.Length * 40, result.Summary);
            return result;
        }
        finally
        {
            lock (state.Gate)
            {
                if (ReferenceEquals(state.Run, run))
                {
                    state.Run = null;
                }
            }
            run.Dispose();
        }
    }

    public async Task<GapReadResult> ReadGapsAsync(Action<SyncProgress> progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(progress);
        var state = State;
        var started = source.Clock.GetUtcNow();
        ImmutableArray<CensusGapRecord> selection;
        RunState run;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            if (state.Run is not null)
            {
                throw new DomeniaOperationException(SyncErrors.Busy, SyncErrors.BusyMessage);
            }
            selection = [.. state.OpenGaps().OrderBy(g => g.SeenAt).ThenBy(g => g.ObjectGuid.ToString("D"), StringComparer.Ordinal).Take(SyncAbsences.CheckLimit)];
            if (selection.IsEmpty)
            {
                throw new DomeniaOperationException(SyncErrors.NothingToRead, SyncErrors.NothingToReadMessage);
            }
            run = new RunState(WritePlans.NewId(), SyncTarget.Domain, "Lecture des objets manquants", started);
            state.Run = run;
        }
        try
        {
            var c = SyncText.C;
            var truth = Truth(started).ToDictionary(t => t.ObjectGuid);
            for (var offset = 0; offset < selection.Length; offset += SyncAbsences.BatchSize)
            {
                await source.SimulateScreenLatencyAsync("synchro/gaps/batch", 180, 320, cancellationToken).ConfigureAwait(false);
                var done = Math.Min(selection.Length, offset + SyncAbsences.BatchSize);
                Report(state, run, progress, SyncPhase.Reading, done, selection.Length, done * 40, "Lecture par GUID" + c + FrenchText.Integer(done) + " sur " + FrenchText.Integer(selection.Length) + ".");
            }
            var observed = source.Clock.GetUtcNow();
            GapReadResult result;
            lock (state.Gate)
            {
                var outcomes = ImmutableDictionary.CreateBuilder<Guid, GapOutcome>();
                foreach (var gap in selection)
                {
                    var check = truth.TryGetValue(gap.ObjectGuid, out var found)
                        ? new GapCheck(DomainRead.Read, found.Dn, found with { ObservedAt = observed })
                        : new GapCheck(DomainRead.Read, null, null);
                    outcomes[gap.ObjectGuid] = SyncAbsences.ResolveGap(gap, check);
                }
                var built = outcomes.ToImmutable();
                var batch = new GapBatch(WritePlans.NewId(), "Objets manquants lus le " + SyncText.ShortDateTime(observed, observed, state.Zone), observed, observed + SimulatedSyncState.BatchLifetime,
                    state.Controller, built, SyncReconcile.IdentityFingerprint(built.Keys));
                state.Batches.Remove(state.Batches.Values.OfType<GapBatch>().FirstOrDefault()?.Id ?? "");
                state.Batches[batch.Id] = batch;
                var rows = selection.Select(g => built[g.ObjectGuid].Resolution).ToImmutableArray();
                var added = rows.Count(r => r.Status == "visible");
                var gone = rows.Count(r => r.Status == "notFound");
                var unread = rows.Length - added - gone;
                var summary = "Lecture terminée" + c + FrenchText.Count(added, "objet à ajouter", "objets à ajouter") + ", " + FrenchText.Count(gone, "objet qui n’est plus visible", "objets qui ne sont plus visibles")
                    + ", " + FrenchText.Count(unread, "non lu", "non lus") + ". Enregistrez pour les ajouter à la base.";
                result = new GapReadResult(batch.Id, rows.Length, added, gone, unread, rows, summary, added + gone > 0, batch.ExpiresAt);
            }
            Report(state, run, progress, SyncPhase.Done, selection.Length, selection.Length, selection.Length * 40, result.Summary);
            return result;
        }
        finally
        {
            lock (state.Gate)
            {
                if (ReferenceEquals(state.Run, run))
                {
                    state.Run = null;
                }
            }
            run.Dispose();
        }
    }

    public async Task<ParkSharedRead> ReadSharedParkAsync(CancellationToken cancellationToken)
    {
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            if (string.IsNullOrEmpty(state.SharedPath))
            {
                throw new DomeniaOperationException(SyncErrors.SharedNotConfigured, SyncErrors.SharedNotConfiguredMessage);
            }
        }
        // The lock file of another console is found once, then obtained at the second attempt.
        await source.SimulateScreenLatencyAsync("synchro/shared/lock", 250, 450, cancellationToken).ConfigureAwait(false);
        await source.SimulateScreenLatencyAsync("synchro/shared/read", 250, 450, cancellationToken).ConfigureAwait(false);
        var now = source.Clock.GetUtcNow();
        lock (state.Gate)
        {
            var merge = SyncPark.Merge(state.Park, state.SharedFile);
            var differences = SyncPark.Differences(state.Park, state.SharedFile);
            var kept = state.Park.Count(p => state.SharedFile.TryGetValue(p.Key, out var theirs) && p.Value.LastProbe > theirs.LastProbe)
                + state.Park.Keys.Count(k => !state.SharedFile.ContainsKey(k));
            var localSha = SimulatedSyncState.ParkFingerprint(state.Park);
            var sharedSha = SimulatedSyncState.ParkFingerprint(state.SharedFile);
            var mergedSha = SimulatedSyncState.ParkFingerprint(merge.State);
            var batch = new ParkSharedBatch(WritePlans.NewId(), "Relevé partagé lu le " + SyncText.ShortDateTime(now, now, state.Zone), now, now + SimulatedSyncState.BatchLifetime,
                merge.State, localSha, sharedSha, merge.Added, merge.Replaced, state.SharedFile.Count, mergedSha);
            state.Batches.Remove(state.Batches.Values.OfType<ParkSharedBatch>().FirstOrDefault()?.Id ?? "");
            state.Batches[batch.Id] = batch;
            var c = SyncText.C;
            var text = "Partage" + c + FrenchText.Count(state.SharedFile.Count, "ligne reçue", "lignes reçues") + ", " + FrenchText.Count(merge.Added, "poste ajouté", "postes ajoutés")
                + ", " + FrenchText.Count(merge.Replaced, "relevé actualisé", "relevés actualisés") + ", " + FrenchText.Count(kept, "relevé de cette console à partager", "relevés de cette console à partager")
                + ", " + FrenchText.Integer(merge.Total) + " au total. Verrou obtenu au 2ᵉ essai sur " + FrenchText.Integer(SyncPark.LockAttempts) + ". Rien n’est écrit avant votre confirmation.";
            return new ParkSharedRead(batch.Id, state.SharedPath, state.SharedFile.Count, merge.Added, merge.Replaced, kept, merge.Total, false, 2, differences, text,
                merge.Added + merge.Replaced + kept > 0, batch.ExpiresAt);
        }
    }

    // ---------------------------------------------------------------- helpers

    private static void Report(SimulatedSyncState state, RunState run, Action<SyncProgress> progress, SyncPhase phase, int count, int? total, int elapsedMs, string text, double? rate = null)
    {
        lock (state.Gate)
        {
            run.Phase = phase;
        }
        double? percent = total is > 0 ? Math.Round(100.0 * count / total.Value, 1) : phase == SyncPhase.Done ? 100.0 : (double?)null;
        progress(new SyncProgress(run.RunId, phase, PhaseLabel(phase), count, total, rate is null ? null : Math.Round(rate.Value, 0), elapsedMs, percent, text));
    }

    internal static string Phase(SyncPhase phase) => phase switch
    {
        SyncPhase.Backup => "backup",
        SyncPhase.Reading => "reading",
        SyncPhase.Census => "census",
        SyncPhase.Fingerprint => "fingerprint",
        SyncPhase.Validation => "validation",
        _ => "done",
    };

    internal static string PhaseLabel(SyncPhase phase) => phase switch
    {
        SyncPhase.Backup => "Sauvegarde vérifiée",
        SyncPhase.Reading => "Lecture de l’annuaire",
        SyncPhase.Census => "Recensement des identités",
        SyncPhase.Fingerprint => "Empreinte du transfert",
        SyncPhase.Validation => "Validation du lot",
        _ => "Prêt à enregistrer",
    };

    /// <summary>What a pass read, naming only the object types it returned.</summary>
    internal static string ReadText(int computers, int accounts)
    {
        if (computers > 0 && accounts > 0)
        {
            return FrenchText.Count(computers + accounts, "objet lu", "objets lus") + " (" + FrenchText.Count(computers, "poste", "postes") + ", " + FrenchText.Count(accounts, "compte", "comptes") + ")";
        }
        return computers > 0 ? FrenchText.Count(computers, "poste lu", "postes lus")
            : accounts > 0 ? FrenchText.Count(accounts, "compte lu", "comptes lus")
            : "aucun objet lu";
    }

    /// <summary>What storing the pass would change, naming only the non-empty categories.</summary>
    internal static string StoreText(SyncReconcileCounts counts)
    {
        var parts = new List<string>();
        if (counts.Added > 0)
        {
            parts.Add(FrenchText.Count(counts.Added, "ajout", "ajouts"));
        }
        if (counts.Updated > 0)
        {
            parts.Add(FrenchText.Count(counts.Updated, "mise à jour", "mises à jour"));
        }
        if (counts.Unseen > 0)
        {
            parts.Add(FrenchText.Count(counts.Unseen, "objet non revu", "objets non revus"));
        }
        return parts.Count > 0
            ? "À enregistrer" + SyncText.C + string.Join(", ", parts) + "."
            : "Aucun changement" + SyncText.Semi + " l’enregistrement actualise la couverture et le repère.";
    }

    internal static string ModeLabel(SyncReadMode mode) => mode switch
    {
        SyncReadMode.Ou => "Lecture complète de l’OU et de ses sous-OU",
        SyncReadMode.Incremental => "Changements depuis le repère (USN)",
        _ => "Relecture complète du domaine",
    };
}
