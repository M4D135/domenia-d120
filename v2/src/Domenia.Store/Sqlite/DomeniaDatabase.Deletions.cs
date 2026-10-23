using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    public Task<DirectoryDeletionLinks> CountDeletionLinksAsync(WriteTarget target, CancellationToken token) => Task.Run(() =>
    {
        ValidateDeletedTarget(target);
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return new DirectoryDeletionLinks(0, 0); }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: token);
        CheckIdentity(db, allowLegacy: true);
        var links = DeletionLinks(db, target);
        return new DirectoryDeletionLinks(links.Keys.Length, links.Unresolved);
    }, token);

    public async Task<DirectoryDeletionLinks> ApplyDeletionAsync(WriteTarget target, DateTimeOffset observedAt, CancellationToken token)
    {
        ValidateDeletedTarget(target);
        if (observedAt == DateTimeOffset.MinValue || observedAt > clock.GetUtcNow().AddMinutes(2)) { throw new InvalidDataException("Date de disparition invalide."); }
        await writer.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady();
                CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = new SqliteDatabase(Path, readOnly: false, cancellationToken: token);
                CheckIdentity(db, allowLegacy: false);
                lastBackup = Backup(db, token);
                db.Script("PRAGMA synchronous=FULL;");
                db.Begin();
                CheckIdentity(db, allowLegacy: false);
                // A later positive reading can be an AD restore of this same GUID. A late cleanup must not erase it.
                if ((long)db.Scalar("SELECT count(*) FROM domenia_v2_objects WHERE object_guid=?1 AND julianday(observed_at)>julianday(?2);", target.ObjectGuid, Stamp(observedAt))! > 0
                    || (long)db.Scalar("SELECT count(*) FROM domenia_v2_fiches WHERE object_guid=?1 AND julianday(observed_at)>julianday(?2);", target.ObjectGuid, Stamp(observedAt))! > 0)
                { throw new InvalidDataException("Une lecture positive plus récente existe ; le nettoyage local demande une nouvelle vérification AD."); }
                var links = DeletionLinks(db, target);
                foreach (var key in links.Keys) { db.Execute("DELETE FROM user_machine_links WHERE computer_key=?1;", key); }
                foreach (var table in new[] { "ad_objects", "ad_computer_facts", "domenia_directory_data", "domenia_provenance", "domenia_v2_objects", "domenia_v2_fiches" })
                { db.Execute("DELETE FROM " + table + " WHERE object_guid=?1 COLLATE NOCASE;", target.ObjectGuid); }
                // Keep observation/history tables as dated evidence. Only current directory projections and current links go.
                db.Execute("INSERT INTO domenia_v2_deletions(object_guid,dn,observed_at) VALUES(?1,?2,?3) ON CONFLICT(object_guid) DO UPDATE SET dn=excluded.dn,observed_at=excluded.observed_at WHERE julianday(excluded.observed_at)>julianday(domenia_v2_deletions.observed_at);",
                    target.ObjectGuid, target.Dn, Stamp(observedAt));
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                db.Commit();
                return new DirectoryDeletionLinks(links.Keys.Length, links.Unresolved);
            }, token).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private void ValidateDeletedTarget(WriteTarget target)
    {
        if (!Guid.TryParseExact(target.ObjectGuid, "D", out var id) || id == Guid.Empty || !InDomain(target.Dn)
            || target.Kind is not ("user" or "computer" or "group" or "contact" or "ou"))
        { throw new InvalidDataException("Identité de suppression locale invalide."); }
    }

    private static (string[] Keys, int Unresolved) DeletionLinks(SqliteDatabase db, WriteTarget target)
    {
        if (target.Kind is not ("user" or "computer") || !Table(db, "user_machine_links")) { return ([], 0); }
        var columns = db.Query("PRAGMA table_info(user_machine_links);").Select(r => (string)r["name"]!).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var prefix = target.Kind == "user" ? "user" : "computer";
        var guid = prefix + "_guid"; var dn = prefix + "_dn"; var name = target.Kind == "user" ? "user_login" : "computer";
        var rows = db.Query("SELECT computer_key," + name + " AS label," + (columns.Contains(guid) ? guid : "NULL") + " AS guid," + (columns.Contains(dn) ? dn : "NULL") + " AS dn FROM user_machine_links;");
        var keys = new List<string>(); var unresolved = 0;
        foreach (var row in rows)
        {
            if (row["guid"] is string identity && !string.IsNullOrWhiteSpace(identity))
            {
                if (Guid.TryParse(identity, out var parsed) && parsed.ToString("D").Equals(target.ObjectGuid, StringComparison.OrdinalIgnoreCase)) { keys.Add((string)row["computer_key"]!); }
                continue; // Never fall back to a matching name when another GUID is known.
            }
            if (row["dn"] is string knownDn && !string.IsNullOrWhiteSpace(knownDn))
            {
                if (FicheValues.SameDn(knownDn, target.Dn)) { keys.Add((string)row["computer_key"]!); }
                continue;
            }
            var label = Normalize(row["label"] as string, target.Kind);
            if (label.Length > 0 && (label == Normalize(target.SamAccountName, target.Kind) || label == Normalize(target.Name, target.Kind))) { unresolved++; }
        }
        return ([.. keys], unresolved);
    }

    private static string Normalize(string? value, string kind)
    {
        var text = (value ?? "").Trim().ToUpperInvariant();
        if (kind == "computer") { return text.TrimEnd('$').Split('.')[0]; }
        return text.Split('\\')[^1].Split('@')[0];
    }
}
