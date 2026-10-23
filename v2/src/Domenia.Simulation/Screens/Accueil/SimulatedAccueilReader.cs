using System.Collections.Concurrent;
using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Accueil;
using QueryComputerIdentity = Domenia.Core.Queries.QueryComputerIdentity;

namespace Domenia.Simulation;

/// <summary>
/// Home page reader of the simulation (docs/ops/accueil.md § 10): facts the generated world does not carry (console users,
/// BIOS versions, WMI answers, recorded OU collections), daily snapshots of the fleet figures, BitLocker presence and probe
/// readings, all derived from the world and from the sub-stream « screen/accueil »: the central generator is untouched and
/// the same seed gives the same data. Nothing leaves the memory; delays are realistic and cancellable.
/// </summary>
public sealed class SimulatedAccueilReader : IAccueilReader
{
    private readonly SimulatedDirectorySource source;
    private readonly Lazy<AccueilFacts> facts;
    private readonly ConcurrentDictionary<string, Lazy<ImmutableArray<FleetSnapshot>>> histories = new(StringComparer.Ordinal);

    public SimulatedAccueilReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
        facts = new Lazy<AccueilFacts>(BuildFacts, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public async Task<AccueilFacts> FactsAsync(CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("accueil/facts", 20, 60, cancellationToken).ConfigureAwait(false);
        return facts.Value;
    }

    public async Task<ImmutableArray<FleetSnapshot>> HistoryAsync(ScopeSelection scope, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scope);
        await source.SimulateScreenLatencyAsync("accueil/history", 30, 90, cancellationToken).ConfigureAwait(false);
        var key = CollectionClocks.Key(scope.Dn, scope.Subtree);
        return histories.GetOrAdd(key, _ => new Lazy<ImmutableArray<FleetSnapshot>>(() => BuildHistory(scope), LazyThreadSafetyMode.ExecutionAndPublication)).Value;
    }

