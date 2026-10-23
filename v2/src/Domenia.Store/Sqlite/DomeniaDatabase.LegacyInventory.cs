using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private sealed record LegacyInventory(long Revision, string Fingerprint, ImmutableDictionary<string, long> Counts,
        ImmutableHashSet<string> LinkedComputers, string? Marker, DateTimeOffset? ImportedAt);
    private static readonly string[] LegacyTables = ["ad_objects", "park_state", "user_scan_history", "secret_state", "user_machine_links", "user_machine_history"];

    internal Task<LocalStoreSnapshot> InspectLegacySourcesAsync(LocalStoreSnapshot snapshot, IReadOnlyList<string> roots, CancellationToken token) => Task.Run(() =>
    {
        try
        {
            using var sources = LegacyImportFiles.Read(roots, token, clock.LocalTimeZone);
            LegacyInventory? inventory = null;
            if (snapshot.Available)
            {
                using var db = new SqliteDatabase(Path, true, cancellationToken: token);
                db.Begin(false); CheckIdentity(db, true); inventory = ReadLegacyInventory(db, token);
            }
            return WithLegacySources(snapshot, sources, inventory);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or DecoderFallbackException)
        { return snapshot with { Legacy = snapshot.Legacy with { ReadProblem = ex.Message } }; }
    }, token);

    private LocalStoreSnapshot WithLegacySources(LocalStoreSnapshot snapshot, LegacyImportFiles sources, LegacyInventory? inventory)
    {
        var files = sources.Files.Select(f => f.Info with { ImportRows = f.Info.Kind == "Liens" && inventory is not null
            ? f.Rows.LongCount(r => !inventory.LinkedComputers.Contains(r.Key)) : f.Rows.Length }).ToImmutableArray();
        return snapshot with { Revision = inventory?.Revision ?? snapshot.Revision, Legacy = snapshot.Legacy with
        {
            Found = snapshot.Legacy.Found || !files.IsEmpty, Files = files, ReadAt = clock.GetUtcNow(),
            Location = System.IO.Path.GetDirectoryName(Path)!, Marker = sources.Marker, ReadProblem = null,
            TargetRows = inventory?.Counts ?? ImmutableDictionary<string, long>.Empty,
            AppliedMarker = inventory?.Marker, ImportedAt = inventory?.ImportedAt,
        } };
    }

    private LegacyInventory ReadLegacyInventory(SqliteDatabase db, CancellationToken token)
    {
        var counts = ImmutableDictionary.CreateBuilder<string, long>(StringComparer.Ordinal);
        var linked = ImmutableHashSet.CreateBuilder<string>(StringComparer.OrdinalIgnoreCase);
        var parts = new StringBuilder(ReadPurgeInventory(db, token).Fingerprint);
        foreach (var table in LegacyTables)
        {
            token.ThrowIfCancellationRequested();
            var count = Table(db, table) ? (long)db.Scalar("SELECT count(*) FROM " + table + ";")! : 0;
            if (count > LegacyRules.MaxRows) { throw new InvalidDataException("Inventaire historique limité à 250 000 lignes par table."); }
            counts[table] = count;
            parts.Append('\n').Append(table).Append(':').Append(count.ToString(CultureInfo.InvariantCulture));
            if (count == 0) { continue; }
            var columns = db.Query("PRAGMA table_info(" + table + ");").Select(x => (string)x["name"]!).ToArray();
            if (columns.Length > 64) { throw new InvalidDataException("Table historique non qualifiée."); }
            static string Quote(string value) => "\"" + value.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
            var valid = string.Join(" AND ", columns.Select(c => "COALESCE(length(CAST(" + Quote(c) + " AS BLOB)),0)<=262144"));
            var projection = "CASE WHEN " + valid + " THEN 1 ELSE 0 END AS _legacy_valid," + string.Join(',', columns.Select(c => "CASE WHEN " + valid + " THEN " + Quote(c) + " ELSE NULL END AS " + Quote(c)));
            for (var offset = 0; offset < count; offset += 128)
            foreach (var row in db.Query("SELECT " + projection + " FROM " + table + " ORDER BY rowid LIMIT 128 OFFSET ?1;", offset))
            {
                token.ThrowIfCancellationRequested();
                if (row["_legacy_valid"] is not 1L) { throw new InvalidDataException("Cellule historique supérieure à 256 Kio."); }
                foreach (var cell in row.OrderBy(x => x.Key, StringComparer.Ordinal))
                {
                    var text = cell.Value is byte[] bytes ? Convert.ToBase64String(bytes) : Convert.ToString(cell.Value, CultureInfo.InvariantCulture) ?? "";
                    if (text.Length > 262144 || parts.Length + text.Length > 64 * 1024 * 1024) { throw new InvalidDataException("Contenu historique trop volumineux pour une reprise sûre."); }
                    parts.Append('|').Append(cell.Key).Append('=').Append(cell.Value is null ? -1 : text.Length).Append(':').Append(text);
                }
                if (table == "user_machine_links" && row["computer_key"] is string computer) { linked.Add(computer); }
                parts.Append('\n');
            }
        }
        var marker = Table(db, "sync_state") ? db.Query("SELECT details,last_sync,base_dn FROM sync_state WHERE scope='legacy_import';").SingleOrDefault() : null;
        string? applied = null; DateTimeOffset? importedAt = null;
        if (marker is not null)
        {
            var details = marker["details"] as string;
            if (marker["base_dn"] as string != DomainDn || details is null || !details.StartsWith("marker=", StringComparison.Ordinal))
            { throw new InvalidDataException("Marqueur de reprise historique incohérent ; aucune nouvelle importation."); }
            applied = details[7..]; importedAt = ParseStoredDate(marker["last_sync"] as string);
            if (applied.Length != 64 || applied.Any(c => !char.IsAsciiHexDigit(c)) || importedAt is null)
            { throw new InvalidDataException("Marqueur de reprise historique illisible."); }
        }
        parts.Append("\nmarker=").Append(applied).Append('|').Append(importedAt?.ToString("O", CultureInfo.InvariantCulture));
        var revision = Table(db, "domenia_store_state") ? (long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") ?? 0 : 0;
        return new(revision, BackupPreferencesRules.Sha256(parts.ToString()), counts.ToImmutable(), linked.ToImmutable(), applied, importedAt);
    }
}
