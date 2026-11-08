using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    // Counts displayed in Settings are not authorization to delete. PrepareStoragePurgeAsync reads and hashes the
    // complete inventory again. In particular, a large cached JSON document must not make this read-only page fail.
    private ImmutableArray<LocalStorePurgeTarget> ReadPurgeSummary(SqliteDatabase db, CachedFleet fleet, DateTimeOffset now, CancellationToken token)
    {
        ValidatePurgeCatalog();
        var protectedKeys = ReadSummaryRows("user_machine_links", ["computer_key", "source"])
            .Where(row => RelationRules.IsProtectedSource(row["source"] as string))
            .Select(row => ((string?)row["computer_key"] ?? "").Trim()).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var result = ImmutableArray.CreateBuilder<LocalStorePurgeTarget>();
        foreach (var target in NativePurgeTables)
        {
            token.ThrowIfCancellationRequested();
            var table = target.Table.Split('.')[0];
            long count = 0;
            var days = target.Category == "history" ? new int[StoragePolicyRules.MaxRetentionDays + 1] : [];
            if (target.Table == "fleet.measurements") { count = NativeMeasurementCount(fleet) > 0 ? 1 : 0; }
            else if (target.Table == "fleet.directoryClocks") { count = fleet.Facts.Runs.Any(x => x.Family == CollectionFamily.Directory) ? 1 : 0; }
            else if (Table(db, table))
            {
                if (target.Category == "history")
                {
                    var date = table switch { "user_machine_history" => "observed_at", "user_scan_history" => "scanned_at", "operation_runs" => "finished_at", _ => "snapshot_day" };
                    string[] columns = table == "user_machine_history" ? new[] { date, "computer_key", "source" } : [date];
                    foreach (var row in ReadSummaryRows(table, columns))
                    {
                        if (table == "user_machine_history" && (RelationRules.IsProtectedSource(row["source"] as string)
                            || protectedKeys.Contains(((string?)row["computer_key"] ?? "").Trim()))) { continue; }
                        count++;
                        if (ParseStoredDate(row[date] as string) is { } at && at <= now)
                        { days[(int)Math.Min(StoragePolicyRules.MaxRetentionDays, Math.Floor((now - at).TotalDays))]++; }
                    }
                }
                else
                {
                    var where = target.Table switch
                    {
                        "domenia_domain_metadata.collection" => " WHERE family IN ('Presence','Inventory')",
                        "domenia_domain_metadata.directory" => " WHERE family='Directory'",
                        "domenia_v2_metadata.directory" => " WHERE key='directory'",
                        "sync_state" => " WHERE scope='directory' OR scope GLOB 'ou:*' OR scope GLOB 'attempt:*'",
                        _ => "",
                    };
                    count = (long)db.Scalar("SELECT count(*) FROM " + table + where + ";")!;
                }
            }
            result.Add(new(target.Category, target.Table, target.Action, target.Label, count, [.. days]));
        }
        return result.ToImmutable();

        IEnumerable<Dictionary<string, object?>> ReadSummaryRows(string table, string[] columns)
        {
            if (!Table(db, table)) { yield break; }
            var count = (long)db.Scalar("SELECT count(*) FROM " + table + ";")!;
            if (count > 300_000) { throw new InvalidDataException("Synthèse de stockage limitée à 300 000 lignes par table ; aucun compte partiel affiché."); }
            // Every identifier above is a fixed, internal schema column. Only the narrow date/source keys are loaded.
            var safe = string.Join(" AND ", columns.Select(c => "COALESCE(length(CAST(" + c + " AS BLOB)),0)<=262144"));
            var projection = "rowid AS summary_row,CASE WHEN " + safe + " THEN 1 ELSE 0 END AS summary_valid,"
                + string.Join(',', columns.Select(c => "CASE WHEN " + safe + " THEN " + c + " ELSE NULL END AS " + c));
            long? after = null;
            while (true)
            {
                token.ThrowIfCancellationRequested();
                var rows = after is null
                    ? db.Query("SELECT " + projection + " FROM " + table + " ORDER BY rowid LIMIT 128;")
                    : db.Query("SELECT " + projection + " FROM " + table + " WHERE rowid>?1 ORDER BY rowid LIMIT 128;", after.Value);
                if (rows.Count == 0) { yield break; }
                foreach (var row in rows)
                {
                    if (row["summary_valid"] is not 1L) { throw new InvalidDataException("Clé de synthèse trop volumineuse ; aucun compte partiel affiché."); }
                    after = (long)row["summary_row"]!;
                    yield return row;
                }
            }
        }
    }
}
