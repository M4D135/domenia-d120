using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    public Task<CachedFleet> ReadFleetAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return CachedFleet.Empty(StoreId); }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
        db.Begin(write: false);
        CheckIdentity(db, allowLegacy: true);
        var result = ReadFleet(db);
        db.Commit();
        return result;
    }, cancellationToken);

    public async Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(patch);
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady();
                CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = new SqliteDatabase(Path, readOnly: false, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: false);
                EnsureBackup(db, cancellationToken);
                db.Script("PRAGMA synchronous=FULL;");
                db.Begin();
                CheckIdentity(db, allowLegacy: false);
                var identities = db.Query("SELECT object_guid,dn FROM domenia_v2_objects WHERE kind='computer';")
                    .ToDictionary(r => Guid.Parse((string)r["object_guid"]!), r => (string)r["dn"]!);
                var ids = patch.Observations.Workstations.Select(o => o.ComputerGuid).Concat(patch.Machines.Keys)
                    .Concat(patch.Addresses.Keys).Concat(patch.Inventories.Keys).Concat(patch.WorkstationProbes.Keys)
                    .Concat(patch.Probes.ByProbe.Values.SelectMany(p => p.Keys)).Concat(patch.BitLocker.SelectMany(p => p.Machines.Keys));
                if (ids.Any(id => !identities.TryGetValue(id, out var dn) || !InDomain(dn)))
                { throw new InvalidDataException("Relevé d’un poste inconnu ou d’un autre domaine : aucune écriture."); }
                if (patch.Observations.Workstations.Select(o => o.ComputerGuid).Distinct().Count() != patch.Observations.Workstations.Length)
                { throw new InvalidDataException("Identité dupliquée dans le relevé."); }
                var dates = patch.Observations.Workstations.SelectMany(o => new[] { o.Presence.CheckedAt, o.Presence.LastOnlineAt, o.Inventory.CheckedAt })
                    .Concat(patch.Machines.Values.SelectMany(m => new[] { m.ConsoleAt, m.BiosAt, m.WmiAt }))
                    .Concat(patch.Probes.ByProbe.Values.SelectMany(p => p.Values.Select(v => v.At)))
                    .Concat(patch.BitLocker.Select(b => (DateTimeOffset?)b.At)).Concat(patch.Addresses.Values.SelectMany(v => v.Select(a => a.ObservedAt)))
                    .Concat(patch.Inventories.Values.Select(v => (DateTimeOffset?)v.CollectedAt)).Append(patch.Observations.TakenAt);
                if (dates.Any(d => d == DateTimeOffset.MinValue || d > clock.GetUtcNow().AddMinutes(2)))
                { throw new InvalidDataException("Date de relevé invalide ou future."); }
                if (patch.Addresses.Values.Any(v => v.IsDefaultOrEmpty || v.Length > 256 || v.Any(a => a.ObservedAt is null
                    || a.Ip is not null && SearchText.ParseAddress(a.Ip)?.Kind != "ipv4" || a.Mac is not null && SearchText.ParseAddress(a.Mac)?.Kind != "mac")))
                { throw new InvalidDataException("Adresses de poste invalides ou non datées."); }
                foreach (var presence in patch.BitLocker)
                {
                    var scope = new ScopeSelection(presence.ScopeDn, "", presence.Subtree);
                    if (!InDomain(scope.Dn) || ScopeRules.IsDomainRoot(scope, DomainDn) || presence.Machines.Any(p => p.Value.Keys < 0 || !ScopeRules.Contains(scope, identities[p.Key]) || p.Value.Newest > presence.At))
                    { throw new InvalidDataException("Présence BitLocker hors du périmètre ou incohérente."); }
                }
                if (patch.Probes.ByProbe.Keys.Any(id => ProbeCatalog.Find(id) is null)) { throw new InvalidDataException("Sonde non reconnue."); }
                foreach (var detail in patch.WorkstationProbes.Values) { Domenia.Core.Poste.PosteProbeCache.Validate(detail, clock.GetUtcNow()); }
                var merged = ReadFleet(db).Merge(patch);
                var payload = JsonSerializer.Serialize(merged, Json);
                db.Execute("INSERT INTO domenia_v2_metadata(key,payload) VALUES('fleet',?1) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload;", payload);
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                db.Commit();
                // Read the committed value back before acknowledging it to the source.
                return ReadFleet(db);
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private CachedFleet ReadFleet(SqliteDatabase db)
    {
        var json = Table(db, "domenia_v2_metadata") ? db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") as string : null;
        var fleet = json is null ? CachedFleet.Empty(StoreId) : JsonSerializer.Deserialize<CachedFleet>(json, Json)
            ?? throw new InvalidDataException("Relevés locaux illisibles.");
        if (fleet.Facts.StoreId != StoreId) { throw new InvalidDataException("Relevés d’une autre base locale."); }
        var associations = Table(db, "user_machine_links") ? checked((int)(long)db.Scalar("SELECT count(*) FROM user_machine_links;")!) : 0;
        return fleet with { Facts = fleet.Facts with { Associations = associations } };
    }
}
