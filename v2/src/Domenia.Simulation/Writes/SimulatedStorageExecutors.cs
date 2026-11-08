using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Writes of the local base in simulation (docs/ops/parametres.md § 6): they change only the fictitious base kept in memory
/// by <see cref="SimulatedLocalStore"/> — no file, no SQLite, no real effect — through the same circuit as every write
/// (plan, confirmation, receipt written before, re-read after). The rules of the plans are those of the real base
/// (<see cref="StorageWritePlans"/>, pure, Domenia.Core). Each step waits a short realistic delay of its own sub-sequence
/// (« latency/screen/settings/write/… »). Abstract: only the sealed executors below are discovered.
/// </summary>
public abstract class SimulatedStorageExecutor : IWriteExecutor
{
    private protected SimulatedStorageExecutor(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        Source = source;
    }

    private protected SimulatedDirectorySource Source { get; }

    private protected SimulatedLocalStore Store => SimulatedLocalStore.For(Source);

    private protected DateTimeOffset Now => Source.Clock.GetUtcNow();

    private protected TimeZoneInfo Zone => Source.World.TimeZone;

    public abstract string Kind { get; }

    private protected Task PlanDelayAsync(CancellationToken cancellationToken) =>
        Source.SimulateScreenLatencyAsync("settings/write/plan", 90, 220, cancellationToken);

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Source.SimulateScreenLatencyAsync("settings/write/check", 60, 140, cancellationToken).ConfigureAwait(false);
        return Check(plan, Store.Snapshot());
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Source.SimulateScreenLatencyAsync("settings/write/execute", 320, 720, cancellationToken).ConfigureAwait(false);
        return Execute(plan);
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Source.SimulateScreenLatencyAsync("settings/write/verify", 90, 200, cancellationToken).ConfigureAwait(false);
        return Verify(plan, Store.Snapshot());
    }

    /// <summary>Preconditions: the same base, at the same revision when the plan carries one.</summary>
    private protected virtual WritePrecheck Check(WritePlan plan, LocalStoreSnapshot store) => StorageWritePlans.CheckRevision(plan, store);

    private protected abstract WriteOutcome Execute(WritePlan plan);

    private protected abstract WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store);

    private protected static string Raw(WritePlan plan, string attribute) =>
        plan.Changes.FirstOrDefault(c => c.Attribute == attribute)?.AfterValue ?? "";

    private protected const string NoEffect = " Simulation" + FrenchText.Nbsp + ": base fictive en mémoire, aucun fichier écrit, aucun effet réel.";
}

/// <summary>Verified backup of the fictitious base (PAR-033, PAR-034).</summary>
public sealed class SimulatedStorageBackupExecutor : SimulatedStorageExecutor, IStorageBackupExecutor
{
    public SimulatedStorageBackupExecutor(SimulatedDirectorySource source)
        : base(source)
    {
    }

    public override string Kind => StorageWritePlans.Backup;

    public async Task<WritePlanDraft> PlanBackupAsync(StoragePolicy policy, string annex, string series, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(annex);
        ArgumentNullException.ThrowIfNull(series);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return StorageWritePlans.BackupDraft(Store.Snapshot(), policy, annex, Now, Zone, series);
    }

    private protected override WritePrecheck Check(WritePlan plan, LocalStoreSnapshot store)
    {
        var check = StorageWritePlans.CheckRevision(plan with { Changes = [.. plan.Changes.Where(c => c.Attribute != "revision")] }, store);
        if (!check.Current)
        {
            return check;
        }
        return store.Maintenance.Locked
            ? WritePrecheck.Stale("Bascule à terminer" + FrenchText.Colon + "la sauvegarde attend la fin de la maintenance. Rien n’a été envoyé.")
            : WritePrecheck.Valid("Base relue" + FrenchText.Colon + "ouverte en lecture seule pour la copie, aucune maintenance en cours.");
    }

