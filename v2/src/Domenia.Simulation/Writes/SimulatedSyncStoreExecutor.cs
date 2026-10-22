using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Changes of the local base of the simulation (docs/ops/synchro.md § 5): storage of a read, of a verification, of a census gap
/// read or of the shared park survey; snapshots captured and deleted; park survey forgotten. It writes only to the base kept in
/// memory for the session (<see cref="SimulatedSyncState"/>): no network, no disk, no directory object. Each step waits a short
/// realistic delay; the commit holds the base (concurrent searches answer « busy », Domenia 1 point 4).
/// </summary>
public sealed class SimulatedSyncStoreExecutor : ISyncStoreExecutor
{
    private const string Unreadable = "Plan illisible pour la base locale : rien n’a été écrit.";
    private readonly SimulatedDirectorySource source;

    /// <summary>Found by WriteExecutors.Discover for the simulated source; cheap: nothing is read here.</summary>
    public SimulatedSyncStoreExecutor(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public string Kind => SyncStoreChange.Kind;

    private SimulatedSyncState State => SimulatedSyncState.For(source);

    /// <summary>« : » with its no-break space.</summary>
    private static string c0 => SyncText.C;

    // ---------------------------------------------------------------- plans

    public async Task<WritePlanDraft> PlanBatchAsync(string batchId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(batchId);
        await source.SimulateScreenLatencyAsync("write/plan", 60, 140, cancellationToken).ConfigureAwait(false);
        var now = source.Clock.GetUtcNow();
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            state.Purge(now);
            if (!state.Batches.TryGetValue(batchId, out var batch))
            {
                throw new DomeniaOperationException(SyncErrors.BatchUnknown, SyncErrors.BatchUnknownMessage);
            }
            var backup = SyncCoverageRules.BackupNotice(SyncCoverageRules.Backup(state.LastBackupAt, now), state.Zone);
            return batch switch
            {
                IndexBatch index => DraftIndex(state, index, backup, now),
                AbsenceBatch absences => DraftAbsences(state, absences, backup),
                GapBatch gaps => DraftGaps(state, gaps, backup),
                ParkSharedBatch park => DraftShared(state, park),
                _ => throw new DomeniaOperationException(SyncErrors.BatchUnknown, SyncErrors.BatchUnknownMessage),
            };
        }
    }

