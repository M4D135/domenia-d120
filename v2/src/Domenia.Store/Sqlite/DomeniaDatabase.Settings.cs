using System.Collections.Immutable;
using System.Diagnostics;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private readonly object inspectionGate = new();
    private LocalStoreUsage? measuredUsage;
    private LocalStoreIntegrity? measuredIntegrity;
    private LocalStoreSpace measuredSpace = new(null, null, 0);

    private static readonly (string Id, string[] Tables)[] InspectionCategories =
    [
        ("observations", ["domenia_observations", "domenia_details", "presence_cache", "park_session_cache"]),
        ("snapshots", ["ad_snapshots", "ad_snapshot_rows", "fleet_snapshots"]),
        ("history", ["user_machine_history", "operation_runs", "domenia_store_batches"]),
        ("index", ["ad_objects", "domenia_directory_data", "ad_computer_facts"]),
        ("manualLinks", ["user_machine_links"]), ("secrets", ["secret_state"]),
    ];

    public Task<LocalStoreSnapshot> InspectLocalStoreAsync(bool measure, bool integrity, CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        var watch = Stopwatch.StartNew();
        var now = clock.GetUtcNow();
        var exists = File.Exists(Path);
        var bytes = exists ? new FileInfo(Path).Length : 0;
        var wal = File.Exists(Path + "-wal") ? new FileInfo(Path + "-wal").Length : 0;
        var counts = new LocalStoreCounts(null, null, null, null, null, null);
        var tables = ImmutableArray<LocalStoreTable>.Empty;
        var categories = ImmutableArray<LocalStoreCategory>.Empty;
        var scopes = ImmutableArray<LocalStoreScope>.Empty;
        var families = ImmutableArray<LocalStoreFamily>.Empty;
        var nativePurge = ImmutableArray<LocalStorePurgeTarget>.Empty;
        long revision = 0;
        string schema = exists ? "Inconnu" : "Non créée";
        string? legacySchema = null; string? legacySchemaRevision = null;
        var corrupt = false;
        DateTimeOffset? lastWrite = null;
        string? failure = null;
        var checks = LocalStoreRules.CheckLabels.ToDictionary(x => x.Id, x => new LocalStoreCheck(x.Id, "unknown", "Non contrôlé."), StringComparer.Ordinal);
        if (exists)
        {
            try
            {
                using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
                checks["open"] = new("open", "ok", "Ouverte en lecture seule.");
                CheckIdentity(db, allowLegacy: true);
                checks["identity"] = new("identity", "ok", "Domaine et emplacement de la base vérifiés.");
                checks["schema"] = new("schema", "ok", "Schéma Domenia 1 compatible, version 11.");
                db.Begin(write: false);
                var inspection = Inspect(db);
                families = RetentionFamilies(ReadRetentionInventory(db, cancellationToken), WritePlans.TruncateToSecond(now));
                nativePurge = PurgeTargets(ReadPurgeInventory(db, cancellationToken), WritePlans.TruncateToSecond(now));
                revision = inspection.Revision;
                legacySchema = inspection.SchemaVersion.ToString(CultureInfo.InvariantCulture);
                legacySchemaRevision = inspection.SchemaRevision.ToString(CultureInfo.InvariantCulture);
                schema = inspection.SchemaVersion.ToString(CultureInfo.InvariantCulture) + "/" + inspection.SchemaRevision.ToString(CultureInfo.InvariantCulture);
                // The closed schema determines identifiers; arbitrary names from a modified database are never interpolated.
                using var expected = new SqliteDatabase(":memory:", readOnly: false);
                expected.Script(Schema.Value);
                var names = expected.Query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';").Select(r => (string)r["name"]!).ToArray();
                var tableRows = ImmutableArray.CreateBuilder<LocalStoreTable>();
                var missing = new List<string>();
                foreach (var name in names)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (!Table(db, name)) { missing.Add(name); continue; }
                    var columns = db.Query("PRAGMA table_info(" + name + ");").Select(r => (string)r["name"]!).ToHashSet(StringComparer.OrdinalIgnoreCase);
                    if (expected.Query("PRAGMA table_info(" + name + ");").Any(r => !columns.Contains((string)r["name"]!))) { missing.Add(name + " (colonnes)"); }
                    tableRows.Add(new(name, (long)db.Scalar("SELECT count(*) FROM " + name + ";")!));
                }
                tables = tableRows.ToImmutable();
                checks["tables"] = new("tables", missing.Count == 0 ? "ok" : "warning", missing.Count == 0 ? "Tables et colonnes du schéma 11 présentes." : "Parties absentes : " + string.Join(", ", missing) + ". Aucune migration effectuée.");
                long? Count(string name) => tables.FirstOrDefault(t => t.Table == name)?.Rows;
                counts = new(Count("ad_objects"), Count("domenia_observations"), Count("domenia_details"), Count("user_machine_links"), Count("domenia_query_recipes"), Count("domenia_store_batches"));
                categories = [.. InspectionCategories.Select(c => new LocalStoreCategory(c.Id, LocalStoreRules.CategoryLabel(c.Id), tables.Where(t => c.Tables.Contains(t.Table, StringComparer.Ordinal)).Sum(t => t.Rows), null))];
                if (Table(db, "sync_state"))
                {
                    scopes = [.. db.Query("SELECT scope,server,base_dn,last_sync,item_count FROM sync_state WHERE scope='directory' OR scope LIKE 'ou:%' OR scope LIKE 'attempt:%' LIMIT 10001;")
                        .Select(r => new LocalStoreScope((string?)r["base_dn"] ?? "", (string?)r["scope"] ?? "", (string?)r["server"] ?? "", "Non conservé dans ce repère", (long?)r["item_count"] ?? 0, ParseStoredDate(r["last_sync"] as string)))];
                    if (scopes.Length > 10000) { throw new InvalidDataException("Plus de 10 000 périmètres : inspection bornée interrompue."); }
                    lastWrite = scopes.Select(s => s.ObservedAt).Max();
                }
                if (measure)
                {
                    var probes = ImmutableArray.CreateBuilder<LocalStoreReadProbe>();
                    foreach (var probe in new[] { ("directoryPage", "ad_objects", "SELECT object_guid,name FROM ad_objects ORDER BY object_type,name LIMIT 200;"),
                        ("activeMachines", "ad_objects", "SELECT object_guid,name FROM ad_objects WHERE object_type='Machine' AND state='Actif' ORDER BY name LIMIT 200;"),
                        ("familyPage", "domenia_observations", "SELECT object_guid,family FROM domenia_observations WHERE family='Presence' LIMIT 200;"),
                        ("textSearch", "ad_objects", "SELECT object_guid FROM ad_objects WHERE name LIKE 'DOM%' LIMIT 200;") })
                    {
                        if (!Table(db, probe.Item2)) { continue; }
                        var timer = Stopwatch.StartNew();
                        var rows = db.Query(probe.Item3);
                        timer.Stop();
                        var plan = string.Join(" · ", db.Query("EXPLAIN QUERY PLAN " + probe.Item3).Select(r => r["detail"] as string));
                        probes.Add(new(probe.Item1, rows.Count, timer.Elapsed.TotalMilliseconds, plan));
                    }
                    lock (inspectionGate)
                    {
                        measuredUsage = new(now, bytes, wal, false, categories, probes.ToImmutable(), watch.ElapsedMilliseconds);
                        measuredSpace = new(new DriveInfo(System.IO.Path.GetPathRoot(Path)!).AvailableFreeSpace, now, 0);
                    }
                }
                if (integrity)
                {
                    var quick = db.Query("PRAGMA quick_check(10);");
                    var healthy = quick.Count == 1 && quick[0].Values.FirstOrDefault() as string == "ok";
                    corrupt = !healthy;
                    checks["quickCheck"] = new("quickCheck", healthy ? "ok" : "failed", healthy ? "SQLite : ok." : "SQLite signale une incohérence ; aucune réparation effectuée.");
                    var foreign = db.Query("PRAGMA foreign_key_check;");
                    checks["foreignKeys"] = new("foreignKeys", foreign.Count == 0 ? "ok" : "failed", foreign.Count == 0 ? "Aucune référence étrangère invalide." : "Références étrangères invalides.");
                    var receiptsBad = Table(db, "domenia_store_batches") && (long)db.Scalar("SELECT count(*) FROM domenia_store_batches WHERE revision<0 OR revision>?1 OR length(payload_hash)<>64;", revision)! > 0;
                    checks["receipts"] = new("receipts", receiptsBad ? "failed" : "warning", receiptsBad ? "En-tête de reçu incohérent." : "En-têtes contrôlés ; contenu des reçus historiques non rejoué ni certifié.");
                    checks["redirect"] = new("redirect", "unknown", "Aucune bascule déduite du seul fichier de base ; aucun emplacement changé.");
                    checks["wal"] = new("wal", "ok", "Journal lu par SQLite dans la même transaction ; aucun checkpoint ni suppression demandé.");
                }
                db.Commit();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
            {
                corrupt = ex is SqliteStoreException sqlite && (sqlite.SqliteCode & 255) is 11 or 26;
                failure = "Inspection locale interrompue : " + ex.Message;
                checks["open"] = new("open", "failed", failure);
            }
        }
        else { checks["open"] = new("open", integrity ? "failed" : "unknown", "Aucune base créée à cet emplacement."); }
        LocalStoreUsage? usage; LocalStoreIntegrity? report; LocalStoreSpace space;
        lock (inspectionGate)
        {
            if (integrity) { measuredIntegrity = new(now, watch.ElapsedMilliseconds, exists && failure is null, [.. LocalStoreRules.CheckLabels.Select(x => checks[x.Id])]); }
            usage = measuredUsage; report = measuredIntegrity; space = measuredSpace;
        }
        var legacyParts = tables.Where(t => t.Rows > 0).Select(t => new LegacyPart(t.Table, t.Table, t.Table, t.Rows, t.Rows, "history")).ToImmutableArray();
        var legacy = new LegacySource(exists, Path, DomainDn, exists ? now : null,
            exists ? new LegacyDatabase(System.IO.Path.GetFileName(Path), Path, legacySchema, legacySchemaRevision, DomainDn, bytes, legacyParts) : null,
            [], [], ImmutableDictionary<string, long>.Empty, "", null, null);
        var registered = ReadRegisteredBackups();
        ImmutableArray<LocalStoreBackup> backups = lastBackup is { } backup && !registered.Any(x => x.FileName == System.IO.Path.GetFileName(backup.Path))
            ? [new(System.IO.Path.GetFileName(backup.Path), System.IO.Path.GetFileName(backup.Path), backup.At, backup.Bytes, backup.Sha256, true, backup.At, "gesture", revision, new(null, null, null, null, null, null), null, null)] : [];
        backups = backups.AddRange(registered);
        return new LocalStoreSnapshot(exists && (failure is null || corrupt), false, DomainDn, Path, StoreId, revision, schema, bytes, wal, lastWrite, counts, categories, tables,
            families, backups, space, new(failure is not null, false, writer.CurrentCount == 0, 0, 0, 0, 0, 0, lastWrite, failure),
            new(false, false, null, corrupt, false, null, false, null), usage, report, scopes, legacy, [], failure, failure is null ? null : now) { NativePurgeTargets = nativePurge };
    }, cancellationToken);
}
