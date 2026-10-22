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

    public async Task<WritePlanDraft> PlanBackupAsync(StoragePolicy policy, int preferenceKeys, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(policy);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return StorageWritePlans.BackupDraft(Store.Snapshot(), policy, preferenceKeys, Now, Zone);
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

    private protected override WriteOutcome Execute(WritePlan plan) => BackupNow(plan, Store, Now, "manual");

    internal static WriteOutcome BackupNow(WritePlan plan, SimulatedLocalStore store, DateTimeOffset now, string kind)
    {
        var keep = plan.Changes.Any(c => c.Attribute == "backup.rotation")
            ? store.Snapshot().Backups.Count(b => LocalStoreRules.InRotation(b.Kind))
            : int.MaxValue;
        var preferenceKeys = int.TryParse(Raw(plan, "backup.preferences"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var keys) ? keys : 0;
        var backup = store.AddBackup(kind, now, keep, preferenceKeys);
        return new WriteOutcome(WriteResult.Applied, "Copie " + backup.FileName + " (" + SettingsFormat.Size(backup.Bytes) + ") contrôlée" + FrenchText.Colon + "quick_check réussi, SHA-256 " + SettingsFormat.ShortSha(backup.Sha256) + "." + NoEffect);
    }

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store) => VerifyBackup(plan, store, Zone);

    internal static WriteVerification VerifyBackup(WritePlan plan, LocalStoreSnapshot store, TimeZoneInfo zone)
    {
        var file = Raw(plan, "backup.file");
        var created = store.Backups.Where(b => b.At >= plan.CreatedAt - TimeSpan.FromSeconds(1)).OrderByDescending(b => b.At).FirstOrDefault();
        if (created is null)
        {
            return new WriteVerification(VerificationState.Mismatch, "Aucune nouvelle sauvegarde relue depuis le plan (" + file + ").");
        }
        return StoragePolicyRules.IsVerified(created)
            ? new WriteVerification(VerificationState.Verified, "Sauvegarde relue" + FrenchText.Colon + created.FileName + ", quick_check réussi, SHA-256 " + SettingsFormat.ShortSha(created.Sha256) + ", vérifiée le " + SettingsFormat.LocalDate(created.VerifiedAt!.Value, zone, seconds: true) + ".")
            : new WriteVerification(VerificationState.Mismatch, "Sauvegarde relue sans preuve complète (contrôle, empreinte ou date absents)" + FrenchText.Colon + "elle ne compte pas comme réussie.");
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

    public async Task<WritePlanDraft> PlanBackupCopyAsync(string destination, StoragePolicy policy, int preferenceKeys, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ArgumentNullException.ThrowIfNull(policy);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return StorageWritePlans.BackupCopyDraft(Store.Snapshot(), destination, policy, preferenceKeys, Now, Zone);
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
        var outcome = SimulatedStorageBackupExecutor.BackupNow(plan, Store, Now, "manual");
        var backup = Store.Snapshot().Backups.OrderByDescending(b => b.At).First();
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
        var export = store.Exports.LastOrDefault(e => string.Equals(e.Destination, destination, StringComparison.OrdinalIgnoreCase));
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
        var backup = Store.AddBackup("retention", now, int.MaxValue, 0, "Avant-conservation");
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
            ? new WriteVerification(VerificationState.Verified, "Base relue" + FrenchText.Colon + "plus aucune mesure antérieure aux dates limites du plan ; révision " + FrenchText.Integer(store.Revision) + ".")
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
        var backup = Store.AddBackup("purge", now, int.MaxValue, 0, "Avant-purge");
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
            ? new WriteVerification(VerificationState.Verified, "Base relue" + FrenchText.Colon + "catégories purgées vides ; associations déclarées, reçus et préférences intacts.")
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

    private protected override WriteOutcome Execute(WritePlan plan)
    {
        var file = Raw(plan, "store.path");
        var backupId = Raw(plan, "restore.source");
        var backup = Store.Snapshot().Backups.FirstOrDefault(b => b.Id == backupId)
            ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "La sauvegarde du plan n’existe plus" + FrenchText.Colon + "rien n’a été restauré.");
        Store.Restore(backup, file);
        return new WriteOutcome(WriteResult.Applied, "Sauvegarde " + backup.FileName + " restaurée dans " + file + " (nouveau fichier), puis bascule ; la base précédente est conservée." + NoEffect);
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

/// <summary>End of an interrupted switch (PAR-018); the simulation never leaves a switch interrupted.</summary>
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

    private protected override WriteOutcome Execute(WritePlan plan) =>
        throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune bascule interrompue" + FrenchText.Colon + "rien à reprendre.");

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store) =>
        store.Maintenance.Locked
            ? new WriteVerification(VerificationState.Mismatch, "Bascule toujours à terminer.")
            : new WriteVerification(VerificationState.Verified, "Aucune bascule en attente.");
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

/// <summary>Resumption of the suspended writer (PAR-010); the writer of the simulation is never suspended.</summary>
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
        store.Writer.Suspended
            ? WritePrecheck.Valid("Écrivain relu" + FrenchText.Colon + "suspendu, aucun enregistrement actif.")
            : WritePrecheck.Stale("Les enregistrements locaux ne sont plus suspendus" + FrenchText.Colon + "rien n’a été envoyé.");

    private protected override WriteOutcome Execute(WritePlan plan) =>
        new(WriteResult.NoChange, "Écrivain déjà actif" + FrenchText.Colon + "rien à reprendre.");

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store) =>
        store.Writer.Suspended
            ? new WriteVerification(VerificationState.Mismatch, "Écrivain toujours suspendu.")
            : new WriteVerification(VerificationState.Verified, "Écrivain relu" + FrenchText.Colon + "actif.");
}

