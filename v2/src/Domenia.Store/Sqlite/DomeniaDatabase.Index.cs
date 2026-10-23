using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    public Task<ImmutableArray<IndexRecord>> ReadIndexAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
        CheckIdentity(db, allowLegacy: true);
        db.Begin(write: false);
        var result = IndexRows(db, null);
        db.Commit();
        return result;
    }, cancellationToken);

    /// <summary>The count, sort and page use the same read transaction, including Domenia 1 rows.</summary>
    public Task<IndexSearchPage> SearchIndexAsync(IndexQuery query, CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!InDomain(query.Scope.Dn)) { throw new InvalidDataException("Périmètre local hors domaine."); }
        try
        {
            using var db = new SqliteDatabase(Path, readOnly: true, busyTimeoutMs: 50, cancellationToken: cancellationToken);
            CheckIdentity(db, allowLegacy: true);
            db.Begin(write: false);
            var rows = IndexRows(db, new ScopeSelection(query.Scope.Dn, query.Scope.Label, query.Scope.Subtree));
            var revision = Table(db, "domenia_store_state") ? (long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") ?? 0 : 0;
            var links = Table(db, "user_machine_links") ? db.Query("SELECT computer_guid,computer,user_login FROM user_machine_links;") : [];
            string? Association(IndexRecord row) => links.FirstOrDefault(l => string.Equals(l["computer_guid"] as string, row.ObjectGuid.ToString("D"), StringComparison.OrdinalIgnoreCase)
                || string.Equals(l["computer"] as string, row.Name, StringComparison.OrdinalIgnoreCase))?["user_login"] as string;
            var result = SyncIndex.Page(rows, query, Association, revision);
            var legacy = ReadUnidentifiedIndex(db, query.Scope);
            if (legacy.Count > 0) { result = result with { Message = result.Message + " " + LegacyIndexNotice(legacy.Count) }; }
            db.Commit();
            return result;
        }
        catch (SqliteStoreException ex) when (ex.Busy) { return SyncIndex.Busy(query, 0); }
    }, cancellationToken);

    private ImmutableArray<IndexRecord> IndexRows(SqliteDatabase db, ScopeSelection? scope)
    {
        var facts = Table(db, "ad_computer_facts");
        var sql = "SELECT a.object_key,a.object_guid,a.object_type,a.name,a.login,a.upn,a.display_name,a.description,a.extra,a.state,a.distinguished_name,a.when_changed,a.usn_changed,a.last_logon,a.synced_at,"
            + (facts ? "f.laps_kind,f.laps_expiry FROM ad_objects a LEFT JOIN ad_computer_facts f ON f.object_guid=a.object_guid" : "NULL AS laps_kind,NULL AS laps_expiry FROM ad_objects a")
            + " WHERE a.object_type IN ('Utilisateur','Machine')";
        object?[] parameters = [];
        if (scope is not null)
        {
            sql += " AND (a.distinguished_name=?1 COLLATE NOCASE OR a.distinguished_name LIKE ?2 ESCAPE '!')";
            parameters = [scope.Dn, "%," + EscapeLike(scope.Dn)];
        }
        var records = ImmutableArray.CreateBuilder<IndexRecord>();
        var identities = new HashSet<Guid>();
        foreach (var row in db.Query(sql + ";", parameters))
        {
            string? Text(string key) => row[key] as string;
            var dn = Text("distinguished_name");
            if (string.IsNullOrEmpty(Text("object_guid")) && InDomain(dn) && string.Equals(Text("object_key"), Text("object_type") + "|" + dn, StringComparison.OrdinalIgnoreCase)) { continue; }
            if (!Guid.TryParse(Text("object_guid"), out var id) || id == Guid.Empty || !InDomain(dn) || !identities.Add(id))
            {
                throw new InvalidDataException("Identité illisible ou dupliquée dans l’index local : relisez son contrôle d’intégrité.");
            }
            if (scope is not null && !ScopeRules.Contains(scope, dn!)) { continue; }
            var enabled = Text("state")?.ToLowerInvariant() switch
            {
                "actif" or "active" or "enabled" => true,
                "desactive" or "désactivé" or "disabled" => false,
                _ => throw new InvalidDataException("État de compte inconnu dans l’index historique."),
            };
            var laps = Text("laps_kind")?.ToLowerInvariant() switch { "windows" => LapsKind.Windows, "legacy" => LapsKind.Legacy, _ => LapsKind.None };
            records.Add(new(id, Text("object_type") == "Machine" ? IndexObjectType.Computer : IndexObjectType.User, Text("name") ?? "", Text("login"), Text("upn"), Text("display_name"),
                Text("description"), Text("extra"), enabled, dn!, ParseStoredDate(Text("when_changed")), (long?)row["usn_changed"] ?? 0, ParseStoredDate(Text("last_logon")), laps,
                ParseStoredDate(Text("laps_expiry")), ParseStoredDate(Text("synced_at")) ?? DateTimeOffset.MinValue));
        }
        return records.ToImmutable();
    }

    private static string EscapeLike(string value) => value.Replace("!", "!!", StringComparison.Ordinal).Replace("%", "!%", StringComparison.Ordinal).Replace("_", "!_", StringComparison.Ordinal);

    private DateTimeOffset? ParseStoredDate(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) { return null; }
        if (value.Contains('T', StringComparison.Ordinal) && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var iso)) { return iso; }
        if (DateTime.TryParseExact(value, ["dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "dd/MM/yyyy", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"], CultureInfo.GetCultureInfo("fr-FR"), DateTimeStyles.None, out var date))
        {
            return clock.LocalTimeZone.IsInvalidTime(date) ? null : new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(date, clock.LocalTimeZone), TimeSpan.Zero);
        }
        return null;
    }
}
