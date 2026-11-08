using System.Collections.Immutable;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domenia.Core;

namespace Domenia.Store;

internal sealed record SharedParkCommitReceipt(int Version, string PlanId, string PlanFingerprint, string BatchId, string BatchFingerprint,
    string StoreId, string DomainDn, string Path, string RemoteSha256, string RowsFingerprint, long Revision, long Generation,
    int Updated, DateTimeOffset CommittedAt);

public sealed partial class DomeniaDatabase
{
    private const string SharedParkReceipts = "domenia_v2_shared_park_receipts";
    private const string SharedParkReceiptSchema = "CREATE TABLE IF NOT EXISTS domenia_v2_shared_park_receipts(plan_id TEXT NOT NULL PRIMARY KEY,plan_fingerprint TEXT NOT NULL,payload TEXT NOT NULL,sha256 TEXT NOT NULL);";
    private const int MaxSharedParkReceipts = 128;
    private const int MaxSharedParkReceiptBytes = 16384;
    private static readonly JsonSerializerOptions SharedParkReceiptJson = new() { MaxDepth = 8, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };

    /// <summary>
    /// Explicit cold verification, including after restart/expiration: reads the private intention, both physical initial copies,
    /// the current SQLite receipt and park snapshot, then the current TSV. It creates nothing and never publishes/replays.
    /// An intention without a committed SQLite receipt stays Unknown, even if the TSV happens to equal the proposal.
    /// Verified describes these re-read states, not a permanent cross-resource transaction or the state of a disconnected share.
    /// </summary>
    internal Task<WriteVerification> VerifySharedParkConfirmedAsync(WritePlan plan, string backupRoot, string journalRoot,
        ImmutableArray<string> configFiles, ImmutableArray<string> protectedDirectories, CancellationToken token) => Task.Run(async () =>
    {
        token.ThrowIfCancellationRequested(); ValidateSharedParkRoots(backupRoot, journalRoot);
        try
        {
            var journal = new SharedParkIntentJournal(journalRoot, StoreId, DomainDn, clock);
            var intent = await journal.ReadAsync(plan.Id, plan.Fingerprint, token).ConfigureAwait(false);
            if (intent is null) { return new WriteVerification(VerificationState.Unknown, "Aucune intention durable pour ce plan ; aucune publication n’est déduite."); }
            ValidateSharedParkPlan(plan, intent.Batch, current: false);
            var batch = intent.Batch;
            var protections = protectedDirectories.Add(backupRoot).Add(journalRoot);
            SharedParkRemoteReader.Validate(batch.Path, Path, configFiles, protections, token);
            using var privatePaths = SharedParkBackupFiles.Open(backupRoot, Path, batch.Path, configFiles, protectedDirectories.Add(journalRoot), token);
            using var evidence = OpenSharedParkEvidence(intent, backupRoot, token);
            CompatibleDirectoryCache.ValidateLocalPath(Path);
            if (LocalBaseAbsent(token)) { return new WriteVerification(VerificationState.Unknown, "Base actuelle absente ; le résultat de l’intention reste inconnu."); }
            using var sourceIdentity = privatePaths.PinSqliteSource(Path, token);
            using var db = Open(true, cancellationToken: token);
            var dataVersion = db.Scalar("PRAGMA data_version;");
            db.Begin(false); CheckIdentity(db, allowLegacy: true);
            var receipt = ReadSharedParkReceipt(db, plan.Id);
            if (receipt is null) { return new WriteVerification(VerificationState.Unknown, "Intention conservée sans reçu SQLite commis ; vérification manuelle requise, aucun rejeu."); }
            ValidateSharedParkReceipt(receipt, intent);
            var current = ReadSharedParkBackupLocal(db, token);
            if (current.Generation != receipt.Generation || current.Revision < receipt.Revision || current.RowsFingerprint != receipt.RowsFingerprint)
            { return new WriteVerification(VerificationState.Mismatch, "La mémoire locale diffère de l’état relu dans le reçu du partage."); }
            var remote = await SharedParkRemoteReader.ReadAsync(batch.Path, Path, configFiles, protections, clock.GetUtcNow(), token).ConfigureAwait(false);
            if (!remote.Exists || remote.Sha256 != receipt.RemoteSha256)
            { return new WriteVerification(VerificationState.Mismatch, "Le fichier partagé diffère du contenu publié dans le reçu."); }
            using var remoteParents = new SharedParkPublicationFile.PathPins(System.IO.Path.GetDirectoryName(batch.Path)!, token);
            using var remoteHeld = SharedParkPublicationFile.BoundFile.Open(batch.Path, SharedParkFile.MaxBytes, token, allowDelete: false);
            if (remoteHeld.Sha256 != receipt.RemoteSha256)
            { return new WriteVerification(VerificationState.Mismatch, "Le fichier partagé a changé pendant la vérification."); }
            db.Commit();
            if (!Equals(dataVersion, db.Scalar("PRAGMA data_version;")))
            { return new WriteVerification(VerificationState.Unknown, "La base locale a changé pendant la vérification des deux ressources."); }
            // Every state above has just been re-read; the token is asked one last time so an already granted cancellation never
            // leaves this method on a Verified answer.
            token.ThrowIfCancellationRequested();
            return new WriteVerification(VerificationState.Verified, "Copies initiales, intention, reçu SQLite, observations locales et SHA du fichier partagé relus à l’identique.");
        }
        catch (OperationCanceledException) { throw; }
        catch (InvalidDataException)
        { return new WriteVerification(VerificationState.Mismatch, "Une identité, une protection ou une preuve du partage ne correspond plus au plan."); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or SqliteStoreException)
        { return new WriteVerification(VerificationState.Unknown, "Une ressource ou une preuve du partage est inaccessible ; aucune réussite déduite."); }
    }, token);

