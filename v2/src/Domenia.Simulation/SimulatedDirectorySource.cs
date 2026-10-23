using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Fictitious directory. The world is generated on first use (always off the UI thread: bridge handlers run on the thread
/// pool). No network, no LDAP, WMI or DNS, no disk: only memory. The presence changes by deterministic rounds; the writes of
/// the simulation go to an in-memory overlay (<see cref="Overlay"/>, never persisted) that every read sees. The generated
/// world itself never changes. <see cref="IDirectorySource"/> still has no write method: only the write executors of this
/// assembly change the overlay.
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
    private readonly SimulatedDirectoryOverlay overlay = new();
    // Account of the session after « Changer de compte » (Comptes screen, CPT-007); null: the generated session account.
    private (AccountIdentity Account, RightsInfo Rights)? switched;
    private long sessionEpoch;

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

    /// <summary>
    /// The generated world (generated now if needed), as generated: the writes of the session are not in it. Screen readers
    /// read the directory through <see cref="CurrentDirectory"/>.
    /// </summary>
    public SimulatedWorld World => world.Value;

    /// <summary>Clock of the simulation (dates of the writes and of their receipts).</summary>
    public TimeProvider Clock => timeProvider;

    /// <summary>Changes made by the writes of this session (in memory only).</summary>
    public SimulatedDirectoryOverlay Overlay => overlay;

    /// <summary>
    /// The directory as every read of the session sees it: the last directory read (generated, or read again by a refresh) with
    /// the writes of the session applied. Screen readers and write executors read this, never <see cref="SimulatedWorld.Directory"/>.
    /// </summary>
    public DirectorySnapshot CurrentDirectory => overlay.Apply(Base().Directory);

    /// <summary>Changes one user in the overlay (write executors of the simulation only); null when no user has this GUID.</summary>
    internal DirectoryUser? UpdateUser(Guid id, Func<DirectoryUser, long, DirectoryUser?> change) =>
        overlay.UpdateUser(Base().Directory, id, change);

    /// <summary>
    /// Applies one write of the simulation to the overlay, several objects at once if needed (write executors of the simulation
    /// only): <paramref name="edit"/> returns true to keep its changes.
    /// </summary>
    internal bool EditDirectory(Func<SimulatedDirectoryEdit, bool> edit) => overlay.Edit(Base().Directory, edit);

    /// <summary>Last observations of the workstations (presence rounds of the session included), read at once from memory.</summary>
    internal FleetObservations CurrentObservations => Base().Observations;

    /// <summary>Changes one computer in the overlay (write executors of the simulation only); null when no computer has this GUID.</summary>
    internal DirectoryComputer? UpdateComputer(Guid id, Func<DirectoryComputer, long, DirectoryComputer?> change) =>
        overlay.UpdateComputer(Base().Directory, id, change);

    /// <summary>Changes one group in the overlay (write executors of the simulation only); null when no group has this GUID.</summary>
    internal DirectoryGroup? UpdateGroup(Guid id, Func<DirectoryGroup, long, DirectoryGroup?> change) =>
        overlay.UpdateGroup(Base().Directory, id, change);

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
        var session = CurrentSession with { Store = new StoreStatus(directory.ReadAt, directory.ObjectCount, directory.Complete) };
        return Task.FromResult(session);
    }

    /// <summary>The session as it is now: the generated one, with the account chosen by « Changer de compte » if any.</summary>
    public SessionSnapshot CurrentSession
    {
        get
        {
            lock (gate)
            {
                return switched is { } s ? World.Session with { Account = s.Account, Rights = s.Rights, Epoch = sessionEpoch } : World.Session;
            }
        }
    }

    /// <summary>
    /// « Changer de compte » in simulation (Comptes screen, CPT-007, after one validation): the fictitious session takes this user
    /// of the same domain. Its rights are estimated from adminCount (the overlay never checks rights). Memory only.
    /// </summary>
    internal AccountIdentity SwitchSessionAccount(DirectoryUser user)
    {
        ArgumentNullException.ThrowIfNull(user);
        var generated = World.Session;
        var identity = new AccountIdentity(World.Directory.Domain.NetbiosName + "\\" + user.SamAccountName, user.DisplayName ?? user.Cn, user.GivenName, user.DistinguishedName);
        var rights = user.AdminCount == 1
            ? generated.Rights
            : new RightsInfo(RightsLevel.Read, "Lecture (estimée)", true, "Compte sans adminCount" + FrenchText.Colon + "l’annuaire réel refuserait probablement ses écritures ; la simulation ne vérifie pas les droits.");
        lock (gate)
        {
            switched = (identity, rights);
            sessionEpoch++;
        }
        return identity;
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
            return WithOverlay(state);
        }
    }

    /// <summary>
    /// Inventory read again on the given workstations only (explicit OU refresh, ACC-004 and ACC-038): the workstations of the
    /// working OU that answered the ping and still need a reading. The others keep their earlier reading and its date, so the
    /// provenance never shows a fresh WMI date for a workstation that was not contacted. Never the domain root.
    /// </summary>
    public async Task<DirectoryState> RefreshInventoryAsync(ScopeSelection scope, IReadOnlySet<Guid> targets, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scope);
        ArgumentNullException.ThrowIfNull(targets);
        var generated = World;
        ScopeRules.EnsureNotDomainRoot(scope, generated.Directory.Domain.RootDn);
        await DelayAsync("refresh", ref refreshDraws, 400, 900, cancellationToken).ConfigureAwait(false);
        var now = timeProvider.GetUtcNow();
        lock (gate)
        {
            var state = current ?? generated.InitialState;
            var inScope = generated.Directory.Computers.Where(c => ScopeRules.Contains(scope, c.DistinguishedName)).Select(c => c.ObjectGuid).ToHashSet();
            state = state with
            {
                Observations = new FleetObservations(now, [.. state.Observations.Workstations.Select(o =>
                    inScope.Contains(o.ComputerGuid) && targets.Contains(o.ComputerGuid) && o.Inventory.HasReading ? o with { Inventory = o.Inventory with { CheckedAt = now } } : o)]),
            };
            current = state;
            return WithOverlay(state);
        }
    }

    /// <summary>Last known state as the session sees it (writes of the session applied).</summary>
    private DirectoryState Current() => WithOverlay(Base());

    /// <summary>Exact population of an Accueil plan: the other observations keep their prior dates.</summary>
    internal async Task<DirectoryState> RefreshFrozenAsync(ScopeSelection scope,
        IReadOnlyDictionary<Guid, Domenia.Core.Queries.QueryComputerIdentity> targets, long expectedEpoch, bool inventory, CancellationToken token)
    {
        var generated = World;
        ScopeRules.EnsureNotDomainRoot(scope, generated.Directory.Domain.RootDn);
        await DelayAsync("refresh", ref refreshDraws, 400, 900, token).ConfigureAwait(false);
        var now = timeProvider.GetUtcNow();
        lock (gate)
        {
            if (CurrentSession.Epoch != expectedEpoch) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Session simulée modifiée depuis le plan."); }
            var state = current ?? generated.InitialState;
            var actual = WithOverlay(state).Directory.Computers.ToDictionary(c => c.ObjectGuid);
            if (targets.Any(t => !actual.TryGetValue(t.Key, out var pc) || !t.Value.Matches(pc) || !ScopeRules.Contains(scope, pc.DistinguishedName)))
            { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Identité simulée modifiée depuis le plan ; aucune mesure."); }
            var wanted = targets.Keys.Where(id => !AdValues.IsDisabled(actual[id].UserAccountControl)).ToHashSet();
            var measured = inventory ? RereadInventory(state.Observations, now) : PresenceRounds.Apply(generated.Presence, state.Observations, ++round, now);
            var previous = state.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
            state = state with { Observations = measured with { Workstations = [.. measured.Workstations.Select(o => wanted.Contains(o.ComputerGuid)
                && (!inventory || previous.TryGetValue(o.ComputerGuid, out var old) && old.Presence.HasReading && old.Presence.Answered == true)
                ? o : previous.GetValueOrDefault(o.ComputerGuid, o))] } };
            current = state;
            return WithOverlay(state);
        }
    }

    /// <summary>Last known state of the generated directory, before the overlay.</summary>
    private DirectoryState Base()
    {
        var generated = World;
        lock (gate)
        {
            return current ?? generated.InitialState;
        }
    }

    private DirectoryState WithOverlay(DirectoryState state)
    {
        var directory = overlay.Apply(state.Directory);
        return ReferenceEquals(directory, state.Directory) ? state : state with { Directory = directory };
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
