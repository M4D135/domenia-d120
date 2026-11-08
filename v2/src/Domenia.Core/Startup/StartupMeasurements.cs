namespace Domenia.Core;

public enum StartupPhase { Integrity, Assemblies, Readers, Preferences, Configuration, Modules, Registry, Window, NativeVisible, Composition, WebViewEnvironment, WebViewControl, Navigation, InterfaceReady, LocalSource, LocalSession, Host, ModulePlan, LibraryIdentity }
public sealed record StartupMeasurement(StartupPhase Phase, double ProcessMilliseconds, double DurationMilliseconds);

/// <summary>One monotonic process clock, bounded history; observations never participate in admission or startup decisions.</summary>
public sealed class StartupMeasurements(TimeProvider clock, Action<StartupMeasurement>? publish = null)
{
    private readonly Lock gate = new();
    private readonly long started = clock.GetTimestamp();
    private readonly Queue<StartupMeasurement> observations = new();
    public IReadOnlyList<StartupMeasurement> Snapshot { get { lock (gate) return observations.ToArray(); } }
    public void Mark(StartupPhase phase) => Record(phase, clock.GetTimestamp());
    public IDisposable Measure(StartupPhase phase) => new Measurement(this, phase, clock.GetTimestamp());
    private void Record(StartupPhase phase, long since)
    {
        var now = clock.GetTimestamp();
        var value = new StartupMeasurement(phase, clock.GetElapsedTime(started, now).TotalMilliseconds, clock.GetElapsedTime(since, now).TotalMilliseconds);
        lock (gate) { if (observations.Count == 32) observations.Dequeue(); observations.Enqueue(value); }
#pragma warning disable CA1031 // Best-effort measurement output must never turn a healthy startup into a failure.
        try { publish?.Invoke(value); } catch (Exception) { }
#pragma warning restore CA1031
    }
    private sealed class Measurement(StartupMeasurements owner, StartupPhase phase, long since) : IDisposable
    {
        private StartupMeasurements? remaining = owner;
        public void Dispose() => Interlocked.Exchange(ref remaining, null)?.Record(phase, since);
    }
}

/// <summary>Host milestone; the page reports readiness only after its initial shell has been rendered.</summary>
public interface IStartupPresentation : IScreenReader
{
    void InterfaceReady();
    IDisposable? MeasureInitialSession();
}
