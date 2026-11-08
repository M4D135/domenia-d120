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
    private sealed record StoredDirectoryHeader(DomainInfo Domain, ScopeSelection Scope, DateTimeOffset ReadAt, bool Complete, string? Controller = null, [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingDefault)] bool PointRead = false, [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] string? ReaderLogin = null);

    /// <summary>Immutable, hashed JSONL stage; one transaction; a replay returns the original receipt.</summary>
    private async Task<DirectoryCommitReceipt> SaveDirectoryCoreAsync(string batchId, DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken, bool preserveCoverage = false)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(scope);
        if (!Guid.TryParseExact(batchId, "D", out var batchGuid) || batchGuid == Guid.Empty || !string.Equals(snapshot.Domain.RootDn, DomainDn, StringComparison.OrdinalIgnoreCase)
            || !InDomain(scope.Dn) || !preserveCoverage && snapshot.Coverage is not null && !ScopeRules.SameScope(snapshot.Coverage, scope)
            || snapshot.ReadAt == DateTimeOffset.MinValue || snapshot.ReadAt > clock.GetUtcNow().AddMinutes(2) || preserveCoverage && snapshot.Complete)
        {
            throw new ArgumentException("Identité ou périmètre du lot de stockage invalide.");
        }
        var objects = snapshot.OrganizationalUnits.Select(o => new StoredObject(o.ObjectGuid, "ou", o.DistinguishedName, JsonSerializer.Serialize(o, Json)))
            .Concat(snapshot.Users.Select(o => new StoredObject(o.ObjectGuid, "user", o.DistinguishedName, JsonSerializer.Serialize(o, Json))))
            .Concat(snapshot.Computers.Select(o => new StoredObject(o.ObjectGuid, "computer", o.DistinguishedName, JsonSerializer.Serialize(o, Json))))
            .Concat(snapshot.Groups.Select(o => new StoredObject(o.ObjectGuid, "group", o.DistinguishedName, JsonSerializer.Serialize(o, Json))))
            .Concat((snapshot.Contacts ?? []).Select(o => new StoredObject(o.ObjectGuid, "contact", o.DistinguishedName, JsonSerializer.Serialize(o, Json))));
        var header = new StoredDirectoryHeader(snapshot.Domain, scope, snapshot.ReadAt, snapshot.Complete, controller, preserveCoverage, snapshot.ReaderLogin);
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady();
                CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var stage = OpenDirectoryStage(batchId, header, objects, snapshot.ObjectCount, scope, cancellationToken);
                var hash = stage.Hash;
                using var db = Open(readOnly: false, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: false);
                var previous = Receipt(db, batchId, hash);
                if (previous is not null) { stage.Delete(); return previous; }
                EnsureBackup(db, cancellationToken, fleetMigration: true);
                db.Script("PRAGMA synchronous=FULL;");
                db.Begin();
                CheckIdentity(db, allowLegacy: false);
                previous = Receipt(db, batchId, hash);
                if (previous is not null) { db.Rollback(); stage.Delete(); return previous; }
                var revision = checked((long)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;")! + 1);
                var observed = Stamp(snapshot.ReadAt);
                var invalidatedComputers = new HashSet<Guid>();
                var hasFleet = (long)db.Scalar("SELECT count(*) FROM domenia_v2_metadata WHERE key='fleet';")! != 0 || Table(db, "domenia_v2_query_results");
                foreach (var obj in stage.Objects())
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var guid = obj.Guid.ToString("D");
                    if ((long)db.Scalar("SELECT count(*) FROM domenia_v2_deletions WHERE object_guid=?1 AND julianday(observed_at)>=julianday(?2);", guid, observed)! > 0) { continue; }
                    if ((long)db.Scalar("SELECT count(*) FROM ad_objects WHERE object_guid=?1 AND julianday(synced_at)>julianday(?2);", guid, observed)! > 0) { continue; }
                    // A late read cannot erase a newer object. An identity moved between OUs remains a single GUID.
                    var prior = db.Query("SELECT kind,payload,observed_at FROM domenia_v2_objects WHERE object_guid=?1;", guid).SingleOrDefault();
                    if (prior is not null && !Equals(prior["kind"], obj.Kind)) throw new InvalidDataException("Type d’identité modifié ; aucune fusion.");
                    var priorPayload = prior?["payload"] as string;
                    var fields = MergeDirectoryFields(obj, priorPayload);
                    var merged = fields.Object;
                    if (fields.Observed is not null && priorPayload == merged.Json && ParseStoredDate(prior?["observed_at"] as string) == snapshot.ReadAt) continue;
                    var oldComputer = hasFleet && obj.Kind == "computer" ? priorPayload : null;
                    var changed = db.Execute("INSERT INTO domenia_v2_objects(object_guid,kind,dn,payload,observed_at) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(object_guid) DO UPDATE SET kind=excluded.kind,dn=excluded.dn,payload=excluded.payload,observed_at=excluded.observed_at WHERE julianday(excluded.observed_at)>=julianday(domenia_v2_objects.observed_at);", guid, obj.Kind, obj.Dn, merged.Json, observed);
                    if (changed == 0) { continue; }
                    if (oldComputer is not null && !SameFleetComputer(oldComputer, merged.Json)) { invalidatedComputers.Add(obj.Guid); }
                    var row = IndexProjection(merged, snapshot.ReadAt);
                    if (row is not null) { WriteIndex(db, row, controller, revision, fields.Observed, writeLaps: false); }
                    if (obj.Kind == "computer") WriteComputerFacts(db, JsonSerializer.Deserialize<DirectoryComputer>(merged.Json, Json)!, snapshot.ReadAt, fields.Observed);
                }
                InvalidateFleetComputers(db, invalidatedComputers);
                var oldHeaderJson = db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='directory';") as string;
                var oldHeader = oldHeaderJson is null ? null : JsonSerializer.Deserialize<StoredDirectoryHeader>(oldHeaderJson, Json);
                if (oldHeader is null || !preserveCoverage && oldHeader.ReadAt <= header.ReadAt)
                {
                    db.Execute("INSERT OR REPLACE INTO domenia_v2_metadata(key,payload) VALUES('directory',?1);", JsonSerializer.Serialize(header, Json));
                }
                var key = ScopeRules.IsDomainRoot(scope, DomainDn) ? "directory" : "ou:" + (scope.Subtree ? "" : "onelevel:") + scope.Dn.ToLowerInvariant();
                if (!snapshot.Complete) { key = "attempt:" + key; }
                // A partial pass does not advance a complete checkpoint, remove absences or delete unseen objects.
                db.Execute("INSERT INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES(?1,?2,?3,0,?4,?5,?6) ON CONFLICT(scope) DO UPDATE SET server=excluded.server,base_dn=excluded.base_dn,last_sync=excluded.last_sync,item_count=excluded.item_count,details=excluded.details WHERE julianday(excluded.last_sync)>=julianday(sync_state.last_sync);",
                    key, controller, scope.Dn, observed, snapshot.ObjectCount, JsonSerializer.Serialize(new DirectoryReadDetails(1, scope.Subtree ? "Subtree" : "OneLevel", snapshot.Complete, snapshot.ReaderLogin), Json));
                var committed = clock.GetUtcNow();
                db.Execute("UPDATE domenia_store_state SET revision=?1 WHERE id=1;", revision);
                db.Execute("INSERT INTO domenia_v2_batches(batch_id,sha256,revision,committed_at,items) VALUES(?1,?2,?3,?4,?5);", batchId, hash, revision, Stamp(committed), snapshot.ObjectCount);
                db.Commit();
                using var confirmation = Open(readOnly: true, cancellationToken: cancellationToken);
                confirmation.Begin(write: false);
                CheckIdentity(confirmation, allowLegacy: false);
                var receipt = Receipt(confirmation, batchId, hash) ?? throw new InvalidDataException("Reçu de stockage absent après commit.");
                confirmation.Commit();
                // Staging is kept until its committed receipt has been reread; only this task's stage is then removed.
                stage.Delete();
                return receipt with { AlreadyCommitted = false };
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    public Task<DirectorySnapshot?> ReadDirectoryAsync(CancellationToken cancellationToken, bool allKnown = false) => ReadDirectoryCoreAsync(cancellationToken, allKnown);

    public async Task<DirectorySnapshot> ReadStoredDirectoryAsync(DirectorySnapshot submitted, DirectoryStorageReceipt receipt, CancellationToken token) =>
        await ReadDirectoryCoreAsync(token, true, submitted, receipt).ConfigureAwait(false)
        ?? throw new InvalidDataException("Projection absente après acquittement du relevé.");

    private Task<DirectorySnapshot?> ReadDirectoryCoreAsync(CancellationToken cancellationToken, bool allKnown,
        DirectorySnapshot? submitted = null, DirectoryStorageReceipt? proof = null) => Task.Run(() =>
    {
        using var phase = OperationPhases.Measure(OperationPhase.LocalRead);
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!DatabaseFileExists()) { return null; }
        using var db = Open(readOnly: true, cancellationToken: cancellationToken);
        CheckIdentity(db, allowLegacy: true);
        if (!Table(db, "domenia_v2_metadata")) { return null; }
        db.Begin(write: false);
        if (submitted is not null)
        {
            if (proof is null || !proof.MatchesWrite(StoreId, DomainDn, proof.Scope, submitted, clock.GetUtcNow()))
                throw new InvalidDataException("Reçu du relevé non confirmé pour cette base.");
            var saved = Receipt(db, proof.BatchId, proof.Sha256);
            if (saved is null || saved.Revision != proof.Revision || saved.Items != proof.Items || saved.At != proof.CommittedAt)
                throw new InvalidDataException("Le reçu annoncé ne correspond pas à la transaction conservée.");
        }
        var raw = db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='directory';") as string;
        if (raw is null) { var historical = ReadLegacyDirectory(db, null); db.Commit(); return historical; }
        var header = JsonSerializer.Deserialize<StoredDirectoryHeader>(raw, Json) ?? throw new InvalidDataException("Contexte du relevé illisible.");
        if (!string.Equals(header.Domain.RootDn, DomainDn, StringComparison.OrdinalIgnoreCase) || !InDomain(header.Scope.Dn)) { throw new InvalidDataException("Relevé d’un autre domaine."); }
        var observedAt = ImmutableDictionary.CreateBuilder<Guid, DateTimeOffset>();
        var ous = ImmutableArray.CreateBuilder<DirectoryOu>();
        var users = ImmutableArray.CreateBuilder<DirectoryUser>();
        var computers = ImmutableArray.CreateBuilder<DirectoryComputer>();
        var groups = ImmutableArray.CreateBuilder<DirectoryGroup>();
        var contacts = ImmutableArray.CreateBuilder<DirectoryContact>();
        var selected = submitted is null ? null : DirectoryIdentities(submitted).Select(x => x.ToString("D")).ToArray();
        IEnumerable<IReadOnlyDictionary<string, object?>> Rows()
        {
            if (selected is null) return db.Query("SELECT object_guid,kind,dn,payload,observed_at FROM domenia_v2_objects;");
            // Bounded parameter lists; a 100-object page never scans the 100,000-object retained projection.
            return selected.Chunk(500).SelectMany(ids => db.Query("SELECT object_guid,kind,dn,payload,observed_at FROM domenia_v2_objects WHERE object_guid IN ("
                + string.Join(',', ids.Select((_, i) => "?" + (i + 1))) + ");", ids.Cast<object?>().ToArray()));
        }
        foreach (var row in Rows())
        {
            var dn = (string)row["dn"]!;
            if (!InDomain(dn)) { throw new InvalidDataException("Projection locale hors domaine."); }
            if (!allKnown && !InReadScope(header.Scope, dn)) { continue; }
            var json = (string)row["payload"]!;
            object? item = (string)row["kind"]! switch
            {
                "ou" => JsonSerializer.Deserialize<DirectoryOu>(json, Json),
                "user" => JsonSerializer.Deserialize<DirectoryUser>(json, Json),
                "computer" => JsonSerializer.Deserialize<DirectoryComputer>(json, Json),
                "group" => JsonSerializer.Deserialize<DirectoryGroup>(json, Json),
                "contact" => JsonSerializer.Deserialize<DirectoryContact>(json, Json),
                _ => throw new InvalidDataException("Type de projection locale inconnu."),
            };
            var identity = item switch
            {
                DirectoryOu o => (o.ObjectGuid, o.DistinguishedName), DirectoryUser u => (u.ObjectGuid, u.DistinguishedName),
                DirectoryComputer c => (c.ObjectGuid, c.DistinguishedName), DirectoryGroup g => (g.ObjectGuid, g.DistinguishedName),
                DirectoryContact c => (c.ObjectGuid, c.DistinguishedName),
                _ => throw new InvalidDataException("Projection locale vide."),
            };
            if (identity.Item1.ToString("D") != (string)row["object_guid"]! || identity.Item2 != dn) { throw new InvalidDataException("Identité de projection incohérente."); }
            if (!DateTimeOffset.TryParse((string?)row["observed_at"], CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var seen)
                || seen == DateTimeOffset.MinValue || seen > clock.GetUtcNow().AddMinutes(2)) { throw new InvalidDataException("Date de projection locale invalide."); }
            observedAt.Add(identity.Item1, seen);
            switch (item)
            {
                case DirectoryOu o: ous.Add(o); break;
                case DirectoryUser u: users.Add(u); break;
                case DirectoryComputer c: computers.Add(c); break;
                case DirectoryGroup g: groups.Add(g); break;
                case DirectoryContact c: contacts.Add(c); break;
            }
        }
        // Retained objects can predate the last pass; the union is never presented as a complete fresh census.
        var local = new DirectorySnapshot(header.Domain, header.ReadAt, false, ous.ToImmutable(), users.ToImmutable(), computers.ToImmutable(), groups.ToImmutable()) { Coverage = header.Scope, ObjectReadAt = observedAt.ToImmutable(), Contacts = contacts.ToImmutable(), ReaderLogin = header.ReaderLogin };
        if (submitted is null) local = ReadLegacyDirectory(db, local, allKnown) ?? local;
        db.Commit();
        return submitted is null ? local : DirectoryReadback.Select(submitted, local);
    }, cancellationToken);

    private static IEnumerable<Guid> DirectoryIdentities(DirectorySnapshot snapshot) => snapshot.OrganizationalUnits.Select(x => x.ObjectGuid)
        .Concat(snapshot.Users.Select(x => x.ObjectGuid)).Concat(snapshot.Computers.Select(x => x.ObjectGuid))
        .Concat(snapshot.Groups.Select(x => x.ObjectGuid)).Concat((snapshot.Contacts ?? []).Select(x => x.ObjectGuid));

    private void EnsureBackup(SqliteDatabase db, CancellationToken token, bool force = false, bool fleetMigration = false)
    {
        // Revision 2 changes the fleet representation. Retain an exact legacy fleet immediately
        // before that migration, even when an earlier routine backup is still recent.
        var legacyFleet = fleetMigration && Table(db, "domenia_v2_metadata") ? db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") as string : null;
        var migration = legacyFleet is not null && !IsRowsFleet(legacyFleet);
        if (!force && !migration && lastBackup is { } saved && clock.GetUtcNow() >= saved.At && clock.GetUtcNow() - saved.At < TimeSpan.FromMinutes(30) && File.Exists(saved.Path))
        {
            CompatibleDirectoryCache.ValidateLocalPath(saved.Path);
            if (VerifyOrRetainBackup(saved)) { return; }
        }
        lastBackup = Backup(db, token);
        if (!VerifyOrRetainBackup(lastBackup)) { throw new InvalidDataException("La sauvegarde de la collecte ne correspond plus à son empreinte vérifiée."); }
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

    private void WriteIndex(SqliteDatabase db, IndexRecord row, string? controller, long revision, HashSet<string>? observed = null, bool writeLaps = true)
    {
        var guid = row.ObjectGuid.ToString("D");
        var previousIndex = db.Query("SELECT name,login,upn,display_name,description,extra,state,when_changed,usn_changed,last_logon FROM ad_objects WHERE object_guid=?1;", guid).SingleOrDefault();
        // A narrow identity read without account status cannot manufacture an enabled/disabled index row.
        if (previousIndex is null && !Observed(observed, "useraccountcontrol")) return;
        row = PreserveIndexFields(row, previousIndex, observed);
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
        var sources = record["FieldSources"] is null ? new JsonObject() : record["FieldSources"] as JsonObject ?? throw new InvalidDataException("Provenance des champs historiques illisible.");
        var fields = new JsonObject
        {
            ["Type"] = row.Type == IndexObjectType.User ? "Utilisateur" : "Machine", ["Name"] = row.Name, ["Login"] = row.Login, ["Upn"] = row.Upn,
            ["Display"] = row.DisplayName, ["Description"] = row.Description, ["Extra"] = row.Extra, ["State"] = row.Enabled ? "Actif" : "Desactive",
            ["DN"] = row.Dn, ["WhenChanged"] = Stamp(row.WhenChanged), ["Usn"] = row.Usn, ["LastLogon"] = Stamp(row.LastLogon),
        };
        foreach (var field in fields)
        {
            if (!IndexFieldObserved(field.Key, row.Type, observed)) continue;
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
        // Sync/index-only callers retain their established LAPS write; full typed objects write all facts together.
        if (writeLaps && row.Type == IndexObjectType.Computer && BothObserved(observed, "mslaps-passwordexpirationtime", "ms-mcs-admpwdexpirationtime"))
            db.Execute("INSERT INTO ad_computer_facts(object_guid,object_key,laps_kind,laps_expiry,read_at) VALUES(?1,?1,?2,?3,?4) ON CONFLICT(object_guid) DO UPDATE SET object_key=excluded.object_key,laps_kind=excluded.laps_kind,laps_expiry=excluded.laps_expiry,read_at=excluded.read_at;",
                guid, row.Laps == LapsKind.Windows ? "windows" : row.Laps == LapsKind.Legacy ? "legacy" : "none", Stamp(row.LapsExpiration), Stamp(row.ObservedAt));

    }

    private static string? Stamp(DateTimeOffset? at) => at is null || at == DateTimeOffset.MinValue ? null : at.Value.UtcDateTime.ToString("O", CultureInfo.InvariantCulture);
}