    public async Task<WritePlanDraft> PlanSnapshotCaptureAsync(string? label, SyncScope scope, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scope);
        await source.SimulateScreenLatencyAsync("write/plan", 60, 140, cancellationToken).ConfigureAwait(false);
        var now = source.Clock.GetUtcNow();
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            state.Purge(now);
            if (state.Snapshots.Count >= SyncSnapshots.MaxPerDomain)
            {
                throw new DomeniaOperationException(SyncErrors.SnapshotLimit, SyncErrors.SnapshotLimitMessage);
            }
            var lines = Lines(state, scope);
            if (lines.Length > SyncSnapshots.MaxObjects)
            {
                throw new DomeniaOperationException(SyncErrors.SnapshotTooLarge, SyncErrors.SnapshotTooLargeMessage);
            }
            var coverage = SyncCoverageRules.Coverage(scope.IsDomain ? null : scope.Dn, state.DomainDn, state.SyncStates, now, state.Zone);
            var request = SyncSnapshots.Request(state.DomainDn, scope.Dn, true, label, coverage, WritePlans.NewId(), now, state.Zone);
            var sha = SyncSnapshots.Fingerprint(lines);
            state.Captures[request.Id] = new PendingCapture(request.Id, request.Label, scope, request.Coverage, sha, lines.Length, now);
            var head = new WriteChange(SyncStoreChange.SnapshotCaptureAttribute, "Nouveau relevé", WriteChangeKind.Add, null,
                FrenchText.Quote(request.Label) + " · " + SyncStoreChange.Objects(lines.Length) + " · " + scope.Path, null, SyncStoreChange.HeadValue("capture", request.Id, sha, lines.Length));
            var effects = new[]
            {
                SyncStoreChange.Effect("snapshot.count", "Relevés du domaine", WriteChangeKind.Replace, FrenchText.Integer(state.Snapshots.Count), FrenchText.Integer(state.Snapshots.Count + 1),
                    "count=" + state.Snapshots.Count.ToString(CultureInfo.InvariantCulture), "count=" + (state.Snapshots.Count + 1).ToString(CultureInfo.InvariantCulture)),
            };
            var risks = new List<WriteRisk>
            {
                new(request.Coverage.State == SnapshotCoverageState.Complete ? Tone.Info : Tone.Warn, request.Coverage.Text),
                new(Tone.Info, SyncSnapshots.Notice),
            };
            return SyncStoreChange.Draft("Enregistrer un relevé du périmètre", "Relevé daté de l’annuaire",
                "Copie datée de la base locale pour " + FrenchText.Quote(scope.Label) + c0 + SyncStoreChange.Objects(lines.Length) + " (identité, emplacement et quelques attributs), avec la preuve de sa couverture. Aucune lecture de l’annuaire.",
                SyncStoreChange.SnapshotTarget(request.Label, true), head, effects, risks, SyncStoreChange.SnapshotRemovable, null);
        }
    }

    public async Task<WritePlanDraft> PlanSnapshotDeleteAsync(string snapshotId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(snapshotId);
        await source.SimulateScreenLatencyAsync("write/plan", 60, 140, cancellationToken).ConfigureAwait(false);
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            var snapshot = state.Snapshots.FirstOrDefault(s => s.Id == snapshotId)
                ?? throw new DomeniaOperationException(SyncErrors.SnapshotUnknown, SyncErrors.SnapshotUnknownMessage);
            var row = SyncSnapshots.Row(snapshot, state.Zone);
            var head = new WriteChange(SyncStoreChange.SnapshotDeleteAttribute, "Relevé", WriteChangeKind.Remove,
                FrenchText.Quote(snapshot.Label) + " · " + SyncText.LocalDateTime(snapshot.CapturedAt, state.Zone) + " · " + SyncStoreChange.Objects(snapshot.Lines.Length),
                "Supprimé de la base locale", SyncStoreChange.HeadValue("delete", snapshot.Id, snapshot.RowsSha256, snapshot.Lines.Length), null);
            var risks = new[]
            {
                new WriteRisk(Tone.Alert, "Suppression définitive" + c0 + "ce relevé ne pourra plus servir de comparaison. L’annuaire n’est pas concerné."),
                new WriteRisk(Tone.Info, "Périmètre du relevé" + c0 + row.ScopeText + ". " + snapshot.CoverageText),
            };
            return SyncStoreChange.Draft("Supprimer un relevé", "Suppression d’un relevé",
                "Supprime de la base locale le relevé " + FrenchText.Quote(snapshot.Label) + " (" + SyncStoreChange.Objects(snapshot.Lines.Length) + "). Les autres relevés et l’annuaire ne changent pas.",
                SyncStoreChange.SnapshotTarget(snapshot.Label, true), head, [], risks, SyncStoreChange.Definitive, null);
        }
    }

    public async Task<WritePlanDraft> PlanParkResetAsync(CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("write/plan", 60, 140, cancellationToken).ConfigureAwait(false);
        var now = source.Clock.GetUtcNow();
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            if (state.Park.Count == 0)
            {
                throw new DomeniaOperationException(SyncErrors.ParkEmpty, SyncErrors.ParkEmptyMessage);
            }
            var latest = state.Park.Values.Max(e => e.LastProbe);
            var backup = SyncCoverageRules.BackupNotice(SyncCoverageRules.Backup(state.LastBackupAt, now), state.Zone);
            var head = new WriteChange(SyncStoreChange.ParkResetAttribute, "État de balayage du parc", WriteChangeKind.Clear,
                FrenchText.Count(state.Park.Count, "poste relevé", "postes relevés") + " (dernier passage le " + SyncText.LocalDateTime(latest, state.Zone) + ")", "Aucun relevé",
                SyncStoreChange.HeadValue("park", "reset", SimulatedSyncState.ParkFingerprint(state.Park), state.Park.Count), null);
            var risks = new[]
            {
                new WriteRisk(Tone.Info, "Les associations, les observations et l’historique sont conservés" + c0 + "seul l’état des relevés (dernier passage, statut, tentatives) est effacé."),
                new WriteRisk(Tone.Warn, "Le prochain relevé du parc repartira de zéro."),
                new WriteRisk(Tone.Info, backup),
            };
            return SyncStoreChange.Draft("Oublier les relevés du parc", "Oubli des relevés du parc",
                "Efface l’état de balayage du parc de cette base (" + FrenchText.Count(state.Park.Count, "poste", "postes") + "), après la sauvegarde vérifiée de la base. Associations, observations et historique ne sont pas touchés.",
                SyncStoreChange.ParkTarget("État de balayage · " + FrenchText.Count(state.Park.Count, "poste", "postes"), true), head, [], risks, SyncStoreChange.BackedUp(backup), null);
        }
    }

    private static WritePlanDraft DraftIndex(SimulatedSyncState state, IndexBatch batch, string backup, DateTimeOffset now)
    {
        if (Refusal(state, batch) is { } refusal)
        {
            throw new DomeniaOperationException(WriteErrors.Stale, refusal);
        }
        var reconciliation = Reconcile(state, batch);
        var counts = reconciliation.Counts;
        var zone = state.Zone;
        var head = new WriteChange(SyncStoreChange.BatchAttribute, "Lot vérifié", WriteChangeKind.Add, null,
            batch.Label + " · " + SyncStoreChange.Objects(batch.Rows.Length) + " · empreinte " + SyncText.ShortHash(batch.Sha256), null,
            SyncStoreChange.HeadValue("index", batch.Id, batch.Sha256, batch.Rows.Length, SyncReconcile.PreviewFingerprint(reconciliation)));
        var effects = new List<WriteChange>();
        if (counts.Added > 0)
        {
            effects.Add(SyncStoreChange.Effect("index.added", "Objets ajoutés", WriteChangeKind.Add, null, SyncStoreChange.Objects(counts.Added), null, "added=" + Int(counts.Added)));
        }
        if (counts.Updated > 0)
        {
            effects.Add(SyncStoreChange.Effect("index.updated", "Objets mis à jour", WriteChangeKind.Replace, "versions précédentes",
                SyncStoreChange.Objects(counts.Updated) + " (" + FrenchText.Count(counts.Moved, "déplacé", "déplacés") + ", " + FrenchText.Count(counts.Renamed, "renommé", "renommés")
                + ", " + FrenchText.Count(counts.Changed, "aux valeurs modifiées", "aux valeurs modifiées") + ")", null, "updated=" + Int(counts.Updated)));
        }
        if (counts.Unseen > 0)
        {
            effects.Add(SyncStoreChange.Effect("index.unseen", "Marqués non revus", WriteChangeKind.Remove, SyncStoreChange.Objects(counts.Unseen),
                "Retirés de la copie, listés dans " + FrenchText.Quote("Disparitions"), "unseen=" + Int(counts.Unseen), null));
        }
        if (counts.Conflicts > 0)
        {
            effects.Add(SyncStoreChange.Effect("index.kept", "Observations locales plus récentes", WriteChangeKind.Replace, SyncStoreChange.Objects(counts.Conflicts), "Conservées (jamais écrasées)",
                "kept=" + Int(counts.Conflicts), "kept=" + Int(counts.Conflicts)));
        }
        var risks = new List<WriteRisk>();
        if (batch.Target == SyncTarget.Ou)
        {
            var key = SyncStateEntry.OuKey(batch.Scope.Dn);
            var previous = state.SyncStates.FirstOrDefault(e => string.Equals(e.Key, key, StringComparison.OrdinalIgnoreCase));
            effects.Add(batch.Complete
                ? SyncStoreChange.Effect("coverage", "Couverture de l’OU " + FrenchText.Quote(batch.Scope.Label), WriteChangeKind.Replace,
                    previous is null ? "Aucune lecture complète" : SyncText.LocalDateTime(previous.LastSync, zone), SyncText.LocalDateTime(batch.CreatedAt, zone),
                    previous?.LastSync.UtcDateTime.ToString("o", CultureInfo.InvariantCulture), "complete:" + batch.CreatedAt.UtcDateTime.ToString("o", CultureInfo.InvariantCulture))
                : SyncStoreChange.Effect("coverage", "Tentative incomplète", WriteChangeKind.Add, null, "Passe partielle notée" + c0 + "la date de couverture ne bouge pas", null,
                    "attempt:" + batch.CreatedAt.UtcDateTime.ToString("o", CultureInfo.InvariantCulture)));
        }
        else if (batch.Complete && state.Checkpoint is { } checkpoint)
        {
            effects.Add(SyncStoreChange.Effect("checkpoint", "Repère de synchronisation", WriteChangeKind.Replace,
                "USN " + FrenchText.Integer(checkpoint.Usn) + " · " + checkpoint.Controller + " · " + SyncText.LocalDateTime(checkpoint.At, zone),
                "USN " + FrenchText.Integer(batch.HighestUsn) + " · " + batch.Controller + " · " + SyncText.LocalDateTime(batch.CreatedAt, zone),
                "usn=" + checkpoint.Usn.ToString(CultureInfo.InvariantCulture), "usn=" + batch.HighestUsn.ToString(CultureInfo.InvariantCulture)));
            if (!batch.Census.IsEmpty)
            {
                var gaps = CensusGaps(state, batch, reconciliation);
                var open = state.OpenGaps().Count;
                effects.Add(SyncStoreChange.Effect("census", "Identités recensées absentes de la base", WriteChangeKind.Replace, SyncStoreChange.Objects(open), SyncStoreChange.Objects(gaps.Count),
                    "gaps=" + Int(open), "gaps=" + Int(gaps.Count)));
            }
        }
        if (counts.Unseen > 0)
        {
            risks.Add(new WriteRisk(Tone.Warn, FrenchText.Count(counts.Unseen, "objet de ce périmètre n’a pas été revu", "objets de ce périmètre n’ont pas été revus")
                + " par cette lecture complète" + c0 + "retirés de la copie locale et listés dans " + FrenchText.Quote("Disparitions") + ", jamais supprimés de l’annuaire. Vérifiez-les avant toute conclusion."));
        }
        if (!batch.Complete)
        {
            risks.Add(new WriteRisk(Tone.Warn, "Lecture incomplète" + c0 + (batch.Cut?.Text ?? "passe coupée.") + " Les objets reçus sont enregistrés, aucune disparition n’est déduite et la date de couverture ne bouge pas."));
        }
        if (batch.Mode == SyncReadMode.Incremental)
        {
            risks.Add(new WriteRisk(Tone.Info, "Lecture différentielle" + c0 + "elle ne voit ni les objets supprimés ni ceux devenus visibles sans modification. Seule une lecture complète du périmètre les repère."));
        }
        if (counts.Conflicts > 0)
        {
            risks.Add(new WriteRisk(Tone.Info, FrenchText.Count(counts.Conflicts, "ligne plus récente de la base est conservée", "lignes plus récentes de la base sont conservées") + "."));
        }
        risks.Add(new WriteRisk(Tone.Info, backup));
        var title = batch.Mode switch
        {
            SyncReadMode.Ou => "Enregistrer la lecture de l’OU " + FrenchText.Quote(batch.Scope.Label),
            SyncReadMode.Incremental => "Enregistrer les changements du domaine",
            _ => "Enregistrer la relecture complète du domaine",
        };
        var summary = "Enregistre dans la base locale la lecture du " + SyncText.LocalDateTime(batch.CreatedAt, zone) + " sur " + batch.Controller + c0
            + FrenchText.Count(batch.Rows.Length, "objet vérifié", "objets vérifiés") + " (empreinte " + SyncText.ShortHash(batch.Sha256) + "), "
            + FrenchText.Count(counts.Added, "ajout", "ajouts") + ", " + FrenchText.Count(counts.Updated, "mise à jour", "mises à jour") + ", "
            + FrenchText.Count(counts.Unseen, "objet marqué non revu", "objets marqués non revus") + ". Active Directory n’est pas modifié.";
        var name = batch.Target == SyncTarget.Ou ? "OU " + batch.Scope.Label + " · " + SyncStoreChange.Objects(batch.Rows.Length) : "Domaine " + state.DomainName + " · " + SyncStoreChange.Objects(batch.Rows.Length);
        _ = now;
        return SyncStoreChange.Draft(title, "Mise à jour de la base locale", summary, SyncStoreChange.IndexTarget(name, true), head, effects, risks, SyncStoreChange.BackedUp(backup), batch.Controller);
    }

    private static WritePlanDraft DraftAbsences(SimulatedSyncState state, AbsenceBatch batch, string backup)
    {
        var resolutions = batch.Outcomes.Values.Select(o => o.Resolution).ToList();
        var counts = SyncAbsences.Counts(resolutions);
        var back = batch.Outcomes.Values.Count(o => o.Keep is not null);
        var head = new WriteChange(SyncStoreChange.BatchAttribute, "Vérification", WriteChangeKind.Add, null,
            batch.Label + " · empreinte " + SyncText.ShortHash(batch.Sha256), null, SyncStoreChange.HeadValue("absences", batch.Id, batch.Sha256, batch.Outcomes.Count));
        var effects = new List<WriteChange>
        {
            SyncStoreChange.Effect("absence.results", "Disparitions vérifiées", WriteChangeKind.Replace, FrenchText.Count(batch.Outcomes.Count, "objet à vérifier", "objets à vérifier"),
                string.Join(", ", counts.Select(x => SyncAbsences.CountText(x.Status, x.Count))), "pending=" + Int(batch.Outcomes.Count),
                string.Join(';', counts.Select(x => x.Status.ToString().ToLowerInvariant() + "=" + Int(x.Count)))),
        };
        if (back > 0)
        {
            effects.Add(SyncStoreChange.Effect("index.added", "Objets retrouvés remis dans la base", WriteChangeKind.Add, null, SyncStoreChange.Objects(back) + " (même GUID, nouvel emplacement)", null, "added=" + Int(back)));
        }
        var risks = new List<WriteRisk>
        {
            new(Tone.Info, "Seule une entrée isDeleted lue par GUID prouve une suppression" + c0 + "les autres absences restent sans conclusion."),
            new(Tone.Info, backup),
        };
        if (counts.Any(x => x.Status == AbsenceStatus.Deleted))
        {
            risks.Insert(0, new WriteRisk(Tone.Warn, "Suppressions constatées dans l’annuaire" + c0 + "elles restent listées pour mémoire. La restauration depuis la corbeille AD sera une écriture à part, avec son propre plan."));
        }
        return SyncStoreChange.Draft("Enregistrer les vérifications", "Résultats de vérification des disparitions",
            "Enregistre le résultat de la vérification de " + FrenchText.Count(batch.Outcomes.Count, "objet non revu", "objets non revus") + " (lecture par GUID sur " + batch.Server + "). Un objet retrouvé reprend sa place dans la base sous le même GUID.",
            SyncStoreChange.IndexTarget("Disparitions · " + SyncStoreChange.Objects(batch.Outcomes.Count), true), head, effects, risks, SyncStoreChange.BackedUp(backup), batch.Server);
    }

    private static WritePlanDraft DraftGaps(SimulatedSyncState state, GapBatch batch, string backup)
    {
        var added = batch.Outcomes.Values.Count(o => o.Keep is not null);
        var leaving = batch.Outcomes.Values.Count(o => o.LeavesList);
        var head = new WriteChange(SyncStoreChange.BatchAttribute, "Lecture par GUID", WriteChangeKind.Add, null,
            batch.Label + " · empreinte " + SyncText.ShortHash(batch.Sha256), null, SyncStoreChange.HeadValue("gaps", batch.Id, batch.Sha256, batch.Outcomes.Count));
        var effects = new List<WriteChange>();
        if (added > 0)
        {
            effects.Add(SyncStoreChange.Effect("index.added", "Objets ajoutés à la base", WriteChangeKind.Add, null, SyncStoreChange.Objects(added), null, "added=" + Int(added)));
        }
        var open = state.OpenGaps().Count;
        effects.Add(SyncStoreChange.Effect("census", "Identités recensées absentes de la base", WriteChangeKind.Replace, SyncStoreChange.Objects(open),
            SyncStoreChange.Objects(Math.Max(0, open - leaving)), "gaps=" + Int(open), "gaps=" + Int(Math.Max(0, open - leaving))));
        var risks = new List<WriteRisk>
        {
            new(Tone.Info, "Un objet que la lecture par GUID ne renvoie plus quitte la liste, sans conclusion sur son sort."),
            new(Tone.Info, backup),
        };
        return SyncStoreChange.Draft("Ajouter les objets lus à la base", "Lecture des objets manquants du recensement",
            "Ajoute à la base locale " + FrenchText.Count(added, "objet lu par son GUID", "objets lus par leur GUID") + " et retire de la liste des manquants " + FrenchText.Count(leaving, "identité", "identités") + ".",
            SyncStoreChange.IndexTarget("Objets manquants · " + SyncStoreChange.Objects(batch.Outcomes.Count), true), head, effects, risks, SyncStoreChange.BackedUp(backup), batch.Server);
    }

    private static WritePlanDraft DraftShared(SimulatedSyncState state, ParkSharedBatch batch)
    {
        var head = new WriteChange(SyncStoreChange.BatchAttribute, "Relevé partagé fusionné", WriteChangeKind.Add, null,
            batch.Label + " · empreinte " + SyncText.ShortHash(batch.Sha256), null, SyncStoreChange.HeadValue("park", batch.Id, batch.Sha256, batch.Merged.Count));
        var effects = new List<WriteChange>
        {
            SyncStoreChange.Effect("park.local", "Relevé de cette base", WriteChangeKind.Replace, FrenchText.Count(state.Park.Count, "poste", "postes"),
                FrenchText.Count(batch.Merged.Count, "poste", "postes") + " (" + FrenchText.Count(batch.Added, "ajouté", "ajoutés") + ", " + FrenchText.Count(batch.Replaced, "actualisé", "actualisés") + ")",
                "sha=" + batch.LocalSha, "sha=" + batch.Sha256),
            SyncStoreChange.Effect("park.shared", "Fichier partagé", WriteChangeKind.Replace, FrenchText.Count(state.SharedFile.Count, "ligne", "lignes"), FrenchText.Count(batch.Merged.Count, "ligne", "lignes"),
                "sha=" + batch.SharedSha, "sha=" + batch.Sha256),
        };
        var risks = new List<WriteRisk>
        {
            new(Tone.Info, "Fusion par poste" + c0 + "la ligne la plus récente gagne, deux consoles ne s’effacent jamais."),
            new(Tone.Info, "Écriture du fichier partagé " + state.SharedPath + " sous verrou (fichier .lock, " + FrenchText.Integer(SyncPark.LockAttempts) + " essais)" + SyncText.Semi
                + " si le verrou n’est pas obtenu, rien n’est écrit et Domenia travaille en local."),
        };
        return SyncStoreChange.Draft("Fusionner le relevé partagé", "Synchronisation du relevé partagé du parc",
            "Fusionne le relevé partagé entre consoles avec celui de cette base, puis réécrit le fichier partagé" + c0 + FrenchText.Count(batch.Merged.Count, "poste", "postes") + " au total.",
            SyncStoreChange.ParkTarget("Relevé partagé · " + FrenchText.Count(batch.Merged.Count, "poste", "postes"), true), head, effects, risks,
            new WriteReversibility(false, "Fusion", "Une fusion ne se défait pas" + SyncText.Semi + " chaque console garde la ligne la plus récente par poste."), null);
    }

    // ---------------------------------------------------------------- check, execute, verify

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await source.SimulateScreenLatencyAsync("write/check", 60, 140, cancellationToken).ConfigureAwait(false);
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            return Check(state, plan, source.Clock.GetUtcNow());
        }
    }

    private static WritePrecheck Check(SimulatedSyncState state, WritePlan plan, DateTimeOffset now)
    {
        if (SyncStoreChange.Head(plan) is not { } head)
        {
            return WritePrecheck.Stale(Unreadable);
        }
        switch (head.Operation)
        {
            case SyncStoreOperation.Batch:
                if (!state.Batches.TryGetValue(head.Id, out var batch) || batch.ExpiresAt <= now)
                {
                    return WritePrecheck.Stale("La lecture a expiré ou a déjà été enregistrée" + c0 + "rien n’a été écrit. Relancez la lecture.");
                }
                if (!string.Equals(batch.Kind, head.Kind, StringComparison.Ordinal) || batch.Count != head.Count || !string.Equals(Sha(batch), head.Sha256, StringComparison.Ordinal))
                {
                    return WritePrecheck.Stale("Lot modifié depuis la lecture (nombre de lignes ou empreinte différents)" + c0 + "transaction refusée, rien n’a été écrit.");
                }
                return batch switch
                {
                    IndexBatch index => CheckIndex(state, index, plan),
                    AbsenceBatch absences => absences.Outcomes.Keys.All(g => state.Absences.Any(a => a.ObjectGuid == g && a.Status is AbsenceStatus.NotSeen or AbsenceStatus.Unconfirmed))
                        ? WritePrecheck.Valid(FrenchText.Count(absences.Outcomes.Count, "objet toujours à vérifier", "objets toujours à vérifier") + " dans la base" + SyncText.Semi + " empreinte du lot vérifiée.")
                        : WritePrecheck.Stale("La liste des disparitions a changé depuis la vérification" + c0 + "relancez-la, rien n’a été écrit."),
                    GapBatch gaps => gaps.Outcomes.Keys.All(g => state.OpenGaps().Any(x => x.ObjectGuid == g))
                        ? WritePrecheck.Valid(FrenchText.Count(gaps.Outcomes.Count, "identité toujours manquante", "identités toujours manquantes") + SyncText.Semi + " empreinte du lot vérifiée.")
                        : WritePrecheck.Stale("La liste des objets manquants a changé depuis la lecture" + c0 + "relancez-la, rien n’a été écrit."),
                    ParkSharedBatch park => SimulatedSyncState.ParkFingerprint(state.Park) == park.LocalSha && SimulatedSyncState.ParkFingerprint(state.SharedFile) == park.SharedSha
                        ? WritePrecheck.Valid("Relevé local et fichier partagé inchangés depuis leur lecture" + SyncText.Semi + " verrou du fichier partagé disponible.")
                        : WritePrecheck.Stale("Le relevé local ou le fichier partagé a changé depuis sa lecture" + c0 + "relisez le partage, rien n’a été écrit."),
                    _ => WritePrecheck.Stale(Unreadable),
                };
            case SyncStoreOperation.SnapshotCapture:
                if (!state.Captures.TryGetValue(head.Id, out var capture))
                {
                    return WritePrecheck.Stale("Préparation du relevé expirée" + c0 + "préparez-le de nouveau, rien n’a été écrit.");
                }
                if (state.Snapshots.Count >= SyncSnapshots.MaxPerDomain)
                {
                    return WritePrecheck.Stale(SyncErrors.SnapshotLimitMessage);
                }
                var lines = Lines(state, capture.Scope);
                return SyncSnapshots.Fingerprint(lines) == head.Sha256 && lines.Length == head.Count
                    ? WritePrecheck.Valid("Base inchangée depuis le plan" + c0 + SyncStoreChange.Objects(lines.Length) + " à copier, empreinte " + SyncText.ShortHash(head.Sha256) + ".")
                    : WritePrecheck.Stale("La base locale a changé depuis le plan" + c0 + "préparez de nouveau le relevé pour revoir son contenu, rien n’a été écrit.");
            case SyncStoreOperation.SnapshotDelete:
                return state.Snapshots.FirstOrDefault(s => s.Id == head.Id) is { } snapshot && snapshot.RowsSha256 == head.Sha256
                    ? WritePrecheck.Valid("Relevé toujours présent et inchangé (empreinte " + SyncText.ShortHash(head.Sha256) + ").")
                    : WritePrecheck.Stale("Relevé déjà supprimé ou modifié" + c0 + "rien n’a été écrit.");
            case SyncStoreOperation.ParkReset:
                return SimulatedSyncState.ParkFingerprint(state.Park) == head.Sha256
                    ? WritePrecheck.Valid("Relevé du parc inchangé depuis le plan (" + FrenchText.Count(state.Park.Count, "poste", "postes") + ").")
                    : WritePrecheck.Stale("Le relevé du parc a changé depuis le plan" + c0 + "préparez de nouveau l’oubli, rien n’a été effacé.");
            default:
                return WritePrecheck.Stale(Unreadable);
        }
    }

    private static WritePrecheck CheckIndex(SimulatedSyncState state, IndexBatch batch, WritePlan plan)
    {
        if (Refusal(state, batch) is { } refusal)
        {
            return WritePrecheck.Stale(refusal);
        }
        var reconciliation = Reconcile(state, batch);
        var counts = reconciliation.Counts;
        int Planned(string attribute, string key)
        {
            var change = plan.Changes.FirstOrDefault(c => c.Attribute == attribute);
            var raw = change?.AfterValue ?? change?.BeforeValue;
            return raw is not null && raw.StartsWith(key + "=", StringComparison.Ordinal) && int.TryParse(raw.AsSpan(key.Length + 1), NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : 0;
        }
        // The counts and the fingerprint of the preview (GUID and category of every object): a base changed by another storage
        // that gives the same counts never passes for the preview the operator confirmed.
        var preview = SyncStoreChange.Head(plan)?.Preview ?? "";
        if (Planned("index.added", "added") != counts.Added || Planned("index.updated", "updated") != counts.Updated || Planned("index.unseen", "unseen") != counts.Unseen
            || !string.Equals(preview, SyncReconcile.PreviewFingerprint(reconciliation), StringComparison.Ordinal))
        {
            return WritePrecheck.Stale("La base locale a changé depuis le plan (autre enregistrement)" + c0 + "préparez de nouveau l’enregistrement pour revoir l’aperçu, rien n’a été écrit.");
        }
        return WritePrecheck.Valid("Lot relu" + c0 + FrenchText.Count(batch.Rows.Length, "ligne", "lignes") + " et leurs identités, empreinte " + SyncText.ShortHash(batch.Sha256)
            + " vérifiée" + SyncText.Semi + " aperçu identique à la base du moment.");
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var state = State;
        var head = SyncStoreChange.Head(plan) ?? throw new DomeniaOperationException(WriteErrors.Stale, Unreadable);
        state.BeginCommit();
        try
        {
            // The commit holds the base: concurrent searches answer « busy » (one short retry in the page, Domenia 1 point 4).
            await source.SimulateScreenLatencyAsync("write/execute", 320, 700, CancellationToken.None).ConfigureAwait(false);
            var now = source.Clock.GetUtcNow();
            lock (state.Gate)
            {
                state.EnsureSeeded();
                var precheck = Check(state, plan, now);
                if (!precheck.Current)
                {
                    throw new DomeniaOperationException(WriteErrors.Stale, precheck.Detail);
                }
                return head.Operation switch
                {
                    SyncStoreOperation.Batch => state.Batches[head.Id] switch
                    {
                        IndexBatch index => ApplyIndex(state, index, now),
                        AbsenceBatch absences => ApplyAbsences(state, absences, now),
                        GapBatch gaps => ApplyGaps(state, gaps, now),
                        ParkSharedBatch park => ApplyShared(state, park, now),
                        _ => throw new DomeniaOperationException(WriteErrors.Stale, Unreadable),
                    },
                    SyncStoreOperation.SnapshotCapture => ApplyCapture(state, state.Captures[head.Id], now),
                    SyncStoreOperation.SnapshotDelete => ApplyDelete(state, head.Id, now),
                    _ => ApplyParkReset(state, now),
                };
            }
        }
        finally
        {
            state.EndCommit();
        }
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await source.SimulateScreenLatencyAsync("write/verify", 70, 160, cancellationToken).ConfigureAwait(false);
        var state = State;
        lock (state.Gate)
        {
            state.EnsureSeeded();
            if (SyncStoreChange.Head(plan) is not { } head)
            {
                return new WriteVerification(VerificationState.Unknown, Unreadable);
            }
            switch (head.Operation)
            {
                case SyncStoreOperation.Batch:
                    if (state.StorageReceipts.FirstOrDefault(r => r.BatchId == head.Id) is { } receipt && receipt.Sha256 == head.Sha256 && receipt.Count == head.Count)
                    {
                        return new WriteVerification(VerificationState.Verified, "Reçu de stockage relu dans la base" + c0 + FrenchText.Count(receipt.Count, "ligne", "lignes") + ", empreinte "
                            + SyncText.ShortHash(receipt.Sha256) + SyncText.Semi + " base relue (génération " + FrenchText.Integer(state.Generation) + ").");
                    }
                    return state.Batches.ContainsKey(head.Id)
                        ? new WriteVerification(VerificationState.Mismatch, "Le lot n’est pas dans la base" + c0 + "rien n’a été enregistré.")
                        : new WriteVerification(VerificationState.Unknown, "Lot introuvable dans la base et dans la mémoire du moteur" + c0 + "relisez la base avant toute nouvelle lecture.");
                case SyncStoreOperation.SnapshotCapture:
                    return state.Snapshots.FirstOrDefault(s => s.Id == head.Id) is { } snapshot && snapshot.RowsSha256 == head.Sha256 && snapshot.Lines.Length == head.Count
                        ? new WriteVerification(VerificationState.Verified, "Relevé relu dans la base" + c0 + SyncStoreChange.Objects(snapshot.Lines.Length) + ", empreinte " + SyncText.ShortHash(snapshot.RowsSha256) + ".")
                        : new WriteVerification(VerificationState.Mismatch, "Relevé absent de la base" + c0 + "il n’a pas été enregistré (50 relevés au plus par domaine, 300 000 objets).");
                case SyncStoreOperation.SnapshotDelete:
                    return state.Snapshots.Any(s => s.Id == head.Id)
                        ? new WriteVerification(VerificationState.Mismatch, "Le relevé est toujours dans la base.")
                        : new WriteVerification(VerificationState.Verified, "Relevé absent de la base relue" + c0 + "suppression confirmée.");
                default:
                    return state.Park.Count == 0
                        ? new WriteVerification(VerificationState.Verified, "Relevé du parc relu" + c0 + "aucun poste, l’état de balayage est effacé.")
                        : new WriteVerification(VerificationState.Mismatch, "Le relevé du parc contient encore " + FrenchText.Count(state.Park.Count, "poste", "postes") + ".");
            }
        }
    }

    // ---------------------------------------------------------------- application to the base (under the gate)

    private static WriteOutcome ApplyIndex(SimulatedSyncState state, IndexBatch batch, DateTimeOffset now)
    {
        Backup(state, now);
        var reconciliation = Reconcile(state, batch);
        var scopeDn = batch.Target == SyncTarget.Ou ? batch.Scope.Dn : state.DomainDn;
        var census = batch.Target == SyncTarget.Domain && batch.Complete && !batch.Census.IsEmpty ? CensusGaps(state, batch, reconciliation) : null;
        var (rows, absences) = SyncReconcile.Apply(state.Rows, reconciliation, scopeDn, batch.CreatedAt, batch.Controller);
        state.SetRows(rows);
        // Every pass reads the LAPS schema with the computers (absent, or present but not visible with this account).
        state.LapsSchema = batch.LapsSchema;
        var back = batch.Rows.Select(r => r.ObjectGuid).ToHashSet();
        state.Absences.RemoveAll(a => back.Contains(a.ObjectGuid) || absences.Any(n => n.ObjectGuid == a.ObjectGuid));
        state.Absences.AddRange(absences);
        if (batch.Target == SyncTarget.Ou)
        {
            var key = SyncStateEntry.OuKey(batch.Scope.Dn);
            if (batch.Complete)
            {
                state.PutSyncState(new SyncStateEntry(key, batch.Scope.Dn, batch.CreatedAt, "Subtree", false, rows.Values.Count(r => SyncLocations.InScope(r.Dn, batch.Scope.Dn)), batch.Controller, 0, batch.InvocationId, null, 0));
                state.SyncStates.RemoveAll(e => e.IsAttempt && SyncLocations.InScope(e.BaseDn, batch.Scope.Dn));
            }
            else
            {
                state.PutSyncState(new SyncStateEntry(SyncStateEntry.AttemptPrefix + key, batch.Scope.Dn, batch.CreatedAt, "Subtree", true, batch.Rows.Length, batch.Controller, 0, null, batch.Cut?.Reason, batch.Cut?.Limit ?? 0));
            }
        }
        else if (batch.Complete)
        {
            state.Checkpoint = new SyncCheckpoint(batch.Controller, batch.InvocationId ?? state.InvocationId, batch.HighestUsn, batch.CreatedAt, rows.Count, state.DomainDn);
            state.PutSyncState(new SyncStateEntry(SyncStateEntry.DirectoryKey, state.DomainDn, batch.CreatedAt, "Subtree", false, rows.Count, batch.Controller, batch.HighestUsn, batch.InvocationId, null, 0));
            if (census is not null)
            {
                state.Gaps.Clear();
                state.Gaps.AddRange(census);
            }
        }
        else
        {
            state.PutSyncState(new SyncStateEntry(SyncStateEntry.AttemptPrefix + SyncStateEntry.DirectoryKey, state.DomainDn, batch.CreatedAt, "Subtree", true, batch.Rows.Length, batch.Controller, 0, null, batch.Cut?.Reason, batch.Cut?.Limit ?? 0));
        }
        if (!batch.Complete)
        {
            state.Partial = new PartialMarker(batch.CreatedAt, batch.Rows.Length, batch.Cut?.Reason, batch.Cut?.Limit ?? 0, scopeDn);
        }
        else if (state.Partial is { } marker && SyncLocations.InScope(marker.ScopeDn, scopeDn))
        {
            state.Partial = null;
        }
        var counts = reconciliation.Counts;
        Commit(state, batch, now, FrenchText.Count(batch.Rows.Length, "ligne et son identité vérifiées", "lignes et leurs identités vérifiées") + " avant l’écriture, transaction validée.");
        return new WriteOutcome(WriteResult.Applied, FrenchText.Count(batch.Rows.Length, "ligne enregistrée", "lignes enregistrées") + " en une transaction (empreinte vérifiée)" + c0
            + FrenchText.Count(counts.Added, "ajout", "ajouts") + ", " + FrenchText.Count(counts.Updated, "mise à jour", "mises à jour") + ", "
            + FrenchText.Count(counts.Unseen, "objet marqué non revu", "objets marqués non revus") + ". Base locale de la simulation, en mémoire.");
    }

    private static WriteOutcome ApplyAbsences(SimulatedSyncState state, AbsenceBatch batch, DateTimeOffset now)
    {
        Backup(state, now);
        var rows = new Dictionary<Guid, IndexRecord>(state.Rows);
        for (var i = 0; i < state.Absences.Count; i++)
        {
            var absence = state.Absences[i];
            if (batch.Outcomes.TryGetValue(absence.ObjectGuid, out var outcome))
            {
                state.Absences[i] = absence with { Status = outcome.Status, FoundDn = outcome.FoundDn, Detail = outcome.Detail, CheckedAt = batch.CreatedAt, Server = batch.Server };
                if (outcome.Keep is { } keep)
                {
                    rows[keep.ObjectGuid] = keep;
                }
            }
        }
        state.SetRows(rows);
        Commit(state, batch, now, FrenchText.Count(batch.Outcomes.Count, "résultat enregistré", "résultats enregistrés") + ", liste relue depuis la base.");
        return new WriteOutcome(WriteResult.Applied, FrenchText.Count(batch.Outcomes.Count, "vérification enregistrée", "vérifications enregistrées") + SyncText.Semi + " "
            + FrenchText.Count(batch.Outcomes.Values.Count(o => o.Keep is not null), "objet remis dans la base", "objets remis dans la base") + " sous le même GUID.");
    }

    private static WriteOutcome ApplyGaps(SimulatedSyncState state, GapBatch batch, DateTimeOffset now)
    {
        Backup(state, now);
        var rows = new Dictionary<Guid, IndexRecord>(state.Rows);
        foreach (var outcome in batch.Outcomes.Values.Where(o => o.Keep is not null))
        {
            rows[outcome.Keep!.ObjectGuid] = outcome.Keep;
        }
        state.SetRows(rows);
        var leaving = batch.Outcomes.Where(o => o.Value.LeavesList).Select(o => o.Key).ToHashSet();
        state.Gaps.RemoveAll(g => leaving.Contains(g.ObjectGuid));
        Commit(state, batch, now, FrenchText.Count(batch.Outcomes.Count, "identité traitée", "identités traitées") + ", liste relue depuis la base.");
        return new WriteOutcome(WriteResult.Applied, FrenchText.Count(batch.Outcomes.Values.Count(o => o.Keep is not null), "objet ajouté", "objets ajoutés") + " à la base, "
            + FrenchText.Count(leaving.Count, "identité retirée", "identités retirées") + " de la liste des manquants.");
    }

    private static WriteOutcome ApplyShared(SimulatedSyncState state, ParkSharedBatch batch, DateTimeOffset now)
    {
        state.SetPark(new Dictionary<string, ParkEntry>(batch.Merged, StringComparer.Ordinal));
        state.SetSharedFile(new Dictionary<string, ParkEntry>(batch.Merged, StringComparer.Ordinal));
        state.SharedLastSync = now;
        Commit(state, batch, now, "Fichier partagé réécrit sous verrou, relevé local fusionné.");
        return new WriteOutcome(WriteResult.Applied, "Relevé fusionné" + c0 + FrenchText.Count(batch.Merged.Count, "poste", "postes") + " dans la base et dans le fichier partagé (simulation, en mémoire).");
    }

    private static WriteOutcome ApplyCapture(SimulatedSyncState state, PendingCapture capture, DateTimeOffset now)
    {
        var lines = Lines(state, capture.Scope);
        state.Snapshots.Add(new SnapshotRecord(capture.Id, capture.Label, state.DomainDn, capture.Scope.Dn, true, WritePlans.TruncateToSecond(now), capture.Coverage.State,
            capture.Coverage.At, capture.Coverage.Source, capture.Coverage.Text, lines, SyncSnapshots.Fingerprint(lines)));
        state.Captures.Remove(capture.Id);
        state.Generation++;
        return new WriteOutcome(WriteResult.Applied, "Relevé " + FrenchText.Quote(capture.Label) + " enregistré" + c0 + SyncStoreChange.Objects(lines.Length) + ". " + capture.Coverage.Text);
    }

    private static WriteOutcome ApplyDelete(SimulatedSyncState state, string id, DateTimeOffset now)
    {
        var removed = state.Snapshots.RemoveAll(s => s.Id == id);
        state.Generation++;
        _ = now;
        return removed > 0
            ? new WriteOutcome(WriteResult.Applied, "Relevé supprimé de la base locale.")
            : new WriteOutcome(WriteResult.NoChange, "Relevé déjà absent" + c0 + "aucune écriture.");
    }

    private static WriteOutcome ApplyParkReset(SimulatedSyncState state, DateTimeOffset now)
    {
        Backup(state, now);
        var count = state.Park.Count;
        state.SetPark(new Dictionary<string, ParkEntry>(StringComparer.Ordinal));
        state.Generation++;
        return new WriteOutcome(WriteResult.Applied, "État de balayage effacé" + c0 + FrenchText.Count(count, "relevé oublié", "relevés oubliés") + ". Associations, observations et historique conservés.");
    }

    // ---------------------------------------------------------------- helpers

    private static void Backup(SimulatedSyncState state, DateTimeOffset now)
    {
        if (SyncCoverageRules.Backup(state.LastBackupAt, now).Due)
        {
            state.LastBackupAt = now;
        }
    }

    private static void Commit(SimulatedSyncState state, HeldBatch batch, DateTimeOffset now, string text)
    {
        state.AddReceipt(new SyncStorageReceipt(batch.Id, batch.Kind, batch.Label, now, batch.Count, Sha(batch), true, text));
        state.Batches.Remove(batch.Id);
        state.Generation++;
    }

    private static string Sha(HeldBatch batch) => batch switch
    {
        IndexBatch index => index.Sha256,
        AbsenceBatch absences => absences.Sha256,
        GapBatch gaps => gaps.Sha256,
        ParkSharedBatch park => park.Sha256,
        _ => "",
    };

    private static SyncReconciliation Reconcile(SimulatedSyncState state, IndexBatch batch) =>
        SyncReconcile.Reconcile(state.Rows, batch.Rows, batch.Target == SyncTarget.Ou ? batch.Scope.Dn : null, batch.Complete && batch.Mode != SyncReadMode.Incremental, batch.Rebuild);

    /// <summary>An empty census of a complete domain pass is refused outside an explicit rebuild (Domenia 1 IndexBulk).</summary>
    private static string? Refusal(SimulatedSyncState state, IndexBatch batch) =>
        batch.Mode == SyncReadMode.Ou ? null : SyncReconcile.StorageRefusal(true, batch.Complete, batch.Rebuild, batch.Census.Length, state.Rows.Count);

    /// <summary>Identities of the census missing from the base once the batch is stored.</summary>
    private static List<CensusGapRecord> CensusGaps(SimulatedSyncState state, IndexBatch batch, SyncReconciliation reconciliation)
    {
        var after = state.Rows.Keys.ToHashSet();
        foreach (var item in reconciliation.Items)
        {
            after.Add(item.Row.ObjectGuid);
        }
        foreach (var row in reconciliation.Unseen)
        {
            after.Remove(row.ObjectGuid);
        }
        return [.. batch.Census.Where(g => !after.Contains(g.ObjectGuid))];
    }

    private static ImmutableArray<SnapshotLine> Lines(SimulatedSyncState state, SyncScope scope) =>
        [.. state.Rows.Values.Where(r => scope.IsDomain || SyncLocations.InScope(r.Dn, scope.Dn)).OrderBy(r => r.Dn, StringComparer.OrdinalIgnoreCase).Select(SnapshotLine.From)];

    private static string Int(int value) => value.ToString(CultureInfo.InvariantCulture);
}
