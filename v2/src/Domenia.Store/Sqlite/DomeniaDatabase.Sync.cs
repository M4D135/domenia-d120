using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private const int SyncRowsLimit = 300_000;

    public Task<SyncLocalState> ReadSyncStateAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return new SyncLocalState(StoreId, DomainDn, 0, false, [], [], [], [], [], [], null) { Park = EmptySweeps() }; }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
        CheckIdentity(db, allowLegacy: true);
        db.Begin(write: false);
        var result = ReadSyncState(db);
        db.Commit();
        return result;
    }, cancellationToken);

    public async Task<IndexSearchPage> SearchSyncIndexAsync(IndexQuery query, CancellationToken cancellationToken)
    {
        if (!InDomain(query.Scope.Dn)) { throw new InvalidDataException("Périmètre local hors domaine."); }
        if (!File.Exists(Path)) { return SyncIndex.Page([], query, _ => null, 0); }
        return await SearchIndexAsync(query, cancellationToken).ConfigureAwait(false);
    }

    private SyncLocalState ReadSyncState(SqliteDatabase db)
    {
        long Count(string table) => Table(db, table) ? (long)db.Scalar("SELECT count(*) FROM " + table + ";")! : 0;
        if (Count("ad_objects") > SyncRowsLimit || Count("ad_absences") > SyncRowsLimit || Count("ad_census_gaps") > SyncRowsLimit
            || Count("sync_state") > 10_000 || Count("ad_snapshots") > SyncSnapshots.MaxPerDomain || Count("ad_snapshot_rows") > SyncRowsLimit)
        { throw new InvalidDataException("Base au-delà de la limite de lecture sûre (300 000 lignes, 50 relevés) ; aucun résultat partiel présenté comme complet."); }
        var rows = Table(db, "ad_objects") ? IndexRows(db, null) : [];
        var scopes = ImmutableArray.CreateBuilder<SyncStateEntry>();
        if (Table(db, "sync_state"))
        {
            foreach (var row in db.Query("SELECT scope,base_dn,last_sync,server,highest_usn,item_count,CASE WHEN length(details)<=16384 THEN details ELSE NULL END AS details FROM sync_state WHERE scope='directory' OR scope LIKE 'ou:%' OR scope LIKE 'attempt:%';"))
            {
                var key = row["scope"] as string ?? "";
                var dn = row["base_dn"] as string ?? "";
                if (!InDomain(dn) || ParseStoredDate(row["last_sync"] as string) is not { } at) { throw new InvalidDataException("Repère de synchronisation illisible."); }
                var details = row["details"] as string ?? "";
                string? depth = details.Split(';').FirstOrDefault(x => x.StartsWith("depth=", StringComparison.Ordinal))?[6..];
                if (depth is not ("Subtree" or "OneLevel")) { depth = null; }
                scopes.Add(new(key, dn, at, depth, key.StartsWith("attempt:", StringComparison.OrdinalIgnoreCase) || details.Contains(";partial", StringComparison.Ordinal),
                    checked((int)((long?)row["item_count"] ?? 0)), row["server"] as string, (long?)row["highest_usn"] ?? 0, null, details.Split(';').FirstOrDefault(x => x.StartsWith("cut=", StringComparison.Ordinal))?[4..] is { Length: > 0 } cut ? cut : null,
                    long.TryParse(details.Split(';').FirstOrDefault(x => x.StartsWith("limit=", StringComparison.Ordinal))?[6..], NumberStyles.None, CultureInfo.InvariantCulture, out var limit) ? limit : 0));
            }
        }
        var absences = ImmutableArray.CreateBuilder<AbsenceRecord>();
        if (Table(db, "ad_absences"))
        {
            foreach (var row in db.Query("SELECT object_guid,object_type,name,last_dn,scope_dn,noticed_at,server,status,checked_at,found_dn,CASE WHEN length(detail)<=4096 THEN detail ELSE NULL END AS detail FROM ad_absences;"))
            {
                var dn = row["last_dn"] as string;
                var scope = row["scope_dn"] as string;
                if (!Guid.TryParse(row["object_guid"] as string, out var id) || id == Guid.Empty || !InDomain(dn) || !InDomain(scope)
                    || ParseStoredDate(row["noticed_at"] as string) is not { } noticed) { throw new InvalidDataException("Disparition historique illisible ; aucune conclusion déduite."); }
                var state = (row["status"] as string)?.ToLowerInvariant() switch
                {
                    "notseen" => AbsenceStatus.NotSeen, "visible" => AbsenceStatus.Visible, "moved" => AbsenceStatus.Moved, "deleted" => AbsenceStatus.Deleted,
                    "notfound" => AbsenceStatus.NotFound, "invisible" => AbsenceStatus.Invisible, _ => AbsenceStatus.Unconfirmed,
                };
                absences.Add(new(id, row["name"] as string ?? "", row["object_type"] as string == "Machine" ? IndexObjectType.Computer : IndexObjectType.User,
                    dn!, row["found_dn"] as string, state, noticed, ParseStoredDate(row["checked_at"] as string), row["detail"] as string ?? "Détail non disponible", scope!, row["server"] as string));
            }
        }
        var gaps = ImmutableArray.CreateBuilder<CensusGapRecord>();
        if (Table(db, "ad_census_gaps"))
        {
            foreach (var row in db.Query("SELECT object_guid,dn,noticed_at FROM ad_census_gaps;"))
            {
                if (!Guid.TryParse(row["object_guid"] as string, out var id) || id == Guid.Empty || !InDomain(row["dn"] as string)
                    || ParseStoredDate(row["noticed_at"] as string) is not { } at) { throw new InvalidDataException("Identité du recensement illisible."); }
                gaps.Add(new(id, (string)row["dn"]!, at));
            }
        }
        var snapshots = ImmutableArray.CreateBuilder<SnapshotRecord>();
        if (Table(db, "ad_snapshots"))
        {
            foreach (var row in db.Query("SELECT snapshot_id,label,domain_dn,scope_dn,subtree,captured_at,object_count,coverage_state,coverage_at,coverage_source,coverage_text,rows_sha256 FROM ad_snapshots;"))
            {
                var id = row["snapshot_id"] as string ?? "";
                var scope = row["scope_dn"] as string;
                if (!WritePlans.IsPlanId(id) || !DistinguishedName.AreEqual(row["domain_dn"] as string ?? "", DomainDn) || !InDomain(scope)
                    || ParseStoredDate(row["captured_at"] as string) is not { } captured) { throw new InvalidDataException("Identité de relevé illisible."); }
                var lines = ImmutableArray.CreateBuilder<SnapshotLine>();
                foreach (var item in db.Query("SELECT object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name FROM ad_snapshot_rows WHERE snapshot_id=?1;", id))
                {
                    if (!Guid.TryParse(item["object_guid"] as string, out var guid) || guid == Guid.Empty || !InDomain(item["distinguished_name"] as string)) { throw new InvalidDataException("Objet de relevé illisible."); }
                    lines.Add(new(guid, item["object_type"] as string == "Machine" ? IndexObjectType.Computer : IndexObjectType.User, item["name"] as string ?? "", item["login"] as string, item["upn"] as string,
                        item["display_name"] as string, item["description"] as string, item["extra"] as string, (item["state"] as string) is "Actif" or "active" or "enabled", (string)item["distinguished_name"]!));
                }
                var built = lines.ToImmutable();
                if (built.Length != (long?)row["object_count"] || built.Select(x => x.ObjectGuid).Distinct().Count() != built.Length) { throw new InvalidDataException("Nombre d’objets du relevé incohérent."); }
                var hash = SyncSnapshots.Fingerprint(built);
                if (!string.Equals(row["rows_sha256"] as string, hash, StringComparison.OrdinalIgnoreCase)
                    && !string.Equals(row["rows_sha256"] as string, LegacySnapshotHash(db, id), StringComparison.OrdinalIgnoreCase))
                { throw new InvalidDataException("Empreinte du relevé non conforme au format vérifié ; original conservé."); }
                var coverage = Enum.TryParse<SnapshotCoverageState>(row["coverage_state"] as string, true, out var value) ? value : SnapshotCoverageState.Unknown;
                snapshots.Add(new(id, row["label"] as string ?? "", DomainDn, scope!, (long?)row["subtree"] == 1, captured, coverage, ParseStoredDate(row["coverage_at"] as string),
                    row["coverage_source"] as string, row["coverage_text"] as string ?? "Couverture non documentée", built, hash));
            }
        }
        var receipts = ImmutableArray.CreateBuilder<SyncStorageReceipt>();
        if (Table(db, "domenia_v2_sync_receipts"))
        {
            foreach (var row in db.Query("SELECT CASE WHEN length(payload)<=16384 THEN payload ELSE NULL END AS payload FROM domenia_v2_sync_receipts ORDER BY committed_at DESC LIMIT 64;"))
            { receipts.Add(JsonSerializer.Deserialize<SyncStorageReceipt>(row["payload"] as string ?? throw new InvalidDataException("Reçu trop volumineux."), Json) ?? throw new InvalidDataException("Reçu illisible.")); }
        }
        var revision = Table(db, "domenia_store_state") ? (long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") ?? 0 : 0;
        return new(StoreId, DomainDn, revision, true, rows, scopes.ToImmutable(), absences.ToImmutable(), gaps.ToImmutable(), snapshots.ToImmutable(), receipts.ToImmutable(), lastBackup?.At) { Park = ReadRelationSweeps(db, CancellationToken.None) };
    }

    private static string LegacySnapshotHash(SqliteDatabase db, string id)
    {
        string[] columns = ["object_guid", "object_type", "name", "login", "upn", "display_name", "description", "extra", "state", "distinguished_name", "when_changed", "last_logon", "source_dc", "synced_at"];
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var row in db.Query("SELECT " + string.Join(',', columns) + " FROM ad_snapshot_rows WHERE snapshot_id=?1 ORDER BY object_guid;", id))
        { hash.AppendData(Encoding.UTF8.GetBytes(string.Join('\u001f', columns.Select(c => row[c] as string ?? "")) + "\n")); }
        return Convert.ToHexStringLower(hash.GetHashAndReset());
    }
}
