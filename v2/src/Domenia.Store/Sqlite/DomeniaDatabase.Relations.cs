using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private const int RelationReadCap = 50_000;
    private static readonly (string Name, int Limit)[] RelationColumns =
    [
        ("computer_key", 1024), ("user_login", 320), ("computer", 255), ("source", 512), ("observed_at", 100),
        ("details", 16_384), ("user_guid", 40), ("computer_guid", 40), ("user_dn", 4096), ("computer_dn", 4096),
        ("batch_id", 128), ("declarant", 320), ("kind", 32),
    ];

    public Task<RelationCacheSnapshot> ReadRelationsAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return RelationCacheSnapshot.Empty(StoreId, DomainDn); }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
        db.Begin(write: false); CheckIdentity(db, allowLegacy: true);
        var result = ReadRelations(db, cancellationToken);
        db.Commit(); return result;
    }, cancellationToken);

    private RelationCacheSnapshot ReadRelations(SqliteDatabase db, CancellationToken cancellationToken)
    {
        var revision = Table(db, "domenia_store_state") ? (long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") ?? 0 : 0;
        if (!Table(db, "user_machine_links")) { return RelationCacheSnapshot.Empty(StoreId, DomainDn) with { Revision = revision }; }
        var columns = db.Query("PRAGMA table_info(user_machine_links);").Select(r => (string)r["name"]!).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (new[] { "computer_key", "user_login", "computer" }.Any(c => !columns.Contains(c)))
        { throw new InvalidDataException("Table des associations incomplète ; aucune interprétation ni modification."); }
        var total = (long)db.Scalar("SELECT count(*) FROM user_machine_links;")!;
        // Project bounded cells before crossing the SQLite/native boundary; page inside one consistent read transaction.
        var projection = RelationColumns.Select(c => columns.Contains(c.Name)
            ? "CASE WHEN typeof(" + c.Name + ")='text' AND length(" + c.Name + ")<=" + c.Limit.ToString(CultureInfo.InvariantCulture) + " THEN " + c.Name + " ELSE NULL END AS " + c.Name
            : "NULL AS " + c.Name).ToList();
        projection.Add(columns.Contains("verified_in_ad") ? "CASE WHEN typeof(verified_in_ad)='integer' AND verified_in_ad IN (0,1) THEN verified_in_ad ELSE NULL END AS verified_in_ad" : "NULL AS verified_in_ad");
        projection.Add(columns.Contains("confidence") ? "CASE WHEN typeof(confidence) IN ('integer','real') AND confidence BETWEEN -1.7976931348623157e308 AND 1.7976931348623157e308 THEN confidence ELSE NULL END AS confidence" : "NULL AS confidence");
        var invalid = RelationColumns.Where(c => columns.Contains(c.Name)).Select(c => "(" + c.Name + " IS NOT NULL AND (typeof(" + c.Name + ")<>'text' OR length(" + c.Name + ")>" + c.Limit.ToString(CultureInfo.InvariantCulture) + "))").ToList();
        if (columns.Contains("verified_in_ad")) { invalid.Add("(verified_in_ad IS NOT NULL AND (typeof(verified_in_ad)<>'integer' OR verified_in_ad NOT IN (0,1)))"); }
        if (columns.Contains("confidence")) { invalid.Add("(confidence IS NOT NULL AND (typeof(confidence) NOT IN ('integer','real') OR confidence NOT BETWEEN -1.7976931348623157e308 AND 1.7976931348623157e308))"); }
        // Include D1 extension columns in the physical fingerprint, without allocating an unbounded opaque payload.
        var known = RelationColumns.Select(c => c.Name).Append("verified_in_ad").Append("confidence").ToHashSet(StringComparer.OrdinalIgnoreCase);
        var extras = columns.Where(c => !known.Contains(c)).OrderBy(c => c, StringComparer.Ordinal).ToArray();
        static string Quote(string name) => "\"" + name.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
        if (extras.Length > 32) { invalid.Add("1"); }
        else if (extras.Length > 0)
        {
            var size = "(" + string.Join('+', extras.Select(c => "COALESCE(length(CAST(" + Quote(c) + " AS BLOB)),0)")) + ")<=65536";
            invalid.Add("NOT (" + size + ")");
            foreach (var extra in extras)
            {
                var name = Quote(extra);
                var finite = "(typeof(" + name + ")<>'real' OR " + name + " BETWEEN -1.7976931348623157e308 AND 1.7976931348623157e308)";
                invalid.Add("NOT " + finite);
                projection.Add("CASE WHEN " + size + " AND " + finite + " THEN " + name + " ELSE NULL END AS " + Quote("extension:" + extra));
            }
        }
        projection.Add("CASE WHEN " + string.Join(" OR ", invalid) + " THEN 1 ELSE 0 END AS invalid_cell");
        var rows = ImmutableArray.CreateBuilder<CachedRelation>(); var rejected = 0; var dates = 0; var readCount = 0; long bytes = 0;
        var truncated = total > RelationReadCap;
        while (readCount < total && readCount < RelationReadCap)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var page = db.Query("SELECT " + string.Join(',', projection) + " FROM user_machine_links ORDER BY computer_key COLLATE BINARY LIMIT ?1 OFFSET ?2;", Math.Min(512, RelationReadCap - readCount), readCount);
            if (page.Count == 0) { break; }
            foreach (var row in page)
            {
                readCount++;
                bytes += row.Values.OfType<string>().Sum(s => (long)Encoding.UTF8.GetByteCount(s)) + row.Values.OfType<byte[]>().Sum(b => (long)b.Length);
                if (bytes > 32L * 1024 * 1024) { truncated = true; break; }
                if ((long)row["invalid_cell"]! != 0 || !TryRelation(row, out var relation, out var uncertain)) { rejected++; continue; }
                dates += uncertain ? 1 : 0;
                var raw = JsonSerializer.SerializeToUtf8Bytes(row);
                rows.Add(new((string)row["computer_key"]!, Convert.ToHexStringLower(SHA256.HashData(raw)), relation!));
            }
            if (bytes > 32L * 1024 * 1024) { break; }
        }
        return new RelationCacheSnapshot(StoreId, DomainDn, revision, rows.ToImmutable(), total, rejected, dates, truncated,
            FrenchText.Count(rows.Count, "association lue", "associations lues") + " dans la base locale. "
            + (rejected > 0 ? FrenchText.Count(rejected, "ligne incohérente conservée dans la base mais écartée", "lignes incohérentes conservées dans la base mais écartées") + ". " : "")
            + (dates > 0 ? FrenchText.Count(dates, "date non qualifiée", "dates non qualifiées") + ". " : "")
            + (truncated ? "Lecture partielle : plafond de 50 000 lignes ou 32 Mio atteint. " : "")
            + "Clés de stockage et GUID historiques conservés ; aucun rapprochement par homonymie.");
    }

    private bool TryRelation(IReadOnlyDictionary<string, object?> row, out StoredRelation? relation, out bool uncertainDate)
    {
        relation = null; uncertainDate = false;
        string? Text(string key) => row.GetValueOrDefault(key) as string;
        var key = Text("computer_key"); var login = Text("user_login"); var computer = Text("computer");
        if (string.IsNullOrWhiteSpace(key) || key.Any(char.IsControl) || string.IsNullOrWhiteSpace(login) || login.Any(char.IsControl)
            || string.IsNullOrWhiteSpace(computer) || computer.Any(char.IsControl)) { return false; }
        static bool Identity(string? text, out Guid? id)
        {
            id = null;
            if (string.IsNullOrWhiteSpace(text)) { return true; }
            if (!Guid.TryParse(text, out var guid) || guid == Guid.Empty) { return false; }
            id = guid; return true;
        }
        if (!Identity(Text("user_guid"), out var userId) || !Identity(Text("computer_guid"), out var computerId)) { return false; }
        string? Dn(string key) => string.IsNullOrWhiteSpace(Text(key)) ? null : Text(key);
        var userDn = Dn("user_dn"); var computerDn = Dn("computer_dn");
        try { if (userDn is not null && !InDomain(userDn) || computerDn is not null && !InDomain(computerDn)) { return false; } }
        catch (FormatException) { return false; }
        var source = Text("source") ?? "";
        var kind = RelationRules.KindOf(source);
        if (Text("kind") is { Length: > 0 } rawKind)
        {
            kind = rawKind.ToLowerInvariant() switch
            {
                "assignment" or "affectation" => RelationKind.Assignment, "console" => RelationKind.Console,
                "remotesession" or "sessionrdp" => RelationKind.RemoteSession, "history" or "historique" => RelationKind.History,
                "imported" or "importe" => RelationKind.Imported, "hint" or "indice" => RelationKind.Hint,
                "unknown" or "inconnu" => RelationKind.Unknown, _ => kind,
            };
        }
        var stamp = Text("observed_at");
        var at = RelationRules.ParseStoredWhen(stamp, clock.LocalTimeZone);
        // A DST fold or gap cannot supply a unique instant. Preserve the row, but do not invent an observation date.
        if (stamp is { Length: > 0 } && !OffsetSuffix().IsMatch(stamp.Trim()) && DateTime.TryParse(stamp, CultureInfo.InvariantCulture, DateTimeStyles.None, out var time))
        {
            var local = DateTime.SpecifyKind(time, DateTimeKind.Unspecified);
            if (clock.LocalTimeZone.IsAmbiguousTime(local) || clock.LocalTimeZone.IsInvalidTime(local)) { at = null; }
        }
        if (at == DateTimeOffset.MinValue || at > clock.GetUtcNow().AddMinutes(2)) { at = null; }
        uncertainDate = !string.IsNullOrWhiteSpace(stamp) && at is null;
        var details = Text("details");
        var batch = Text("batch_id");
        if (string.IsNullOrWhiteSpace(batch) && details is not null)
        {
            var match = LegacyImportBatch().Match(details);
            if (match.Success) { batch = match.Groups[1].Value; }
        }
        relation = new(login, userId, userDn, computer, computerId, computerDn, kind, source, at, details,
            (long?)row["verified_in_ad"] == 1, Text("declarant"), string.IsNullOrWhiteSpace(batch) ? null : batch);
        return true;
    }

    [GeneratedRegex(@"(Z|[+-]\d{2}:?\d{2})$", RegexOptions.CultureInvariant)]
    private static partial Regex OffsetSuffix();
    [GeneratedRegex(@"Lot d['’ʼ]import ([A-Za-z0-9_-][A-Za-z0-9_.-]{0,127})\.\s", RegexOptions.CultureInvariant)]
    private static partial Regex LegacyImportBatch();
}
