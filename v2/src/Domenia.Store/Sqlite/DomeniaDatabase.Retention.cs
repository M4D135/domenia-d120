using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private const string RetentionStateAttribute = "local.retentionState";
    private sealed record RetentionProof(string PlanId, string PlanFingerprint, string StoreId, string DomainDn,
        long Revision, long Removed, string AfterFingerprint, DatabaseBackup Backup);

    public async Task<WritePlanDraft> PrepareStorageRetentionAsync(StoragePolicy policy, string previewFingerprint, CancellationToken cancellationToken)
    {
        if (StoragePolicyRules.Problem(policy) is { } problem) { throw new ArgumentException(problem, nameof(policy)); }
        var store = await InspectLocalStoreAsync(false, false, cancellationToken).ConfigureAwait(false);
        StorageWritePlans.EnsureWritable(store);
        return await Task.Run(() =>
        {
            CompatibleDirectoryCache.ValidateLocalPath(Path);
            using var db = new SqliteDatabase(Path, true, cancellationToken: cancellationToken);
            db.Begin(false); CheckIdentity(db, true);
            var inventory = ReadRetentionInventory(db, cancellationToken);
            var now = WritePlans.TruncateToSecond(clock.GetUtcNow());
            store = store with { Revision = inventory.Revision, Families = RetentionFamilies(inventory, now) };
            var preview = StoragePolicyRules.Preview(policy, store, now, clock.LocalTimeZone);
            var draft = StorageWritePlans.RetentionDraft(store, preview, previewFingerprint, clock.LocalTimeZone);
            db.Commit();
            return draft with { Changes = draft.Changes.Add(new(RetentionStateAttribute, "Empreinte des mesures relues", WriteChangeKind.Replace,
                inventory.Fingerprint, "Même inventaire avant suppression", inventory.Fingerprint, null)) };
        }, cancellationToken).ConfigureAwait(false);
    }

    public Task<WritePrecheck> CheckStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken) => Task.Run(() =>
    {
        ValidateRetentionPlan(plan, true);
        if (!File.Exists(Path)) { return WritePrecheck.Stale("Base absente ; aucune création pour la conservation."); }
        using var db = new SqliteDatabase(Path, true, cancellationToken: cancellationToken);
        db.Begin(false); CheckIdentity(db, true);
        if (ReadRetentionProof(db, plan) is not null) { return WritePrecheck.Stale("Conservation déjà envoyée ; relisez son reçu sans la rejouer."); }
        var current = ReadRetentionInventory(db, cancellationToken);
        return MatchesRetentionPlan(plan, current) ? WritePrecheck.Valid("Révision et contenu exact des mesures relus.")
            : WritePrecheck.Stale("Mesures modifiées depuis le plan ; refaites la prévisualisation.");
    }, cancellationToken);

    public async Task<WriteOutcome> ApplyStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ValidateRetentionPlan(plan, true);
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await Task.Run(() => ExecuteStorageRetention(plan, cancellationToken), cancellationToken).ConfigureAwait(false); }
        finally { writer.Release(); }
    }

    private WriteOutcome ExecuteStorageRetention(WritePlan plan, CancellationToken token)
    {
        ValidateRetentionPlan(plan, true); CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { throw WriteErrors.Refusal(WriteErrors.Stale, "Base absente ; aucune création pour la conservation."); }
        using (var read = new SqliteDatabase(Path, true, cancellationToken: token))
        {
            read.Begin(false); CheckIdentity(read, true);
            if (ReadRetentionProof(read, plan) is not null) { return new(WriteResult.NoChange, "Conservation déjà validée ; aucun rejeu."); }
            if (!MatchesRetentionPlan(plan, ReadRetentionInventory(read, token))) { throw WriteErrors.Refusal(WriteErrors.Stale, "Mesures modifiées depuis le plan."); }
        }
        _ = Initialize(token);
        using var db = new SqliteDatabase(Path, false, cancellationToken: token);
        CheckIdentity(db, false);
        var backup = lastBackup = Backup(db, token);
        db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, false);
        if (ReadRetentionProof(db, plan) is not null) { return new(WriteResult.NoChange, "Conservation déjà validée ; aucun rejeu."); }
        var before = ReadRetentionInventory(db, token);
        if (!MatchesRetentionPlan(plan, before)) { throw WriteErrors.Refusal(WriteErrors.Stale, "Mesures modifiées pendant la confirmation ; aucune suppression."); }
        using (var copy = new SqliteDatabase(backup.Path, true, cancellationToken: token))
        {
            CheckIdentity(copy, true);
            if (ReadRetentionInventory(copy, token).Fingerprint != before.Fingerprint)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "La sauvegarde ne correspond plus aux mesures ; aucune suppression."); }
        }
        if ((long)db.Scalar("SELECT count(*) FROM sqlite_master WHERE type='trigger';")! != 0)
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Déclencheur SQLite non qualifié ; aucune suppression."); }
        var selected = RetentionSelection(plan, before);
        foreach (var entry in selected.Where(x => x.Table != "fleet"))
        {
            token.ThrowIfCancellationRequested();
            if (entry.Table is not ("domenia_observations" or "domenia_details" or "user_machine_history")
                || db.Execute("DELETE FROM " + entry.Table + " WHERE rowid=?1;", entry.RowId) != 1)
            { throw new InvalidDataException("Identité de mesure incohérente ; transaction annulée."); }
        }
        var nativeKeys = selected.Where(x => x.Table == "fleet").Select(x => x.Key).ToHashSet(StringComparer.Ordinal);
        if (nativeKeys.Count > 0)
        {
            var changed = StorageFleetRetention.Transform(before.Fleet, (key, _, _) => nativeKeys.Contains(key));
            if (db.Execute("UPDATE domenia_v2_metadata SET payload=?1 WHERE key='fleet';", JsonSerializer.Serialize(changed, Json)) != 1)
            { throw new InvalidDataException("Relevés natifs absents ; transaction annulée."); }
        }
        var revision = checked(before.Revision + 1);
        db.Execute("UPDATE domenia_store_state SET revision=?1 WHERE id=1;", revision);
        var after = ReadRetentionInventory(db, token);
        var removedKeys = selected.Select(x => x.Key).ToHashSet(StringComparer.Ordinal);
        if (after.Revision != revision || after.Entries.Any(x => removedKeys.Contains(x.Key) && (x.Table != "fleet" || x.At is not null)))
        { throw new InvalidDataException("Relecture de la conservation incohérente ; transaction annulée."); }
        var proof = new RetentionProof(plan.Id, plan.Fingerprint, StoreId, DomainDn, revision, selected.Length, after.Fingerprint, backup);
        SaveRetentionProof(db, proof);
        if (ReadRetentionProof(db, plan) != proof) { throw new InvalidDataException("Reçu de conservation incohérent avant commit."); }
        db.Commit();
        using var reread = new SqliteDatabase(Path, true, cancellationToken: token);
        CheckIdentity(reread, false);
        if (ReadRetentionProof(reread, plan) != proof) { throw new InvalidDataException("Preuve de conservation absente après commit."); }
        return new(WriteResult.Applied, selected.Length.ToString(CultureInfo.InvariantCulture) + " mesures retirées et relues ; sauvegarde SHA-256 " + backup.Sha256 + ".");
    }

    public Task<WriteVerification> VerifyStorageRetentionAsync(WritePlan plan, CancellationToken cancellationToken) => Task.Run(() =>
    {
        ValidateRetentionPlan(plan, false);
        if (!File.Exists(Path)) { return new WriteVerification(VerificationState.Unknown, "Base absente ; preuve de conservation inaccessible."); }
        using var db = new SqliteDatabase(Path, true, cancellationToken: cancellationToken);
        db.Begin(false); CheckIdentity(db, true);
        var proof = ReadRetentionProof(db, plan);
        if (proof is null) { return new WriteVerification(VerificationState.Unknown, "Aucune preuve de conservation validée ; aucun rejeu automatique."); }
        var current = ReadRetentionInventory(db, cancellationToken);
        if (!File.Exists(proof.Backup.Path) || BackupFileHash(proof.Backup.Path) != proof.Backup.Sha256)
        { return new WriteVerification(VerificationState.Mismatch, "Conservation enregistrée mais sauvegarde absente ou altérée."); }
        return current.Revision == proof.Revision && current.Fingerprint == proof.AfterFingerprint
            ? new WriteVerification(VerificationState.Verified, "Mesures retirées, révision et sauvegarde relues ; reçu durable conforme.")
            : new WriteVerification(VerificationState.Mismatch, "Conservation enregistrée ; la base a changé depuis son reçu, état courant différent.");
    }, cancellationToken);

    private void ValidateRetentionPlan(WritePlan plan, bool current)
    {
        if (plan.Kind != StorageWritePlans.Retention || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText || !WritePlans.IsPlanId(plan.Id)
            || !WritePlans.IsIntact(plan) || plan.Target.Kind != StorageWritePlans.TargetKind || plan.Target.Dn != Path
            || plan.Target.ObjectGuid != StorageWritePlans.StoreGuid(StoreId) || current && plan.ExpiresAt <= clock.GetUtcNow())
        { throw new InvalidDataException("Plan de conservation invalide, expiré ou d’une autre base."); }
        var anchor = plan.Changes.SingleOrDefault(x => x.Attribute == RetentionStateAttribute)?.BeforeValue;
        var revision = plan.Changes.SingleOrDefault(x => x.Attribute == "revision");
        var rows = StorageWritePlans.PlannedRows(plan, "retention.");
        if (anchor is null || anchor.Length != 64 || anchor.Any(c => !char.IsAsciiHexDigit(c)) || revision is null
            || !long.TryParse(revision.BeforeValue, NumberStyles.None, CultureInfo.InvariantCulture, out var before) || before == long.MaxValue
            || revision.AfterValue != (before + 1).ToString(CultureInfo.InvariantCulture) || rows.IsEmpty
            || rows.Select(x => x.Id).Distinct(StringComparer.Ordinal).Count() != rows.Length
            || rows.Any(x => x.Rows <= 0 || x.Cutoff is null || !StoragePolicyRules.Families.Any(f => f.Family == x.Id)))
        { throw new InvalidDataException("Identités ou quantités de conservation invalides."); }
    }
    private static bool MatchesRetentionPlan(WritePlan plan, RetentionInventory current) => current.Revision.ToString(CultureInfo.InvariantCulture) == plan.Changes.Single(x => x.Attribute == "revision").BeforeValue
        && current.Fingerprint == plan.Changes.Single(x => x.Attribute == RetentionStateAttribute).BeforeValue;
    private static ImmutableArray<RetentionEntry> RetentionSelection(WritePlan plan, RetentionInventory inventory)
    {
        var selected = ImmutableArray.CreateBuilder<RetentionEntry>();
        foreach (var row in StorageWritePlans.PlannedRows(plan, "retention."))
        {
            var matches = inventory.Entries.Where(x => x.Family == row.Id && x.At is not null && x.At <= row.Cutoff && (row.Id != "linkHistory" || x.Repeated)).ToArray();
            if (matches.LongLength != row.Rows) { throw WriteErrors.Refusal(WriteErrors.Stale, "Quantité de mesures différente de l’aperçu ; aucune suppression."); }
            selected.AddRange(matches);
        }
        return selected.ToImmutable();
    }
    private static void SaveRetentionProof(SqliteDatabase db, RetentionProof proof)
    {
        db.Script("CREATE TABLE IF NOT EXISTS domenia_v2_retention_receipts(plan_id TEXT PRIMARY KEY,sha256 TEXT NOT NULL,payload TEXT NOT NULL);");
        var payload = JsonSerializer.Serialize(proof, Json);
        db.Execute("INSERT INTO domenia_v2_retention_receipts(plan_id,sha256,payload) VALUES(?1,?2,?3);", proof.PlanId, BackupPreferencesRules.Sha256(payload), payload);
    }
    private RetentionProof? ReadRetentionProof(SqliteDatabase db, WritePlan plan)
    {
        if (!Table(db, "domenia_v2_retention_receipts")) { return null; }
        var row = db.Query("SELECT sha256,CASE WHEN length(payload)<=16384 THEN payload ELSE NULL END AS payload FROM domenia_v2_retention_receipts WHERE plan_id=?1;", plan.Id).SingleOrDefault();
        if (row is null) { return null; }
        var payload = row["payload"] as string ?? throw new InvalidDataException("Reçu de conservation trop volumineux.");
        if (BackupPreferencesRules.Sha256(payload) != row["sha256"] as string) { throw new InvalidDataException("Reçu de conservation altéré."); }
        var proof = JsonSerializer.Deserialize<RetentionProof>(payload, Json) ?? throw new InvalidDataException("Reçu de conservation illisible.");
        if (proof.PlanId != plan.Id || proof.PlanFingerprint != plan.Fingerprint || proof.StoreId != StoreId || proof.DomainDn != DomainDn
            || proof.Revision < 1 || proof.Removed < 1 || proof.Backup.Sha256.Length != 64 || proof.AfterFingerprint.Length != 64
            || System.IO.Path.GetDirectoryName(proof.Backup.Path) != BackupFolder)
        { throw new InvalidDataException("Preuve de conservation d’une autre base ou incohérente."); }
        return proof;
    }
}
