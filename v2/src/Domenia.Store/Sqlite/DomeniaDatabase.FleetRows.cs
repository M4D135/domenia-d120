using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private const string FleetRowsFormat = "Domenia.FleetRows/1";
    private const string FleetRowsTable = "domenia_v2_fleet_rows";
    private const string FleetRowsState = "domenia_v2_fleet_state";
    private const long FleetSnapshotBytes = 512L * 1024 * 1024;
    private const int FleetRowBytes = 16 * 1024 * 1024;
    private sealed record FleetRowsHeader(string Format, string StoreId, DateTimeOffset? TakenAt, int RejectedObservations, ImmutableArray<CollectionRun> Runs);
    private sealed record FleetComputerRow(WorkstationObservation? Observation, MachineFacts? Machine,
        ImmutableDictionary<string, ProbeReading> Probes, ImmutableArray<SearchAddressReading> Addresses, InventorySnapshot? Inventory,
        ProbeStore? WorkstationProbes, WorkstationSecretMetadata? Secrets, WorkstationSessionMemory? Sessions, ImmutableDictionary<string, PosteDetailMemory>? Details = null);
    private readonly record struct FleetRowsStamp(long Generation, long Schema, long Computers, long Scopes, long Bytes);
    private sealed record FleetRowsSnapshot(string Header, FleetRowsStamp Stamp, CachedFleet Fleet);
    private FleetRowsSnapshot? fleetRowsSnapshot;

    // Every supported row mutation advances a transaction-local generation, including an external
    // SQLite writer that does not know domenia_store_state.revision. A dropped/recreated trigger
    // also changes schema_version and invalidates the snapshot before any cached value is reused.
    private static readonly string[] FleetRowGuards = [.. new[] { "INSERT", "UPDATE", "DELETE" }.Select(FleetGuard),
        "CREATE TRIGGER domenia_fleet_state_monotonic BEFORE UPDATE ON " + FleetRowsState + " WHEN OLD.generation=9223372036854775807 OR NEW.generation<>OLD.generation+1 BEGIN SELECT RAISE(ABORT,'Fleet generation must advance'); END",
        "CREATE TRIGGER domenia_fleet_state_unique BEFORE INSERT ON " + FleetRowsState + " WHEN EXISTS(SELECT 1 FROM " + FleetRowsState + ") BEGIN SELECT RAISE(ABORT,'Fleet generation cannot be replaced'); END",
        "CREATE TRIGGER domenia_fleet_state_immutable BEFORE DELETE ON " + FleetRowsState + " BEGIN SELECT RAISE(ABORT,'Fleet generation cannot be removed'); END"];
    private static string FleetGuard(string action)
    {
        string Delta(string expression) => action == "INSERT" ? expression.Replace("ROW.", "NEW.", StringComparison.Ordinal)
            : action == "DELETE" ? "-(" + expression.Replace("ROW.", "OLD.", StringComparison.Ordinal) + ")"
            : "(" + expression.Replace("ROW.", "NEW.", StringComparison.Ordinal) + ")-(" + expression.Replace("ROW.", "OLD.", StringComparison.Ordinal) + ")";
        return "CREATE TRIGGER domenia_fleet_rows_" + action.ToLowerInvariant() + " AFTER " + action + " ON " + FleetRowsTable
            + " BEGIN UPDATE " + FleetRowsState + " SET generation=CASE WHEN generation=9223372036854775807 THEN RAISE(ABORT,'Fleet generation exhausted') ELSE generation+1 END,"
            + "computers=computers+(" + Delta("CASE WHEN ROW.kind='computer' THEN 1 ELSE 0 END") + "),"
            + "scopes=scopes+(" + Delta("CASE WHEN ROW.kind='scope' THEN 1 ELSE 0 END") + "),"
            + "bytes=bytes+(" + Delta("length(CAST(ROW.payload AS BLOB))") + ") WHERE id=1;"
            + " SELECT CASE WHEN changes()<>1 THEN RAISE(ABORT,'Fleet generation missing') END; END";
    }

    private static string FleetHash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    private static string NormalizeFleetGuard(string? sql) => (sql ?? "").Replace("IF NOT EXISTS ", "", StringComparison.Ordinal).Trim().TrimEnd(';');
    private static bool KnownFleetGuard(string? sql) => FleetRowGuards.Contains(NormalizeFleetGuard(sql), StringComparer.Ordinal);

    private static bool IsRowsFleet(string? json)
    {
        if (json is null || json.Length > 1_048_576) { return false; }
        using var document = JsonDocument.Parse(json);
        if (!document.RootElement.TryGetProperty("format", out var format)) { return false; }
        if (format.GetString() != FleetRowsFormat) { throw new InvalidDataException("Version du cache de parc non prise en charge."); }
        return true;
    }

    private void EnsureFleetRows(SqliteDatabase db)
    {
        db.Script("CREATE TABLE IF NOT EXISTS " + FleetRowsTable + "(row_key TEXT PRIMARY KEY NOT NULL,kind TEXT NOT NULL CHECK(kind IN ('computer','scope')),payload TEXT NOT NULL,sha256 TEXT NOT NULL);"
            + "CREATE TABLE IF NOT EXISTS " + FleetRowsState + "(id INTEGER PRIMARY KEY CHECK(id=1),generation INTEGER NOT NULL CHECK(generation>=0),"
            + "computers INTEGER NOT NULL CHECK(computers BETWEEN 0 AND 100000),scopes INTEGER NOT NULL CHECK(scopes BETWEEN 0 AND 4096),bytes INTEGER NOT NULL CHECK(bytes BETWEEN 0 AND 536870912));"
            + "INSERT INTO " + FleetRowsState + "(id,generation,computers,scopes,bytes) SELECT 1,0,0,0,0 WHERE NOT EXISTS(SELECT 1 FROM " + FleetRowsState + ");");
        foreach (var guard in FleetRowGuards) { db.Script(guard.Replace("CREATE TRIGGER ", "CREATE TRIGGER IF NOT EXISTS ", StringComparison.Ordinal) + ";"); }
        if (!FleetGuardsIntact(db)) { throw new InvalidDataException("Protection du cache de parc modifiée ; aucune écriture."); }
    }

    private static bool FleetGuardsIntact(SqliteDatabase db)
    {
        var guards = db.Query("SELECT sql FROM sqlite_master WHERE type='trigger' AND name IN ('domenia_fleet_rows_insert','domenia_fleet_rows_update','domenia_fleet_rows_delete','domenia_fleet_state_monotonic','domenia_fleet_state_unique','domenia_fleet_state_immutable');");
        return guards.Count == FleetRowGuards.Length && guards.All(row => KnownFleetGuard(row["sql"] as string));
    }

    private static FleetRowsStamp FleetStamp(SqliteDatabase db)
    {
        if (!Table(db, FleetRowsState) || !Table(db, FleetRowsTable))
        { throw new InvalidDataException("Génération du cache de parc absente ou invalide."); }
        var state = db.Query("SELECT generation,computers,scopes,bytes FROM " + FleetRowsState + " WHERE id=1;").SingleOrDefault();
        if (state is null || state["generation"] is not long generation || generation < 0
            || state["computers"] is not long computers || computers is < 0 or > OperationsPersistence.MaxTargets
            || state["scopes"] is not long scopes || scopes is < 0 or > 4096
            || state["bytes"] is not long bytes || bytes is < 0 or > FleetSnapshotBytes)
        { throw new InvalidDataException("Compteurs du cache de parc absents ou hors limites."); }
        return new(generation, (long)db.Scalar("PRAGMA schema_version;")!, computers, scopes, bytes);
    }

    private CachedFleet ReadFleetRows(SqliteDatabase db, string json)
    {
        var header = JsonSerializer.Deserialize<FleetRowsHeader>(json, Json) ?? throw new InvalidDataException("En-tête du parc illisible.");
        if (header.Format != FleetRowsFormat || header.StoreId != StoreId || header.Runs.IsDefault || header.RejectedObservations < 0)
        { throw new InvalidDataException("Identité ou version du cache de parc incohérente."); }
        var stamp = FleetStamp(db); var guards = FleetGuardsIntact(db);
        lock (fleetDecodeGate)
        {
            if (guards && fleetRowsSnapshot is { } saved && saved.Header == json && saved.Stamp == stamp)
            { return saved.Fleet; }
        }
        var observations = ImmutableDictionary.CreateBuilder<Guid, WorkstationObservation>();
        var machines = ImmutableDictionary.CreateBuilder<Guid, MachineFacts>();
        var probes = new Dictionary<string, ImmutableDictionary<Guid, ProbeReading>.Builder>(StringComparer.Ordinal);
        var addresses = ImmutableDictionary.CreateBuilder<Guid, ImmutableArray<SearchAddressReading>>();
        var inventories = ImmutableDictionary.CreateBuilder<Guid, InventorySnapshot>();
        var detailed = ImmutableDictionary.CreateBuilder<Guid, ProbeStore>();
        var secrets = ImmutableDictionary.CreateBuilder<Guid, WorkstationSecretMetadata>();
        var sessions = ImmutableDictionary.CreateBuilder<Guid, WorkstationSessionMemory>();
        var details = ImmutableDictionary.CreateBuilder<Guid, ImmutableDictionary<string, PosteDetailMemory>>();
        var bitlocker = ImmutableArray.CreateBuilder<BitLockerPresence>();
        foreach (var (key, kind, payload) in FleetStoredRows(db))
        {
            if (kind == "scope")
            {
                var scope = JsonSerializer.Deserialize<BitLockerPresence>(payload, Json) ?? throw new InvalidDataException("Présence BitLocker illisible.");
                if (scope.Machines is null || !InDomain(scope.ScopeDn) || FleetScopeKey(scope) != key) { throw new InvalidDataException("Périmètre du cache BitLocker incohérent."); }
                bitlocker.Add(scope); continue;
            }
            if (kind != "computer" || !Guid.TryParseExact(key, "D", out var id) || id == Guid.Empty)
            { throw new InvalidDataException("Clé du cache de parc non reconnue."); }
            var item = JsonSerializer.Deserialize<FleetComputerRow>(payload, Json) ?? throw new InvalidDataException("Cache de poste illisible.");
            if (item.Probes is null || item.Addresses.IsDefault || item.Addresses.Length > 256 || item.Observation is { } observation && observation.ComputerGuid != id)
            { throw new InvalidDataException("Identité ou contenu du cache de poste incohérent."); }
            if (item.Observation is { } row) { observations.Add(id, row); }
            if (item.Machine is { } machine) { machines.Add(id, machine); }
            foreach (var (probe, reading) in item.Probes)
            {
                if (Domenia.Core.Accueil.ProbeCatalog.Find(probe) is null && !PersonalProbeCatalog.IsKey(probe)) { throw new InvalidDataException("Sonde de parc inconnue."); }
                if (!probes.TryGetValue(probe, out var values)) { probes.Add(probe, values = ImmutableDictionary.CreateBuilder<Guid, ProbeReading>()); }
                values.Add(id, reading);
            }
            if (!item.Addresses.IsEmpty) { addresses.Add(id, item.Addresses); }
            if (item.Inventory is { } inventory) { inventories.Add(id, inventory); }
            if (item.WorkstationProbes is { } detail) { detailed.Add(id, detail); }
            if (item.Secrets is { } secret) { secrets.Add(id, secret); }
            if (item.Sessions is { } session) { sessions.Add(id, session); }
            if (item.Details is { } records)
            {
                if (records.Count > 4) throw new InvalidDataException("Trop de familles de relevés détaillés.");
                foreach (var (family, record) in records) PosteDetailCache.Validate(record, family, clock.GetUtcNow());
                details.Add(id, records);
            }
        }
        var fleet = new CachedFleet(FleetObservations.Indexed(header.TakenAt, observations.ToImmutable()),
            new(machines.ToImmutable(), header.RejectedObservations, header.Runs, 0, StoreId, bitlocker.ToImmutable()),
            new(probes.ToImmutableDictionary(p => p.Key, p => p.Value.ToImmutable(), StringComparer.Ordinal)))
        { Addresses = addresses.ToImmutable(), Inventories = inventories.ToImmutable(), WorkstationProbes = detailed.ToImmutable(), WorkstationSecrets = secrets.ToImmutable(), WorkstationSessions = sessions.ToImmutable(), WorkstationDetails = details.ToImmutable() };
        // A rollback may reuse a generation number: never publish an uncommitted read into the
        // process cache. SaveFleet publishes its verified snapshot only after Commit succeeds.
        if (guards && !db.InWriteTransaction) { RememberFleetRows(json, stamp, fleet); }
        return fleet;
    }

    private static IEnumerable<(string Key, string Kind, string Payload)> FleetStoredRows(SqliteDatabase db)
    {
        long bytes = 0; var computers = 0; var scopes = 0;
        foreach (var row in db.ReadRows("SELECT row_key,kind,CASE WHEN length(CAST(payload AS BLOB))<=16777216 THEN payload END AS payload,sha256 FROM " + FleetRowsTable + " ORDER BY row_key;"))
        {
            if (row["row_key"] is not string key || key.Length > 128 || row["kind"] is not string kind || row["payload"] is not string payload || FleetHash(payload) != row["sha256"] as string)
            { throw new InvalidDataException("Ligne du cache de parc hors limites ou empreinte altérée."); }
            bytes += Encoding.UTF8.GetByteCount(payload);
            if (bytes > FleetSnapshotBytes || kind == "computer" && ++computers > OperationsPersistence.MaxTargets || kind == "scope" && ++scopes > 4096)
            { throw new InvalidDataException("Cache de parc supérieur au budget de lecture (100 000 postes, 512 Mio) ; aucune lecture partielle."); }
            yield return (key, kind, payload);
        }
        var state = db.Query("SELECT computers,scopes,bytes FROM " + FleetRowsState + " WHERE id=1;").SingleOrDefault();
        if (state is null || (long)state["computers"]! != computers || (long)state["scopes"]! != scopes || (long)state["bytes"]! != bytes)
        { throw new InvalidDataException("Compteurs du cache de parc incohérents ; aucune lecture partielle."); }
    }

    private static string FleetScopeKey(BitLockerPresence scope) => "scope:" + FleetHash((scope.Subtree ? "tree\n" : "one\n")
        + string.Join('\n', DistinguishedName.Parse(scope.ScopeDn).Select(p => p.Type.ToUpperInvariant() + ":" + p.Value.Length.ToString(CultureInfo.InvariantCulture) + ":" + p.Value.ToUpperInvariant())));

    private static IEnumerable<Guid> FleetComputerIds(CachedFleet fleet) => fleet.Observations.Workstations.Select(o => o.ComputerGuid).Concat(fleet.Facts.Machines.Keys)
        .Concat(fleet.Addresses.Keys).Concat(fleet.Inventories.Keys).Concat(fleet.WorkstationProbes.Keys).Concat(fleet.WorkstationSecrets.Keys).Concat(fleet.WorkstationSessions.Keys).Concat(fleet.WorkstationDetails.Keys)
        .Concat(fleet.Probes.ByProbe.Values.SelectMany(p => p.Keys)).Distinct();

    private static FleetComputerRow ComputerRow(CachedFleet fleet, Guid id) => new(fleet.Observations.Find(id), fleet.Facts.Machines.GetValueOrDefault(id),
        fleet.Probes.ByProbe.Where(p => p.Value.ContainsKey(id)).ToImmutableDictionary(p => p.Key, p => p.Value[id], StringComparer.Ordinal),
        fleet.Addresses.GetValueOrDefault(id, []), fleet.Inventories.GetValueOrDefault(id), fleet.WorkstationProbes.GetValueOrDefault(id),
        fleet.WorkstationSecrets.GetValueOrDefault(id), fleet.WorkstationSessions.GetValueOrDefault(id), fleet.WorkstationDetails.GetValueOrDefault(id));

    private static bool EmptyComputerRow(FleetComputerRow row) => row.Observation is null && row.Machine is null && row.Probes.IsEmpty && row.Addresses.IsEmpty
        && row.Inventory is null && row.WorkstationProbes is null && row.Secrets is null && row.Sessions is null && row.Details is null;

    private static void WriteFleetRow(SqliteDatabase db, string key, string kind, string payload)
    {
        var bytes = Encoding.UTF8.GetByteCount(payload);
        if (bytes > FleetRowBytes) { throw new InvalidDataException("Cache d’un poste supérieur à 16 Mio ; aucune écriture partielle."); }
        var previous = db.Query("SELECT kind,length(CAST(payload AS BLOB)) AS bytes FROM " + FleetRowsTable + " WHERE row_key=?1;", key).SingleOrDefault();
        var state = db.Query("SELECT computers,scopes,bytes FROM " + FleetRowsState + " WHERE id=1;").Single();
        if ((long)state["bytes"]! + bytes - (previous?["bytes"] as long? ?? 0) > FleetSnapshotBytes
            || previous is null && kind == "computer" && (long)state["computers"]! >= OperationsPersistence.MaxTargets
            || previous is null && kind == "scope" && (long)state["scopes"]! >= 4096)
        { throw new InvalidDataException("Budget du cache atteint (100 000 postes, 512 Mio) ; aucune écriture partielle, examinez la conservation des anciens relevés."); }
        var hash = FleetHash(payload);
        db.Execute("INSERT INTO " + FleetRowsTable + "(row_key,kind,payload,sha256) VALUES(?1,?2,?3,?4) ON CONFLICT(row_key) DO UPDATE SET kind=excluded.kind,payload=excluded.payload,sha256=excluded.sha256 WHERE kind<>excluded.kind OR payload<>excluded.payload OR sha256<>excluded.sha256;", key, kind, payload, hash);
        if (db.Scalar("SELECT payload FROM " + FleetRowsTable + " WHERE row_key=?1 AND kind=?2 AND sha256=?3;", key, kind, hash) as string != payload)
        { throw new InvalidDataException("Cache de poste différent après écriture ; transaction annulée."); }
    }

    /// <summary>Called within the existing write transaction; full replacement is reserved for migration/maintenance.</summary>
    private string WriteFleetRows(SqliteDatabase db, CachedFleet fleet, IEnumerable<Guid>? computers = null, IEnumerable<BitLockerPresence>? scopes = null, bool replace = false)
    {
        var prior = db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") as string;
        if (prior is not null && !IsRowsFleet(prior))
        {
            if (lastBackup is null) { throw new InvalidDataException("Sauvegarde antérieure à la migration absente."); }
            using var copy = OpenPath(lastBackup.Path, true);
            if (copy.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") as string != prior)
            { throw new InvalidDataException("Cache modifié depuis la sauvegarde de migration ; aucune migration partielle."); }
        }
        EnsureFleetRows(db);
        if (replace) { db.Execute("DELETE FROM " + FleetRowsTable + ";"); }
        foreach (var id in computers ?? FleetComputerIds(fleet))
        {
            var row = ComputerRow(fleet, id);
            if (EmptyComputerRow(row)) { db.Execute("DELETE FROM " + FleetRowsTable + " WHERE row_key=?1;", id.ToString("D")); }
            else { WriteFleetRow(db, id.ToString("D"), "computer", JsonSerializer.Serialize(row, Json)); }
        }
        foreach (var scope in scopes ?? fleet.Facts.BitLocker) { WriteFleetRow(db, FleetScopeKey(scope), "scope", JsonSerializer.Serialize(scope, Json)); }
        var header = JsonSerializer.Serialize(new FleetRowsHeader(FleetRowsFormat, fleet.Facts.StoreId, fleet.Observations.TakenAt, fleet.Facts.RejectedObservations, fleet.Facts.Runs), Json);
        if (Encoding.UTF8.GetByteCount(header) > 1_048_576) { throw new InvalidDataException("En-tête du cache de parc hors limites."); }
        db.Execute("INSERT INTO domenia_v2_metadata(key,payload) VALUES('fleet',?1) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload;", header);
        if (db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") as string != header) { throw new InvalidDataException("En-tête du parc différent après écriture."); }
        // Older packs explicitly reject revision 2. The existing verified pre-write backup remains
        // the rollback path; no old reader may mistake this header for an empty monolithic fleet.
        db.Execute("UPDATE schema_info SET value='2' WHERE key='domenia_schema';");
        return header;
    }

    private void RememberFleetRows(string header, FleetRowsStamp stamp, CachedFleet fleet)
    {
        lock (fleetDecodeGate)
        { fleetRowsSnapshot = new(header, stamp, fleet); decodedFleetPayload = null; decodedFleet = null; }
    }

    private void ReplaceFleet(SqliteDatabase db, CachedFleet fleet)
    {
        // Maintenance also upgrades the old monolithic representation atomically, after its existing
        // complete content proof and verified backup have admitted this exact transaction.
        _ = WriteFleetRows(db, fleet, replace: true);
    }

    private void RebindFleet(SqliteDatabase db, string previousStoreId)
    {
        if (!Table(db, "domenia_v2_metadata") || db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") is not string json) { return; }
        if (IsRowsFleet(json))
        {
            var header = JsonSerializer.Deserialize<FleetRowsHeader>(json, Json) ?? throw new InvalidDataException("Cache de parc de la copie illisible.");
            if (header.StoreId != previousStoreId) { throw new InvalidDataException("Cache de parc d’une autre base dans la copie."); }
            var rebound = JsonSerializer.Serialize(header with { StoreId = StoreId }, Json);
            db.Execute("UPDATE domenia_v2_metadata SET payload=?1 WHERE key='fleet';", rebound);
            // A structurally healthy SQLite file can still contain a damaged typed row. Validate
            // every payload/hash before the copy can be published under its new storage identity.
            _ = ReadFleetRows(db, rebound);
        }
        else
        {
            var fleet = JsonSerializer.Deserialize<CachedFleet>(json, Json) ?? throw new InvalidDataException("Relevés de la copie illisibles.");
            if (fleet.Facts.StoreId != previousStoreId) { throw new InvalidDataException("Relevés d’une autre base dans la copie."); }
            db.Execute("UPDATE domenia_v2_metadata SET payload=?1 WHERE key='fleet';", JsonSerializer.Serialize(fleet with { Facts = fleet.Facts with { StoreId = StoreId } }, Json));
        }
    }
}
