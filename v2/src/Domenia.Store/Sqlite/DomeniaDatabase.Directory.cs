using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;

namespace Domenia.Store;

public sealed record DirectoryCommitReceipt(string BatchId, string Sha256, long Revision, int Items, DateTimeOffset At, bool AlreadyCommitted);

public sealed partial class DomeniaDatabase
{
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, MaxDepth = 40 };
    private sealed record StoredObject(Guid Guid, string Kind, string Dn, string Json);
    private sealed record StoredDirectoryHeader(DomainInfo Domain, ScopeSelection Scope, DateTimeOffset ReadAt, bool Complete);

    /// <summary>Immutable, hashed JSONL stage; one transaction; a replay returns the original receipt.</summary>
    public async Task<DirectoryCommitReceipt> SaveDirectoryAsync(string batchId, DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(scope);
        if (!Guid.TryParseExact(batchId, "D", out _) || !string.Equals(snapshot.Domain.RootDn, DomainDn, StringComparison.OrdinalIgnoreCase)
            || !InDomain(scope.Dn) || snapshot.ReadAt == DateTimeOffset.MinValue || snapshot.ReadAt > clock.GetUtcNow().AddMinutes(2))
        {
            throw new ArgumentException("Identité ou périmètre du lot de stockage invalide.");
        }
        var objects = snapshot.OrganizationalUnits.Select(o => new StoredObject(o.ObjectGuid, "ou", o.DistinguishedName, JsonSerializer.Serialize(o, Json)))
            .Concat(snapshot.Users.Select(o => new StoredObject(o.ObjectGuid, "user", o.DistinguishedName, JsonSerializer.Serialize(o, Json))))
            .Concat(snapshot.Computers.Select(o => new StoredObject(o.ObjectGuid, "computer", o.DistinguishedName, JsonSerializer.Serialize(o, Json))))
            .Concat(snapshot.Groups.Select(o => new StoredObject(o.ObjectGuid, "group", o.DistinguishedName, JsonSerializer.Serialize(o, Json)))).ToArray();
        if (objects.Any(o => o.Guid == Guid.Empty || !InReadScope(scope, o.Dn)) || objects.Select(o => o.Guid).Distinct().Count() != objects.Length)
        {
            throw new InvalidDataException("Lot hors périmètre ou identités dupliquées : aucune écriture.");
        }
        var header = new StoredDirectoryHeader(snapshot.Domain, scope, snapshot.ReadAt, snapshot.Complete);
        var payload = JsonSerializer.Serialize(header, Json) + "\n" + string.Join("\n", objects.Select(o => JsonSerializer.Serialize(o, Json))) + "\n";
        var bytes = Encoding.UTF8.GetBytes(payload);
        var hash = Convert.ToHexStringLower(SHA256.HashData(bytes));
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady();
                CompatibleDirectoryCache.ValidateLocalPath(Path);
                var folder = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Path)!, "Staging");
                Directory.CreateDirectory(folder);
                var staged = System.IO.Path.Combine(folder, batchId + ".jsonl");
                CompatibleDirectoryCache.ValidateLocalPath(staged);
                if (!File.Exists(staged))
                {
                    using var file = new FileStream(staged, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.WriteThrough);
                    file.Write(bytes);
                    file.Flush(flushToDisk: true);
                }
                var retained = File.ReadAllBytes(staged);
                if (Convert.ToHexStringLower(SHA256.HashData(retained)) != hash) { throw new InvalidDataException("Identifiant de lot déjà utilisé avec un contenu différent."); }
                var lines = Encoding.UTF8.GetString(retained).Split('\n', StringSplitOptions.RemoveEmptyEntries);
                var decoded = lines.Skip(1).Select(line => JsonSerializer.Deserialize<StoredObject>(line, Json) ?? throw new InvalidDataException("Ligne de lot illisible.")).ToArray();
                if (decoded.Length != objects.Length || !decoded.Select(o => o.Guid).SequenceEqual(objects.Select(o => o.Guid))) { throw new InvalidDataException("Relecture du lot incohérente."); }
                using var db = new SqliteDatabase(Path, readOnly: false, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: false);
                var previous = Receipt(db, batchId, hash);
                if (previous is not null) { File.Delete(staged); return previous; }
                EnsureBackup(db, cancellationToken);
                db.Script("PRAGMA synchronous=FULL;");
                db.Begin();
                CheckIdentity(db, allowLegacy: false);
                previous = Receipt(db, batchId, hash);
                if (previous is not null) { db.Rollback(); File.Delete(staged); return previous; }
                var revision = checked((long)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;")! + 1);
                var observed = Stamp(snapshot.ReadAt);
                foreach (var obj in decoded)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var guid = obj.Guid.ToString("D");
                    if ((long)db.Scalar("SELECT count(*) FROM ad_objects WHERE object_guid=?1 AND julianday(synced_at)>julianday(?2);", guid, observed)! > 0) { continue; }
                    // A late read cannot erase a newer object. An identity moved between OUs remains a single GUID.
                    var changed = db.Execute("INSERT INTO domenia_v2_objects(object_guid,kind,dn,payload,observed_at) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(object_guid) DO UPDATE SET kind=excluded.kind,dn=excluded.dn,payload=excluded.payload,observed_at=excluded.observed_at WHERE julianday(excluded.observed_at)>=julianday(domenia_v2_objects.observed_at);", guid, obj.Kind, obj.Dn, obj.Json, observed);
                    if (changed == 0) { continue; }
                    var row = IndexProjection(obj, snapshot.ReadAt);
                    if (row is not null) { WriteIndex(db, row, controller, revision); }
                }
                var oldHeaderJson = db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='directory';") as string;
                var oldHeader = oldHeaderJson is null ? null : JsonSerializer.Deserialize<StoredDirectoryHeader>(oldHeaderJson, Json);
                if (oldHeader is null || oldHeader.ReadAt <= header.ReadAt)
                {
                    db.Execute("INSERT OR REPLACE INTO domenia_v2_metadata(key,payload) VALUES('directory',?1);", JsonSerializer.Serialize(header, Json));
                }
                var key = ScopeRules.IsDomainRoot(scope, DomainDn) ? "directory" : "ou:" + (scope.Subtree ? "" : "onelevel:") + scope.Dn.ToLowerInvariant();
                if (!snapshot.Complete) { key = "attempt:" + key; }
                // A partial pass does not advance a complete checkpoint, remove absences or delete unseen objects.
                db.Execute("INSERT INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES(?1,?2,?3,0,?4,?5,?6) ON CONFLICT(scope) DO UPDATE SET server=excluded.server,base_dn=excluded.base_dn,last_sync=excluded.last_sync,item_count=excluded.item_count,details=excluded.details WHERE julianday(excluded.last_sync)>=julianday(sync_state.last_sync);",
                    key, controller, scope.Dn, observed, objects.Length, "depth=" + (scope.Subtree ? "Subtree" : "OneLevel") + (snapshot.Complete ? ";full" : ";partial"));
                var committed = clock.GetUtcNow();
                db.Execute("UPDATE domenia_store_state SET revision=?1 WHERE id=1;", revision);
                db.Execute("INSERT INTO domenia_v2_batches(batch_id,sha256,revision,committed_at,items) VALUES(?1,?2,?3,?4,?5);", batchId, hash, revision, Stamp(committed), objects.Length);
                db.Commit();
                var receipt = Receipt(db, batchId, hash) ?? throw new InvalidDataException("Reçu de stockage absent après commit.");
                // Staging is kept until its committed receipt has been reread; only this task's stage is then removed.
                File.Delete(staged);
                return receipt with { AlreadyCommitted = false };
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    public Task<DirectorySnapshot?> ReadDirectoryAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return null; }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
        CheckIdentity(db, allowLegacy: true);
        if (!Table(db, "domenia_v2_metadata")) { return null; }
        db.Begin(write: false);
        var raw = db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='directory';") as string;
        if (raw is null) { db.Commit(); return null; }
        var header = JsonSerializer.Deserialize<StoredDirectoryHeader>(raw, Json) ?? throw new InvalidDataException("Contexte du relevé illisible.");
        if (!string.Equals(header.Domain.RootDn, DomainDn, StringComparison.OrdinalIgnoreCase) || !InDomain(header.Scope.Dn)) { throw new InvalidDataException("Relevé d’un autre domaine."); }
        var ous = ImmutableArray.CreateBuilder<DirectoryOu>();
        var users = ImmutableArray.CreateBuilder<DirectoryUser>();
        var computers = ImmutableArray.CreateBuilder<DirectoryComputer>();
        var groups = ImmutableArray.CreateBuilder<DirectoryGroup>();
        foreach (var row in db.Query("SELECT object_guid,kind,dn,payload,observed_at FROM domenia_v2_objects;"))
        {
            var dn = (string)row["dn"]!;
            if (!InDomain(dn)) { throw new InvalidDataException("Projection locale hors domaine."); }
            if (!InReadScope(header.Scope, dn)) { continue; }
            var json = (string)row["payload"]!;
            object? item = (string)row["kind"]! switch
            {
                "ou" => JsonSerializer.Deserialize<DirectoryOu>(json, Json),
                "user" => JsonSerializer.Deserialize<DirectoryUser>(json, Json),
                "computer" => JsonSerializer.Deserialize<DirectoryComputer>(json, Json),
                "group" => JsonSerializer.Deserialize<DirectoryGroup>(json, Json),
                _ => throw new InvalidDataException("Type de projection locale inconnu."),
            };
            var identity = item switch
            {
                DirectoryOu o => (o.ObjectGuid, o.DistinguishedName), DirectoryUser u => (u.ObjectGuid, u.DistinguishedName),
                DirectoryComputer c => (c.ObjectGuid, c.DistinguishedName), DirectoryGroup g => (g.ObjectGuid, g.DistinguishedName),
                _ => throw new InvalidDataException("Projection locale vide."),
            };
            if (identity.Item1.ToString("D") != (string)row["object_guid"]! || identity.Item2 != dn) { throw new InvalidDataException("Identité de projection incohérente."); }
            switch (item)
            {
                case DirectoryOu o: ous.Add(o); break;
                case DirectoryUser u: users.Add(u); break;
                case DirectoryComputer c: computers.Add(c); break;
                case DirectoryGroup g: groups.Add(g); break;
            }
        }
        db.Commit();
        // Retained objects can predate the last pass; the union is never presented as a complete fresh census.
        return new DirectorySnapshot(header.Domain, header.ReadAt, false, ous.ToImmutable(), users.ToImmutable(), computers.ToImmutable(), groups.ToImmutable());
    }, cancellationToken);

    private void EnsureBackup(SqliteDatabase db, CancellationToken token)
    {
        if (lastBackup is { } saved && clock.GetUtcNow() - saved.At < TimeSpan.FromMinutes(30) && File.Exists(saved.Path))
        {
            using var file = File.OpenRead(saved.Path);
            if (Convert.ToHexStringLower(SHA256.HashData(file)) == saved.Sha256) { return; }
        }
        lastBackup = Backup(db, token);
    }

    private static DirectoryCommitReceipt? Receipt(SqliteDatabase db, string id, string expectedHash)
    {
        var row = db.Query("SELECT sha256,revision,committed_at,items FROM domenia_v2_batches WHERE batch_id=?1;", id).SingleOrDefault();
        if (row is null) { return null; }
        if ((string)row["sha256"]! != expectedHash) { throw new InvalidDataException("Identifiant de lot réutilisé avec un autre contenu."); }
        return new(id, expectedHash, (long)row["revision"]!, checked((int)(long)row["items"]!), DateTimeOffset.Parse((string)row["committed_at"]!, CultureInfo.InvariantCulture), true);
    }

    private static IndexRecord? IndexProjection(StoredObject obj, DateTimeOffset at)
    {
        if (obj.Kind == "user")
        {
            var u = JsonSerializer.Deserialize<DirectoryUser>(obj.Json, Json)!;
            return new(u.ObjectGuid, IndexObjectType.User, u.Cn, u.SamAccountName, u.UserPrincipalName, u.DisplayName, u.Description,
                string.Join(" / ", new[] { u.Department, u.Title }.Where(s => !string.IsNullOrWhiteSpace(s))), !AdValues.IsDisabled(u.UserAccountControl), u.DistinguishedName,
                u.WhenChanged, u.UsnChanged, AdValues.FromFileTime(u.LastLogonTimestamp), LapsKind.None, null, at);
        }
        if (obj.Kind == "computer")
        {
            var c = JsonSerializer.Deserialize<DirectoryComputer>(obj.Json, Json)!;
            return new(c.ObjectGuid, IndexObjectType.Computer, c.Name, c.SamAccountName, c.DnsHostName, null, c.Description,
                string.Join(" / ", new[] { c.OperatingSystem, c.Location }.Where(s => !string.IsNullOrWhiteSpace(s))), !AdValues.IsDisabled(c.UserAccountControl), c.DistinguishedName,
                c.WhenChanged, c.UsnChanged, AdValues.FromFileTime(c.LastLogonTimestamp), c.Laps, AdValues.FromFileTime(c.LapsExpiration), at);
        }
        return null;
    }

    private static void WriteIndex(SqliteDatabase db, IndexRecord row, string? controller, long revision)
    {
        var guid = row.ObjectGuid.ToString("D");
        var originalSearch = string.Join(' ', row.Name, row.Login, row.Upn, row.DisplayName, row.Description, row.Extra).ToLowerInvariant();
        var search = originalSearch + " " + FrenchText.Fold(originalSearch);
        var collision = db.Scalar("SELECT object_guid FROM ad_objects WHERE object_key=?1;", guid) as string;
        if (collision is not null && !string.Equals(collision, guid, StringComparison.OrdinalIgnoreCase)) { throw new InvalidDataException("Collision d’identités dans l’index historique."); }
        // Delete only obsolete aliases of this same GUID, not other objects absent from this pass.
        db.Execute("DELETE FROM ad_objects WHERE object_guid=?1 AND object_key<>?1;", guid);
        db.Execute("INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at) VALUES(?1,?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16) ON CONFLICT(object_key) DO UPDATE SET object_guid=excluded.object_guid,object_type=excluded.object_type,name=excluded.name,login=excluded.login,upn=excluded.upn,display_name=excluded.display_name,description=excluded.description,extra=excluded.extra,state=excluded.state,distinguished_name=excluded.distinguished_name,when_changed=excluded.when_changed,usn_changed=excluded.usn_changed,last_logon=excluded.last_logon,search_key=excluded.search_key,source_dc=excluded.source_dc,synced_at=excluded.synced_at;",
            guid, row.Type == IndexObjectType.User ? "Utilisateur" : "Machine", row.Name, row.Login, row.Upn, row.DisplayName, row.Description, row.Extra,
            row.Enabled ? "Actif" : "Desactive", row.Dn, Stamp(row.WhenChanged), row.Usn, Stamp(row.LastLogon), search, controller, Stamp(row.ObservedAt));
        var old = db.Query("SELECT payload,field_times FROM domenia_directory_data WHERE object_guid=?1;", guid).SingleOrDefault();
        var record = old is null ? new JsonObject() : JsonNode.Parse((string)old["payload"]!) as JsonObject ?? throw new InvalidDataException("Projection historique illisible.");
        var times = old is null ? new JsonObject() : JsonNode.Parse((string)old["field_times"]!) as JsonObject ?? throw new InvalidDataException("Dates des champs historiques illisibles.");
        var sources = record["FieldSources"] as JsonObject ?? new JsonObject();
        var fields = new JsonObject
        {
            ["Type"] = row.Type == IndexObjectType.User ? "Utilisateur" : "Machine", ["Name"] = row.Name, ["Login"] = row.Login, ["Upn"] = row.Upn,
            ["Display"] = row.DisplayName, ["Description"] = row.Description, ["Extra"] = row.Extra, ["State"] = row.Enabled ? "Actif" : "Desactive",
            ["DN"] = row.Dn, ["WhenChanged"] = Stamp(row.WhenChanged), ["Usn"] = row.Usn, ["LastLogon"] = Stamp(row.LastLogon),
        };
        foreach (var field in fields)
        {
            record[field.Key] = field.Value?.DeepClone();
            times[field.Key] = Stamp(row.ObservedAt);
            sources[field.Key] = controller;
        }
        record["Guid"] = guid;
        record["ObservedAtUtc"] = Stamp(row.ObservedAt);
        record["Source"] = controller;
        record["Revision"] = revision;
        // Keep earlier detailed attributes and their individual dates; this projection did not reread them.
        if (record["FieldSources"] is null) { record["FieldSources"] = sources; }
        db.Execute("INSERT OR REPLACE INTO domenia_directory_data(object_guid,payload,field_times,revision,observed_at) VALUES(?1,?2,?3,?4,?5);",
            guid, record.ToJsonString(), times.ToJsonString(), revision, Stamp(row.ObservedAt));
        if (row.Type == IndexObjectType.Computer)
        {
            db.Execute("INSERT INTO ad_computer_facts(object_guid,object_key,laps_kind,laps_expiry,read_at) VALUES(?1,?1,?2,?3,?4) ON CONFLICT(object_guid) DO UPDATE SET object_key=excluded.object_key,laps_kind=excluded.laps_kind,laps_expiry=excluded.laps_expiry,read_at=excluded.read_at;",
                guid, row.Laps == LapsKind.Windows ? "windows" : row.Laps == LapsKind.Legacy ? "legacy" : "none", Stamp(row.LapsExpiration), Stamp(row.ObservedAt));
        }
    }

    private static string? Stamp(DateTimeOffset? at) => at is null || at == DateTimeOffset.MinValue ? null : at.Value.UtcDateTime.ToString("O", CultureInfo.InvariantCulture);
}
