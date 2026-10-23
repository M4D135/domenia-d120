using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    public Task<RelationSweepCacheSnapshot> ReadRelationSweepsAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return EmptySweeps(); }
        using var db = new SqliteDatabase(Path, true, cancellationToken: cancellationToken);
        db.Begin(false); CheckIdentity(db, true);
        var result = ReadRelationSweeps(db, cancellationToken); db.Commit(); return result;
    }, cancellationToken);

    private RelationSweepCacheSnapshot EmptySweeps() => new(StoreId, DomainDn, [], 0, 0, 0, false,
        Convert.ToHexStringLower(SHA256.HashData([])), "Aucun relevé enregistré dans park_state.");

    private RelationSweepCacheSnapshot ReadRelationSweeps(SqliteDatabase db, CancellationToken token)
    {
        var generation = ReadSweepGeneration(db);
        if (!Table(db, "park_state")) { return EmptySweeps() with { Generation = generation }; }
        var columns = db.Query("PRAGMA table_info(park_state);").Select(r => (string)r["name"]!).Order(StringComparer.Ordinal).ToArray();
        if (columns.Length > 40 || columns.Any(c => c.Length > 128 || c.Any(char.IsControl) || c.Equals("v2_invalid_sweep_cell", StringComparison.OrdinalIgnoreCase))
            || new[] { "computer_key", "computer", "last_probe", "status", "user_login", "attempts" }.Any(c => !columns.Contains(c, StringComparer.OrdinalIgnoreCase)))
        { throw new InvalidDataException("Schéma park_state incompatible ; aucune lecture partielle interprétée ni migration."); }
        static string Quote(string name) => "\"" + name.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
        var limits = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
        { ["computer_key"] = 1024, ["computer"] = 255, ["computer_guid"] = 40, ["computer_dn"] = 4096, ["last_probe"] = 100, ["status"] = 128, ["user_login"] = 320 };
        var valid = new List<string>(); var projection = new List<string>();
        foreach (var column in columns)
        {
            var q = Quote(column);
            var condition = column.Equals("attempts", StringComparison.OrdinalIgnoreCase)
                ? "typeof(" + q + ")='integer' AND " + q + " BETWEEN 0 AND 2147483647"
                : limits.TryGetValue(column, out var limit) ? "(" + q + " IS NULL OR (typeof(" + q + ")='text' AND length(" + q + ")<=" + limit.ToString(CultureInfo.InvariantCulture) + "))"
                : "(length(CAST(" + q + " AS BLOB))<=32768 OR " + q + " IS NULL) AND (typeof(" + q + ")<>'real' OR " + q + " BETWEEN -1.7976931348623157e308 AND 1.7976931348623157e308)";
            valid.Add("(" + condition + ")");
        }
        valid.Add("(" + string.Join('+', columns.Select(c => "COALESCE(length(CAST(" + Quote(c) + " AS BLOB)),0)")) + ")<=32768");
        var safe = string.Join(" AND ", valid);
        foreach (var column in columns) { projection.Add("CASE WHEN " + safe + " THEN " + Quote(column) + " ELSE NULL END AS " + Quote(column)); }
        projection.Add("CASE WHEN " + safe + " THEN 0 ELSE 1 END AS v2_invalid_sweep_cell");
        var total = (long)db.Scalar("SELECT count(*) FROM park_state;")!;
        var rows = ImmutableArray.CreateBuilder<RelationSweepRecord>(); var rejected = 0; var uncertain = 0; long bytes = 0;
        var count = 0; var truncated = total > 50_000;
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        while (count < total && count < 50_000)
        {
            token.ThrowIfCancellationRequested();
            var page = db.Query("SELECT " + string.Join(',', projection) + " FROM park_state ORDER BY computer_key COLLATE BINARY LIMIT ?1 OFFSET ?2;", Math.Min(256, 50_000 - count), count);
            if (page.Count == 0) { break; }
            foreach (var row in page)
            {
                count++;
                var raw = JsonSerializer.SerializeToUtf8Bytes(row); bytes += raw.Length;
                if (bytes > 16L * 1024 * 1024) { truncated = true; break; }
                hash.AppendData(raw); hash.AppendData([10]);
                string? Text(string key) => row.GetValueOrDefault(key) as string;
                var key = Text("computer_key"); var name = Text("computer"); var dn = Text("computer_dn"); var idText = Text("computer_guid");
                Guid? guid = null;
                if ((long)row["v2_invalid_sweep_cell"]! != 0 || string.IsNullOrWhiteSpace(key) || key.Any(char.IsControl)
                    || string.IsNullOrWhiteSpace(name) || name.Any(char.IsControl) || Text("status")?.Any(char.IsControl) == true
                    || Text("user_login")?.Any(char.IsControl) == true
                    || !string.IsNullOrWhiteSpace(idText) && (!Guid.TryParse(idText, out var parsed) || parsed == Guid.Empty))
                { rejected++; continue; }
                if (!string.IsNullOrWhiteSpace(idText)) { guid = Guid.Parse(idText); }
                try { if (!string.IsNullOrWhiteSpace(dn) && !InDomain(dn)) { rejected++; continue; } }
                catch (FormatException) { rejected++; continue; }
                var date = RelationRules.ParseStoredWhen(Text("last_probe"), clock.LocalTimeZone);
                if (date == DateTimeOffset.MinValue || date > clock.GetUtcNow().AddMinutes(2)) { date = null; }
                if (date is null && !string.IsNullOrWhiteSpace(Text("last_probe"))) { uncertain++; }
                var preserved = row.Where(p => !p.Key.Equals("computer", StringComparison.OrdinalIgnoreCase) && !p.Key.Equals("computer_guid", StringComparison.OrdinalIgnoreCase)
                    && !p.Key.Equals("computer_dn", StringComparison.OrdinalIgnoreCase) && !p.Key.Equals("last_probe", StringComparison.OrdinalIgnoreCase)
                    && !p.Key.Equals("status", StringComparison.OrdinalIgnoreCase) && !p.Key.Equals("user_login", StringComparison.OrdinalIgnoreCase) && !p.Key.Equals("attempts", StringComparison.OrdinalIgnoreCase))
                    .ToDictionary(p => p.Key, p => p.Value, StringComparer.OrdinalIgnoreCase);
                rows.Add(new(key, Convert.ToHexStringLower(SHA256.HashData(raw)), name, guid, string.IsNullOrWhiteSpace(dn) ? null : dn,
                    date, Text("status") ?? "", Text("user_login"), checked((int)(long)row["attempts"]!))
                { PreservedFingerprint = Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(preserved))) });
            }
            if (bytes > 16L * 1024 * 1024) { break; }
        }
        return new(StoreId, DomainDn, rows.ToImmutable(), total, rejected, uncertain, truncated, Convert.ToHexStringLower(hash.GetHashAndReset()),
            FrenchText.Count(rows.Count, "relevé D1 lu", "relevés D1 lus") + ". "
            + (rejected > 0 ? FrenchText.Count(rejected, "ligne invalide conservée dans la base", "lignes invalides conservées dans la base") + ". " : "")
            + (uncertain > 0 ? FrenchText.Count(uncertain, "date non qualifiée", "dates non qualifiées") + ". " : "")
            + (truncated ? "Lecture partielle : 50 000 lignes ou 16 Mio au plus. " : "")
            + "Aucun GUID déduit d’un ancien nom de poste.") { Generation = generation };
    }

    private static long ReadSweepGeneration(SqliteDatabase db)
    {
        if (!Table(db, "domenia_v2_sweep_state")) { return 0; }
        var rows = db.Query("SELECT id,generation FROM domenia_v2_sweep_state LIMIT 2;");
        if (rows.Count != 1 || rows[0]["id"] is not long id || id != 1 || rows[0]["generation"] is not long generation || generation < 0)
        { throw new InvalidDataException("Génération de la mémoire des relevés illisible ; aucune écriture."); }
        return generation;
    }
}
