using System.Collections.Concurrent;
using System.Collections.Immutable;
using System.Globalization;
using System.Runtime.CompilerServices;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Simulation.Poste;

/// <summary>
/// The fictitious workstations of one simulated source and what the session changed on them (pings, inventories, probe
/// readings, service states, restarts, detected users, secrets index). Memory only, never written; a new session starts from
/// the generated world again. Shared by the reader and the write executors of the same source. Thread safe.
/// </summary>
internal sealed class PosteSimulation
{
    private static readonly ConditionalWeakTable<SimulatedDirectorySource, PosteSimulation> Table = new();

    private readonly SimulatedDirectorySource source;
    private readonly ConcurrentDictionary<Guid, PosteMachine> machines = new();
    private readonly ConcurrentDictionary<Guid, int> draws = new();
    private readonly Lock gate = new();
    private readonly Lazy<SeededRandom> screen;
    private readonly Lazy<ImmutableDictionary<Guid, WorkstationObservation>> initial;

    private readonly Dictionary<Guid, PresenceReading> pings = [];
    private readonly Dictionary<Guid, PosteLive> lives = [];
    private readonly Dictionary<Guid, InventorySnapshot> inventories = [];
    private readonly Dictionary<Guid, ProbeStore> probes = [];
    private readonly Dictionary<Guid, Dictionary<string, string>> serviceStates = [];
    private readonly Dictionary<Guid, DateTimeOffset> boots = [];
    private readonly Dictionary<Guid, (DateTimeOffset At, string Message)> restarts = [];
    private readonly Dictionary<Guid, (UserRef User, DateTimeOffset At, string Method)> detected = [];
    private readonly Dictionary<Guid, (int Keys, DateTimeOffset At)> bitLockerIndex = [];
    private readonly Dictionary<Guid, DateTimeOffset> lapsIndex = [];
    private readonly Dictionary<Guid, DateTimeOffset> wakes = [];
    private readonly Dictionary<(Guid Id, string Resource), string> otherAccounts = [];

