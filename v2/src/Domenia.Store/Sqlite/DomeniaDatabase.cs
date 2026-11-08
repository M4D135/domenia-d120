using System.Collections.Concurrent;
using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Store;

public sealed record DatabaseBackup(string Path, string Sha256, long Bytes, DateTimeOffset At);
public sealed record DatabaseInspection(string Path, string StoreId, string DomainDn, long Revision, int SchemaVersion, int SchemaRevision, long? Objects, long? Observations, long? Associations, long? Recipes, DatabaseBackup? Backup);

/// <summary>Schema 11/1 or 11/2 (incremental fleet), migrated after a verified backup. Never downgrades a base.</summary>
public sealed partial class DomeniaDatabase
{
    public const int SupportedDataSchemaRevision = 2;
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> Writers = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Lazy<string> Schema = new(ReadSchema);
    private readonly SemaphoreSlim writer;
    private readonly TimeProvider clock;
    private DatabaseBackup? lastBackup;
    private bool initialized;
    internal Action? UpgradeCheckpoint { get; set; }
    private OperationActivity? operations;
    private UserLocalStorageProtection? userLocalProtection;

    internal void ConfigureUserLocalRoot(string root) => userLocalProtection = new(root);

    /// <summary>Session owner also covers writers outside a tracked bridge request; no process-global fallback.</summary>
    public void ConfigureSession(OperationActivity activity)
    {
        ArgumentNullException.ThrowIfNull(activity);
        var previous = Interlocked.CompareExchange(ref operations, activity, null);
        if (previous is not null && !ReferenceEquals(previous, activity)) throw new InvalidOperationException("Base déjà liée à une autre session.");
    }

    internal SqliteDatabase Open(bool readOnly, CancellationToken cancellationToken = default) =>
        OpenPath(Path, readOnly, cancellationToken);
    private SqliteDatabase OpenPath(string path, bool readOnly, CancellationToken cancellationToken = default)
    {
        SqliteDatabase.ValidateFiles(path, cancellationToken);
        if (!readOnly) userLocalProtection?.PrepareFile(path, cancellationToken);
        return new(path, readOnly, cancellationToken: cancellationToken, operations: operations);
    }