    /// <summary>
    /// The copy of the plan: its planned name, its series (manual or scheduled) and its annex, bound to the SHA-256 of the
    /// copy. The rotation removes the oldest copies of the series in rotation beyond the number kept.
    /// </summary>
    internal static (WriteOutcome Outcome, LocalStoreBackup Backup) BackupNow(WritePlan plan, SimulatedLocalStore store, DateTimeOffset now)
    {
        var keep = plan.Changes.Any(c => c.Attribute == "backup.rotation")
            ? store.Snapshot().Backups.Count(b => LocalStoreRules.InRotation(b.Kind))
            : int.MaxValue;
        var series = Raw(plan, "backup.series") is StorageWritePlans.ScheduledSeries ? "scheduled" : "manual";
        var backup = store.AddBackup(series, now, keep, Raw(plan, "backup.preferences"), "Domenia", Raw(plan, "backup.file"));
        var outcome = new WriteOutcome(WriteResult.Applied, "Copie " + backup.FileName + " (" + SettingsFormat.Size(backup.Bytes) + ") contrôlée" + FrenchText.Colon + "quick_check réussi, SHA-256 "
            + SettingsFormat.ShortSha(backup.Sha256) + " ; annexe des préférences liée (" + FrenchText.Count(backup.PreferenceKeys, "clé", "clés") + ")." + NoEffect);
        return (outcome, backup);
    }

    private protected override WriteOutcome Execute(WritePlan plan) => BackupNow(plan, Store, Now).Outcome;

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store) => VerifyBackup(plan, store, Zone);

    /// <summary>
    /// Re-reads the copy named by the plan (never any other copy made meanwhile): verified only with its quick_check, its
    /// SHA-256, its date of verification and its annex bound to that very SHA-256 (PAR-033, PAR-034).
    /// </summary>
    internal static WriteVerification VerifyBackup(WritePlan plan, LocalStoreSnapshot store, TimeZoneInfo zone)
    {
        var file = Raw(plan, "backup.file");
        var created = store.Backups.Where(b => string.Equals(b.FileName, file, StringComparison.OrdinalIgnoreCase) && b.At >= plan.CreatedAt - TimeSpan.FromSeconds(1)).OrderByDescending(b => b.At).FirstOrDefault();
        if (created is null)
        {
            return new WriteVerification(VerificationState.Mismatch, "La sauvegarde du plan (" + file + ") n’est pas relue" + FrenchText.Colon + "elle ne compte pas comme réussie.");
        }
        if (!StoragePolicyRules.IsVerified(created))
        {
            return new WriteVerification(VerificationState.Mismatch, "Sauvegarde relue sans preuve complète (contrôle, empreinte ou date absents)" + FrenchText.Colon + "elle ne compte pas comme réussie.");
        }
        return BackupPreferencesRules.IsBound(created)
            ? new WriteVerification(VerificationState.Verified, "Sauvegarde relue" + FrenchText.Colon + created.FileName + ", quick_check réussi, SHA-256 " + SettingsFormat.ShortSha(created.Sha256)
                + ", vérifiée le " + SettingsFormat.LocalDate(created.VerifiedAt!.Value, zone, seconds: true) + " ; annexe " + BackupPreferencesRules.Format + " liée à cette copie.")
            : new WriteVerification(VerificationState.Mismatch, "Sauvegarde relue sans annexe de préférences liée à sa copie" + FrenchText.Colon + "elle ne compte pas comme une sauvegarde complète.");
    }
}

/// <summary>Backup published to a chosen file (PAR-035): in simulation the publication is recorded, no file is written.</summary>
public sealed class SimulatedStorageBackupCopyExecutor : SimulatedStorageExecutor, IStorageBackupCopyExecutor
{
    public SimulatedStorageBackupCopyExecutor(SimulatedDirectorySource source)
        : base(source)
    {
    }

