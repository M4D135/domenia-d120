using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private const string PurgeStateAttribute = "local.purgeState";
    private sealed record PurgeProof(string PlanId, string PlanFingerprint, string StoreId, string DomainDn,
        long Revision, long Removed, string AfterFingerprint, DatabaseBackup Backup);

    public async Task<WritePlanDraft> PrepareStoragePurgeAsync(IReadOnlyCollection<string> categories, int historyDays, string previewFingerprint, CancellationToken cancellationToken)
    {
        if (historyDays is < 1 or > StoragePolicyRules.MaxRetentionDays || categories.Count is < 1 or > 8)
        { throw new ArgumentException("Catégories ou âge de purge invalides."); }
        var store = await InspectLocalStoreAsync(false, false, cancellationToken).ConfigureAwait(false);
        StorageWritePlans.EnsureWritable(store);
        return await Task.Run(() =>
        {
            CompatibleDirectoryCache.ValidateLocalPath(Path);
            using var db = new SqliteDatabase(Path, true, cancellationToken: cancellationToken);
            db.Begin(false); CheckIdentity(db, true);
            var inventory = ReadPurgeInventory(db, cancellationToken);
            var now = WritePlans.TruncateToSecond(clock.GetUtcNow());
            store = store with { Revision = inventory.Revision, NativePurgeTargets = PurgeTargets(inventory, now) };
            var preview = LocalStoreRules.PurgePlan(store, categories, historyDays, now, clock.LocalTimeZone);
            var draft = StorageWritePlans.PurgeDraft(store, preview, previewFingerprint, clock.LocalTimeZone);
            db.Commit();
            return draft with { Changes = draft.Changes.Add(new(PurgeStateAttribute, "Empreinte des données relues", WriteChangeKind.Replace,
                inventory.Fingerprint, "Même inventaire avant purge", inventory.Fingerprint, null)) };
        }, cancellationToken).ConfigureAwait(false);
    }

    public Task<WritePrecheck> CheckStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken) => Task.Run(() =>
    {
        ValidatePurgePlan(plan, true);
        if (!File.Exists(Path)) { return WritePrecheck.Stale("Base absente ; aucune création pour la purge."); }
        using var db = new SqliteDatabase(Path, true, cancellationToken: cancellationToken);
        db.Begin(false); CheckIdentity(db, true);
        if (ReadPurgeProof(db, plan) is not null) { return WritePrecheck.Stale("Purge déjà envoyée ; relisez son reçu sans la rejouer."); }
        var current = ReadPurgeInventory(db, cancellationToken);
        return MatchesPurgePlan(plan, current) ? WritePrecheck.Valid("Révision et contenu exact des données relus.")
            : WritePrecheck.Stale("Données modifiées depuis le plan ; refaites la simulation.");
    }, cancellationToken);

    public async Task<WriteOutcome> ApplyStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ValidatePurgePlan(plan, true);
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await Task.Run(() => ExecuteStoragePurge(plan, cancellationToken), cancellationToken).ConfigureAwait(false); }
        finally { writer.Release(); }
    }

    private WriteOutcome ExecuteStoragePurge(WritePlan plan, CancellationToken token)
    {
        ValidatePurgePlan(plan, true); CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { throw WriteErrors.Refusal(WriteErrors.Stale, "Base absente ; aucune création pour la purge."); }
        using (var read = new SqliteDatabase(Path, true, cancellationToken: token))
        {
            read.Begin(false); CheckIdentity(read, true);
            if (ReadPurgeProof(read, plan) is not null) { return new(WriteResult.NoChange, "Purge déjà validée ; aucun rejeu."); }
            if (!MatchesPurgePlan(plan, ReadPurgeInventory(read, token))) { throw WriteErrors.Refusal(WriteErrors.Stale, "Données modifiées depuis le plan."); }
        }
        _ = Initialize(token);
        using var db = new SqliteDatabase(Path, false, cancellationToken: token);
        CheckIdentity(db, false);
        var backup = lastBackup = Backup(db, token);
        db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, false);
        if (ReadPurgeProof(db, plan) is not null) { return new(WriteResult.NoChange, "Purge déjà validée ; aucun rejeu."); }
        var before = ReadPurgeInventory(db, token);
        if (!MatchesPurgePlan(plan, before)) { throw WriteErrors.Refusal(WriteErrors.Stale, "Données modifiées pendant la confirmation ; aucune purge."); }
        using (var copy = new SqliteDatabase(backup.Path, true, cancellationToken: token))
        {
            CheckIdentity(copy, true);
            if (ReadPurgeInventory(copy, token).Fingerprint != before.Fingerprint)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "La sauvegarde ne correspond plus à la base ; aucune purge."); }
        }
        if ((long)db.Scalar("SELECT count(*) FROM sqlite_master WHERE type='trigger';")! != 0)
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Déclencheur SQLite non qualifié ; aucune purge."); }
        var selected = PurgeSelection(plan, before);
        foreach (var entry in selected.Where(x => x.Action != "clear"))
        {
            token.ThrowIfCancellationRequested();
            if (!NativePurgeTables.Any(x => x.Table == entry.Table && x.Action == entry.Action)) { throw new InvalidDataException("Table de purge inconnue."); }
            var table = entry.Table.Split('.')[0];
            var affected = entry.Action == "reset"
                ? db.Execute("UPDATE sync_state SET highest_usn=0,last_sync=NULL,item_count=0,details=NULL WHERE rowid=?1;", entry.RowId)
                : db.Execute("DELETE FROM " + table + " WHERE rowid=?1;", entry.RowId);
            if (affected != 1) { throw new InvalidDataException("Identité de donnée incohérente ; transaction annulée."); }
        }
        var purgeObservations = StorageWritePlans.PlannedRows(plan, "purge.").Any(x => x.Id == "observations");
        var purgeIndex = StorageWritePlans.PlannedRows(plan, "purge.").Any(x => x.Id == "index");
        if (selected.Any(x => x.Action == "clear"))
        {
            var changed = before.Fleet;
            if (purgeObservations)
            {
                changed = CachedFleet.Empty(StoreId) with
                {
                    Facts = AccueilFacts.Empty(StoreId) with { Associations = changed.Facts.Associations, BitLocker = changed.Facts.BitLocker,
                        Runs = [.. changed.Facts.Runs.Where(x => x.Family == CollectionFamily.Directory)] },
                    WorkstationSecrets = changed.WorkstationSecrets,
                };
            }
            if (purgeIndex) { changed = changed with { Facts = changed.Facts with { Runs = [.. changed.Facts.Runs.Where(x => x.Family != CollectionFamily.Directory)] } }; }
            if (db.Execute("UPDATE domenia_v2_metadata SET payload=?1 WHERE key='fleet';", JsonSerializer.Serialize(changed, Json)) != 1)
            { throw new InvalidDataException("Cache natif absent ; transaction annulée."); }
        }
        if (purgeObservations)
        {
            EnsureSweepLedger(db);
            db.Execute("UPDATE domenia_v2_sweep_state SET generation=?1 WHERE id=1;", checked(before.SweepGeneration + 1));
        }
        var revision = checked(before.Revision + 1);
        db.Execute("UPDATE domenia_store_state SET revision=?1 WHERE id=1;", revision);
        var after = ReadPurgeInventory(db, token);
        var gone = selected.Where(x => x.Action != "reset").Select(x => x.Key).ToHashSet(StringComparer.Ordinal);
        if (after.Revision != revision || after.Entries.Any(x => gone.Contains(x.Key)))
        { throw new InvalidDataException("Relecture des données purgées incohérente ; transaction annulée."); }
        foreach (var reset in selected.Where(x => x.Action == "reset"))
        {
            if ((long)db.Scalar("SELECT count(*) FROM sync_state WHERE rowid=?1 AND highest_usn=0 AND last_sync IS NULL AND item_count=0 AND details IS NULL;", reset.RowId)! != 1)
            { throw new InvalidDataException("Point de reprise non réinitialisé ; transaction annulée."); }
        }
        var removed = selected.LongCount(x => x.Action != "reset");
        var proof = new PurgeProof(plan.Id, plan.Fingerprint, StoreId, DomainDn, revision, removed, after.Fingerprint, backup);
        SavePurgeProof(db, proof);
        if (ReadPurgeProof(db, plan) != proof) { throw new InvalidDataException("Reçu de purge incohérent avant commit."); }
        db.Commit();
        using var reread = new SqliteDatabase(Path, true, cancellationToken: token);
        CheckIdentity(reread, false);
        if (ReadPurgeProof(reread, plan) != proof) { throw new InvalidDataException("Preuve de purge absente après commit."); }
        return new(WriteResult.Applied, removed.ToString(CultureInfo.InvariantCulture) + " lignes purgées et relues ; sauvegarde SHA-256 " + backup.Sha256 + ".");
    }

    public Task<WriteVerification> VerifyStoragePurgeAsync(WritePlan plan, CancellationToken cancellationToken) => Task.Run(() =>
    {
        ValidatePurgePlan(plan, false);
        if (!File.Exists(Path)) { return new WriteVerification(VerificationState.Unknown, "Base absente ; preuve de purge inaccessible."); }
        using var db = new SqliteDatabase(Path, true, cancellationToken: cancellationToken);
        db.Begin(false); CheckIdentity(db, true);
        var proof = ReadPurgeProof(db, plan);
        if (proof is null) { return new WriteVerification(VerificationState.Unknown, "Aucune preuve de purge validée ; aucun rejeu automatique."); }
        var current = ReadPurgeInventory(db, cancellationToken);
        if (!File.Exists(proof.Backup.Path) || BackupFileHash(proof.Backup.Path) != proof.Backup.Sha256)
        { return new WriteVerification(VerificationState.Mismatch, "Purge enregistrée mais sauvegarde absente ou altérée."); }
        return current.Revision == proof.Revision && current.Fingerprint == proof.AfterFingerprint
            ? new WriteVerification(VerificationState.Verified, "Catégories purgées, points de reprise et sauvegarde relus ; reçu durable conforme.")
            : new WriteVerification(VerificationState.Mismatch, "Purge enregistrée ; la base a changé depuis son reçu, état courant différent.");
    }, cancellationToken);

    private void ValidatePurgePlan(WritePlan plan, bool current)
    {
        if (plan.Kind != StorageWritePlans.Purge || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText || !WritePlans.IsPlanId(plan.Id)
            || !WritePlans.IsIntact(plan) || plan.Target.Kind != StorageWritePlans.TargetKind || plan.Target.Dn != Path
            || plan.Target.ObjectGuid != StorageWritePlans.StoreGuid(StoreId) || current && plan.ExpiresAt <= clock.GetUtcNow()
            || !plan.Confirmation.TypedNameRequired || plan.Confirmation.TypedName != DomainDn)
        { throw new InvalidDataException("Plan de purge invalide, expiré ou d’une autre base."); }
        var anchor = plan.Changes.SingleOrDefault(x => x.Attribute == PurgeStateAttribute)?.BeforeValue;
        var revision = plan.Changes.SingleOrDefault(x => x.Attribute == "revision");
        var rows = StorageWritePlans.PlannedRows(plan, "purge.");
        if (anchor is null || anchor.Length != 64 || anchor.Any(c => !char.IsAsciiHexDigit(c)) || revision is null
            || !long.TryParse(revision.BeforeValue, NumberStyles.None, CultureInfo.InvariantCulture, out var before) || before == long.MaxValue
            || revision.AfterValue != (before + 1).ToString(CultureInfo.InvariantCulture) || rows.IsEmpty
            || rows.Select(x => x.Id).Distinct(StringComparer.Ordinal).Count() != rows.Length || rows.Sum(x => x.Rows) <= 0
            || rows.Any(x => x.Rows < 0 || (x.Id == "history") != (x.Cutoff is not null) || x.Cutoff >= clock.GetUtcNow()
                || !NativePurgeTables.Any(t => t.Category == x.Id)))
        { throw new InvalidDataException("Catégories ou quantités de purge invalides."); }
    }
    private static bool MatchesPurgePlan(WritePlan plan, PurgeInventory current) => current.Revision.ToString(CultureInfo.InvariantCulture) == plan.Changes.Single(x => x.Attribute == "revision").BeforeValue
        && current.Fingerprint == plan.Changes.Single(x => x.Attribute == PurgeStateAttribute).BeforeValue;
    private static ImmutableArray<PurgeEntry> PurgeSelection(WritePlan plan, PurgeInventory inventory)
    {
        var selected = ImmutableArray.CreateBuilder<PurgeEntry>();
        foreach (var row in StorageWritePlans.PlannedRows(plan, "purge."))
        {
            var matches = inventory.Entries.Where(x => x.Category == row.Id && (row.Id != "history" || x.At is not null && x.At <= row.Cutoff)).ToArray();
            if (matches.LongCount(x => x.Action != "reset") != row.Rows) { throw WriteErrors.Refusal(WriteErrors.Stale, "Quantités différentes de la simulation ; aucune purge."); }
            selected.AddRange(matches);
        }
        return selected.ToImmutable();
    }
    private static void SavePurgeProof(SqliteDatabase db, PurgeProof proof)
    {
        db.Script("CREATE TABLE IF NOT EXISTS domenia_v2_purge_receipts(plan_id TEXT PRIMARY KEY,sha256 TEXT NOT NULL,payload TEXT NOT NULL);");
        var payload = JsonSerializer.Serialize(proof, Json);
        db.Execute("INSERT INTO domenia_v2_purge_receipts(plan_id,sha256,payload) VALUES(?1,?2,?3);", proof.PlanId, BackupPreferencesRules.Sha256(payload), payload);
    }
    private PurgeProof? ReadPurgeProof(SqliteDatabase db, WritePlan plan)
    {
        if (!Table(db, "domenia_v2_purge_receipts")) { return null; }
        var row = db.Query("SELECT sha256,CASE WHEN length(payload)<=16384 THEN payload ELSE NULL END AS payload FROM domenia_v2_purge_receipts WHERE plan_id=?1;", plan.Id).SingleOrDefault();
        if (row is null) { return null; }
        var payload = row["payload"] as string ?? throw new InvalidDataException("Reçu de purge trop volumineux.");
        if (BackupPreferencesRules.Sha256(payload) != row["sha256"] as string) { throw new InvalidDataException("Reçu de purge altéré."); }
        var proof = JsonSerializer.Deserialize<PurgeProof>(payload, Json) ?? throw new InvalidDataException("Reçu de purge illisible.");
        if (proof.PlanId != plan.Id || proof.PlanFingerprint != plan.Fingerprint || proof.StoreId != StoreId || proof.DomainDn != DomainDn
            || proof.Revision < 1 || proof.Removed < 1 || proof.Backup.Sha256.Length != 64 || proof.AfterFingerprint.Length != 64
            || System.IO.Path.GetDirectoryName(proof.Backup.Path) != BackupFolder)
        { throw new InvalidDataException("Preuve de purge d’une autre base ou incohérente."); }
        return proof;
    }
}