/// <summary>Takeover of the Domenia 1 data (PAR-028): migration backup before, idempotent.</summary>
public sealed class SimulatedStorageLegacyImportExecutor : SimulatedStorageExecutor, IStorageLegacyImportExecutor
{
    public SimulatedStorageLegacyImportExecutor(SimulatedDirectorySource source)
        : base(source)
    {
    }

    public override string Kind => StorageWritePlans.LegacyImport;

    public async Task<WritePlanDraft> PlanLegacyImportAsync(string fingerprint, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(fingerprint);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        var store = Store.Snapshot();
        var preview = StorageViewBuilder.LegacySimulation(store, Zone);
        return StorageWritePlans.LegacyImportDraft(store, preview.Fingerprint, fingerprint);
    }

    private protected override WriteOutcome Execute(WritePlan plan)
    {
        var now = Now;
        var backup = Store.AddBackup("import", now, int.MaxValue, 0, "Avant-reprise");
        var taken = Store.ImportLegacy(now);
        return taken > 0
            ? new WriteOutcome(WriteResult.Applied, "Sauvegarde de migration " + backup.FileName + " vérifiée, puis " + FrenchText.Count(taken, "élément repris", "éléments repris") + " ; fichiers de Domenia 1 laissés en place." + NoEffect)
            : new WriteOutcome(WriteResult.NoChange, "Données de Domenia 1 déjà reprises" + FrenchText.Colon + "rien de nouveau.");
    }

    private protected override WriteVerification Verify(WritePlan plan, LocalStoreSnapshot store)
    {
        var planned = plan.Changes.Where(c => c.Attribute.StartsWith("legacy.", StringComparison.Ordinal)).Select(c => c.Attribute["legacy.".Length..]).ToHashSet(StringComparer.Ordinal);
        var missing = store.Legacy.Items.Where(i => planned.Contains(i.Id) && !i.Imported).Select(i => i.Label).ToList();
        return missing.Count == 0
            ? new WriteVerification(VerificationState.Verified, "Base relue" + FrenchText.Colon + "les éléments du plan sont repris ; une nouvelle simulation ne trouverait rien à reprendre.")
            : new WriteVerification(VerificationState.Mismatch, "Éléments non repris à la relecture" + FrenchText.Colon + string.Join(", ", missing) + ".");
    }
}