    public override string Kind => StorageWritePlans.BackupCopy;

    public async Task<WritePlanDraft> PlanBackupCopyAsync(string destination, StoragePolicy policy, string annex, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(annex);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return StorageWritePlans.BackupCopyDraft(Store.Snapshot(), destination, policy, annex, Now, Zone);
    }

    private protected override WritePrecheck Check(WritePlan plan, LocalStoreSnapshot store)
    {
        var check = StorageWritePlans.CheckRevision(plan with { Changes = [.. plan.Changes.Where(c => c.Attribute != "revision")] }, store);
        if (!check.Current)
        {
            return check;
        }
        var destination = Raw(plan, "backup.export");
        return LocalStoreRules.DestinationProblem(destination, store.PathLabel) is string problem
            ? WritePrecheck.Stale(problem + " Rien n’a été envoyé.")
            : WritePrecheck.Valid("Base relue et destination contrôlée" + FrenchText.Colon + destination + ".");
    }

    private protected override WriteOutcome Execute(WritePlan plan)
    {
        var (outcome, backup) = SimulatedStorageBackupExecutor.BackupNow(plan, Store, Now);
        var destination = Raw(plan, "backup.export");
        Store.AddExport(destination, backup);
        return outcome with { Detail = outcome.Detail.Replace(NoEffect, "", StringComparison.Ordinal) + " Publication fictive vers " + destination + "." + NoEffect };
    }

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store)
    {
        var backup = SimulatedStorageBackupExecutor.VerifyBackup(plan, store, Zone);
        if (backup.State != VerificationState.Verified)
        {
            return backup;
        }
        var destination = Raw(plan, "backup.export");
        var file = Raw(plan, "backup.file");
        var copy = store.Backups.FirstOrDefault(b => string.Equals(b.FileName, file, StringComparison.OrdinalIgnoreCase));
        var export = store.Exports.LastOrDefault(e => string.Equals(e.Destination, destination, StringComparison.OrdinalIgnoreCase) && copy is not null && e.BackupId == copy.Id && e.Sha256 == copy.Sha256);
        return export is not null
            ? new WriteVerification(VerificationState.Verified, backup.Detail + " Copie publiée relue" + FrenchText.Colon + destination + " (même empreinte).")
            : new WriteVerification(VerificationState.Mismatch, "La sauvegarde existe mais sa publication vers " + destination + " n’est pas relue" + FrenchText.Colon + "la copie locale vérifiée reste disponible.");
    }
}

/// <summary>Retention of the old measures (PAR-024): backup before, rows older than the planned cutoffs removed.</summary>
public sealed class SimulatedStorageRetentionExecutor : SimulatedStorageExecutor, IStorageRetentionExecutor
{
    public SimulatedStorageRetentionExecutor(SimulatedDirectorySource source)
        : base(source)
    {
    }

    public override string Kind => StorageWritePlans.Retention;

    public async Task<WritePlanDraft> PlanRetentionAsync(StoragePolicy policy, string fingerprint, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(policy);
        ArgumentNullException.ThrowIfNull(fingerprint);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        var store = Store.Snapshot();
        var preview = StoragePolicyRules.Preview(policy, store, Now, Zone);
        return StorageWritePlans.RetentionDraft(store, preview, fingerprint, Zone);
    }

