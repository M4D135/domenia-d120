using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>Clock with a fixed instant and time zone; real timers (so simulated waits stay cancellable).</summary>
internal sealed class FixedTimeProvider(DateTimeOffset now, TimeZoneInfo zone) : TimeProvider
{
    private readonly Lock gate = new();
    private DateTimeOffset current = now;

    public override TimeZoneInfo LocalTimeZone => zone;

    public override DateTimeOffset GetUtcNow()
    {
        lock (gate)
        {
            return current;
        }
    }

    public void Advance(TimeSpan by)
    {
        lock (gate)
        {
            current += by;
        }
    }
}

internal static class TestClock
{
    /// <summary>Wednesday 21 October 2026, 18:26 in Paris.</summary>
    public static DateTimeOffset Reference { get; } = new(2026, 10, 21, 16, 26, 0, TimeSpan.Zero);

    public static TimeZoneInfo Paris { get; } = FindParis();

    public static FixedTimeProvider Fixed(DateTimeOffset? now = null) => new(now ?? Reference, Paris);

    private static TimeZoneInfo FindParis()
    {
        try
        {
            return TimeZoneInfo.FindSystemTimeZoneById("Europe/Paris");
        }
        catch (TimeZoneNotFoundException)
        {
            return TimeZoneInfo.FindSystemTimeZoneById("Romance Standard Time");
        }
    }
}

/// <summary>Small hand-written directories for the pure calculation tests.</summary>
internal static class Fixtures
{
    public const string Root = "DC=test,DC=local";
    public const string Postes = "OU=Postes,DC=test,DC=local";
    public const string People = "OU=Utilisateurs,DC=test,DC=local";

    public static DateTimeOffset Now => TestClock.Reference;

    public static DomainInfo Domain { get; } = new(
        "test.local",
        "TEST",
        Root,
        "S-1-5-21-1-2-3",
        [new DomainController("DC1.test.local", "Paris")],
        new DomainPasswordPolicy(TimeSpan.FromDays(90), 12, 24, 5, TimeSpan.FromMinutes(30), TimeSpan.FromMinutes(30)),
        ["CN=Users," + Root, "CN=Computers," + Root]);

    public static Guid IdOf(string name) => new(SHA256.HashData(Encoding.UTF8.GetBytes(name)).AsSpan(0, 16));

    public static long Ft(DateTimeOffset at) => AdValues.ToFileTime(at);

    /// <summary>Active user, password set 10 days ago (expires in 80 days), logged on yesterday.</summary>
    public static DirectoryUser User(string name)
    {
        var passwordSet = Now - TimeSpan.FromDays(10);
        return new DirectoryUser(
            IdOf(name), "S-1-5-21-1-2-3-" + (IdOf(name).GetHashCode() & 0xFFFF).ToString(System.Globalization.CultureInfo.InvariantCulture),
            $"CN={name},{People}", name, name.ToLowerInvariant(), null, name, null, null, null, null, null, null, null, null, null, null,
            AdValues.NormalAccount, 0, 0, 0, Ft(passwordSet), Ft(passwordSet + TimeSpan.FromDays(90)), Ft(Now - TimeSpan.FromDays(1)), AdValues.Never,
            Now - TimeSpan.FromDays(400), Now - TimeSpan.FromDays(1), 1000, null, 513, []);
    }

    /// <summary>Enabled workstation under OU=Postes, logged on yesterday, machine password changed 5 days ago.</summary>
    public static DirectoryComputer Computer(string name, string parentDn = Postes) => new(
        IdOf(name), "S-1-5-21-1-2-3-9", $"CN={name},{parentDn}", name, name.ToLowerInvariant() + ".test.local", name + "$", null, null, null,
        "Windows 11 Entreprise", "10.0 (26100)", AdValues.WorkstationTrustAccount, Ft(Now - TimeSpan.FromDays(1)), Ft(Now - TimeSpan.FromDays(5)),
        Now - TimeSpan.FromDays(300), Now - TimeSpan.FromDays(5), 2000, LapsKind.None, null, 515, []);

    public static PresenceMeasure Presence(bool answered, TimeSpan age, DateTimeOffset? lastOnline = null) =>
        new(MeasureState.Known, answered, Now - age, answered ? Now - age : lastOnline);

    public static InventoryMeasure Disk(long size, long free, TimeSpan age, TimeSpan? bootAge = null) =>
        new(MeasureState.Known, Now - age, size, free, Now - (bootAge ?? TimeSpan.FromDays(2)), "Modèle", 16L << 30, "Microsoft Windows 11 Entreprise", "26100");

