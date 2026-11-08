using System.Globalization;
using Domenia.Core;

namespace Domenia.App;

internal static class StartupTrace
{
    private static readonly Lock Gate = new();
    private static bool verified;
    internal static event Action? InterfaceBecameReady;
    internal static void MarkInterfaceReady()
    {
        Clock.Mark(StartupPhase.InterfaceReady);
        InterfaceBecameReady?.Invoke();
    }
    internal static StartupMeasurements Clock { get; } = new(TimeProvider.System, Publish);
    private static void Publish(StartupMeasurement value)
    {
        lock (Gate) { if (verified) Write(value); }
    }
    // Before successful integrity, even the journal (which hooks WinForms) must not initialize UI dependencies.
    internal static void PackageVerified()
    {
        lock (Gate)
        {
            if (verified) return;
            foreach (var value in Clock.Snapshot) Write(value);
            verified = true;
        }
    }
    private static void Write(StartupMeasurement value) =>
        TechnicalLog.Info("Démarrage/" + value.Phase + " : " + value.DurationMilliseconds.ToString("F0", CultureInfo.InvariantCulture)
            + " ms ; depuis l’amorçage " + value.ProcessMilliseconds.ToString("F0", CultureInfo.InvariantCulture) + " ms.");

}

/// <summary>Discovery entry for the closed, local-only interface readiness operation.</summary>
public sealed class StartupPresentation : IStartupPresentation
{
    private int ready;
    private int session;
    public StartupPresentation(IDirectorySource source) { ArgumentNullException.ThrowIfNull(source); }
    public IDisposable? MeasureInitialSession() => Interlocked.Exchange(ref session, 1) == 0 ? StartupTrace.Clock.Measure(StartupPhase.LocalSession) : null;
    public void InterfaceReady()
    {
        if (Interlocked.Exchange(ref ready, 1) == 0) StartupTrace.MarkInterfaceReady();
    }
}