    private protected override WriteOutcome Execute(WritePlan plan)
    {
        var now = Now;
        var backup = Store.AddBackup("retention", now, int.MaxValue, null, "Avant-conservation");
        var rows = StorageWritePlans.PlannedRows(plan, "retention.");
        Store.ApplyRetention(rows, now);
        return new WriteOutcome(WriteResult.Applied, "Sauvegarde préalable " + backup.FileName + " vérifiée, puis " + FrenchText.Count(rows.Sum(r => r.Rows), "ligne retirée", "lignes retirées")
            + " (" + string.Join(", ", rows.Select(r => r.Id + " " + FrenchText.Integer(r.Rows))) + ")." + NoEffect);
    }

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store)
    {
        var left = new List<string>();
        foreach (var (family, _, cutoff) in StorageWritePlans.PlannedRows(plan, "retention."))
        {
            var data = store.Families.FirstOrDefault(f => f.Family == family);
            if (data is null || cutoff is not DateTimeOffset at)
            {
                continue;
            }
            var days = Math.Max(0, (int)Math.Ceiling((Now - at).TotalDays - 0.0001));
            var rest = StoragePolicyRules.RowsOlderThan(data, days, family == "linkHistory");
            if (rest > 0)
            {
                left.Add(family + " " + FrenchText.Integer(rest));
            }
        }
        return left.Count == 0
            ? new WriteVerification(VerificationState.Verified, "Base relue" + FrenchText.Colon + "plus aucune mesure antérieure aux dates limites du plan ; révision " + FrenchText.Integer(store.Revision) + ".")
            : new WriteVerification(VerificationState.Mismatch, "Mesures encore antérieures aux dates limites" + FrenchText.Colon + string.Join(", ", left) + ".");
    }
}

/// <summary>Voluntary purge (PAR-031): backup before (improvement), closed categories only.</summary>
public sealed class SimulatedStoragePurgeExecutor : SimulatedStorageExecutor, IStoragePurgeExecutor
{
    public SimulatedStoragePurgeExecutor(SimulatedDirectorySource source)
        : base(source)
    {
    }

    public override string Kind => StorageWritePlans.Purge;

    public async Task<WritePlanDraft> PlanPurgeAsync(IReadOnlyCollection<string> categories, int historyDays, string fingerprint, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(categories);
        ArgumentNullException.ThrowIfNull(fingerprint);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        var store = Store.Snapshot();
        var preview = LocalStoreRules.PurgePlan(store, categories, historyDays, Now, Zone);
        return StorageWritePlans.PurgeDraft(store, preview, fingerprint, Zone);
    }

    private static (string[] Categories, int HistoryDays) Planned(WritePlan plan)
    {
        var rows = StorageWritePlans.PlannedRows(plan, "purge.");
        var categories = rows.Select(r => r.Id).ToArray();
        var days = LocalStoreRules.DefaultHistoryDays;
        if (rows.FirstOrDefault(r => r.Id == "history").Cutoff is DateTimeOffset cutoff)
        {
            days = Math.Max(1, (int)Math.Round((plan.CreatedAt - cutoff).TotalDays));
        }
        return (categories, days);
    }

    private protected override WriteOutcome Execute(WritePlan plan)
    {
        var now = Now;
        var backup = Store.AddBackup("purge", now, int.MaxValue, null, "Avant-purge");
        var (categories, days) = Planned(plan);
        var rows = StorageWritePlans.PlannedRows(plan, "purge.");
        Store.ApplyPurge(categories, days, now);
        return new WriteOutcome(WriteResult.Applied, "Sauvegarde préalable " + backup.FileName + " vérifiée, puis " + FrenchText.Count(rows.Sum(r => r.Rows), "ligne purgée", "lignes purgées")
            + " (" + string.Join(", ", categories.Select(LocalStoreRules.CategoryLabel)) + ")." + NoEffect);
    }

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store)
    {
        var (categories, days) = Planned(plan);
        var left = categories.Select(c => (Category: c, Rows: LocalStoreRules.PurgeRows(store, c, days))).Where(x => x.Rows > 0).ToList();
        return left.Count == 0
            ? new WriteVerification(VerificationState.Verified, "Base relue" + FrenchText.Colon + "catégories purgées vides ; associations déclarées, reçus et préférences intacts.")
            : new WriteVerification(VerificationState.Mismatch, "Lignes encore présentes" + FrenchText.Colon + string.Join(", ", left.Select(x => LocalStoreRules.CategoryLabel(x.Category) + " " + FrenchText.Integer(x.Rows))) + ".");
    }
}