    public DomeniaDatabase(string path, string domainDn, TimeProvider clock)
    {
        ArgumentNullException.ThrowIfNull(clock);
        if (!System.IO.Path.IsPathFullyQualified(path) || path.StartsWith(@"\\", StringComparison.Ordinal) || !path.EndsWith(".db", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("La base doit être un fichier .db sur un disque local.", nameof(path));
        }
        var parts = DistinguishedName.Parse(domainDn);
        if (parts.Length == 0 || parts.Any(p => !string.Equals(p.Type, "DC", StringComparison.OrdinalIgnoreCase) || string.IsNullOrWhiteSpace(p.Value)))
        {
            throw new ArgumentException("DN de domaine invalide.", nameof(domainDn));
        }
        Path = System.IO.Path.GetFullPath(path);
        DomainDn = domainDn.Trim();
        StoreId = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(Path.ToLowerInvariant() + "\n" + DomainDn.ToLowerInvariant())));
        this.clock = clock;
        writer = Writers.GetOrAdd(Path, _ => new SemaphoreSlim(1, 1));
    }

    public string Path { get; }
    public string DomainDn { get; }
    public string StoreId { get; }

    private async Task<DatabaseInspection> InitializeCoreAsync(CancellationToken cancellationToken)
    {
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await Task.Run(() => Initialize(cancellationToken), cancellationToken).ConfigureAwait(false); }
        finally { writer.Release(); }
    }

    public Task<DatabaseInspection?> InspectAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!DatabaseFileExists()) { return null; }
        using var db = Open(readOnly: true, cancellationToken: cancellationToken);
        CheckIdentity(db, allowLegacy: true);
        return Inspect(db);
    }, cancellationToken);

    /// <summary>Revalidates a recent backup and free space before an explicit network refresh.</summary>
    private async Task<DatabaseBackup> PrepareReadCoreAsync(CancellationToken cancellationToken)
    {
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                CompatibleDirectoryCache.ValidateLocalPath(Path);
                CollectionStorageRules.Ensure(ReadCollectionStorage(cancellationToken), clock.GetUtcNow(), clock.LocalTimeZone);
                using var db = Open(readOnly: true, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: false);
                EnsureBackup(db, cancellationToken);
                return lastBackup!;
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private async Task<DatabaseBackup> BackupCoreAsync(CancellationToken cancellationToken)
    {
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = Open(readOnly: true, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: true);
                return lastBackup = Backup(db, cancellationToken);
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private DatabaseInspection Initialize(CancellationToken token)
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        userLocalProtection?.PrepareDirectory(Path, token);
        if (File.Exists(Path))
        {
            using (var read = Open(readOnly: true, cancellationToken: token))
            {
                CheckIdentity(read, allowLegacy: true);
                if (IsCurrent(read)) { initialized = true; return Inspect(read); }
                lastBackup = Backup(read, token, "migration");
            }
            using var db = Open(readOnly: false, cancellationToken: token);
            db.Script("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;");
            db.Begin();
            CheckIdentity(db, allowLegacy: true);
            Upgrade(db);
            UpgradeCheckpoint?.Invoke();
            db.Commit();
            initialized = true;
            return Inspect(db);
        }
        var parent = System.IO.Path.GetDirectoryName(Path)!;
        Directory.CreateDirectory(parent);
        var temporary = System.IO.Path.Combine(parent, ".domenia-create-" + Guid.NewGuid().ToString("N") + ".db");
        try
        {
            // The final path appears only after the complete schema and identity have committed.
            using (var db = OpenPath(temporary, readOnly: false, cancellationToken: token))
            {
                db.Script("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;");
                db.Begin(); Upgrade(db); UpgradeCheckpoint?.Invoke(); db.Commit();
            }
            token.ThrowIfCancellationRequested();
            File.Move(temporary, Path, overwrite: false);
        }
        finally
        {
            foreach (var suffix in new[] { "", "-journal", "-wal", "-shm", ".domenia-write.lock" })
            {
                try { File.Delete(temporary + suffix); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
            }
        }
        using var opened = Open(readOnly: true, cancellationToken: token);
        initialized = true;
        return Inspect(opened);
    }

    private void Upgrade(SqliteDatabase db)
    {
        db.Script(Schema.Value);
        foreach (var table in new[] { "domenia_details", "domenia_observations" })
        {
            var columns = db.Query("PRAGMA table_info(" + table + ");").Select(r => (string)r["name"]!).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var column in new[] { "summary_payload", "attempt_summary" })
            {
                if (!columns.Contains(column)) { db.Script("ALTER TABLE " + table + " ADD COLUMN " + column + " TEXT;"); }
            }
        }
        db.Execute("INSERT OR IGNORE INTO domenia_store_state(id,store_id,domain_dn,revision) VALUES(1,?1,?2,0);", StoreId, DomainDn);
        // Additional typed projections do not change or reinterpret Domenia 1 payloads.
        db.Script("CREATE TABLE IF NOT EXISTS domenia_v2_objects(object_guid TEXT PRIMARY KEY,kind TEXT NOT NULL,dn TEXT NOT NULL,payload TEXT NOT NULL,observed_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS domenia_v2_metadata(key TEXT PRIMARY KEY,payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS domenia_v2_batches(batch_id TEXT PRIMARY KEY,sha256 TEXT NOT NULL,revision INTEGER NOT NULL,committed_at TEXT NOT NULL,items INTEGER NOT NULL);");
        db.Script("CREATE TABLE IF NOT EXISTS domenia_v2_fiches(object_guid TEXT PRIMARY KEY,dn_key TEXT NOT NULL,payload TEXT NOT NULL,summary TEXT NOT NULL,summary_sha256 TEXT NOT NULL,sha256 TEXT NOT NULL,observed_at TEXT NOT NULL); CREATE INDEX IF NOT EXISTS idx_domenia_v2_fiches_dn ON domenia_v2_fiches(dn_key,observed_at);");
        db.Script("CREATE TABLE IF NOT EXISTS domenia_v2_deletions(object_guid TEXT PRIMARY KEY,dn TEXT NOT NULL,observed_at TEXT NOT NULL);");
        db.Execute("INSERT INTO schema_info(key,value) VALUES('domenia_schema','1') ON CONFLICT(key) DO UPDATE SET value='1' WHERE value<>'2';");
        foreach (var table in MaintenanceReceiptTables)
            db.Script("CREATE TABLE IF NOT EXISTS " + table + "(plan_id TEXT PRIMARY KEY,sha256 TEXT NOT NULL,payload TEXT NOT NULL);");
        CheckIdentity(db, allowLegacy: false);
        if (!IsCurrent(db)) { throw new InvalidDataException("Schéma incomplet : mise à niveau annulée."); }
    }

    private void CheckIdentity(SqliteDatabase db, bool allowLegacy, string? expectedStoreId = null)
    {
        if (!Table(db, "schema_info")) { throw new InvalidDataException("Version de base inconnue : aucune modification."); }
        var header = db.Query("SELECT key,value FROM schema_info WHERE key IN ('schema_version','domenia_schema');");
        var versions = header.Where(r => (string?)r["key"] == "schema_version").ToArray();
        var revisions = header.Where(r => (string?)r["key"] == "domenia_schema").ToArray();
        if (versions.Length != 1 || (string?)versions[0]["value"] != "11" || revisions.Length > 1
            || (revisions.Length == 1 && (string?)revisions[0]["value"] is not ("0" or "1" or "2")) || (!allowLegacy && (revisions.Length != 1 || (string?)revisions[0]["value"] is not ("1" or "2"))))
        {
            throw new InvalidDataException("Schéma incompatible ; la base n’est ni remplacée ni rétrogradée.");
        }
        if (Table(db, "domenia_store_state"))
        {
            var states = db.Query("SELECT store_id,domain_dn FROM domenia_store_state;");
            if (states.Count > 1) { throw new InvalidDataException("Identité de stockage ambiguë."); }
            if (states.Count == 1)
            {
                if (!string.Equals((string?)states[0]["domain_dn"], DomainDn, StringComparison.OrdinalIgnoreCase) || (string?)states[0]["store_id"] != (expectedStoreId ?? StoreId))
                {
                    throw new InvalidDataException("Cette base appartient à un autre domaine ou emplacement : utilisez l’assistant de restauration.");
                }
                return;
            }
        }
        if (!allowLegacy) { throw new InvalidDataException("Identité du stockage absente."); }
        // An old, unbound base must contain no object from another domain, even without a global sync checkpoint.
        if (Table(db, "sync_state"))
        {
            foreach (var row in db.Query("SELECT base_dn FROM sync_state WHERE scope='directory' AND COALESCE(base_dn,'')<>'';"))
            {
                if (!string.Equals((string?)row["base_dn"], DomainDn, StringComparison.OrdinalIgnoreCase)) { throw new InvalidDataException("Domaine de la base historique différent."); }
            }
        }
        if (Table(db, "ad_objects"))
        {
            foreach (var row in db.Query("SELECT distinguished_name FROM ad_objects;"))
            {
                if (!InDomain(row["distinguished_name"] as string)) { throw new InvalidDataException("Objet historique hors du domaine attendu."); }
            }
        }
    }

    private bool InDomain(string? dn) => !string.IsNullOrWhiteSpace(dn) && (ScopeRules.IsDomainRoot(new ScopeSelection(dn, dn, true), DomainDn) || ScopeRules.Contains(new ScopeSelection(DomainDn, DomainDn, true), dn));

    private static bool InReadScope(ScopeSelection scope, string dn) => ScopeRules.Contains(scope, dn) || scope.Subtree && ScopeRules.IsDomainRoot(scope, dn);

    private static bool Table(SqliteDatabase db, string name) => (long?)db.Scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?1;", name) == 1;

    private static readonly string[] MaintenanceReceiptTables = ["domenia_v2_purge_receipts", "domenia_v2_writer_receipts", "domenia_v2_retention_receipts", "domenia_v2_legacy_receipts"];
    private static bool IsCurrent(SqliteDatabase db)
    {
        foreach (var table in MaintenanceReceiptTables)
        {
            if (!Table(db, table)) return false;
            var columns = db.Query("PRAGMA table_info(" + table + ");").Select(c => (string)c["name"]!).ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (new[] { "plan_id", "sha256", "payload" }.Any(c => !columns.Contains(c))) return false;
        }
        if ((string?)db.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';") is not ("1" or "2") || !Table(db, "domenia_v2_objects") || !Table(db, "domenia_v2_batches") || !Table(db, "domenia_v2_metadata") || !Table(db, "domenia_v2_fiches") || !Table(db, "domenia_v2_deletions")) { return false; }
        var ficheColumns = db.Query("PRAGMA table_info(domenia_v2_fiches);").Select(c => (string)c["name"]!).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (new[] { "object_guid", "dn_key", "payload", "summary", "summary_sha256", "sha256", "observed_at" }.Any(c => !ficheColumns.Contains(c))) { return false; }
        using var expected = new SqliteDatabase(":memory:", readOnly: false);
        expected.Script(Schema.Value);
        foreach (var row in expected.Query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"))
        {
            var name = (string)row["name"]!;
            if (!Table(db, name)) { return false; }
            var actual = db.Query("PRAGMA table_info(" + name + ");").Select(c => (string)c["name"]!).ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (expected.Query("PRAGMA table_info(" + name + ");").Any(c => !actual.Contains((string)c["name"]!))) { return false; }
        }
        foreach (var name in new[] { "ix_links_computer_guid", "ix_links_user_guid", "ix_links_computer_name" })
            if ((long?)db.Scalar("SELECT count(*) FROM sqlite_master WHERE type='index' AND name=?1;", name) != 1) return false;
        return true;
    }

    private DatabaseInspection Inspect(SqliteDatabase db)
    {
        long? Count(string table) => Table(db, table) ? (long?)db.Scalar("SELECT count(*) FROM " + table + ";") : null;
        var revision = Table(db, "domenia_store_state") ? (long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") ?? 0 : 0;
        var schemaRevision = int.TryParse(db.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';") as string, out var parsed) ? parsed : 0;
        return new(Path, StoreId, DomainDn, revision, 11, schemaRevision, Count("ad_objects"), Count("domenia_observations"), Count("user_machine_links"), Count("domenia_query_recipes"), lastBackup);
    }

    private DatabaseBackup Backup(SqliteDatabase source, CancellationToken token, string kind = "gesture")
    {
        var seconds = backupTimeoutSeconds;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(seconds), clock);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
        try { return BackupInternal(source, linked.Token, kind); }
        catch (OperationCanceledException ex) when (deadline.IsCancellationRequested && !token.IsCancellationRequested)
        { throw new IOException($"Budget de sauvegarde dépassé ({seconds} s). Geste refusé ; base et copies vérifiées conservées.", ex); }
    }

    private DatabaseBackup BackupInternal(SqliteDatabase source, CancellationToken token, string kind)
    {
        if (kind is not ("gesture" or "migration")) throw new ArgumentException("Série interne inconnue.", nameof(kind));
        var ownsRead = !source.InTransaction;
        if (ownsRead) source.Begin(write: false);
        try
        {
            CheckWriterSpace(File.Exists(Path) ? new FileInfo(Path).Length : 0);
            var id = WritePlans.NewId();
            var file = (kind == "migration" ? "Migration-" : "Geste-") + clock.GetUtcNow().ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + "-" + id + ".db";
            var target = System.IO.Path.Combine(BackupFolder, file);
            var partial = System.IO.Path.Combine(BackupFolder, ".backup-" + id + ".partial");
            const int maximumDatabasePath = 260 - 9;
            if (target.Length > maximumDatabasePath || partial.Length > maximumDatabasePath)
                throw new PathTooLongException("Chemin de sauvegarde trop long pour son journal SQLite natif ; choisissez un emplacement local plus court.");
            CompatibleDirectoryCache.ValidateLocalPath(target); CompatibleDirectoryCache.ValidateLocalPath(partial);
            Directory.CreateDirectory(BackupFolder);
            using var cleanup = new BackupTemporaryFiles();
            BackupStage("internal.beforeCopy", token);
            // All callers run on the storage worker. Read the preference store alone, never a directory/session callback.
            var annex = backupPreferences is { } preferences
                ? BackupPreferencesRules.Snapshot(preferences.ReadConfigurationAsync(token).GetAwaiter().GetResult().Values) : null;
            var inspection = Inspect(source);
            using (new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
            cleanup.Add(partial);
            WriteNewBackupFile(partial + ".domenia-write.lock", [], cleanup, token);
            using (var destination = OpenPath(partial, false, token)) source.BackupTo(destination, () => BackupStage("internal.copy", token));
            using (var verify = OpenPath(partial, true, token))
            {
                CheckIdentity(verify, true);
                if (verify.Scalar("PRAGMA quick_check;") as string != "ok" || Inspect(verify).Revision != inspection.Revision)
                    throw new InvalidDataException("Sauvegarde non validée : aucune mutation de la base.");
            }
            BackupStage("internal.verified", token);
            var hash = BackupFileHash(partial, token); var size = new FileInfo(partial).Length; var at = clock.GetUtcNow();
            token.ThrowIfCancellationRequested(); File.Move(partial, target, overwrite: false); cleanup.Forget(partial);
            BackupPreferences? bound = annex is null ? null : BackupPreferencesRules.Bind(annex, hash, at);
            if (bound is not null)
                WriteBackupMetadata(System.IO.Path.ChangeExtension(target, ".preferences.json"), System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(bound, Json), id, cleanup, token);
            var counts = new LocalStoreCounts(inspection.Objects, inspection.Observations, null, inspection.Associations, inspection.Recipes, null);
            var backup = new LocalStoreBackup(id, file, at, size, hash, true, at, kind, inspection.Revision, counts, null, bound);
            SaveStorageBackupProof(new(id, hash, StoreId, DomainDn, backup, null, true, false), token);
            ValidateBackupArtifact(ReadStorageBackupProof(id)!, token);
            return new(target, hash, size, at);
        }
        finally { if (ownsRead) source.Rollback(); }
    }


    private void EnsureReady()
    {
        if (!initialized) { throw new InvalidOperationException("Initialisez et vérifiez la base avant cette écriture."); }
    }

    private static string ReadSchema()
    {
        using var stream = typeof(DomeniaDatabase).Assembly.GetManifestResourceStream("Domenia.Store.Sqlite.schema-11.sql") ?? throw new InvalidOperationException("Schéma embarqué absent.");
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }
}
