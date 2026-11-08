using Domenia.Core;
using Domenia.Store;

namespace Domenia.App;

/// <summary>Process-local queued logging, flushed every 500 ms and at exit; no data collection or service.</summary>
internal static class TechnicalLog
{
    private static readonly RotatingTechnicalJournal Journal = new(
        AppPaths.UserData is string folder ? Path.Combine(folder, "logs", "domenia.log") : null,
        Path.Combine(Path.GetTempPath(), "Domenia", "logs", "domenia.log"), TimeProvider.System);
    private static readonly System.Threading.Timer FlushTimer = new(_ => FlushTick(), null, TimeSpan.FromMilliseconds(500), TimeSpan.FromMilliseconds(500));

    private static readonly Lock FlushGate = new();
    private static Task? flushing;
    private static int exiting;

    private static void FlushTick()
    {
        // A slow disk keeps one worker; timer callbacks and exit never queue competing flushes.
        if (Volatile.Read(ref exiting) == 0) _ = RequestFlush();
    }

    static TechnicalLog()
    {
        Application.ApplicationExit += (_, _) => { _ = RequestFlush(); };
        AppDomain.CurrentDomain.ProcessExit += (_, _) => FlushAtExit();
    }
    public static string? FilePath => Journal.Status.Path;
    public static TechnicalJournalStatus Status => Journal.Status;
    public static void Trace(string message) => Journal.Enqueue("TRACE", message);
    public static void Info(string message) => Journal.Enqueue("INFO", message);
    public static void Warning(string message) => Journal.Enqueue("ATTENTION", message);
    public static void Error(string message, Exception exception) => Journal.Enqueue("ERREUR", message + Environment.NewLine + exception);
    public static HostIncidentReport Incident(Exception failure, bool expert = false) => HostIncidentReport.Create(failure,
        text => Journal.Enqueue("ERREUR", text), () => FlushBounded(TimeSpan.FromMilliseconds(250)), () => Journal.Status, expert);

    private static Task RequestFlush()
    {
        lock (FlushGate)
        {
            if (flushing is null || flushing.IsCompleted) flushing = Task.Run(Flush);
            return flushing;
        }
    }

    internal static bool FlushBounded(TimeSpan limit) => HostShutdown.WaitAsync(RequestFlush(), limit,
        _ => System.Diagnostics.Trace.WriteLine("Domenia : vidange du journal non confirmée.")).GetAwaiter().GetResult();

    private static void FlushAtExit()
    {
        // ApplicationExit already requested the same single-flight worker without blocking the UI.
        if (Interlocked.Exchange(ref exiting, 1) != 0) return;
        FlushTimer.Dispose();
        _ = FlushBounded(TimeSpan.FromMilliseconds(250));
    }
    public static void Flush()
    {
        try { Journal.Flush(); }
#pragma warning disable CA1031 // A diagnostic failure must never stop the application or a process-exit callback.
        catch (Exception ex) { System.Diagnostics.Trace.WriteLine("Domenia : journal non écrit (" + ex.GetType().Name + ")."); }
#pragma warning restore CA1031
    }
}