/// <summary>Move of the fictitious base (PAR-016): new path, original kept read only, return possible.</summary>
public sealed class SimulatedStorageMoveExecutor : SimulatedStorageExecutor, IStorageMoveExecutor
{
    public SimulatedStorageMoveExecutor(SimulatedDirectorySource source)
        : base(source)
    {
    }

    public override string Kind => StorageWritePlans.Move;

    public async Task<WritePlanDraft> PlanMoveAsync(string destination, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(destination);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        var store = Store.Snapshot();
        return StorageWritePlans.MoveDraft(store, destination, store.Space.FreeBytes);
    }

    private protected override WriteOutcome Execute(WritePlan plan)
    {
        var destination = Raw(plan, "store.path");
        Store.Move(destination);
        return new WriteOutcome(WriteResult.Applied, "Copie vérifiée puis bascule vers " + destination + " ; l’original est gardé en lecture seule avec un marqueur." + NoEffect);
    }

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store)
    {
        var destination = Raw(plan, "store.path");
        return string.Equals(store.PathLabel, destination, StringComparison.OrdinalIgnoreCase)
            ? new WriteVerification(VerificationState.Verified, "Base active relue" + FrenchText.Colon + destination + ", révision " + FrenchText.Integer(store.Revision) + ", retour possible.")
            : new WriteVerification(VerificationState.Mismatch, "La base active relue n’est pas " + destination + ".");
    }
}

/// <summary>Restore of a verified backup into a new fictitious file (PAR-017).</summary>
public sealed class SimulatedStorageRestoreExecutor : SimulatedStorageExecutor, IStorageRestoreExecutor
{
    public SimulatedStorageRestoreExecutor(SimulatedDirectorySource source)
        : base(source)
    {
    }

    public override string Kind => StorageWritePlans.Restore;

    public async Task<WritePlanDraft> PlanRestoreAsync(string backupId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(backupId);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        var store = Store.Snapshot();
        var backup = store.Backups.FirstOrDefault(b => b.Id == backupId)
            ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Sauvegarde introuvable dans la base fictive" + FrenchText.Colon + "aucune restauration préparée.");
        return StorageWritePlans.RestoreDraft(store, backup, Now, Zone);
    }

    /// <summary>
    /// A .db file chosen on the disk: in simulation only the files of the fictitious base are known (a copy of its Backups
    /// folder, or a copy published to a file earlier); nothing is read on the disk.
    /// </summary>
    public async Task<WritePlanDraft> PlanRestoreFileAsync(string path, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(path);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        var store = Store.Snapshot();
        var name = path.Trim().Replace('/', '\\');
        var folder = StorageViewBuilder.BackupFolder(store.PathLabel);
        var export = store.Exports.LastOrDefault(e => string.Equals(e.Destination, name, StringComparison.OrdinalIgnoreCase));
        var backup = export is not null
            ? store.Backups.FirstOrDefault(b => b.Id == export.BackupId)
            : store.Backups.FirstOrDefault(b => folder is not null && string.Equals(folder + "\\" + b.FileName, name, StringComparison.OrdinalIgnoreCase));
        if (backup is null)
        {
            throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Simulation" + FrenchText.Colon + "seules les sauvegardes de la base fictive et leurs copies publiées sont restaurables ; aucun fichier n’est lu sur le disque.");
        }
        return StorageWritePlans.RestoreDraft(store, backup, Now, Zone);
    }

