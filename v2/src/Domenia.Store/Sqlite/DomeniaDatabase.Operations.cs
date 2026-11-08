using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    public Task<IDisposable> AcquireOperationsLeaseAsync(CancellationToken cancellationToken) => Task.Run<IDisposable>(() =>
    {
        cancellationToken.ThrowIfCancellationRequested(); CompatibleDirectoryCache.ValidateLocalPath(Path);
        var lockPath = Path + ".collection.lock";
        if (File.Exists(lockPath) && (File.GetAttributes(lockPath) & FileAttributes.ReparsePoint) != 0)
        { throw new InvalidDataException("Verrou de collecte redirigé ; acquisition refusée."); }
        try { return RetainCollectionLock(new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.None)); }
        catch (IOException) { throw new DomeniaOperationException("operations.surveyBusy", "Une autre instance utilise la collecte de cette base ; aucune sonde envoyée."); }
    }, cancellationToken);

    public Task<OperationsLocalState> ReadOperationsAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!DatabaseFileExists()) { return EmptyOperations(); }
        using var db = Open(readOnly: true, cancellationToken: cancellationToken);
        db.Begin(write: false); CheckIdentity(db, allowLegacy: true);
        var result = WithLegacyOperations(db, ReadOperations(db)); db.Commit(); return result;
    }, cancellationToken);

    private async Task<OperationsLocalState> UpdateOperationsCoreAsync(long expectedRevision, OperationsLocalState next, CancellationToken cancellationToken)
    {
        OperationsPersistence.Validate(next);
        if (next.StoreId != StoreId || !DistinguishedName.AreEqual(next.DomainDn, DomainDn) || next.Revision != expectedRevision + 1)
        { throw new InvalidDataException("Journal d’un autre magasin ou révision non consécutive."); }
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady(); CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = Open(readOnly: false, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: false);
                var paged = next.HomeCampaign is not null || next.Survey is not null;
                EnsureBackup(db, cancellationToken, force: paged && db.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';") as string != "2");
                db.Script("PRAGMA synchronous=FULL;"); db.Begin();
                var before = ReadOperations(db);
                if (before.Revision != expectedRevision) { throw new InvalidDataException("Journal modifié simultanément ; aucune progression écrasée."); }
                db.Execute("CREATE TABLE IF NOT EXISTS domenia_v2_operations(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL,payload TEXT NOT NULL,sha256 TEXT NOT NULL);");
                var targets = new OperationsTargetPages(this, db);
                var payload = OperationsDocumentCodec.Encode(next, targets);
                if (Encoding.UTF8.GetByteCount(payload) > 8_388_608) { throw new InvalidDataException("Journal d’opérations supérieur à 8 Mio."); }
                var hash = OperationsHash(payload);
                db.Execute("INSERT INTO domenia_v2_operations(id,revision,payload,sha256) VALUES(1,?1,?2,?3) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload,sha256=excluded.sha256;", next.Revision, payload, hash);
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                var inside = ReadOperations(db);
                if (OperationsDocumentCodec.Encode(inside, targets) != payload) { throw new InvalidDataException("Journal différent après écriture ; transaction annulée."); }
                targets.RemoveUnreferenced();
                if (paged) { db.Execute("UPDATE schema_info SET value='2' WHERE key='domenia_schema';"); }
                db.Commit(); targets.Committed(); return inside;
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private OperationsLocalState EmptyOperations() => new(StoreId, DomainDn, 0, [], [], null);
    private static string OperationsHash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    private OperationsLocalState ReadOperations(SqliteDatabase db, string? expectedStoreId = null)
    {
        if (!Table(db, "domenia_v2_operations")) { return EmptyOperations(); }
        var rows = db.Query("SELECT revision,CASE WHEN length(CAST(payload AS BLOB))<=8388608 THEN payload END AS payload,sha256 FROM domenia_v2_operations WHERE id=1;");
        if (rows.Count == 0) { return EmptyOperations(); }
        var row = rows.Single();
        if (row["payload"] is not string payload || OperationsHash(payload) != row["sha256"] as string)
        { throw new InvalidDataException("Journal d’opérations altéré ou hors limites."); }
        var result = OperationsDocumentCodec.Decode(payload, new OperationsTargetPages(this, db));
        if (result.StoreId != (expectedStoreId ?? StoreId) || !DistinguishedName.AreEqual(result.DomainDn, DomainDn) || result.Revision != (long?)row["revision"])
        { throw new InvalidDataException("Identité du journal d’opérations incohérente."); }
        OperationsPersistence.Validate(result); return result;
    }
}
