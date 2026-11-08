using System.Collections.Immutable;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
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
        ("observations", ["domenia_observations", "domenia_details", "presence_cache", "park_session_cache", "domenia_v2_fleet_rows", "domenia_v2_fiches", "domenia_v2_query_results"]),
        ("snapshots", ["ad_snapshots", "ad_snapshot_rows", "fleet_snapshots"]),
        ("history", ["user_machine_history", "operation_runs", "domenia_store_batches", "domenia_v2_batches"]),
        ("index", ["ad_objects", "domenia_directory_data", "ad_computer_facts", "domenia_v2_objects", "domenia_v2_directory_branches"]),
        ("manualLinks", ["user_machine_links"]), ("secrets", ["secret_state"]),
    ];

    private Task<LocalStoreSnapshot> InspectLocalStoreCoreAsync(bool measure, bool integrity, CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        var watch = Stopwatch.StartNew();
        var now = clock.GetUtcNow();
        var exists = DatabaseFileExists();
        var bytes = exists ? new FileInfo(Path).Length : 0;
        var wal = File.Exists(Path + "-wal") ? new FileInfo(Path + "-wal").Length : 0;
        var counts = new LocalStoreCounts(null, null, null, null, null, null);
        var tables = ImmutableArray<LocalStoreTable>.Empty;
        var categories = ImmutableArray<LocalStoreCategory>.Empty;
        var scopes = ImmutableArray<LocalStoreScope>.Empty;
        var families = ImmutableArray<LocalStoreFamily>.Empty;
        var nativePurge = ImmutableArray<LocalStorePurgeTarget>.Empty;
        long revision = 0;
        long unmigrated = 0;
        var catalogTruncated = false;
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
                using var db = Open(readOnly: true, cancellationToken: cancellationToken);
                checks["open"] = new("open", "ok", "Ouverte en lecture seule.");
                CheckIdentity(db, allowLegacy: !(measure || integrity));
                checks["identity"] = new("identity", "ok", "Domaine et emplacement de la base vérifiés.");
                checks["schema"] = new("schema", "ok", "Schéma local Domenia reconnu, version 11.");
                db.Begin(write: false);
                var inspection = Inspect(db);
                var retention = ReadRetentionInventory(db, cancellationToken, fingerprint: false);
                families = RetentionFamilies(retention, WritePlans.TruncateToSecond(now));
                unmigrated = retention.UnmigratedObservations;
                nativePurge = ReadPurgeSummary(db, retention.Fleet, WritePlans.TruncateToSecond(now), cancellationToken);
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
                // Native projections are not part of the immutable D1 schema; count only this closed extra list.
                foreach (var name in NativeInspectionTables)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (!names.Contains(name, StringComparer.Ordinal) && Table(db, name))
                        tableRows.Add(new(name, (long)db.Scalar("SELECT count(*) FROM " + name + ";")!));
                }
                tables = tableRows.ToImmutable();
                checks["tables"] = new("tables", missing.Count == 0 ? "ok" : "warning", missing.Count == 0 ? "Tables et colonnes du schéma 11 présentes." : "Parties absentes : " + string.Join(", ", missing) + ". Aucune migration effectuée.");
                long? Count(string name) => tables.FirstOrDefault(t => t.Table == name)?.Rows;
                counts = new(Count("ad_objects"), Count("domenia_observations"), Count("domenia_details"), Count("user_machine_links"), Count("domenia_query_recipes"), Count("domenia_store_batches"));
                categories = [.. InspectionCategories.Select(c => new LocalStoreCategory(c.Id, LocalStoreRules.CategoryLabel(c.Id), tables.Where(t => c.Tables.Contains(t.Table, StringComparer.Ordinal)).Sum(t => t.Rows), null))];
                if (Table(db, "sync_state"))
                {
                    var rows = db.Query("SELECT scope,server,base_dn,last_sync,item_count,details FROM sync_state WHERE scope='directory' OR scope LIKE 'ou:%' OR scope LIKE 'attempt:%' ORDER BY last_sync DESC,scope LIMIT 10001;");
                    catalogTruncated = rows.Count > 10000;
                    scopes = [.. rows.Take(10000).Select(ReadCatalogScope)];
                    lastWrite = scopes.Select(s => s.ObservedAt).Max();
                }
                if (measure)
                {
                    var allocation = MeasureAllocatedBytes(db);
                    tables = [.. tables.Select(t => t with { Bytes = allocation.Available ? allocation.Bytes.GetValueOrDefault(t.Table) : null })];
                    categories = [.. categories.Select(c => c with { Bytes = allocation.Available ? InspectionCategories.First(x => x.Id == c.Id).Tables.Sum(t => allocation.Bytes.GetValueOrDefault(t)) : null })];
                    var assigned = InspectionCategories.SelectMany(c => c.Tables).ToHashSet(StringComparer.Ordinal);
                    if (allocation.Available) { categories = categories.Add(new("other", "Autres tables et métadonnées", 0, allocation.Bytes.Where(x => !assigned.Contains(x.Key)).Sum(x => x.Value))); }
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
                        measuredUsage = new(now, bytes, wal, allocation.Available, categories, probes.ToImmutable(), watch.ElapsedMilliseconds) { SizeNote = allocation.Note, Tables = tables };
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
                    checks["receipts"] = CheckReceiptHeaders(db, revision);
                    checks["redirect"] = new("redirect", "unknown", "Le contrôle du marqueur exige le gestionnaire de la base active ; aucun emplacement déduit du fichier seul.");
                    checks["wal"] = ReadJournalCheck(db);
                }
                db.Commit();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or InvalidDataException or JsonException)
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
            exists ? new LegacyDatabase(System.IO.Path.GetFileName(Path), Path, legacySchema, legacySchemaRevision, DomainDn, bytes, legacyParts)
            { Active = true, Notice = System.IO.Path.GetFileName(Path).Equals("ADCC.db", StringComparison.OrdinalIgnoreCase)
                ? "Base ADCC adoptée sur place comme base active ; les évolutions de schéma sont précédées d’une sauvegarde. Ce fichier peut recevoir les nouvelles collectes."
                : "Base active de la session, inspectée localement. Elle peut recevoir les nouvelles collectes ; ce n’est pas une source D1 distincte." } : null,
            [], [], ImmutableDictionary<string, long>.Empty, "", null, null);
        var registered = ReadRegisteredBackups();
        ImmutableArray<LocalStoreBackup> backups = lastBackup is { } backup && !registered.Any(x => x.FileName == System.IO.Path.GetFileName(backup.Path))
            ? [new(System.IO.Path.GetFileName(backup.Path), System.IO.Path.GetFileName(backup.Path), backup.At, backup.Bytes, backup.Sha256, true, backup.At, "gesture", revision, new(null, null, null, null, null, null), null, null)] : [];
        backups = backups.AddRange(registered);
        return new LocalStoreSnapshot(exists && (failure is null || corrupt), false, DomainDn, Path, StoreId, revision, schema, bytes, wal, lastWrite, counts, categories, tables,
            families, backups, ActualWriterSpace(space), ActualWriterState(failure is not null),
            new(false, false, null, corrupt, false, null, false, null), usage, report, scopes, legacy, [], failure, failure is null ? null : now) { NativePurgeTargets = nativePurge, UnmigratedObservations = unmigrated, CatalogTruncated = catalogTruncated };
    }, cancellationToken);
}