    private protected override WriteOutcome Execute(WritePlan plan)
    {
        var file = Raw(plan, "store.path");
        var backupId = Raw(plan, "restore.source");
        var backup = Store.Snapshot().Backups.FirstOrDefault(b => b.Id == backupId)
            ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "La sauvegarde du plan n’existe plus" + FrenchText.Colon + "rien n’a été restauré.");
        Store.Restore(backup, file);
        return new WriteOutcome(WriteResult.Applied, "Sauvegarde " + backup.FileName + " restaurée dans " + file + " (nouveau fichier), puis bascule ; la base précédente est conservée." + NoEffect);
    }

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store)
    {
        var file = Raw(plan, "store.path");
        var revision = Raw(plan, "revision");
        return store.PathLabel.EndsWith(file, StringComparison.OrdinalIgnoreCase) && store.Revision.ToString(CultureInfo.InvariantCulture) == revision
            ? new WriteVerification(VerificationState.Verified, "Base active relue" + FrenchText.Colon + file + ", révision " + FrenchText.Integer(store.Revision) + " de la sauvegarde, intégrité confirmée.")
            : new WriteVerification(VerificationState.Mismatch, "La base active relue n’est pas la base restaurée du plan.");
    }
}

/// <summary>End of an interrupted switch (PAR-018), left by the demonstration scenario « Bascule interrompue ».</summary>
public sealed class SimulatedStorageResumeExecutor : SimulatedStorageExecutor, IStorageResumeExecutor
{
    public SimulatedStorageResumeExecutor(SimulatedDirectorySource source)
        : base(source)
    {
    }

    public override string Kind => StorageWritePlans.Resume;

    public async Task<WritePlanDraft> PlanResumeAsync(CancellationToken cancellationToken)
    {
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return StorageWritePlans.ResumeDraft(Store.Snapshot());
    }

    private protected override WritePrecheck Check(WritePlan plan, LocalStoreSnapshot store)
    {
        var check = StorageWritePlans.CheckRevision(plan, store);
        if (!check.Current)
        {
            return check;
        }
        var target = Raw(plan, "store.path");
        return store.Maintenance.Locked && string.Equals(store.Maintenance.TargetPath, target, StringComparison.OrdinalIgnoreCase)
            ? WritePrecheck.Valid("Marqueur relu" + FrenchText.Colon + "copie vérifiée " + target + ", identité de la base revérifiée.")
            : WritePrecheck.Stale("Le marqueur ne désigne plus la copie du plan" + FrenchText.Colon + "rien n’a été envoyé.");
    }

    private protected override WriteOutcome Execute(WritePlan plan) =>
        Store.ResumeSwitch()
            ? new WriteOutcome(WriteResult.Applied, "Bascule terminée vers " + Raw(plan, "store.path") + " ; l’ancienne base reste en lecture seule, retour possible." + NoEffect)
            : throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune bascule interrompue" + FrenchText.Colon + "rien à reprendre.");

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store)
    {
        var target = Raw(plan, "store.path");
        return !store.Maintenance.Locked && string.Equals(store.PathLabel, target, StringComparison.OrdinalIgnoreCase)
            ? new WriteVerification(VerificationState.Verified, "Base active relue" + FrenchText.Colon + target + ", aucune bascule en attente.")
            : new WriteVerification(VerificationState.Mismatch, "Bascule toujours à terminer.");
    }
}

/// <summary>Return to the previous base after a switch of this session (PAR-019).</summary>
public sealed class SimulatedStorageRollbackExecutor : SimulatedStorageExecutor, IStorageRollbackExecutor
{
    public SimulatedStorageRollbackExecutor(SimulatedDirectorySource source)
        : base(source)
    {
    }

    public override string Kind => StorageWritePlans.Rollback;

    public async Task<WritePlanDraft> PlanRollbackAsync(CancellationToken cancellationToken)
    {
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return StorageWritePlans.RollbackDraft(Store.Snapshot());
    }

