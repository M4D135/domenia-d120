using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private sealed record SyncCommitProof(string PlanFingerprint, string StoreId, string DomainDn, long Revision,
        string AfterSha256, string BackupSha256, SyncStorageReceipt Receipt);

    /// <summary>Reads the durable proof without requiring the in-memory batch, even after the plan expires or the process restarts.</summary>
    public Task<WriteVerification> VerifySyncChangeAsync(WritePlan plan, CancellationToken cancellationToken) => Task.Run(() =>
    {
        if (plan.Kind != SyncStoreChange.Kind || plan.Simulated || plan.Mode != AppInfoBuilder.DirectoryModeText || !WritePlans.IsIntact(plan)
            || plan.Target.Dn != SyncLocalIdentity.Target(StoreId, DomainDn) || plan.Target.ObjectGuid != SyncStoreChange.IndexStoreGuid.ToString("D"))
        { throw new InvalidDataException("Reçu présenté pour une autre base ou un autre plan."); }
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return new WriteVerification(VerificationState.Unknown, "Base introuvable ; aucune création ni nouvelle écriture."); }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
        db.Begin(write: false); CheckIdentity(db, allowLegacy: true);
        var proof = ReadSyncProof(db, plan);
        if (proof is null) { db.Commit(); return new WriteVerification(VerificationState.Unknown, "Aucune preuve durable de ce plan ; aucun rejeu automatique."); }
        var state = ReadSyncState(db);
        var matches = state.Revision == proof.Revision && SyncLocalIdentity.Fingerprint(state) == proof.AfterSha256;
        db.Commit();
        return matches
            ? new WriteVerification(VerificationState.Verified, "Transaction et reçu relus dans la base ; état conforme au plan. Sauvegarde SHA-256 " + proof.BackupSha256 + ".")
            : new WriteVerification(VerificationState.Mismatch, "Le reçu atteste la transaction passée, mais la base a changé depuis. Aucun rejeu ni effacement supplémentaire.");
    }, cancellationToken);

    private void SaveSyncProof(SqliteDatabase db, WritePlan plan, SyncStorageReceipt receipt, string after, long revision, string backup)
    {
        var proof = new SyncCommitProof(plan.Fingerprint, StoreId, DomainDn, revision, after, backup, receipt);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(proof, Json);
        db.Script("CREATE TABLE IF NOT EXISTS domenia_v2_sync_proofs(plan_id TEXT PRIMARY KEY,sha256 TEXT NOT NULL,payload TEXT NOT NULL);");
        db.Execute("INSERT INTO domenia_v2_sync_proofs(plan_id,sha256,payload) VALUES(?1,?2,?3);", plan.Id,
            Convert.ToHexStringLower(SHA256.HashData(bytes)), System.Text.Encoding.UTF8.GetString(bytes));
        if (ReadSyncProof(db, plan) != proof) { throw new InvalidDataException("Preuve de transaction incohérente avant commit."); }
    }

    private SyncCommitProof? ReadSyncProof(SqliteDatabase db, WritePlan plan)
    {
        if (!Table(db, "domenia_v2_sync_proofs")) { return null; }
        var row = db.Query("SELECT sha256,CASE WHEN length(payload)<=32768 THEN payload ELSE NULL END AS payload FROM domenia_v2_sync_proofs WHERE plan_id=?1;", plan.Id).SingleOrDefault();
        if (row is null) { return null; }
        var payload = row["payload"] as string ?? throw new InvalidDataException("Preuve locale trop volumineuse.");
        if (row["sha256"] as string != Convert.ToHexStringLower(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(payload))))
        { throw new InvalidDataException("Empreinte de la preuve locale invalide ; aucun résultat certifié."); }
        var proof = JsonSerializer.Deserialize<SyncCommitProof>(payload, Json) ?? throw new InvalidDataException("Preuve locale illisible.");
        if (proof.PlanFingerprint != plan.Fingerprint || proof.StoreId != StoreId || proof.DomainDn != DomainDn || proof.Revision < 1
            || proof.AfterSha256.Length != 64 || proof.BackupSha256.Length != 64 || proof.Receipt.BatchId != plan.Id || !proof.Receipt.Verified
            || SyncReceipt(db, plan.Id, proof.Receipt.Sha256) != proof.Receipt)
        { throw new InvalidDataException("Preuve locale incompatible avec le plan ou son reçu."); }
        return proof;
    }
}
