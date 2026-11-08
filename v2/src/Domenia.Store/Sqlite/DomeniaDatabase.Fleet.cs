using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private readonly object fleetDecodeGate = new();
    private string? decodedFleetPayload;
    private CachedFleet? decodedFleet;

    public Task<CachedFleet> ReadFleetAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!DatabaseFileExists()) { return CachedFleet.Empty(StoreId); }
        using var db = Open(readOnly: true, cancellationToken: cancellationToken);
        db.Begin(write: false);
        CheckIdentity(db, allowLegacy: true);
        var result = ReadFleet(db);
        db.Commit();
        return result;
    }, cancellationToken);

    private async Task<CachedFleet> SaveFleetCoreAsync(FleetCachePatch patch, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(patch);
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                CollectionWrites.Validate(patch.CollectionContext, StoreId, DomainDn);
                EnsureReady();
                CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = Open(readOnly: false, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: false);
                EnsureBackup(db, cancellationToken, fleetMigration: true);
                db.Script("PRAGMA synchronous=FULL;");
                db.Begin();
                CheckIdentity(db, allowLegacy: false);
                var ids = patch.Observations.Workstations.Select(o => o.ComputerGuid).Concat(patch.Machines.Keys)
                    .Concat(patch.Addresses.Keys).Concat(patch.Inventories.Keys).Concat(patch.WorkstationProbes.Keys).Concat(patch.WorkstationSecrets.Keys).Concat(patch.WorkstationSessions.Keys).Concat(patch.WorkstationDetails.Keys)
                    .Concat(patch.Probes.ByProbe.Values.SelectMany(p => p.Keys)).Concat(patch.BitLocker.SelectMany(p => p.Machines.Keys)).Distinct().ToArray();
                var identities = new Dictionary<Guid, string>();
                // A one-host result must not rescan the 3,500-host directory. All identifiers remain bound parameters.
                foreach (var batch in ids.Chunk(256))
                {
                    var parameters = string.Join(',', Enumerable.Range(1, batch.Length).Select(i => "?" + i));
                    foreach (var row in db.Query("SELECT object_guid,dn FROM domenia_v2_objects WHERE kind='computer' AND object_guid IN (" + parameters + ");", batch.Select(id => (object?)id.ToString("D")).ToArray()))
                    { identities.Add(Guid.Parse((string)row["object_guid"]!), (string)row["dn"]!); }
                }
                if (ids.Any(id => !identities.TryGetValue(id, out var dn) || !InDomain(dn)))
                { throw new InvalidDataException("Relevé d’un poste inconnu ou d’un autre domaine : aucune écriture."); }
                if (patch.Observations.Workstations.Select(o => o.ComputerGuid).Distinct().Count() != patch.Observations.Workstations.Length)
                { throw new InvalidDataException("Identité dupliquée dans le relevé."); }
                var dates = patch.Observations.Workstations.SelectMany(o => new[] { o.Presence.CheckedAt, o.Presence.LastOnlineAt, o.Inventory.CheckedAt, o.Inventory.LastSuccessful?.CheckedAt })
                    .Concat(patch.Machines.Values.SelectMany(m => new[] { m.ConsoleAt, m.BiosAt, m.WmiAt }))
                    .Concat(patch.Probes.ByProbe.Values.SelectMany(p => p.Values.Select(v => v.At)))
                    .Concat(patch.BitLocker.Select(b => (DateTimeOffset?)b.At)).Concat(patch.Addresses.Values.SelectMany(v => v.Select(a => a.ObservedAt)))
                    .Concat(patch.Inventories.Values.Select(v => (DateTimeOffset?)v.CollectedAt)).Append(patch.Observations.TakenAt);
                if (dates.Any(d => d == DateTimeOffset.MinValue || d > clock.GetUtcNow().AddMinutes(2)))
                { throw new InvalidDataException("Date de relevé invalide ou future."); }
                if (patch.Observations.Workstations.Any(o => o.Inventory.LastSuccessful is { } previous
                    && (previous.LastSuccessful is not null || !previous.HasReading || o.Inventory.CheckedAt is null || previous.CheckedAt > o.Inventory.CheckedAt)))
                    throw new InvalidDataException("Historique d’inventaire non daté, imbriqué ou postérieur à la tentative.");
                if (patch.Addresses.Values.Any(v => v.IsDefaultOrEmpty || v.Length > 256 || v.Any(a => a.ObservedAt is null
                    || a.Ip is not null && SearchText.ParseAddress(a.Ip)?.Kind != "ipv4" || a.Mac is not null && SearchText.ParseAddress(a.Mac)?.Kind != "mac")))
                { throw new InvalidDataException("Adresses de poste invalides ou non datées."); }
                foreach (var presence in patch.BitLocker)
                {
                    var scope = new ScopeSelection(presence.ScopeDn, "", presence.Subtree);
                    if (!InDomain(scope.Dn) || ScopeRules.IsDomainRoot(scope, DomainDn) || presence.Machines.Any(p => p.Value.Keys < 0 || !ScopeRules.Contains(scope, identities[p.Key]) || p.Value.Newest > (p.Value.ObservedAt ?? presence.At) || p.Value.ObservedAt > presence.At || p.Value.ObservedAt == DateTimeOffset.MinValue))
                    { throw new InvalidDataException("Présence BitLocker hors du périmètre ou incohérente."); }
                }
                // A personal reading stores only values under the immutable declaration key. It never supplies code or a
                // definition to the reader: the active profile must resolve and validate that key again before collection.
                if (patch.Probes.ByProbe.Keys.Any(id => ProbeCatalog.Find(id) is null && !PersonalProbeCatalog.IsKey(id))) { throw new InvalidDataException("Sonde non reconnue."); }
                foreach (var detail in patch.WorkstationProbes.Values) { Domenia.Core.Poste.PosteProbeCache.Validate(detail, clock.GetUtcNow()); }
                foreach (var metadata in patch.WorkstationSecrets.Values) { Domenia.Core.Poste.PosteSecretCache.Validate(metadata, clock.GetUtcNow()); }
                foreach (var sessions in patch.WorkstationSessions.Values) { Domenia.Core.Poste.PosteSessionCache.Validate(sessions, clock.GetUtcNow()); }
                foreach (var details in patch.WorkstationDetails.Values)
                {
                    if (details.Count > 4) throw new InvalidDataException("Trop de familles de relevés détaillés.");
                    foreach (var (family, memory) in details) Domenia.Core.Poste.PosteDetailCache.Validate(memory, family, clock.GetUtcNow());
                }
                var merged = ReadFleet(db).Merge(patch);
                foreach (var probe in patch.Probes.ByProbe.SelectMany(p => p.Value.Keys.Select(id => merged.Probes.ByProbe[p.Key][id])))
                {
                    if (!ProbeDefinitionIdentity.Valid(probe.DefinitionHash) || probe.Historical is { } history &&
                        (!ProbeDefinitionIdentity.Valid(history.DefinitionHash) || history.Values.IsDefault || history.Values.Length > 2000
                            || history.Values.Any(v => v is null || v.Length > 4096) || history.At == DateTimeOffset.MinValue || history.At > clock.GetUtcNow().AddMinutes(2)))
                        throw new InvalidDataException("Empreinte ou historique de sonde invalide.");
                }

                // Timestamp only snapshots really written by this transaction; no timestamp is exposed before Commit.
                var writtenAt = clock.GetUtcNow();
                foreach (var id in patch.WorkstationProbes.Keys)
                    if (merged.WorkstationProbes.TryGetValue(id, out var probes))
                        merged = merged with { WorkstationProbes = merged.WorkstationProbes.SetItem(id, probes with { StoredAt = writtenAt }) };
                var previousHeader = db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") as string;
                var computers = patch.Observations.Workstations.Select(o => o.ComputerGuid).Concat(patch.Machines.Keys)
                    .Concat(patch.Addresses.Keys).Concat(patch.Inventories.Keys).Concat(patch.WorkstationProbes.Keys).Concat(patch.WorkstationSecrets.Keys).Concat(patch.WorkstationSessions.Keys).Concat(patch.WorkstationDetails.Keys)
                    .Concat(patch.Probes.ByProbe.Values.SelectMany(p => p.Keys)).Distinct();
                var scopes = patch.BitLocker.Select(p => merged.Facts.BitLocker.Single(v => ScopeRules.SameScope(new(v.ScopeDn, "", v.Subtree), new(p.ScopeDn, "", p.Subtree))));
                var payload = IsRowsFleet(previousHeader) ? WriteFleetRows(db, merged, computers, scopes) : WriteFleetRows(db, merged, replace: true);
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                var stamp = FleetStamp(db);
                CollectionWrites.Validate(patch.CollectionContext, StoreId, DomainDn);
                db.Commit();
                // Every affected row and the header were read back within this committed transaction.
                // Publish only now: another instance's later generation will invalidate this snapshot.
                RememberFleetRows(payload, stamp, merged);
                return WithAssociationCount(db, merged);
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private CachedFleet ReadFleet(SqliteDatabase db)
    {
        var json = Table(db, "domenia_v2_metadata") ? db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") as string : null;
        return WithAssociationCount(db, IsRowsFleet(json) ? ReadFleetRows(db, json!) : DecodeFleet(json));
    }

    private CachedFleet DecodeFleet(string? json)
    {
        if (json is null) { return CachedFleet.Empty(StoreId); }
        lock (fleetDecodeGate)
        {
            // Compare actual persisted bytes, not just revision: legacy tools can change a row without advancing it.
            if (decodedFleet is not null && string.Equals(json, decodedFleetPayload, StringComparison.Ordinal)) { return decodedFleet; }
            var fleet = JsonSerializer.Deserialize<CachedFleet>(json, Json) ?? throw new InvalidDataException("Relevés locaux illisibles.");
            if (fleet.Facts is null || fleet.Observations is null || fleet.Probes is null || fleet.Facts.StoreId != StoreId)
            { throw new InvalidDataException("Relevés d’une autre base locale ou format non reconnu."); }
            decodedFleetPayload = json; decodedFleet = fleet; fleetRowsSnapshot = null;
            return fleet;
        }
    }

    private static CachedFleet WithAssociationCount(SqliteDatabase db, CachedFleet fleet)
    {
        var associations = Table(db, "user_machine_links") ? checked((int)(long)db.Scalar("SELECT count(*) FROM user_machine_links;")!) : 0;
        return fleet with { Facts = fleet.Facts with { Associations = associations } };
    }
}
