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
    private sealed record RetentionInventory(long Revision, string Fingerprint, ImmutableArray<RetentionEntry> Entries, CachedFleet Fleet);

    private RetentionInventory ReadRetentionInventory(SqliteDatabase db, CancellationToken token)
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
            var columns = db.Query("PRAGMA table_info(" + table + ");").Select(x => (string)x["name"]!).ToArray();
            if (columns.Length > 64) { throw new InvalidDataException("Table de conservation non qualifiée."); }
            static string Quote(string value) => "\"" + value.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
            var safe = string.Join(" AND ", columns.Select(c => "(COALESCE(length(CAST(" + Quote(c) + " AS BLOB)),0)<=262144)"));
            var projection = "rowid AS _retention_row,CASE WHEN " + safe + " THEN 1 ELSE 0 END AS _retention_valid,"
                + string.Join(',', columns.Select(c => "CASE WHEN " + safe + " THEN " + Quote(c) + " ELSE NULL END AS " + Quote(c)));
            var result = new List<Dictionary<string, object?>>();
            for (var offset = 0; offset < count; offset += 128)
            {
                token.ThrowIfCancellationRequested();
                foreach (var row in db.Query("SELECT " + projection + " FROM " + table + " ORDER BY rowid LIMIT 128 OFFSET ?1;", offset))
                {
                    if (row["_retention_valid"] is not 1L) { throw new InvalidDataException("Ligne de conservation trop volumineuse ; aucune suppression proposée."); }
                    var raw = JsonSerializer.SerializeToUtf8Bytes(row, Json); bytesRead += raw.Length;
                    if (bytesRead > 64L * 1024 * 1024) { throw new InvalidDataException("Inventaire de conservation supérieur à 64 Mio ; aucune lecture partielle acceptée."); }
                    Hash(table, raw); result.Add(row);
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
        foreach (var row in Rows("domenia_observations"))
        {
            var rawFamily = Text(row, "family") ?? "";
            var family = rawFamily.StartsWith("Probe:", StringComparison.OrdinalIgnoreCase) ? "probe" : rawFamily.ToLowerInvariant();
            if (family is not ("presence" or "console" or "inventory" or "probe") || !imported.Contains(Text(row, "object_guid"))) { continue; }
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
            Hash("fleet", Encoding.UTF8.GetBytes(raw ?? ""));
            fleet = raw is null ? CachedFleet.Empty(StoreId) : JsonSerializer.Deserialize<CachedFleet>(raw, Json) ?? throw new InvalidDataException("Cache natif illisible.");
        }
        else { fleet = CachedFleet.Empty(StoreId); Hash("fleet", []); }
        if (fleet.Facts.StoreId != StoreId) { throw new InvalidDataException("Cache natif d’une autre base."); }
        _ = StorageFleetRetention.Transform(fleet, (key, family, at) => { entries.Add(new(key, "fleet", 0, family, at, false)); return false; });
        return new(revision, Convert.ToHexStringLower(digest.GetHashAndReset()), entries.ToImmutable(), fleet);
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