    public static WorkstationObservation Observe(DirectoryComputer computer, PresenceMeasure? presence = null, InventoryMeasure? inventory = null) =>
        new(computer.ObjectGuid, presence ?? PresenceMeasure.Unread, inventory ?? InventoryMeasure.Unread);

    public static DirectorySnapshot Snapshot(IEnumerable<DirectoryUser>? users = null, IEnumerable<DirectoryComputer>? computers = null, DateTimeOffset? readAt = null) =>
        new(Domain, readAt ?? Now - TimeSpan.FromMinutes(10), true, [], [.. users ?? []], [.. computers ?? []], []);

    public static DashboardInput Input(
        DirectorySnapshot snapshot,
        IEnumerable<WorkstationObservation>? observations = null,
        IEnumerable<DailyFigures>? history = null,
        IEnumerable<JournalEntry>? journal = null,
        IEnumerable<string>? disabled = null,
        DateTimeOffset? now = null)
    {
        var entries = ImmutableArray.CreateRange(journal ?? []);
        var state = new DirectoryState(snapshot, new FleetObservations(now ?? Now, [.. observations ?? []]), [.. history ?? []], entries);
        return new DashboardInput(state, new ScopeSelection(Postes, "Postes", true), DashboardPolicy.Default,
            new HashSet<string>(disabled ?? [], StringComparer.Ordinal), entries, now ?? Now, TestClock.Paris, DirectorySourceKind.ActiveDirectory);
    }

    public static DashboardWidget Widget(string id, DashboardInput input) => DashboardCalculator.ComputeWidget(id, input);

    public static KpiData Kpi(DashboardWidget widget) => (KpiData)widget.Data!;

    public static int Part(ImmutableArray<BreakdownItem> breakdown, string key) => breakdown.Single(b => b.Key == key).Value;
}

/// <summary>Source whose local read captures the state, then waits to be released (interleaving tests).</summary>
internal sealed class GatedReadSource(IDirectorySource inner) : IDirectorySource
{
    public TaskCompletionSource ReadCaptured { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public DirectorySourceKind Kind => inner.Kind;

    public Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken) => inner.GetSessionAsync(cancellationToken);

    public async Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken)
    {
        var state = await inner.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        ReadCaptured.TrySetResult();
        await Release.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        return state;
    }

    public Task<DirectoryState> RefreshAsync(MeasureFamily family, CancellationToken cancellationToken) => inner.RefreshAsync(family, cancellationToken);
}

/// <summary>Real bridge over a simulated source without latency.</summary>
internal sealed class SimulatedBridge
{
    private readonly List<BridgeResponse> sent = [];
    private int counter;

    public SimulatedBridge(SimulationLatency latency = SimulationLatency.None, FixedTimeProvider? clock = null)
    {
        Clock = clock ?? TestClock.Fixed();
        Source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = latency }, Clock);
        Service = new DashboardService(Source, new OperationJournal(), Clock);
        Dispatcher = new BridgeDispatcher(new OperationRegistry(DashboardOperations.Create(Service)), Publish, AdmissionGuards.ReadOnlySimulation);
    }

    public FixedTimeProvider Clock { get; }

    public SimulatedDirectorySource Source { get; }

    public DashboardService Service { get; }

    public BridgeDispatcher Dispatcher { get; }

    public async Task<BridgeResponse> CallAsync(string operation, string arguments = "{}", CancellationToken cancellationToken = default)
    {
        var id = "t" + Interlocked.Increment(ref counter).ToString(System.Globalization.CultureInfo.InvariantCulture);
        await Dispatcher.HandleAsync("{\"id\":\"" + id + "\",\"op\":\"" + operation + "\",\"args\":" + arguments + "}", cancellationToken).ConfigureAwait(false);
        lock (sent)
        {
            return sent.Last(r => r.Id == id);
        }
    }

    /// <summary>Data of a result, serialized with the contract options and read back.</summary>
    public static JsonElement Json(BridgeResponse response)
    {
        Check.Equal("result", response.Kind, "réponse attendue : " + (response.Error?.Code ?? ""));
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(response.Data, BridgeJson.Options));
        return document.RootElement.Clone();
    }

    private void Publish(BridgeResponse response)
    {
        lock (sent)
        {
            sent.Add(response);
        }
    }
}