    private void ValidateSharedParkReceipt(SharedParkCommitReceipt receipt, SharedParkIntent intent)
    {
        var batch = intent.Batch;
        if (receipt.Version != 1 || receipt.PlanId != intent.PlanId || receipt.PlanFingerprint != intent.PlanFingerprint
            || receipt.BatchId != batch.Id || receipt.BatchFingerprint != intent.BatchFingerprint || receipt.StoreId != StoreId
            || receipt.DomainDn != DomainDn || receipt.Path != batch.Path || receipt.RemoteSha256 != batch.ProposedSha256
            || batch.Revision == long.MaxValue || receipt.Revision != batch.Revision + 1 || receipt.Generation != batch.Generation
            || receipt.Updated != (long)batch.Added + batch.Replaced || receipt.Updated is < 0 or > SharedParkFile.MaxRows
            || !SharedParkProofHash(receipt.RowsFingerprint) || receipt.CommittedAt.Offset != TimeSpan.Zero
            || receipt.CommittedAt < intent.RecordedAt || receipt.CommittedAt > clock.GetUtcNow())
        { throw new InvalidDataException("Reçu SQLite du partage étranger ou incohérent."); }
    }

    private static bool SharedParkProofHash(string? value) => value is { Length: 64 } && value.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));

    private static void ValidateSharedParkReceiptSchema(SqliteDatabase db, bool admission = true)
    {
        if (!Table(db, SharedParkReceipts)) { return; }
        var columns = db.Query("PRAGMA table_info(domenia_v2_shared_park_receipts);");
        string[] names = ["plan_id", "plan_fingerprint", "payload", "sha256"];
        if (columns.Count != names.Length || columns.Where((c, i) => c["name"] as string != names[i]
            || c["type"] as string != "TEXT" || c["notnull"] is not 1L || c["pk"] is not long pk || pk != (i == 0 ? 1 : 0)).Any())
        { throw new InvalidDataException("Schéma du reçu de partage non qualifié."); }
        var count = (long)db.Scalar("SELECT count(*) FROM domenia_v2_shared_park_receipts;")!;
        if (count > MaxSharedParkReceipts || admission && count >= MaxSharedParkReceipts)
        { throw new InvalidDataException("Quota de 128 reçus de partage atteint ; aucun nettoyage implicite."); }
    }

    private static void SaveSharedParkReceipt(SqliteDatabase db, SharedParkCommitReceipt receipt)
    {
        ValidateSharedParkReceiptSchema(db);
        var payload = JsonSerializer.Serialize(receipt, SharedParkReceiptJson);
        var bytes = Encoding.UTF8.GetBytes(payload);
        if (bytes.Length > MaxSharedParkReceiptBytes) { throw new InvalidDataException("Reçu du partage supérieur à 16 Kio."); }
        db.Script(SharedParkReceiptSchema);
        var sha = Convert.ToHexStringLower(SHA256.HashData(bytes));
        if (db.Execute("INSERT INTO domenia_v2_shared_park_receipts(plan_id,plan_fingerprint,payload,sha256) VALUES(?1,?2,?3,?4);",
            receipt.PlanId, receipt.PlanFingerprint, payload, sha) != 1) { throw new InvalidDataException("Reçu du partage non inséré."); }
    }

    private static SharedParkCommitReceipt? ReadSharedParkReceipt(SqliteDatabase db, string planId)
    {
        if (!Table(db, SharedParkReceipts)) { return null; }
        ValidateSharedParkReceiptSchema(db, admission: false);
        var rows = db.Query("SELECT plan_fingerprint,sha256,CASE WHEN length(CAST(payload AS BLOB))<=16384 THEN payload ELSE NULL END AS payload FROM domenia_v2_shared_park_receipts WHERE plan_id=?1 LIMIT 2;", planId);
        if (rows.Count == 0) { return null; }
        if (rows.Count != 1 || rows[0]["payload"] is not string payload || rows[0]["sha256"] is not string sha || !SharedParkProofHash(sha)
            || Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(payload))) != sha)
        { throw new InvalidDataException("Reçu SQLite du partage trop grand, multiple ou corrompu."); }
        SharedParkCommitReceipt receipt;
        try { receipt = JsonSerializer.Deserialize<SharedParkCommitReceipt>(payload, SharedParkReceiptJson) ?? throw new InvalidDataException("Reçu vide."); }
        catch (JsonException ex) { throw new InvalidDataException("Reçu du partage illisible.", ex); }
        if (receipt.PlanId != planId || receipt.PlanFingerprint != rows[0]["plan_fingerprint"] as string)
        { throw new InvalidDataException("Clé de reçu différente de son contenu."); }
        return receipt;
    }

    private static SharedParkEvidence OpenSharedParkEvidence(SharedParkIntent intent, string backupRoot, CancellationToken token)
        => new(intent, backupRoot, token);

    private sealed class SharedParkEvidence : IDisposable
    {
        private readonly SharedParkPublicationFile.PathPins pins;
        private SharedParkPublicationFile.BoundFile? sqlite;
        private SharedParkPublicationFile.BoundFile? tsv;
        internal SharedParkEvidence(SharedParkIntent intent, string root, CancellationToken token)
        {
            var directory = System.IO.Path.Combine(root, intent.Batch.Id);
            pins = new SharedParkPublicationFile.PathPins(directory, token);
            try
            {
                SharedParkPublicationFile.RequirePrivate(new DirectoryInfo(root).GetAccessControl(), FileSystemRights.FullControl, directory: true);
                SharedParkPublicationFile.RequirePrivate(new DirectoryInfo(directory).GetAccessControl(), FileSystemRights.FullControl, directory: true);
                if (intent.Batch.LocalExists != (intent.SqliteBackup is not null) || intent.Batch.RemoteExists != (intent.TsvBackup is not null))
                { throw new InvalidDataException("Présence des copies incohérente avec l’intention."); }
                if (intent.SqliteBackup is { } db) { sqlite = SharedParkPublicationFile.VerifyBackup(db, System.IO.Path.Combine(directory, "initial.db"), SharedParkBackupFiles.MaxSqliteBytes, token); }
                if (intent.TsvBackup is { } file) { tsv = SharedParkPublicationFile.VerifyBackup(file, System.IO.Path.Combine(directory, "initial.tsv"), SharedParkFile.MaxBytes, token); }
            }
            catch { Dispose(); throw; }
        }
        public void Dispose() { tsv?.Dispose(); sqlite?.Dispose(); pins.Dispose(); }
    }
}