    private PosteSimulation(SimulatedDirectorySource source)
    {
        this.source = source;
        screen = new Lazy<SeededRandom>(() => source.ScreenStream("poste"), LazyThreadSafetyMode.ExecutionAndPublication);
        initial = new Lazy<ImmutableDictionary<Guid, WorkstationObservation>>(
            () => source.World.Observations.Workstations.ToImmutableDictionary(o => o.ComputerGuid), LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public static PosteSimulation For(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        return Table.GetValue(source, static s => new PosteSimulation(s));
    }

    public SimulatedDirectorySource Source => source;

    public TimeZoneInfo Zone => source.World.TimeZone;

    public DateTimeOffset Now => source.Clock.GetUtcNow();

    public string? Controller => source.World.Session.Controller?.DnsName;

    public string Reader => source.World.Session.Account.Login;

    /// <summary>The computer at this DN in the directory as the session sees it (exact text, then RFC 4514); poste.unknown otherwise.</summary>
    public DirectoryComputer Find(string dn)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var directory = source.CurrentDirectory;
        var exact = directory.Computers.FirstOrDefault(c => string.Equals(c.DistinguishedName, dn, StringComparison.OrdinalIgnoreCase));
        if (exact is not null)
        {
            return exact;
        }
        return directory.Computers.FirstOrDefault(c => PosteDirectoryWrites.SameDn(c.DistinguishedName, dn))
            ?? throw new DomeniaOperationException(PosteErrors.ComputerUnknown, PosteErrors.ComputerUnknownMessage);
    }

    public DirectoryComputer? FindByGuid(string objectGuid) =>
        Guid.TryParseExact(objectGuid, "D", out var id) ? source.CurrentDirectory.Computers.FirstOrDefault(c => c.ObjectGuid == id) : null;

    /// <summary>The fictitious workstation of a computer, derived once from the generated world, named as the directory says now.</summary>
    public PosteMachine Machine(DirectoryComputer current)
    {
        ArgumentNullException.ThrowIfNull(current);
        var machine = machines.GetOrAdd(current.ObjectGuid, _ =>
        {
            var world = source.World;
            var generated = world.Directory.Computers.FirstOrDefault(c => c.ObjectGuid == current.ObjectGuid) ?? current;
            initial.Value.TryGetValue(current.ObjectGuid, out var observation);
            return PosteMachines.Build(generated, observation, world, world.Directory, screen.Value);
        });
        return ReferenceEquals(machine.Computer, current) ? machine : machine with { Computer = current };
    }

    /// <summary>Next live sub-stream of a workstation (« live/n »): two reads differ a little, a new session replays the same suite.</summary>
    public SeededRandom Live(PosteMachine machine)
    {
        ArgumentNullException.ThrowIfNull(machine);
        var n = draws.AddOrUpdate(machine.Computer.ObjectGuid, 1, (_, v) => v + 1);
        return new SeededRandom(machine.Seed).Fork("live/" + n.ToString(CultureInfo.InvariantCulture));
    }

    /// <summary>True when the probe of this workstation is always in error (docs/SIMULATION.md § 5.1).</summary>
    public bool ErrorProbe(Guid id) => source.World.Presence.ErrorProbes.Contains(id);

    /// <summary>The workstation whose ping is filtered: it answers WMI and never ICMP (Domenia 1 point 72).</summary>
    public bool PingFiltered(Guid id) =>
        source.World.Presence.NeverAnswer.Contains(id) && initial.Value.TryGetValue(id, out var o) && o.Inventory.HasReading;

    /// <summary>Whether a workstation answers the ping now: last ping of the session, else the stored observation.</summary>
    public bool? Answers(Guid id, WorkstationObservation? observation)
    {
        lock (gate)
        {
            if (pings.TryGetValue(id, out var ping))
            {
                return ping.Answered;
            }
        }
        if (ErrorProbe(id) || PingFiltered(id))
        {
            return false;
        }
        if (observation?.Presence is { HasReading: true } presence)
        {
            return presence.Answered;
        }
        return new SeededRandom(source.Options.Seed).Fork("screen/poste/unread/" + id.ToString("N")).Chance(55);
    }

    /// <summary>Whether WMI can be reached: the workstation answers the ping, or its ping is filtered.</summary>
    public bool Reachable(Guid id, WorkstationObservation? observation) => !ErrorProbe(id) && (PingFiltered(id) || Answers(id, observation) == true);

    public void Unreachable(DirectoryComputer c, WorkstationObservation? observation)
    {
        ArgumentNullException.ThrowIfNull(c);
        if (Reachable(c.ObjectGuid, observation))
        {
            return;
        }
        var reason = ErrorProbe(c.ObjectGuid)
            ? c.Name + " ne peut pas être sondé (sonde en erreur) : aucune lecture WMI n’a été lancée. Le diagnostic montre la couche qui bloque."
            : c.Name + " ne répond pas au ping : aucune lecture WMI n’a été lancée. Une absence de réponse ne prouve pas que le poste est éteint ; le diagnostic montre la couche qui bloque.";
        throw new DomeniaOperationException(PosteErrors.Unreachable, reason);
    }

    public PresenceReading? LastPing(Guid id)
    {
        lock (gate)
        {
            return pings.GetValueOrDefault(id);
        }
    }

    public void RecordPing(Guid id, PresenceReading reading)
    {
        lock (gate)
        {
            pings[id] = reading;
        }
    }

    public PosteLive? LastLive(Guid id)
    {
        lock (gate)
        {
            return lives.GetValueOrDefault(id);
        }
    }

    public void RecordLive(Guid id, PosteLive live)
    {
        lock (gate)
        {
            lives[id] = live;
        }
    }

    public InventorySnapshot? SessionInventory(Guid id)
    {
        lock (gate)
        {
            return inventories.GetValueOrDefault(id);
        }
    }

    public void RecordInventory(Guid id, InventorySnapshot inventory)
    {
        lock (gate)
        {
            inventories[id] = inventory;
        }
    }

    public ProbeStore? SessionProbes(Guid id)
    {
        lock (gate)
        {
            return probes.GetValueOrDefault(id);
        }
    }

    public void RecordProbes(Guid id, ProbeStore store)
    {
        lock (gate)
        {
            probes[id] = store;
        }
    }

    public IReadOnlyDictionary<string, string> ServiceStates(Guid id)
    {
        lock (gate)
        {
            return serviceStates.TryGetValue(id, out var states) ? new Dictionary<string, string>(states, StringComparer.OrdinalIgnoreCase) : new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        }
    }

    public void RecordServiceState(Guid id, string service, string state)
    {
        lock (gate)
        {
            if (!serviceStates.TryGetValue(id, out var states))
            {
                states = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                serviceStates[id] = states;
            }
            states[service] = state;
        }
    }

    public DateTimeOffset? Boot(Guid id)
    {
        lock (gate)
        {
            return boots.TryGetValue(id, out var at) ? at : null;
        }
    }

    public (DateTimeOffset At, string Message)? ScheduledRestart(Guid id, DateTimeOffset now)
    {
        lock (gate)
        {
            if (!restarts.TryGetValue(id, out var r))
            {
                return null;
            }
            if (r.At > now)
            {
                return r;
            }
            // The delay ran out: the workstation restarted then (memory only).
            restarts.Remove(id);
            boots[id] = r.At.AddSeconds(75);
            return null;
        }
    }

    public void RecordRestart(Guid id, DateTimeOffset at, string message, bool immediate)
    {
        lock (gate)
        {
            if (immediate)
            {
                boots[id] = at.AddSeconds(75);
                restarts.Remove(id);
            }
            else
            {
                restarts[id] = (at, message);
            }
        }
    }

    public bool CancelRestart(Guid id)
    {
        lock (gate)
        {
            return restarts.Remove(id);
        }
    }

    public (UserRef User, DateTimeOffset At, string Method)? Detected(Guid id)
    {
        lock (gate)
        {
            return detected.TryGetValue(id, out var d) ? d : null;
        }
    }

    public void RecordDetected(Guid id, UserRef user, DateTimeOffset at, string method)
    {
        lock (gate)
        {
            detected[id] = (user, at, method);
        }
    }

    public (int Keys, DateTimeOffset At)? BitLockerIndex(Guid id)
    {
        lock (gate)
        {
            return bitLockerIndex.TryGetValue(id, out var v) ? v : null;
        }
    }

    /// <summary>Index without secret (PST-066): a count already read is never replaced by the zero of a read that sees nothing.</summary>
    public void RecordBitLockerIndex(Guid id, int keys, DateTimeOffset at)
    {
        lock (gate)
        {
            if (keys == 0 && bitLockerIndex.TryGetValue(id, out var known) && known.Keys > 0)
            {
                bitLockerIndex[id] = (known.Keys, at);
                return;
            }
            bitLockerIndex[id] = (keys, at);
        }
    }

    public DateTimeOffset? LapsIndex(Guid id)
    {
        lock (gate)
        {
            return lapsIndex.TryGetValue(id, out var v) ? v : null;
        }
    }

    public void RecordLapsIndex(Guid id, DateTimeOffset at)
    {
        lock (gate)
        {
            lapsIndex[id] = at;
        }
    }

    public void RecordWake(Guid id, DateTimeOffset at)
    {
        lock (gate)
        {
            wakes[id] = at;
        }
    }

    public DateTimeOffset? Wake(Guid id)
    {
        lock (gate)
        {
            return wakes.TryGetValue(id, out var v) ? v : null;
        }
    }

    /// <summary>The BitLocker read of the postes of Marseille is refused (journal of the simulation: « Lecture BitLocker refusée pour l’OU Marseille »).</summary>
    public static bool BitLockerDenied(PosteMachine machine) => machine.Site == "Marseille";

    /// <summary>The LAPS read of the postes of Lille is refused for the session account (PST-062: refusal remembered per workstation).</summary>
    public static bool LapsDenied(PosteMachine machine) => machine.Site == "Lille";

    /// <summary>
    /// CIM refused on 4 % of the reachable workstations (RPC filtered by a local firewall and WinRM closed): a read of the
    /// inventory, the software or the last user needs the single fallback read authorized in the session (PST-011, PST-023).
    /// </summary>
    public bool CimBlocked(PosteMachine machine)
    {
        ArgumentNullException.ThrowIfNull(machine);
        return !ErrorProbe(machine.Computer.ObjectGuid) && !PingFiltered(machine.Computer.ObjectGuid) && new SeededRandom(machine.Seed).Fork("cim/blocked").Chance(4);
    }

    /// <summary>The other account accepted for a secret resource of a workstation (« laps », « bitlocker »), or null.</summary>
    public string? OtherAccount(Guid id, string resource)
    {
        lock (gate)
        {
            return otherAccounts.TryGetValue((id, resource), out var account) ? account : null;
        }
    }

    public void AcceptOtherAccount(Guid id, string resource, string account)
    {
        lock (gate)
        {
            otherAccounts[(id, resource)] = account;
        }
    }

    /// <summary>
    /// The non-secret index of the local base for one workstation (Domenia 1 SecretMeta): BitLocker keys counted at the last
    /// stored read. On 3 % of the computers the entry was written for an older holder of the same name (another GUID, before
    /// the creation of the current object): the console must leave it out (PST-065).
    /// </summary>
    public (int Keys, DateTimeOffset At, Guid Holder)? StoredBitLockerIndex(PosteMachine machine)
    {
        ArgumentNullException.ThrowIfNull(machine);
        var r = new SeededRandom(machine.Seed).Fork("secrets/stored");
        if (!initial.Value.TryGetValue(machine.Computer.ObjectGuid, out var observation) || observation.Inventory.CheckedAt is not DateTimeOffset checkedAt)
        {
            return null;
        }
        if (r.Chance(3))
        {
            var holder = new Guid(BitConverter.GetBytes(r.NextUInt64()).Concat(BitConverter.GetBytes(r.NextUInt64())).ToArray());
            return (1 + r.Next(2), machine.Computer.WhenCreated.AddDays(-r.Next(30, 400)), holder);
        }
        if (machine.BitLockerConversion == 0 || !r.Chance(70))
        {
            return null;
        }
        return (r.Chance(30) ? 2 : 1, checkedAt.AddDays(-r.Next(1, 20)), machine.Computer.ObjectGuid);
    }
}