    public async Task<BitLockerPresence> ReadBitLockerAsync(ScopeSelection scope, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scope);
        await source.SimulateScreenLatencyAsync("accueil/bitlocker", 350, 800, cancellationToken).ConfigureAwait(false);
        return Presence(scope, source.Clock.GetUtcNow());
    }

    /// <summary>BitLocker presence of an OU as read at <paramref name="at"/>: no key date after the read.</summary>
    private BitLockerPresence Presence(ScopeSelection scope, DateTimeOffset at)
    {
        var world = source.World;
        var random = source.ScreenStream("accueil").Fork("bitlocker");
        var builder = ImmutableDictionary.CreateBuilder<Guid, BitLockerFact>();
        // Same draw for a computer whatever the OU read: one ordered pass over every computer of the world.
        foreach (var computer in world.Directory.Computers)
        {
            var roll = random.Next(100);
            var keys = roll < 8 ? 0 : roll < 80 ? 1 : 2;
            var span = world.Reference - computer.WhenCreated;
            var newest = keys == 0 ? (DateTimeOffset?)null : computer.WhenCreated + TimeSpan.FromHours(random.Next(1, Math.Max(2, (int)Math.Min(span.TotalHours, 24 * 600))));
            if (newest > at)
            {
                newest = at - TimeSpan.FromHours(1);
            }
            if (ScopeRules.Contains(scope, computer.DistinguishedName) && keys > 0 && computer.WhenCreated <= at)
            {
                builder[computer.ObjectGuid] = new BitLockerFact(keys, newest);
            }
        }
        return new BitLockerPresence(scope.Dn, scope.Subtree, at, true, false, builder.ToImmutable());
    }

    public async Task<ProbeReadings> CollectProbesAsync(ImmutableArray<string> probeIds, ScopeSelection scope, IReadOnlyCollection<Guid> online, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scope);
        ArgumentNullException.ThrowIfNull(online);
        await source.SimulateScreenLatencyAsync("accueil/probes", 400, 1100, cancellationToken).ConfigureAwait(false);
        var world = source.World;
        var now = source.Clock.GetUtcNow();
        var known = facts.Value;
        var inventories = world.Observations.Workstations.ToDictionary(o => o.ComputerGuid, o => o.Inventory);
        var wanted = source.CurrentDirectory.Computers.Where(c => online.Contains(c.ObjectGuid) && ScopeRules.Contains(scope, c.DistinguishedName)).Select(c => c.ObjectGuid).ToHashSet();
        var result = ImmutableDictionary.CreateBuilder<string, ImmutableDictionary<Guid, ProbeReading>>(StringComparer.Ordinal);
        foreach (var id in probeIds)
        {
            var probe = ProbeCatalog.Find(id);
            if (probe is null)
            {
                continue;
            }
            var random = source.ScreenStream("accueil").Fork("probe/" + id);
            var readings = ImmutableDictionary.CreateBuilder<Guid, ProbeReading>();
            foreach (var computer in world.Directory.Computers)
            {
                // One draw per computer of the world, in order, so a value never depends on the OU read.
                var draw = random.Fork(computer.ObjectGuid.ToString("N"));
                if (!wanted.Contains(computer.ObjectGuid))
                {
                    continue;
                }
                var refused = probe.Namespace.Contains("Security", StringComparison.OrdinalIgnoreCase) && draw.Next(100) < 3;
                if (refused)
                {
                    readings[computer.ObjectGuid] = new ProbeReading(MeasureState.Refused, now, [], "Accès refusé (0x80070005) : le fournisseur exige un administrateur local du poste.");
                    continue;
                }
                var inventory = inventories.GetValueOrDefault(computer.ObjectGuid) ?? InventoryMeasure.Unread;
                var values = SimulatedProbeValues.Generate(probe, computer, inventory, known.Machines.GetValueOrDefault(computer.ObjectGuid), draw, now);
                readings[computer.ObjectGuid] = new ProbeReading(MeasureState.Known, now, values, null);
            }
            result[id] = readings.ToImmutable();
        }
        return new ProbeReadings(result.ToImmutable());
    }

    public Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlySet<Guid> targets, CancellationToken cancellationToken) =>
        source.RefreshInventoryAsync(scope, targets, cancellationToken);

    public Task<DirectoryState> ReadPresenceAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, CancellationToken token) =>
        source.RefreshFrozenAsync(scope, targets, expectedEpoch, false, token);

    public Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long expectedEpoch, CancellationToken token) =>
        source.RefreshFrozenAsync(scope, targets, expectedEpoch, true, token);

    // ---------------------------------------------------------------- facts

    private AccueilFacts BuildFacts()
    {
        var world = source.World;
        var random = source.ScreenStream("accueil").Fork("facts");
        var reference = world.Reference;
        var users = world.Directory.Users.Where(u => !AdValues.IsDisabled(u.UserAccountControl) && u.DistinguishedName.EndsWith("OU=Utilisateurs," + SimulationProfile.RootDn, StringComparison.OrdinalIgnoreCase)).ToList();
        var usersBySite = users.GroupBy(u => u.Office ?? "Paris", StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.ToList(), StringComparer.Ordinal);
        var userByDn = world.Directory.Users.ToDictionary(u => u.DistinguishedName, StringComparer.OrdinalIgnoreCase);
        var observations = world.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var machines = ImmutableDictionary.CreateBuilder<Guid, MachineFacts>();
        var noInventory = new List<Guid>();
        foreach (var computer in world.Directory.Computers)
        {
            if (!observations.TryGetValue(computer.ObjectGuid, out var o))
            {
                continue;
            }
            var draw = random.Fork(computer.ObjectGuid.ToString("N"));
            string? user = null;
            DateTimeOffset? consoleAt = null;
            if (o.Presence.HasReading && o.Presence.Answered == true)
            {
                if (computer.ManagedByDn is string owner && userByDn.TryGetValue(owner, out var managed))
                {
                    user = SimulationProfile.NetbiosName + "\\" + managed.SamAccountName;
                }
                else if (usersBySite.TryGetValue(SiteOf(computer.DistinguishedName), out var people) && people.Count > 0)
                {
                    user = SimulationProfile.NetbiosName + "\\" + people[draw.Next(people.Count)].SamAccountName;
                }
                consoleAt = o.Presence.CheckedAt;
            }
            string? bios = null;
            DateTimeOffset? biosAt = null;
            var state = MeasureState.Absent;
            DateTimeOffset? wmiAt = null;
            string? error = null;
            switch (o.Inventory.State)
            {
                case MeasureState.Known when o.Inventory.CheckedAt is not null:
                    state = MeasureState.Known;
                    wmiAt = o.Inventory.CheckedAt;
                    if (draw.Next(100) < 86)
                    {
                        bios = Bios(o.Inventory.Model, draw);
                        biosAt = o.Inventory.CheckedAt;
                    }
                    break;
                case MeasureState.Error:
                    state = MeasureState.Error;
                    wmiAt = reference - TimeSpan.FromHours(draw.Next(2, 30));
                    error = "Délai dépassé : le service WMI du poste ne répond pas (RPC indisponible).";
                    break;
                case MeasureState.Expired:
                    state = MeasureState.Expired;
                    wmiAt = o.Inventory.CheckedAt;
                    break;
                default:
                    noInventory.Add(computer.ObjectGuid);
                    break;
            }
            machines[computer.ObjectGuid] = new MachineFacts(user, consoleAt, bios, biosAt, state, wmiAt, error);
        }
        // Two workstations without inventory refused the WMI read (access denied): the reason stays visible (point 3).
        random.Fork("refused").Shuffle(noInventory);
        foreach (var guid in noInventory.Take(2))
        {
            var known = machines[guid];
            machines[guid] = known with { WmiState = MeasureState.Refused, WmiAt = reference - TimeSpan.FromHours(5), WmiError = "Accès refusé (0x80070005)." };
        }
        var domain = SimulationProfile.RootDn;
        var postes = "OU=Postes," + domain;
        string Ou(string site) => "OU=" + site + "," + postes;
        var directory = world.Directory;
        // Morning presence check of the day (yesterday's when the reference comes before it): never a date in the future.
        var morning = LocalDays.StartOf(LocalDays.DateOf(reference, world.TimeZone), world.TimeZone) + TimeSpan.FromHours(7.5);
        if (morning + TimeSpan.FromSeconds(31) > reference)
        {
            morning -= TimeSpan.FromDays(1);
        }
        var runs = new List<CollectionRun>
        {
            Run(CollectionFamily.Directory, domain, CollectionStatus.Success, reference - TimeSpan.FromMinutes(12), TimeSpan.FromSeconds(41), null, null, directory.ObjectCount, null),
            Run(CollectionFamily.Presence, Ou("Paris"), CollectionStatus.Success, reference - TimeSpan.FromMinutes(28), TimeSpan.FromSeconds(19), null, 186, 186, 0),
            Run(CollectionFamily.Inventory, Ou("Lyon"), CollectionStatus.Success, reference - TimeSpan.FromMinutes(55), TimeSpan.FromMinutes(3), null, 82, 74, 0),
            Run(CollectionFamily.Presence, Ou("Lyon"), CollectionStatus.Success, reference - TimeSpan.FromMinutes(302), TimeSpan.FromSeconds(9), null, 82, 82, 0),
            Run(CollectionFamily.Directory, domain, CollectionStatus.Success, reference - TimeSpan.FromHours(25), TimeSpan.FromSeconds(44), null, null, directory.ObjectCount - 2, null),
            Run(CollectionFamily.Inventory, Ou("Paris"), CollectionStatus.Success, reference - TimeSpan.FromHours(26), TimeSpan.FromMinutes(7), null, 186, 171, 0),
            Run(CollectionFamily.Presence, Ou("Marseille"), CollectionStatus.Partial, reference - TimeSpan.FromHours(28), TimeSpan.FromSeconds(12), "3 postes avec une lecture non confirmée (sondes refusées) ; 64/64 postes traités.", 64, 64, 3),
            Run(CollectionFamily.Directory, domain, CollectionStatus.Success, reference - TimeSpan.FromHours(51), TimeSpan.FromSeconds(39), null, null, directory.ObjectCount - 5, null),
            Run(CollectionFamily.Directory, postes, CollectionStatus.Success, reference - TimeSpan.FromDays(3), TimeSpan.FromSeconds(16), null, null, 431 + 6, null),
            Run(CollectionFamily.Inventory, postes, CollectionStatus.Partial, reference - TimeSpan.FromDays(6), TimeSpan.FromMinutes(14), "41 postes sans relevé utilisable (absents, sondes en erreur ou refusées) ; 412/412 postes traités.", 412, 412, 41),
            Run(CollectionFamily.Presence, postes, CollectionStatus.Success, morning, TimeSpan.FromSeconds(31), null, 412, 412, 0),
        };
        var associations = directory.Computers.Count(c => c.ManagedByDn is not null);
        var storeId = "simulation:" + source.Options.Seed.ToString(CultureInfo.InvariantCulture) + ":" + reference.UtcDateTime.ToString("yyyyMMddHHmm", CultureInfo.InvariantCulture);
        // The local base keeps the BitLocker presence read of the workstations three days ago (read again on request).
        var stored = Presence(new ScopeSelection(postes, "Postes", true), reference - TimeSpan.FromDays(3) - TimeSpan.FromMinutes(17));
        return new AccueilFacts(machines.ToImmutable(), 2, [.. runs], associations, storeId, [stored]);
    }

    private CollectionRun Run(CollectionFamily family, string scopeDn, CollectionStatus status, DateTimeOffset started, TimeSpan duration, string? error, long? targets, long? done, long? failed) =>
        CollectionClocks.Create(family, SimulationProfile.RootDn, scopeDn, true, status, started, started + duration, error, targets, done,
            done is long d && failed is long f ? d - f : null, failed, family == CollectionFamily.Directory ? "DC01." + SimulationProfile.DnsName : null, source.World.Reference);

    private static string SiteOf(string dn)
    {
        foreach (var site in SimulationProfile.Sites)
        {
            if (dn.Contains("OU=" + site.Name + ",", StringComparison.OrdinalIgnoreCase))
            {
                return site.Name;
            }
        }
        return "Paris";
    }

    private static string Bios(string? model, SeededRandom draw)
    {
        string[] versions = (model ?? "") switch
        {
            var m when m.StartsWith("Dell Latitude", StringComparison.Ordinal) => ["1.12.1", "1.14.0", "1.15.2"],
            var m when m.StartsWith("Dell OptiPlex", StringComparison.Ordinal) => ["1.9.0", "1.11.1"],
            var m when m.StartsWith("HP EliteBook", StringComparison.Ordinal) => ["01.05.03", "01.06.01"],
            var m when m.StartsWith("HP EliteDesk", StringComparison.Ordinal) => ["02.18.00", "02.21.00", "02.22.00"],
            var m when m.StartsWith("Lenovo ThinkPad", StringComparison.Ordinal) => ["R2FET56W (1.36)", "R2FET60W (1.40)"],
            var m when m.StartsWith("Lenovo ThinkCentre", StringComparison.Ordinal) => ["M4BKT3AA", "M4BKT48A"],
            _ => ["1.0.0"],
        };
        // The newest version is the most frequent one (a campaign of updates is under way).
        var roll = draw.Next(100);
        return roll < 62 ? versions[^1] : versions[draw.Next(versions.Length)];
    }

    // ---------------------------------------------------------------- daily snapshots

    /// <summary>
    /// Daily snapshots of the last 30 days for an OU: the board computed on the state known that day (computers created by
    /// then, readings dated before the end of the day), with the default rules. Missing days stay absent.
    /// </summary>
    private ImmutableArray<FleetSnapshot> BuildHistory(ScopeSelection scope)
    {
        var world = source.World;
        var zone = world.TimeZone;
        var reference = world.Reference;
        var today = LocalDays.DateOf(reference, zone);
        var directory = source.CurrentDirectory;
        var known = facts.Value;
        var snapshots = new List<FleetSnapshot>();
        for (var back = 30; back >= 1; back--)
        {
            var day = today.AddDays(-back);
            var at = LocalDays.StartOf(day, zone) + TimeSpan.FromHours(9);
            var end = LocalDays.StartOf(day.AddDays(1), zone);
            var computers = directory.Computers.Where(c => c.WhenCreated < end).Select(c => c with
            {
                LastLogonTimestamp = c.LastLogonTimestamp is long l && AdValues.FromFileTime(l) is DateTimeOffset when && when > at ? AdValues.ToFileTime(at - TimeSpan.FromHours(14)) : c.LastLogonTimestamp,
                PasswordLastSet = c.PasswordLastSet is long p && AdValues.FromFileTime(p) is DateTimeOffset set && set > at ? AdValues.ToFileTime(at - TimeSpan.FromDays(20)) : c.PasswordLastSet,
            }).ToImmutableArray();
            var observations = world.Observations.Workstations.Select(o => o with
            {
                Presence = o.Presence.CheckedAt is DateTimeOffset checkedAt && checkedAt <= at ? o.Presence : PresenceMeasure.Unread,
                Inventory = o.Inventory.CheckedAt is DateTimeOffset inv && inv <= at ? o.Inventory : InventoryMeasure.Unread,
            }).ToImmutableArray();
            var state = new DirectoryState(directory with { Computers = computers, ReadAt = at - TimeSpan.FromMinutes(20) }, new FleetObservations(at, observations), [], []);
            var input = new FleetBoardInput(state, scope, directory.Domain.RootDn, directory.Domain.DnsName, HealthPolicyBook.Empty(directory.Domain.RootDn),
                known with { Machines = known.Machines.Where(m => m.Value.WmiAt is null || m.Value.WmiAt <= at).ToImmutableDictionary() },
                null, ProbeReadings.Empty, [], [], at, zone);
            var board = FleetBoardCalculator.Compute(input).Board;
            snapshots.Add(board.Snapshot with
            {
                Id = "jour-" + day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                Kind = "daily",
                Label = FleetAnalysis.DailyLabel(day),
                Day = day,
                ComputedAt = at,
            });
        }
        return [.. snapshots];
    }
}
