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
    private sealed record RetentionEntry(string Key, string Table, long RowId, string Family, DateTimeOffset? At, bool Repeated);
    private sealed record RetentionInventory(long Revision, string Fingerprint, ImmutableArray<RetentionEntry> Entries, CachedFleet Fleet, long UnmigratedObservations);

    private RetentionInventory ReadRetentionInventory(SqliteDatabase db, CancellationToken token, bool fingerprint = true)
    {
        var entries = ImmutableArray.CreateBuilder<RetentionEntry>();
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        void Hash(string label, byte[] bytes) { digest.AppendData(Encoding.UTF8.GetBytes(label + "\n")); digest.AppendData(bytes); digest.AppendData([10]); }
        var revision = Table(db, "domenia_store_state") ? (long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") ?? 0 : 0;
        Hash("identity", Encoding.UTF8.GetBytes(StoreId + "\n" + revision.ToString(CultureInfo.InvariantCulture)));
        long bytesRead = 0;
        IReadOnlyList<Dictionary<string, object?>> Rows(string table)
        {
            if (!Table(db, table)) { return []; }
            var count = (long)db.Scalar("SELECT count(*) FROM " + table + ";")!;
            if (count > 100_000) { throw new InvalidDataException("Plus de 100 000 lignes dans une famille ; aucune conservation partielle proposée."); }
            // Opening Settings needs ages and counts, not the payloads or a destructive-operation proof.
            // The complete rows are still read and hashed when an actual retention plan is prepared or checked.
            string[] columns = fingerprint ? db.Query("PRAGMA table_info(" + table + ");").Select(x => (string)x["name"]!).ToArray()
                : table switch
                {
                    "domenia_legacy_observation_imports" => ["object_guid"],
                    "domenia_observations" => ["object_guid", "family", "attempt_at", "success_at"],
                    "domenia_details" => ["attempt_at", "success_at"],
                    "user_machine_links" => ["source", "computer_key"],
                    "user_machine_history" => ["computer_key", "source", "observed_at", "user_login", "user_guid"],
                    _ => throw new InvalidOperationException("Table de synthèse non qualifiée."),
                };
            if (columns.Length > 64) { throw new InvalidDataException("Table de conservation non qualifiée."); }
            static string Quote(string value) => "\"" + value.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
            var safe = string.Join(" AND ", columns.Select(c => "(COALESCE(length(CAST(" + Quote(c) + " AS BLOB)),0)<=262144)"));
            var projection = "rowid AS _retention_row,CASE WHEN " + safe + " THEN 1 ELSE 0 END AS _retention_valid,"
                + string.Join(',', columns.Select(c => "CASE WHEN " + safe + " THEN " + Quote(c) + " ELSE NULL END AS " + Quote(c)));
            var result = new List<Dictionary<string, object?>>();
            long? after = null;
            while (true)
            {
                token.ThrowIfCancellationRequested();
                var rows = after is null
                    ? db.Query("SELECT " + projection + " FROM " + table + " ORDER BY rowid LIMIT 128;")
                    : db.Query("SELECT " + projection + " FROM " + table + " WHERE rowid>?1 ORDER BY rowid LIMIT 128;", after.Value);
                if (rows.Count == 0) { break; }
                foreach (var row in rows)
                {
                    if (row["_retention_valid"] is not 1L) { throw new InvalidDataException("Ligne de conservation trop volumineuse ; aucune suppression proposée."); }
                    if (fingerprint)
                    {
                        var raw = JsonSerializer.SerializeToUtf8Bytes(row, Json); bytesRead += raw.Length;
                        if (bytesRead > 64L * 1024 * 1024) { throw new InvalidDataException("Inventaire de conservation supérieur à 64 Mio ; aucune lecture partielle acceptée."); }
                        Hash(table, raw);
                    }
                    after = (long)row["_retention_row"]!;
                    result.Add(row);
                }
            }
            return result;
        }
        static string? Text(Dictionary<string, object?> row, string key) => row.GetValueOrDefault(key) as string;
        DateTimeOffset? LastDate(Dictionary<string, object?> row, params string[] keys)
        {
            var dates = new List<DateTimeOffset>();
            foreach (var key in keys)
            {
                if (Text(row, key) is not { Length: > 0 } text) { continue; }
                if (ParseStoredDate(text) is not { } at) { return null; }
                dates.Add(at);
            }
            return dates.Count == 0 ? null : dates.Max();
        }
        var imported = Rows("domenia_legacy_observation_imports").Select(x => Text(x, "object_guid")).ToHashSet(StringComparer.OrdinalIgnoreCase);
        long unmigrated = 0;
        foreach (var row in Rows("domenia_observations"))
        {
            if (!imported.Contains(Text(row, "object_guid"))) { unmigrated++; continue; }
            var rawFamily = Text(row, "family") ?? "";
            var family = rawFamily.StartsWith("Probe:", StringComparison.OrdinalIgnoreCase) ? "probe" : rawFamily.ToLowerInvariant();
            if (family is not ("presence" or "console" or "inventory" or "probe")) { continue; }
            var id = (long)row["_retention_row"]!;
            entries.Add(new("domenia_observations:" + id, "domenia_observations", id, family, LastDate(row, "attempt_at", "success_at"), false));
        }
        foreach (var row in Rows("domenia_details"))
        {
            var id = (long)row["_retention_row"]!;
            entries.Add(new("domenia_details:" + id, "domenia_details", id, "detail", LastDate(row, "attempt_at", "success_at"), false));
        }
        var protectedComputers = Rows("user_machine_links").Where(x => RelationRules.IsProtectedSource(Text(x, "source")))
            .Select(x => (Text(x, "computer_key") ?? "").Trim()).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var history = Rows("user_machine_history");
        foreach (var group in history.GroupBy(x => Text(x, "computer_key") ?? "", StringComparer.OrdinalIgnoreCase))
        {
            var ordered = group.Select(x => (Row: x, At: LastDate(x, "observed_at"))).Where(x => x.At is not null)
                .OrderBy(x => x.At).ThenBy(x => (long)x.Row["_retention_row"]!).ToArray();
            static string Who(Dictionary<string, object?> row) => ((row.GetValueOrDefault("user_login") as string ?? "") + "\u001f" + (row.GetValueOrDefault("user_guid") as string ?? "")).ToLowerInvariant();
            for (var i = 0; i < ordered.Length; i++)
            {
                var (row, at) = ordered[i]; var id = (long)row["_retention_row"]!;
                var protectedRow = protectedComputers.Contains(group.Key.Trim()) || RelationRules.IsProtectedSource(Text(row, "source"));
                var repeated = !protectedRow && i > 0 && i < ordered.Length - 1 && !string.IsNullOrWhiteSpace(Text(row, "user_login"))
                    && Who(row) == Who(ordered[i - 1].Row) && Who(row) == Who(ordered[i + 1].Row);
                entries.Add(new("user_machine_history:" + id, "user_machine_history", id, "linkHistory", protectedRow ? null : at, repeated));
            }
        }
        CachedFleet fleet;
        if (Table(db, "domenia_v2_metadata"))
        {
            var stored = db.Query("SELECT CASE WHEN length(payload)<=33554432 THEN payload ELSE NULL END AS payload FROM domenia_v2_metadata WHERE key='fleet';").SingleOrDefault();
            var raw = stored is null ? null : stored["payload"] as string ?? throw new InvalidDataException("Cache natif supérieur à 32 Mio ; conservation refusée.");
            if (fingerprint) { Hash("fleet", Encoding.UTF8.GetBytes(raw ?? "")); }
            if (IsRowsFleet(raw))
            {
                fleet = ReadFleetRows(db, raw!);
                if (fingerprint)
                {
                    foreach (var (key, kind, payload) in FleetStoredRows(db))
                    { token.ThrowIfCancellationRequested(); Hash("fleet:" + kind + ":" + key, Encoding.UTF8.GetBytes(payload)); }
                }
            }
            else { fleet = DecodeFleet(raw); }
        }
        else { fleet = CachedFleet.Empty(StoreId); Hash("fleet", []); }
        if (fleet.Facts.StoreId != StoreId) { throw new InvalidDataException("Cache natif d’une autre base."); }
        _ = StorageFleetRetention.Transform(fleet, (key, family, at) => { entries.Add(new(key, "fleet", 0, family, at, false)); return false; });
        return new(revision, Convert.ToHexStringLower(digest.GetHashAndReset()), entries.ToImmutable(), fleet, unmigrated);
    }

    private static ImmutableArray<LocalStoreFamily> RetentionFamilies(RetentionInventory inventory, DateTimeOffset now)
    {
        return [.. StoragePolicyRules.Families.Select(family =>
        {
            var all = new int[StoragePolicyRules.MaxRetentionDays + 1]; var repeated = new int[all.Length];
            foreach (var entry in inventory.Entries.Where(x => x.Family == family.Family && x.At is not null && x.At <= now))
            {
                var age = (int)Math.Min(StoragePolicyRules.MaxRetentionDays, Math.Floor((now - entry.At!.Value).TotalDays));
                all[age]++; if (entry.Repeated) { repeated[age]++; }
            }
            return new LocalStoreFamily(family.Family, [.. all], [.. repeated]);
        })];
    }
}
