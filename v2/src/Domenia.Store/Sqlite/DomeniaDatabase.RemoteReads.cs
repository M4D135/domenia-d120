using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private const string RemoteReads = "domenia_v2_remote_reads";
    private static string RemoteHash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    private async Task<RemoteTaskReadRecord> PrepareTaskReadCoreAsync(RemoteTaskReadPlan plan, CancellationToken token)
    {
        RemoteTaskReadRules.Validate(plan, clock.GetUtcNow());
        if (plan.StoreId != StoreId || !InDomain(plan.ComputerDn)) { throw new InvalidDataException("Plan d’une autre base ou d’un autre domaine."); }
        await writer.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady(); CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = new SqliteDatabase(Path, false, cancellationToken: token); CheckIdentity(db, false);
                if (!Table(db, RemoteReads)) { lastBackup = Backup(db, token); } else { EnsureBackup(db, token); }
                db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, false);
                var payload = JsonSerializer.Serialize(plan, Json); var hash = RemoteHash(payload);
                if (ReadTaskRead(db, plan.Id) is { } old)
                {
                    if (RemoteHash(JsonSerializer.Serialize(old.Plan, Json)) != hash) { throw new InvalidDataException("Identifiant de lecture déjà lié à un autre plan."); }
                    db.Commit(); return old;
                }
                var objectPayload = db.Scalar("SELECT CASE WHEN length(CAST(payload AS BLOB))<=1048576 THEN payload ELSE NULL END FROM domenia_v2_objects WHERE kind='computer' AND object_guid=?1;", plan.ComputerGuid.ToString("D")) as string;
                var computer = objectPayload is null ? null : JsonSerializer.Deserialize<DirectoryComputer>(objectPayload, Json);
                if (computer is null || computer.ObjectGuid != plan.ComputerGuid || !DistinguishedName.AreEqual(computer.DistinguishedName, plan.ComputerDn)
                    || computer.WhenCreated != plan.ComputerCreated || !string.Equals(computer.DnsHostName, plan.Host, StringComparison.OrdinalIgnoreCase)
                    || WorkstationIdentity.ExpectedName(computer) is null || (computer.UserAccountControl & AdValues.ServerTrustAccount) != 0)
                { throw new InvalidDataException("Poste absent, recréé, renommé ou contrôleur de domaine ; aucun artefact autorisé par ce plan."); }
                EnsureRemoteReads(db);
                if ((long)db.Scalar("SELECT count(*) FROM " + RemoteReads + " WHERE pending=1;")! >= RemoteTaskReadRules.MaximumPending
                    || (long)db.Scalar("SELECT count(*) FROM " + RemoteReads + " WHERE pending=1 AND (computer_guid=?1 OR host=?2 COLLATE NOCASE);", plan.ComputerGuid.ToString("D"), plan.Host)! != 0)
                { throw new InvalidDataException("Une lecture distante doit encore être vérifiée ou nettoyée ; aucune nouvelle tâche pour ce poste."); }
                var changes = (long)db.Scalar("SELECT total_changes();")!;
                db.Execute("INSERT INTO " + RemoteReads + "(id,computer_guid,host,plan,plan_hash,pending,completion,completion_hash,revision) VALUES(?1,?2,?3,?4,?5,1,NULL,NULL,1);",
                    plan.Id.ToString("N"), plan.ComputerGuid.ToString("D"), plan.Host, payload, hash);
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                var saved = ReadTaskRead(db, plan.Id) ?? throw new InvalidDataException("Préparation non relue.");
                if (saved.Plan != plan || saved.Revision != 1 || saved.Completion is not null || (long)db.Scalar("SELECT total_changes();")! != changes + 2)
                { throw new InvalidDataException("Préparation modifiée pendant son enregistrement."); }
                db.Commit(); return ReadTaskRead(db, plan.Id) ?? throw new InvalidDataException("Préparation non confirmée après validation locale.");
            }, token).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private async Task<RemoteTaskReadRecord> CompleteTaskReadCoreAsync(Guid id, long expectedRevision, RemoteTaskReadCompletion completion, CancellationToken token)
    {
        if (id == Guid.Empty || expectedRevision < 1) { throw new ArgumentException("Identité du reçu invalide."); }
        await writer.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady(); CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = new SqliteDatabase(Path, false, cancellationToken: token); CheckIdentity(db, false); EnsureBackup(db, token);
                db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, false);
                var old = ReadTaskRead(db, id) ?? throw new InvalidDataException("Lecture distante non préparée ; reçu sans autorité.");
                if (old.Plan.StoreId != StoreId) { throw new InvalidDataException("Reçu historique d’un autre emplacement ; aucune écriture ou reprise autorisée."); }
                if (old.Completion == completion) { db.Commit(); return old; }
                if (old.Revision != expectedRevision || old.Revision == long.MaxValue || !old.CleanupRequired)
                { throw new InvalidDataException("Reçu périmé ou lecture déjà nettoyée ; état conservé."); }
                RemoteTaskReadRules.Validate(old, completion, clock.GetUtcNow());
                var json = JsonSerializer.Serialize(completion, Json);
                var changes = (long)db.Scalar("SELECT total_changes();")!;
                db.Execute("UPDATE " + RemoteReads + " SET completion=?1,completion_hash=?2,pending=?3,revision=revision+1 WHERE id=?4 AND revision=?5;",
                    json, RemoteHash(json), completion.ExecutionStopped && completion.ArtifactsRemoved ? 0 : 1, id.ToString("N"), expectedRevision);
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                var saved = ReadTaskRead(db, id) ?? throw new InvalidDataException("Reçu non relu.");
                if (saved.Completion != completion || saved.Revision != expectedRevision + 1 || saved.Plan != old.Plan || (long)db.Scalar("SELECT total_changes();")! != changes + 2)
                { throw new InvalidDataException("Reçu modifié pendant son enregistrement."); }
                db.Commit(); return ReadTaskRead(db, id) ?? throw new InvalidDataException("Reçu non confirmé après validation locale.");
            }, token).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private static void EnsureRemoteReads(SqliteDatabase db) => db.Script("CREATE TABLE IF NOT EXISTS " + RemoteReads
        + "(id TEXT PRIMARY KEY NOT NULL,computer_guid TEXT NOT NULL,host TEXT NOT NULL,plan TEXT NOT NULL,plan_hash TEXT NOT NULL,pending INTEGER NOT NULL CHECK(pending IN (0,1)),completion TEXT,completion_hash TEXT,revision INTEGER NOT NULL CHECK(revision>0));"
        + "CREATE INDEX IF NOT EXISTS ix_domenia_v2_remote_reads_pending ON " + RemoteReads + "(pending,host);");

    public Task<RemoteTaskReadRecord?> ReadTaskReadAsync(Guid id, CancellationToken token) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return null; }
        using var db = new SqliteDatabase(Path, true, cancellationToken: token); db.Begin(false); CheckIdentity(db, true);
        var result = ReadTaskRead(db, id); db.Commit(); return result;
    }, token);

    public Task<ImmutableArray<RemoteTaskReadRecord>> PendingTaskReadsAsync(CancellationToken token) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return ImmutableArray<RemoteTaskReadRecord>.Empty; }
        using var db = new SqliteDatabase(Path, true, cancellationToken: token); db.Begin(false); CheckIdentity(db, true);
        if (!Table(db, RemoteReads)) { db.Commit(); return ImmutableArray<RemoteTaskReadRecord>.Empty; }
        var rows = db.Query("SELECT CASE WHEN length(id)=32 THEN id ELSE NULL END AS id FROM " + RemoteReads + " WHERE pending=1 ORDER BY id LIMIT ?1;", RemoteTaskReadRules.MaximumPending + 1);
        if (rows.Count > RemoteTaskReadRules.MaximumPending) { throw new InvalidDataException("Journal des lectures en attente hors limites."); }
        var result = ImmutableArray.CreateBuilder<RemoteTaskReadRecord>();
        foreach (var row in rows)
        {
            token.ThrowIfCancellationRequested();
            if (row["id"] is not string key || !Guid.TryParseExact(key, "N", out var id) || ReadTaskRead(db, id) is not { CleanupRequired: true } read)
            { throw new InvalidDataException("Lecture en attente incohérente ; aucune reprise automatique."); }
            result.Add(read);
        }
        db.Commit(); return result.ToImmutable();
    }, token);

    private RemoteTaskReadRecord? ReadTaskRead(SqliteDatabase db, Guid id)
    {
        if (!Table(db, RemoteReads)) { return null; }
        var rows = db.Query("SELECT CASE WHEN length(computer_guid)=36 THEN computer_guid ELSE NULL END AS computer_guid,"
            + "CASE WHEN length(host)<=253 THEN host ELSE NULL END AS host,pending,revision,"
            + "CASE WHEN length(plan_hash)=64 THEN plan_hash ELSE NULL END AS plan_hash,"
            + "CASE WHEN length(completion_hash)=64 THEN completion_hash ELSE NULL END AS completion_hash,"
            + "CASE WHEN completion IS NOT NULL OR completion_hash IS NOT NULL THEN 1 ELSE 0 END AS has_completion,"
            + "CASE WHEN length(CAST(plan AS BLOB))<=32768 THEN plan ELSE NULL END AS plan,"
            + "CASE WHEN length(CAST(completion AS BLOB))<=16384 THEN completion ELSE NULL END AS completion FROM " + RemoteReads + " WHERE id=?1;", id.ToString("N"));
        if (rows.Count == 0) { return null; }
        var row = rows.Single();
        if (row["plan"] is not string json || RemoteHash(json) != row["plan_hash"] as string) { throw new InvalidDataException("Plan distant illisible ou altéré."); }
        var plan = JsonSerializer.Deserialize<RemoteTaskReadPlan>(json, Json) ?? throw new InvalidDataException("Plan distant absent.");
        RemoteTaskReadRules.Validate(plan, clock.GetUtcNow());
        if (plan.Id != id || plan.StoreId != StoreId && !HistoricalStore(db, plan.StoreId) || !InDomain(plan.ComputerDn) || plan.ComputerGuid.ToString("D") != row["computer_guid"] as string
            || plan.Host != row["host"] as string || row["revision"] is not long revision || revision < 1)
        { throw new InvalidDataException("Identité du journal de lecture incompatible."); }
        RemoteTaskReadCompletion? completion = null;
        if (row["completion"] is string payload)
        {
            if (RemoteHash(payload) != row["completion_hash"] as string) { throw new InvalidDataException("Reçu distant altéré."); }
            completion = JsonSerializer.Deserialize<RemoteTaskReadCompletion>(payload, Json) ?? throw new InvalidDataException("Reçu absent.");
            RemoteTaskReadRules.Validate(new(plan, revision, null), completion, clock.GetUtcNow());
        }
        else if ((long)row["has_completion"]! != 0) { throw new InvalidDataException("Reçu incomplet ou hors limites."); }
        var record = new RemoteTaskReadRecord(plan, revision, completion);
        if (plan.StoreId != StoreId && record.CleanupRequired) { throw new InvalidDataException("Lecture distante non terminée dans un magasin historique ; aucun nettoyage sous une nouvelle identité."); }
        if (row["pending"] is not long pending || pending != (record.CleanupRequired ? 1 : 0)) { throw new InvalidDataException("État de nettoyage contradictoire."); }
        return record;
    }
}