    private protected override WriteOutcome Execute(WritePlan plan) =>
        Store.Rollback()
            ? new WriteOutcome(WriteResult.Applied, "Retour à " + Raw(plan, "store.path") + " ; le marqueur de l’original est retiré, aucun fichier supprimé." + NoEffect)
            : throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Retour impossible" + FrenchText.Colon + "la nouvelle base a reçu une écriture ou aucune bascule n’est à annuler. Rien n’a été changé.");

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store)
    {
        var target = Raw(plan, "store.path");
        return string.Equals(store.PathLabel, target, StringComparison.OrdinalIgnoreCase)
            ? new WriteVerification(VerificationState.Verified, "Base active relue" + FrenchText.Colon + target + ".")
            : new WriteVerification(VerificationState.Mismatch, "La base active relue n’est pas " + target + ".");
    }
}

/// <summary>Resumption of the suspended writer (PAR-010), suspended by the demonstration scenario « Enregistrement suspendu ».</summary>
public sealed class SimulatedStorageWriterResumeExecutor : SimulatedStorageExecutor, IStorageWriterResumeExecutor
{
    public SimulatedStorageWriterResumeExecutor(SimulatedDirectorySource source)
        : base(source)
    {
    }

    public override string Kind => StorageWritePlans.WriterResume;

    public async Task<WritePlanDraft> PlanWriterResumeAsync(CancellationToken cancellationToken)
    {
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return StorageWritePlans.WriterResumeDraft(Store.Snapshot());
    }

    private protected override WritePrecheck Check(WritePlan plan, LocalStoreSnapshot store) =>
        !store.Writer.Suspended
            ? WritePrecheck.Stale("Les enregistrements locaux ne sont plus suspendus" + FrenchText.Colon + "rien n’a été envoyé.")
            : store.Writer.Active
                ? WritePrecheck.Stale("Un enregistrement est encore actif" + FrenchText.Colon + "rien n’a été envoyé ; attendez sa fin.")
                : WritePrecheck.Valid("Écrivain relu" + FrenchText.Colon + "suspendu, aucun enregistrement actif.");

    private protected override WriteOutcome Execute(WritePlan plan)
    {
        var pending = Store.Snapshot().Writer.Pending;
        return Store.ResumeWriter(Now)
            ? new WriteOutcome(WriteResult.Applied, "Écrivain réarmé" + FrenchText.Colon + FrenchText.Count(pending, "élément en mémoire enregistré", "éléments en mémoire enregistrés") + ", rien de perdu." + NoEffect)
            : new WriteOutcome(WriteResult.NoChange, "Écrivain déjà actif" + FrenchText.Colon + "rien à reprendre.");
    }

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store) =>
        store.Writer.Suspended
            ? new WriteVerification(VerificationState.Mismatch, "Écrivain toujours suspendu.")
            : new WriteVerification(VerificationState.Verified, "Écrivain relu" + FrenchText.Colon + "actif.");
}

/// <summary>Takeover of the Domenia 1 data (PAR-028): migration backup before, the steps of the plan, idempotent.</summary>
public sealed class SimulatedStorageLegacyImportExecutor : SimulatedStorageExecutor, IStorageLegacyImportExecutor
{
    public SimulatedStorageLegacyImportExecutor(SimulatedDirectorySource source)
        : base(source)
    {
    }

    public override string Kind => StorageWritePlans.LegacyImport;

    public async Task<WritePlanDraft> PlanLegacyImportAsync(string domain, string fingerprint, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(domain);
        ArgumentNullException.ThrowIfNull(fingerprint);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        var store = Store.Snapshot();
        var preview = StorageViewBuilder.LegacySimulation(store, domain, Zone);
        return StorageWritePlans.LegacyImportDraft(store, domain, preview.Fingerprint, fingerprint);
    }

    private protected override WritePrecheck Check(WritePlan plan, LocalStoreSnapshot store)
    {
        var check = StorageWritePlans.CheckRevision(plan, store);
        if (!check.Current)
        {
            return check;
        }
        return string.Equals(Raw(plan, "legacy.marker"), store.Legacy.Marker, StringComparison.Ordinal) && store.Legacy.AppliedMarker is null
            ? WritePrecheck.Valid("Sources de Domenia 1 relues" + FrenchText.Colon + "même marqueur que la simulation, aucune reprise appliquée.")
            : WritePrecheck.Stale("Les données de Domenia 1 ou la reprise ont changé depuis le plan" + FrenchText.Colon + "rien n’a été envoyé.");
    }

