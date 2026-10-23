using System.Diagnostics;
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

    private static int ticking;

    private static void FlushTick()
    {
        // A slow local disk must not accumulate blocked ThreadPool timer callbacks.
        if (Interlocked.CompareExchange(ref ticking, 1, 0) != 0) { return; }
        try { Flush(); } finally { Volatile.Write(ref ticking, 0); }
    }

    static TechnicalLog()
    {
        Application.ApplicationExit += (_, _) => Flush();
        AppDomain.CurrentDomain.ProcessExit += (_, _) => { FlushTimer.Dispose(); Flush(); };
    }
    public static string? FilePath => Journal.Status.Path;
    public static TechnicalJournalStatus Status => Journal.Status;
    public static void Info(string message) => Journal.Enqueue("INFO", message);
    public static void Warning(string message) => Journal.Enqueue("ATTENTION", message);
    public static void Error(string message, Exception exception) => Journal.Enqueue("ERREUR", message + Environment.NewLine + exception);
    public static void Flush()
    {
        try { Journal.Flush(); }
#pragma warning disable CA1031 // A diagnostic failure must never stop the application or a process-exit callback.
        catch (Exception ex) { Trace.WriteLine("Domenia : journal non écrit (" + ex.GetType().Name + ")."); }
#pragma warning restore CA1031
    }
}
