using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Read-only fictitious directory. The world is generated on first use (always off the UI thread: bridge handlers run on the
/// thread pool). No network, no LDAP, WMI or DNS, no disk: only memory. Only the presence changes, by deterministic rounds.
/// </summary>
public sealed class SimulatedDirectorySource : IDirectorySource
{
    private readonly SimulationOptions options;
    private readonly TimeProvider timeProvider;
    private readonly Lazy<SimulatedWorld> world;
    private readonly Lock gate = new();
    private DirectoryState? current;
    private int round;
    // Separate draw counters: refreshes are serialized by the caller, so their delays follow the seed whatever the reads do.
    private int readDraws;
    private int refreshDraws;
    // Delays of the screen readers, one counter per kind: a screen never shifts the delays of another one.
    private readonly ConcurrentDictionary<string, StrongBox<int>> screenDraws = new(StringComparer.Ordinal);

    public SimulatedDirectorySource(SimulationOptions options, TimeProvider timeProvider)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(timeProvider);
        this.options = options;
        this.timeProvider = timeProvider;
        // The reference date is read once, at the first use of the source.
        world = new Lazy<SimulatedWorld>(
            () => SimulatedWorldGenerator.Generate(options, timeProvider.GetUtcNow(), timeProvider.LocalTimeZone),
            LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public DirectorySourceKind Kind => DirectorySourceKind.Simulation;

    /// <summary>Seed and latency of this simulation (screen readers derive their own data and delays from them).</summary>
    public SimulationOptions Options => options;

    /// <summary>
    /// Named sub-stream of the seed for the data of one screen (« screen/&lt;name&gt; »): deterministic, independent of the
    /// central generator and of every other screen. Derive screen data from <see cref="World"/> and this stream only.
    /// </summary>
    public SeededRandom ScreenStream(string screen)
    {
        ArgumentException.ThrowIfNullOrEmpty(screen);
        return new SeededRandom(options.Seed).Fork("screen/" + screen);
    }

    /// <summary>
    /// Realistic delay of a screen read (n-th draw of « latency/screen/&lt;kind&gt;/n »), cancellable; none with
    /// <see cref="SimulationLatency.None"/>. Separate from the home page delays, which keep their own sequences.
    /// </summary>
    public Task SimulateScreenLatencyAsync(string kind, int minMilliseconds, int maxMilliseconds, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrEmpty(kind);
        var counter = screenDraws.GetOrAdd(kind, static _ => new StrongBox<int>());
        return DelayAsync("screen/" + kind, ref counter.Value, minMilliseconds, maxMilliseconds, cancellationToken);
    }

    /// <summary>The generated world (generated now if needed).</summary>
    public SimulatedWorld World => world.Value;

    /// <summary>Number of presence rounds run since the start (0 = initial state only).</summary>
    public int PresenceRound
    {
        get
        {
            lock (gate)
            {
                return round;
            }
        }
    }

    public Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var directory = Current().Directory;
        var session = World.Session with { Store = new StoreStatus(directory.ReadAt, directory.ObjectCount, directory.Complete) };
        return Task.FromResult(session);
    }

    public async Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken)
    {
        await DelayAsync("read", ref readDraws, 120, 250, cancellationToken).ConfigureAwait(false);
        return Current();
    }

    public async Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken cancellationToken)
    {
        var generated = World;
        if (family is MeasureFamily.Presence or MeasureFamily.Inventory)
        {
            // Same rule as the real directory: workstation measures never run on the domain root.
            ScopeRules.EnsureNotDomainRoot(scope, generated.Directory.Domain.RootDn);
        }
        // Every family, local computation included, answers after the refresh delay (docs/OPERATIONS.md § 6).
        await DelayAsync("refresh", ref refreshDraws, 400, 900, cancellationToken).ConfigureAwait(false);
        var now = timeProvider.GetUtcNow();
        lock (gate)
        {
            var state = current ?? generated.InitialState;
            state = family switch
            {
                // Same directory read again: values unchanged, read date now.
                MeasureFamily.Directory => state with { Directory = state.Directory with { ReadAt = now } },
                // Only the workstations of the working OU are probed; the others keep their earlier readings.
                MeasureFamily.Presence => state with { Observations = WithinScope(generated, scope!, state.Observations, PresenceRounds.Apply(generated.Presence, state.Observations, ++round, now)) },
                // Same inventory read again: values unchanged, reading dates now (working OU only).
                MeasureFamily.Inventory => state with { Observations = WithinScope(generated, scope!, state.Observations, RereadInventory(state.Observations, now)) },
                // Local computation: recomputed from the state in memory, nothing measured.
                _ => state,
            };
            current = state;
            return state;
        }
    }

    private DirectoryState Current()
    {
        var generated = World;
        lock (gate)
        {
            return current ?? generated.InitialState;
        }
    }

    /// <summary>Readings of the workstations inside the scope from <paramref name="measured"/>, the others from before.</summary>
    private static FleetObservations WithinScope(SimulatedWorld world, ScopeSelection scope, FleetObservations before, FleetObservations measured)
    {
        var inScope = world.Directory.Computers.Where(c => ScopeRules.Contains(scope, c.DistinguishedName)).Select(c => c.ObjectGuid).ToHashSet();
        var previous = before.Workstations.ToDictionary(o => o.ComputerGuid);
        return measured with
        {
            Workstations = [.. measured.Workstations.Select(o => inScope.Contains(o.ComputerGuid) ? o : previous.GetValueOrDefault(o.ComputerGuid, o))],
        };
    }

    private static FleetObservations RereadInventory(FleetObservations observations, DateTimeOffset now) => new(
        now,
        [.. observations.Workstations.Select(o => o.Inventory.HasReading ? o with { Inventory = o.Inventory with { CheckedAt = now } } : o)]);

    /// <summary>Waits the n-th delay of the kind (sub-sequence latency/kind/n of the seed); cancellable.</summary>
    private Task DelayAsync(string kind, ref int draws, int minMilliseconds, int maxMilliseconds, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (options.Latency == SimulationLatency.None)
        {
            return Task.CompletedTask;
        }
        var draw = Interlocked.Increment(ref draws);
        var random = new SeededRandom(options.Seed).Fork("latency/" + kind + "/" + draw.ToString(CultureInfo.InvariantCulture));
        var milliseconds = random.Next(minMilliseconds, maxMilliseconds + 1);
        return Task.Delay(TimeSpan.FromMilliseconds(milliseconds), timeProvider, cancellationToken);
    }
}
