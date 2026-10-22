using System.Collections.Concurrent;
using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Store;

public sealed record DatabaseBackup(string Path, string Sha256, long Bytes, DateTimeOffset At);
public sealed record DatabaseInspection(string Path, string StoreId, string DomainDn, long Revision, int SchemaVersion, int SchemaRevision, long? Objects, long? Observations, long? Associations, long? Recipes, DatabaseBackup? Backup);

/// <summary>Schema 11/1, additive migration after a verified backup. Never replaces an unreadable or foreign base.</summary>
public sealed partial class DomeniaDatabase
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> Writers = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Lazy<string> Schema = new(ReadSchema);
    private readonly SemaphoreSlim writer;
    private readonly TimeProvider clock;
    private DatabaseBackup? lastBackup;
    private bool initialized;

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

    public async Task<DatabaseInspection> InitializeAsync(CancellationToken cancellationToken)
    {
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await Task.Run(() => Initialize(cancellationToken), cancellationToken).ConfigureAwait(false); }
        finally { writer.Release(); }
    }

    public Task<DatabaseInspection?> InspectAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return null; }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
        CheckIdentity(db, allowLegacy: true);
        return Inspect(db);
    }, cancellationToken);

    /// <summary>Revalidates a recent backup and free space before an explicit network refresh.</summary>
    public async Task<DatabaseBackup> PrepareReadAsync(CancellationToken cancellationToken)
    {
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                CompatibleDirectoryCache.ValidateLocalPath(Path);
                var drive = new DriveInfo(System.IO.Path.GetPathRoot(Path)!);
                if (drive.AvailableFreeSpace < 512L * 1024 * 1024)
                { throw new IOException("Moins de 512 Mio libres pour la base locale : relecture refusée."); }
                using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: false);
                EnsureBackup(db, cancellationToken);
                return lastBackup!;
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    public async Task<DatabaseBackup> BackupAsync(CancellationToken cancellationToken)
    {
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: true);
                return lastBackup = Backup(db, cancellationToken);
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private DatabaseInspection Initialize(CancellationToken token)
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (File.Exists(Path))
        {
            using (var read = new SqliteDatabase(Path, readOnly: true, cancellationToken: token))
            {
                CheckIdentity(read, allowLegacy: true);
                if (IsCurrent(read)) { initialized = true; return Inspect(read); }
                lastBackup = Backup(read, token);
            }
            using var db = new SqliteDatabase(Path, readOnly: false, cancellationToken: token);
            db.Script("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;");
            db.Begin();
            CheckIdentity(db, allowLegacy: true);
            Upgrade(db);
            db.Commit();
            initialized = true;
            return Inspect(db);
        }
        var parent = System.IO.Path.GetDirectoryName(Path)!;
        Directory.CreateDirectory(parent);
        var temporary = System.IO.Path.Combine(parent, ".domenia-create-" + Guid.NewGuid().ToString("N") + ".db");
        // The final path appears only after the complete schema and identity have committed.
        using (var db = new SqliteDatabase(temporary, readOnly: false, cancellationToken: token))
        {
            db.Script("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;");
            db.Begin();
            Upgrade(db);
            db.Commit();
        }
        token.ThrowIfCancellationRequested();
        File.Move(temporary, Path, overwrite: false);
        using var opened = new SqliteDatabase(Path, readOnly: true, cancellationToken: token);
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
        db.Execute("INSERT OR REPLACE INTO schema_info(key,value) VALUES('domenia_schema','1');");
        CheckIdentity(db, allowLegacy: false);
        if (!IsCurrent(db)) { throw new InvalidDataException("Schéma incomplet : mise à niveau annulée."); }
    }

    private void CheckIdentity(SqliteDatabase db, bool allowLegacy)
    {
        if (!Table(db, "schema_info")) { throw new InvalidDataException("Version de base inconnue : aucune modification."); }
        var header = db.Query("SELECT key,value FROM schema_info WHERE key IN ('schema_version','domenia_schema');");
        var versions = header.Where(r => (string?)r["key"] == "schema_version").ToArray();
        var revisions = header.Where(r => (string?)r["key"] == "domenia_schema").ToArray();
        if (versions.Length != 1 || (string?)versions[0]["value"] != "11" || revisions.Length > 1
            || (revisions.Length == 1 && (string?)revisions[0]["value"] is not ("0" or "1")) || (!allowLegacy && (revisions.Length != 1 || (string?)revisions[0]["value"] != "1")))
        {
            throw new InvalidDataException("Schéma incompatible ; la base n’est ni remplacée ni rétrogradée.");
        }
        if (Table(db, "domenia_store_state"))
        {
            var states = db.Query("SELECT store_id,domain_dn FROM domenia_store_state;");
            if (states.Count > 1) { throw new InvalidDataException("Identité de stockage ambiguë."); }
            if (states.Count == 1)
            {
                if (!string.Equals((string?)states[0]["domain_dn"], DomainDn, StringComparison.OrdinalIgnoreCase) || (string?)states[0]["store_id"] != StoreId)
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

    private static bool IsCurrent(SqliteDatabase db)
    {
        if ((string?)db.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';") != "1" || !Table(db, "domenia_v2_objects") || !Table(db, "domenia_v2_batches") || !Table(db, "domenia_v2_metadata")) { return false; }
        using var expected = new SqliteDatabase(":memory:", readOnly: false);
        expected.Script(Schema.Value);
        foreach (var row in expected.Query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"))
        {
            var name = (string)row["name"]!;
            if (!Table(db, name)) { return false; }
            var actual = db.Query("PRAGMA table_info(" + name + ");").Select(c => (string)c["name"]!).ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (expected.Query("PRAGMA table_info(" + name + ");").Any(c => !actual.Contains((string)c["name"]!))) { return false; }
        }
        return true;
    }

    private DatabaseInspection Inspect(SqliteDatabase db)
    {
        long? Count(string table) => Table(db, table) ? (long?)db.Scalar("SELECT count(*) FROM " + table + ";") : null;
        var revision = Table(db, "domenia_store_state") ? (long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") ?? 0 : 0;
        var schemaRevision = int.TryParse(db.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';") as string, out var parsed) ? parsed : 0;
        return new(Path, StoreId, DomainDn, revision, 11, schemaRevision, Count("ad_objects"), Count("domenia_observations"), Count("user_machine_links"), Count("domenia_query_recipes"), lastBackup);
    }

    private DatabaseBackup Backup(SqliteDatabase source, CancellationToken token)
    {
        var folder = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Path)!, "Backups");
        Directory.CreateDirectory(folder);
        var target = System.IO.Path.Combine(folder, System.IO.Path.GetFileNameWithoutExtension(Path) + "-" + clock.GetUtcNow().ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + "-" + Guid.NewGuid().ToString("N") + ".db");
        CompatibleDirectoryCache.ValidateLocalPath(target);
        var partial = target + ".partial";
        using (new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
        using (var destination = new SqliteDatabase(partial, readOnly: false, cancellationToken: token)) { source.BackupTo(destination); }
        using (var verify = new SqliteDatabase(partial, readOnly: true, cancellationToken: token))
        {
            if ((string?)verify.Scalar("PRAGMA quick_check;") != "ok") { throw new InvalidDataException("Sauvegarde non validée : aucune migration."); }
        }
        token.ThrowIfCancellationRequested();
        File.Move(partial, target, overwrite: false);
        using var stream = File.OpenRead(target);
        return new(target, Convert.ToHexStringLower(SHA256.HashData(stream)), stream.Length, clock.GetUtcNow());
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
