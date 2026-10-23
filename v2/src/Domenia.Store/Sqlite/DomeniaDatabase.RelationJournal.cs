using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private const int RelationJournalTailBytes = 8 * 1024 * 1024;
    private const int RelationJournalLineBytes = 64 * 1024;
    private static readonly UTF8Encoding JournalUtf8 = new(false, true);

    /// <summary>D1 keeps removed/restored entries next to the scoped database. Read only a bounded tail of that exact file.</summary>
    public Task<RelationJournalCache> ReadRelationJournalAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        using var db = File.Exists(Path) ? new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken) : null;
        if (db is not null) { db.Begin(false); CheckIdentity(db, allowLegacy: true); }
        var result = ReadRelationJournal(db, cancellationToken);
        db?.Commit(); return result;
    }, cancellationToken);

    private RelationJournalCache ReadRelationJournal(SqliteDatabase? db, CancellationToken cancellationToken)
    {
        var path = Path + ".relations-journal.jsonl";
        CompatibleDirectoryCache.ValidateLocalPath(path);
        byte[] bytes = []; long skipped = 0; var legacyReadable = true;
        try
        {
            if (File.Exists(path))
            {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var length = stream.Length;
            skipped = Math.Max(0, length - RelationJournalTailBytes);
            stream.Position = skipped;
            bytes = new byte[checked((int)(length - skipped))];
            stream.ReadExactly(bytes);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { bytes = []; legacyReadable = false; }
        var starts = new Queue<(int Offset, int Count)>(400); var start = 0; var lines = 0;
        void Line(int offset, int count)
        {
            lines++; starts.Enqueue((offset, count));
            if (starts.Count > 400) { starts.Dequeue(); }
        }
        for (var i = 0; i < bytes.Length; i++)
        {
            if ((i & 255) == 0) { cancellationToken.ThrowIfCancellationRequested(); }
            if (bytes[i] != (byte)'\n') { continue; }
            if (skipped == 0 || start > 0) { Line(start, i - start); }
            start = i + 1;
        }
        if (start < bytes.Length && (skipped == 0 || start > 0)) { Line(start, bytes.Length - start); }
        var rejected = 0; var foreign = 0; var truncated = skipped > 0 || lines > 400;
        var records = new List<RelationJournalRecord>();
        foreach (var line in starts)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var span = bytes.AsSpan(line.Offset, line.Count);
            if (line.Offset == 0 && skipped == 0 && span.StartsWith("\uFEFF"u8)) { span = span[3..]; }
            if (span.Length == 0 || span.Length == 1 && span[0] == (byte)'\r') { continue; }
            if (span.Length > RelationJournalLineBytes) { rejected++; continue; }
            try
            {
                var text = JournalUtf8.GetString(span);
                using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 12 });
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object || DuplicateJournalProperties(root)) { rejected++; continue; }
                var domain = JournalText(root, "BaseDn", 4096);
                if (domain is null) { rejected++; continue; }
                if (!DistinguishedName.AreEqual(domain, DomainDn)) { foreign++; continue; }
                var entry = ParseLegacyJournal(root);
                if (entry is null) { rejected++; } else { records.Add(entry); }
            }
            catch (Exception ex) when (ex is JsonException or DecoderFallbackException or FormatException or InvalidDataException)
            { rejected++; }
        }
        if (db is not null && Table(db, RelationJournalTable))
        {
            var durable = db.Query("SELECT id,at,CASE WHEN typeof(payload)='text' AND length(CAST(payload AS BLOB))<=65536 THEN payload ELSE NULL END AS payload FROM domenia_v2_relation_journal ORDER BY at DESC,id DESC LIMIT 401;");
            truncated |= durable.Count > 400;
            foreach (var row in durable.Take(400))
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    if (row["payload"] is not string payload) { rejected++; continue; }
                    using var document = JsonDocument.Parse(payload, new JsonDocumentOptions { MaxDepth = 12 });
                    var root = document.RootElement;
                    if (root.ValueKind != JsonValueKind.Object || DuplicateJournalProperties(root)
                        || JournalText(root, "BaseDn", 4096) is not { } domain || !DistinguishedName.AreEqual(domain, DomainDn)) { rejected++; continue; }
                    var entry = ParseLegacyJournal(root);
                    if (entry is null || entry.Id != (string?)row["id"] || Stamp(entry.At) != (string?)row["at"]) { rejected++; } else { records.Add(entry); }
                }
                catch (Exception ex) when (ex is JsonException or InvalidDataException or FormatException or ArgumentException) { rejected++; }
            }
        }
        // Equal IDs with different content cannot authorize a restoration. Preserve originals on disk, exclude all ambiguous versions.
        var groups = records.GroupBy(r => r.Id, StringComparer.Ordinal).ToArray();
        var ambiguous = groups.Where(g => g.Distinct().Count() > 1).Select(g => g.Key).ToHashSet(StringComparer.Ordinal);
        rejected += records.Count(r => ambiguous.Contains(r.Id));
        var entries = groups.Where(g => !ambiguous.Contains(g.Key)).Select(g => g.First()).OrderBy(r => r.At).ThenBy(r => r.Id, StringComparer.Ordinal).ToImmutableArray();
        return new RelationJournalCache(entries, rejected, foreign, truncated, FrenchText.Count(entries.Length, "entrée de journal relue", "entrées de journal relues")
            + ". " + (truncated ? "Journal limité à 400 entrées SQLite et 400 lignes D1 (8 Mio au plus) ; historique partiel. " : "")
            + (rejected > 0 ? FrenchText.Count(rejected, "entrée illisible ou ambiguë écartée", "entrées illisibles ou ambiguës écartées") + ". " : "")
            + (foreign > 0 ? FrenchText.Count(foreign, "entrée d’un autre domaine écartée", "entrées d’un autre domaine écartées") + ". " : "")
            + (legacyReadable ? "" : "Fichier D1 inaccessible ; seules les entrées SQLite sont disponibles. ")
            + "Fichier original conservé, aucune restauration automatique.") { LegacyReadable = legacyReadable };
    }

    private RelationJournalRecord? ParseLegacyJournal(JsonElement root)
    {
        var id = JournalText(root, "Id", 32); var action = JournalText(root, "Action", 20); var stamp = JournalText(root, "WhenUtc", 100);
        if (!Guid.TryParseExact(id, "N", out var guid) || guid == Guid.Empty || stamp is null || !OffsetSuffix().IsMatch(stamp)
            || !DateTimeOffset.TryParse(stamp, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at)
            || at == DateTimeOffset.MinValue || at > clock.GetUtcNow().AddMinutes(2)
            || !Enum.GetNames<RelationJournalAction>().Contains(action, StringComparer.OrdinalIgnoreCase)
            || !Enum.TryParse<RelationJournalAction>(action, ignoreCase: true, out var kind)
            || !JournalProperty(root, "Relation", out var stored) || stored.ValueKind != JsonValueKind.Object)
        { return null; }
        var row = new Dictionary<string, object?>();
        foreach (var (json, sql, limit) in new[] {
            ("UserLogin", "user_login", 320), ("Computer", "computer", 255), ("Source", "source", 512), ("When", "observed_at", 100),
            ("Details", "details", 16_384), ("UserGuid", "user_guid", 40), ("ComputerGuid", "computer_guid", 40),
            ("UserDn", "user_dn", 4096), ("ComputerDn", "computer_dn", 4096), ("BatchId", "batch_id", 128), ("Declarant", "declarant", 320), ("Kind", "kind", 32) })
        { row[sql] = JournalText(stored, json, limit); }
        row["computer_key"] = row["computer"];
        var verified = JournalProperty(stored, "VerifiedInAD", out var flag) && (flag.ValueKind == JsonValueKind.True
            || flag.ValueKind == JsonValueKind.String && flag.GetString() is { } text && (text.Equals("true", StringComparison.OrdinalIgnoreCase) || text == "1"));
        row["verified_in_ad"] = verified ? 1L : 0L;
        if (!TryRelation(row, out var relation, out _)) { return null; }
        var note = JournalText(root, "Note", 4096);
        if (kind == RelationJournalAction.Restored)
        {
            if (!Guid.TryParseExact(note, "N", out var restored) || restored == Guid.Empty) { return null; }
            note = restored.ToString("N");
        }
        return new(guid.ToString("N"), kind, at.ToUniversalTime(), JournalText(root, "Declarant", 320), note, RelationRules.Key(relation!), relation!);
    }

    private static bool JournalProperty(JsonElement value, string name, out JsonElement property)
    {
        foreach (var item in value.EnumerateObject())
        { if (item.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) { property = item.Value; return true; } }
        property = default; return false;
    }
    private static string? JournalText(JsonElement value, string name, int limit)
    {
        if (!JournalProperty(value, name, out var item) || item.ValueKind == JsonValueKind.Null) { return null; }
        if (item.ValueKind != JsonValueKind.String || item.GetString() is not { } text || text.Length > limit) { throw new InvalidDataException("Champ de journal hors contrat."); }
        return text;
    }
    private static bool DuplicateJournalProperties(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            return value.EnumerateObject().Any(p => !names.Add(p.Name) || DuplicateJournalProperties(p.Value));
        }
        return value.ValueKind == JsonValueKind.Array && value.EnumerateArray().Any(DuplicateJournalProperties);
    }
}