    private protected override WriteOutcome Execute(WritePlan plan)
    {
        var now = Now;
        var backup = Store.AddBackup("import", now, int.MaxValue, null, "Avant-reprise");
        var steps = plan.Changes
            .Where(c => c.Attribute.StartsWith("legacy.", StringComparison.Ordinal) && c.Attribute != "legacy.marker")
            .Select(c => new LegacyStep(c.Attribute["legacy.".Length..], "", c.Label, "", "import", long.Parse(c.AfterValue ?? "0", CultureInfo.InvariantCulture), ""))
            .ToList();
        var taken = Store.ImportLegacy(steps, Raw(plan, "legacy.marker"), now);
        return taken > 0
            ? new WriteOutcome(WriteResult.Applied, "Sauvegarde de migration " + backup.FileName + " vérifiée, puis " + FrenchText.Count(taken, "ligne reprise", "lignes reprises") + " ; base et fichiers de Domenia 1 laissés en place." + NoEffect)
            : new WriteOutcome(WriteResult.NoChange, "Données de Domenia 1 déjà reprises" + FrenchText.Colon + "rien de nouveau.");
    }

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store) =>
        LegacyRules.Plan(store.Legacy, store.Domain).Already
            ? new WriteVerification(VerificationState.Verified, "Base relue" + FrenchText.Colon + "marqueur de reprise posé ; une nouvelle simulation ne trouverait rien à reprendre.")
            : new WriteVerification(VerificationState.Mismatch, "Reprise non constatée à la relecture" + FrenchText.Colon + "le marqueur n’est pas posé.");
}

/// <summary>Demonstration scenarios of the fictitious base (simulation only): states that real failures would leave.</summary>
public sealed class SimulatedStorageScenarioExecutor : SimulatedStorageExecutor, IStorageScenarioExecutor
{
    public SimulatedStorageScenarioExecutor(SimulatedDirectorySource source)
        : base(source)
    {
    }

    public override string Kind => StorageWritePlans.Scenario;

    public async Task<WritePlanDraft> PlanScenarioAsync(string scenario, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scenario);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return StorageWritePlans.ScenarioDraft(Store.Snapshot(), scenario);
    }

    private protected override WritePrecheck Check(WritePlan plan, LocalStoreSnapshot store) =>
        string.Equals(StorageWritePlans.ScenarioOf(store), plan.Changes.First(c => c.Attribute == "scenario").BeforeValue, StringComparison.Ordinal)
            ? WritePrecheck.Valid("Base fictive relue" + FrenchText.Colon + "même état qu’au plan.")
            : WritePrecheck.Stale("La base fictive a changé d’état depuis le plan" + FrenchText.Colon + "rien n’a été envoyé.");

    private protected override WriteOutcome Execute(WritePlan plan)
    {
        var scenario = Raw(plan, "scenario");
        Store.Scenario(scenario, Now);
        var label = StorageWritePlans.Scenarios.First(s => s.Id == scenario).Label;
        return new WriteOutcome(WriteResult.Applied, "Base fictive mise dans l’état " + FrenchText.Quote(label) + "." + NoEffect);
    }

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store)
    {
        var scenario = Raw(plan, "scenario");
        return string.Equals(StorageWritePlans.ScenarioOf(store), scenario, StringComparison.Ordinal)
            ? new WriteVerification(VerificationState.Verified, "Base fictive relue dans l’état attendu.")
            : new WriteVerification(VerificationState.Mismatch, "La base fictive relue n’est pas dans l’état du plan.");
    }
}
