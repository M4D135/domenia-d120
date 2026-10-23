using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Store;

/// <summary>A bounded logical snapshot, including D1 writes which do not advance the D2 revision.</summary>
internal static class StorageWriteSnapshot
{
    internal static string Read(SqliteDatabase db, CancellationToken token)
    {
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        long total = 0;
        void Hash(byte[] bytes)
        {
            total += bytes.Length;
            if (total > 256L * 1024 * 1024) { throw new InvalidDataException("Base trop volumineuse pour retenir un lot réessayable en mémoire."); }
            digest.AppendData(bytes); digest.AppendData([10]);
        }
        var objects = db.Query("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND name<>'domenia_v2_writer_receipts' ORDER BY type,name;");
        if (objects.Count > 512) { throw new InvalidDataException("Plus de 512 objets SQLite ; reprise mémoire non qualifiée."); }
        foreach (var item in objects) { Hash(JsonSerializer.SerializeToUtf8Bytes(item)); }
        static string Quote(string text) => "\"" + text.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
        foreach (var definition in objects.Where(x => x["type"] as string == "table"))
        {
            token.ThrowIfCancellationRequested();
            var table = (string)definition["name"]!;
            var sql = definition["sql"] as string ?? "";
            if (System.Text.RegularExpressions.Regex.IsMatch(sql, @"\bWITHOUT\s+ROWID\b|\bVIRTUAL\s+TABLE\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant))
            { throw new InvalidDataException("Table sans rowid ou virtuelle non qualifiée pour une reprise mémoire."); }
            var count = (long)db.Scalar("SELECT count(*) FROM " + Quote(table) + ";")!;
            if (count > 300000) { throw new InvalidDataException("Plus de 300 000 lignes dans une table ; reprise mémoire non qualifiée."); }
            var columns = db.Query("PRAGMA table_info(" + Quote(table) + ");").Select(x => (string)x["name"]!).ToArray();
            if (columns.Any(c => c.Equals("rowid", StringComparison.OrdinalIgnoreCase) || c.Equals("_rowid_", StringComparison.OrdinalIgnoreCase) || c.Equals("oid", StringComparison.OrdinalIgnoreCase)))
            { throw new InvalidDataException("Identité rowid masquée ; reprise mémoire non qualifiée."); }
            if (columns.Length > 64) { throw new InvalidDataException("Plus de 64 colonnes ; reprise mémoire non qualifiée."); }
            var valid = string.Join(" AND ", columns.Select(c => "COALESCE(length(CAST(" + Quote(c) + " AS BLOB)),0)<=33554432"));
            var projection = "CASE WHEN " + valid + " THEN 1 ELSE 0 END AS _writer_valid," + string.Join(',', columns.Select(c => "CASE WHEN " + valid + " THEN " + Quote(c) + " ELSE NULL END AS " + Quote(c)));
            Hash(Encoding.UTF8.GetBytes(table));
            if (columns.Contains("_writer_cursor", StringComparer.OrdinalIgnoreCase)) { throw new InvalidDataException("Nom de colonne réservé ; reprise mémoire non qualifiée."); }
            long? cursor = null;
            while (true)
            {
                token.ThrowIfCancellationRequested();
                var page = cursor is null
                    ? db.Query("SELECT rowid AS _writer_cursor," + projection + " FROM " + Quote(table) + " ORDER BY rowid LIMIT 32;")
                    : db.Query("SELECT rowid AS _writer_cursor," + projection + " FROM " + Quote(table) + " WHERE rowid>?1 ORDER BY rowid LIMIT 32;", cursor.Value);
                if (page.Count == 0) { break; }
                foreach (var row in page)
                {
                    if (row["_writer_valid"] is not 1L) { throw new InvalidDataException("Cellule supérieure à 32 Mio ; reprise mémoire non qualifiée."); }
                    var next = row["_writer_cursor"] is long id ? id : throw new InvalidDataException("Identité de pagination non entière.");
                    if (cursor is { } previous && next <= previous) { throw new InvalidDataException("Pagination de reprise non progressive."); }
                    Hash(JsonSerializer.SerializeToUtf8Bytes(row));
                    cursor = next;
                }
            }
        }
        return Convert.ToHexStringLower(digest.GetHashAndReset());
    }
}

/// <summary>Only an explicit retry arms this guard; it runs under SQLite's write transaction before any row changes.</summary>
internal static class StorageReplayScope
{
    private static readonly AsyncLocal<ReplayLease?> Current = new();
    internal static ReplayLease Enter(string path, Action<SqliteDatabase> check, Func<SqliteDatabase, string> capture)
    {
        var lease = new ReplayLease(path, check, capture, Current.Value); Current.Value = lease; return lease;
    }
    internal static void Check(string path, SqliteDatabase db)
    { if (Current.Value is { } context && context.Matches(path)) { context.Check(db); } }
    internal static void BeforeCommit(string path, SqliteDatabase db)
    { if (Current.Value is { } context && context.Matches(path)) { context.Prepared = context.Capture(db); } }
    internal static void Committed(string path)
    { if (Current.Value is { } context && context.Matches(path)) { context.AfterFingerprint = context.Prepared; } }
    internal sealed class ReplayLease(string path, Action<SqliteDatabase> check, Func<SqliteDatabase, string> capture, ReplayLease? previous) : IDisposable
    {
        internal string? Prepared { get; set; }
        internal string? AfterFingerprint { get; set; }
        internal Action<SqliteDatabase> Check { get; } = check;
        internal Func<SqliteDatabase, string> Capture { get; } = capture;
        internal bool Matches(string value) => string.Equals(path, value, StringComparison.OrdinalIgnoreCase);
        public void Dispose() => Current.Value = previous;
    }
}

internal static class StorageWriteBudgetScope
{
    private sealed record Context(string Path, Action Check);
    private static readonly AsyncLocal<Context?> Current = new();
    internal static IDisposable Enter(string path, Action check)
    {
        var previous = Current.Value; Current.Value = new(path, check); return new Restore(previous);
    }
    internal static void Check(string path)
    {
        if (Current.Value is { } context && string.Equals(path, context.Path, StringComparison.OrdinalIgnoreCase)) { context.Check(); }
    }
    private sealed class Restore(Context? previous) : IDisposable
    { public void Dispose() => Current.Value = previous; }
}
