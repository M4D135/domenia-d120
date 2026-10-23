using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private sealed record PurgeEntry(string Key, string Category, string Table, string Action, long RowId, DateTimeOffset? At);
    private sealed record PurgeInventory(long Revision, string Fingerprint, long SweepGeneration, CachedFleet Fleet, ImmutableArray<PurgeEntry> Entries);
    private static readonly (string Category, string Table, string Action, string Label)[] NativePurgeTables =
    [
        ("observations", "adcc_live_observations", "delete", "Mesures historiques"),
        ("observations", "domenia_observations", "delete", "Mesures par famille"),
        ("observations", "domenia_details", "delete", "Résultats détaillés"),
        ("observations", "presence_cache", "delete", "Présence en cache"),
        ("observations", "park_state", "delete", "État du parc"),
        ("observations", "park_session_cache", "delete", "Sessions en cache"),
        ("observations", "domenia_domain_metadata.collection", "delete", "Horloges des collectes"),
        ("observations", "fleet.measurements", "clear", "Relevés natifs, hors métadonnées de sécurité"),
        ("snapshots", "adcc_live_queries", "delete", "Instantanés des recherches"),
        ("history", "user_machine_history", "delete", "Historique hors associations déclarées"),
        ("history", "user_scan_history", "delete", "Relevés d’utilisateurs"),
        ("history", "operation_runs", "delete", "Exécutions d’opérations historiques"),
        ("history", "fleet_snapshots", "delete", "Instantanés quotidiens du parc"),
        ("index", "ad_objects", "delete", "Objets AD"),
        ("index", "domenia_directory_data", "delete", "Données AD"),
        ("index", "ad_computer_facts", "delete", "Faits AD"),
        ("index", "domenia_provenance", "delete", "Provenance AD"),
        ("index", "ad_absences", "delete", "Objets non revus"),
        ("index", "ad_census_gaps", "delete", "Écarts de recensement"),
        ("index", "ad_snapshot_rows", "delete", "Lignes des relevés AD"),
        ("index", "ad_snapshots", "delete", "Relevés AD"),
        ("index", "domenia_v2_objects", "delete", "Objets natifs AD"),
        ("index", "domenia_v2_fiches", "delete", "Fiches natives AD"),
        ("index", "domenia_v2_metadata.directory", "delete", "En-tête du cache AD"),
        ("index", "domenia_domain_metadata.directory", "delete", "Horloges AD"),
        ("index", "fleet.directoryClocks", "clear", "Horloges natives AD"),
        ("index", "sync_state", "reset", "Points de reprise AD"),
    ];

    private PurgeInventory ReadPurgeInventory(SqliteDatabase db, CancellationToken token)
    {
        var retention = ReadRetentionInventory(db, token);
        var entries = ImmutableArray.CreateBuilder<PurgeEntry>();
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        void Hash(string label, byte[] raw) { digest.AppendData(Encoding.UTF8.GetBytes(label + "\n")); digest.AppendData(raw); digest.AppendData([10]); }
        Hash("measures", Encoding.UTF8.GetBytes(retention.Fingerprint));
        var generation = Table(db, "domenia_v2_sweep_state") ? (long?)db.Scalar("SELECT generation FROM domenia_v2_sweep_state WHERE id=1;") ?? 0 : 0;
        Hash("sweep", Encoding.UTF8.GetBytes(generation.ToString(CultureInfo.InvariantCulture)));
        long bytes = 0;
        var protectedKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        IEnumerable<Dictionary<string, object?>> Rows(string table)
        {
            if (!Table(db, table)) { yield break; }
            var where = table == "domenia_v2_metadata" ? " WHERE key='directory'" : "";
            var count = (long)db.Scalar("SELECT count(*) FROM " + table + where + ";")!;
            if (count > 300_000) { throw new InvalidDataException("Inventaire de purge limité à 300 000 lignes par table ; aucune purge partielle."); }
            var columns = db.Query("PRAGMA table_info(" + table + ");").Select(x => (string)x["name"]!).ToArray();
            if (columns.Length > 64) { throw new InvalidDataException("Table de purge non qualifiée."); }
            static string Quote(string value) => "\"" + value.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
            var valid = string.Join(" AND ", columns.Select(c => "(COALESCE(length(CAST(" + Quote(c) + " AS BLOB)),0)<=262144)"));
            var projection = "rowid AS _purge_row,CASE WHEN " + valid + " THEN 1 ELSE 0 END AS _purge_valid,"
                + string.Join(',', columns.Select(c => "CASE WHEN " + valid + " THEN " + Quote(c) + " ELSE NULL END AS " + Quote(c)));
            for (var offset = 0; offset < count; offset += 128)
            {
                token.ThrowIfCancellationRequested();
                foreach (var row in db.Query("SELECT " + projection + " FROM " + table + where + " ORDER BY rowid LIMIT 128 OFFSET ?1;", offset))
                {
                    if (row["_purge_valid"] is not 1L) { throw new InvalidDataException("Ligne trop volumineuse ; aucune purge partielle."); }
                    var raw = JsonSerializer.SerializeToUtf8Bytes(row, Json); bytes += raw.Length;
                    if (bytes > 128L * 1024 * 1024) { throw new InvalidDataException("Inventaire de purge supérieur à 128 Mio ; aucune purge partielle."); }
                    Hash(table, raw); yield return row;
                }
            }
        }
        static string? Text(Dictionary<string, object?> row, string key) => row.GetValueOrDefault(key) as string;
        foreach (var row in Rows("user_machine_links"))
        { if (RelationRules.IsProtectedSource(Text(row, "source"))) { protectedKeys.Add((Text(row, "computer_key") ?? "").Trim()); } }
        foreach (var group in NativePurgeTables.Where(x => !x.Table.StartsWith("fleet.", StringComparison.Ordinal)).GroupBy(x => x.Table.Split('.')[0]))
        {
            var table = group.Key;
            foreach (var row in Rows(table))
            {
                var target = group.FirstOrDefault(x => x.Table switch
                {
                    "domenia_domain_metadata.collection" => Text(row, "family") is "Presence" or "Inventory",
                    "domenia_domain_metadata.directory" => Text(row, "family") == "Directory",
                    "domenia_v2_metadata.directory" => Text(row, "key") == "directory",
                    _ => true,
                });
                if (target.Table is null) { continue; }
                DateTimeOffset? at = null;
                if (target.Category == "history")
                {
                    if (table == "user_machine_history" && (RelationRules.IsProtectedSource(Text(row, "source")) || protectedKeys.Contains((Text(row, "computer_key") ?? "").Trim()))) { continue; }
                    var field = table switch { "user_machine_history" => "observed_at", "user_scan_history" => "scanned_at", "operation_runs" => "finished_at", _ => "snapshot_day" };
                    at = ParseStoredDate(Text(row, field));
                }
                if (target.Action == "reset")
                {
                    var scope = Text(row, "scope") ?? "";
                    if (scope != "directory" && !scope.StartsWith("ou:", StringComparison.Ordinal) && !scope.StartsWith("attempt:", StringComparison.Ordinal)) { continue; }
                }
                var id = (long)row["_purge_row"]!;
                entries.Add(new(target.Table + ":" + id, target.Category, target.Table, target.Action, id, at));
            }
        }
        if (NativeMeasurementCount(retention.Fleet) > 0) { entries.Add(new("fleet.measurements", "observations", "fleet.measurements", "clear", 0, null)); }
        if (retention.Fleet.Facts.Runs.Any(x => x.Family == CollectionFamily.Directory))
        { entries.Add(new("fleet.directoryClocks", "index", "fleet.directoryClocks", "clear", 0, null)); }
        return new(retention.Revision, Convert.ToHexStringLower(digest.GetHashAndReset()), generation, retention.Fleet, entries.ToImmutable());
    }

    private static int NativeMeasurementCount(CachedFleet fleet) => fleet.Observations.Workstations.Length + fleet.Facts.Machines.Count
        + fleet.Probes.ByProbe.Values.Sum(x => x.Count) + fleet.Addresses.Count + fleet.Inventories.Count + fleet.WorkstationProbes.Count
        + fleet.WorkstationSessions.Count + fleet.Facts.Runs.Count(x => x.Family != CollectionFamily.Directory) + fleet.Facts.RejectedObservations;

    private static ImmutableArray<LocalStorePurgeTarget> PurgeTargets(PurgeInventory inventory, DateTimeOffset now) => [.. NativePurgeTables.Select(target =>
    {
        var selected = inventory.Entries.Where(x => x.Table == target.Table).ToArray();
        var days = target.Category == "history" ? new int[StoragePolicyRules.MaxRetentionDays + 1] : [];
        foreach (var entry in selected.Where(x => x.At is not null && x.At <= now))
        { days[(int)Math.Min(StoragePolicyRules.MaxRetentionDays, Math.Floor((now - entry.At!.Value).TotalDays))]++; }
        return new LocalStorePurgeTarget(target.Category, target.Table, target.Action, target.Label, selected.LongLength, [.. days]);
    })];
}
