using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace Domenia.App.Capture;

/// <summary>
/// State of one capture run: the validated folder, its capture.log, the images written and the exit code. Lives from
/// the command line check to the end of Main; the watchdog ends the process with code 2 if the run never finishes.
/// </summary>
internal sealed class CaptureSession : IDisposable
{
    public const string LogName = "capture.log";
    public const int SuccessCode = 0;
    public const int FailureCode = 2;

    private readonly Lock gate = new();
    private readonly StreamWriter writer;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly System.Threading.Timer watchdog;
    private int captured;
    private int skipped;
    private bool completed;
    private bool aborted;
    private bool closed;

    private CaptureSession(string folder, StreamWriter writer, CapturePlan plan)
    {
        Folder = folder;
        Plan = plan;
        this.writer = writer;
        watchdog = new System.Threading.Timer(OnWatchdog, null, plan.Watchdog, Timeout.InfiniteTimeSpan);
    }

    /// <summary>Absolute, local, existing folder of the images and of capture.log.</summary>
    public string Folder { get; }

    /// <summary>Steps of this run: the default sequence, then the extra screens and themes asked for.</summary>
    public CapturePlan Plan { get; }

    /// <summary>Steps of the plan.</summary>
    public int Steps => Plan.Steps.Length;

    /// <summary>Images expected: every step, except the optional ones found without object (page that does not scroll).</summary>
    public int Expected => Plan.Steps.Length - Volatile.Read(ref skipped);

    /// <summary>Opens a new capture.log in the folder (replacing the one of an earlier run); null when impossible.</summary>
    public static CaptureSession? Open(string folder, CapturePlan plan)
    {
        ArgumentException.ThrowIfNullOrEmpty(folder);
        ArgumentNullException.ThrowIfNull(plan);
        try
        {
            // UTF-8 with a byte order mark: Windows PowerShell 5.1 and Notepad then read the accents right.
            var stream = new FileStream(Path.Combine(folder, LogName), FileMode.Create, FileAccess.Write, FileShare.Read);
            return new CaptureSession(folder, new StreamWriter(stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true)) { AutoFlush = true }, plan);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Type only: the refusal that follows is traced by the caller, and the folder is not copied to the journal.
            TechnicalLog.Warning($"Journal de capture impossible à créer : {ex.GetType().Name}.");
            return null;
        }
    }

    public void Write(string message)
    {
        var line = DateTimeOffset.UtcNow.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture) + " " + message;
        lock (gate)
        {
            if (closed)
            {
                return;
            }
            try
            {
                writer.WriteLine(line);
            }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException)
            {
                // The images may still be fine: the journal failure goes to the technical journal only.
                TechnicalLog.Warning($"Journal de capture non écrit : {ex.GetType().Name}.");
            }
        }
    }

    /// <summary>
    /// Error line in capture.log: type and code only, since a system message may hold a path (profile, folder) or an
    /// account name. Every caller traces the full detail in the technical journal.
    /// </summary>
    public void Error(string message, Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);
        Write($"ERREUR {message} {exception.GetType().Name} (0x{exception.HResult.ToString("X8", CultureInfo.InvariantCulture)}) ; détail dans le journal technique.");
    }

    /// <summary>
    /// Removes what an earlier run left under the names of this sequence (images and temporary files), before any step:
    /// even a run that stops early never leaves an old image next to the new capture.log.
    /// </summary>
    public void ClearEarlierImages()
    {
        foreach (var step in Plan.Steps)
        {
            Remove(step.Name + ".png");
            Remove(step.Name + ".png.tmp");
        }

        void Remove(string name)
        {
            try
            {
                File.Delete(Path.Combine(Folder, name));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // The step of this image deletes it again, and fails if it still cannot.
                Write($"ATTENTION Ancienne image non supprimée : {name} ({ex.GetType().Name}).");
            }
        }
    }

    public void ImageWritten() => Interlocked.Increment(ref captured);

    /// <summary>An optional step found without object: no image is expected from it.</summary>
    public void StepSkipped() => Interlocked.Increment(ref skipped);

    /// <summary>The sequence ran to its end (successfully or not).</summary>
    public void Complete() => Volatile.Write(ref completed, true);

    /// <summary>Startup or unexpected failure: the run stops and the exit code is 2.</summary>
    public void Abort(string message)
    {
        Volatile.Write(ref aborted, true);
        Write("ARRÊT " + message);
    }

    /// <summary>Writes the summary, closes capture.log and returns the process exit code.</summary>
    public int Finish()
    {
        watchdog.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        var images = Volatile.Read(ref captured);
        var code = Volatile.Read(ref completed) && !Volatile.Read(ref aborted) && images == Expected ? SuccessCode : FailureCode;
        Write($"Fin : {images} image(s) sur {Expected.ToString(CultureInfo.InvariantCulture)} en {clock.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture)} ms ; code de sortie {code.ToString(CultureInfo.InvariantCulture)}.");
        TechnicalLog.Info($"Capture terminée : {images} image(s) sur {Expected.ToString(CultureInfo.InvariantCulture)}, code de sortie {code.ToString(CultureInfo.InvariantCulture)}.");
        Dispose();
        return code;
    }

    private void OnWatchdog(object? state)
    {
        Write($"ARRÊT Délai global de {Plan.Watchdog.TotalSeconds.ToString(CultureInfo.InvariantCulture)} s dépassé : l’application est arrêtée.");
        TechnicalLog.Warning("Capture : délai global dépassé, arrêt de l’application (code 2).");
        Dispose();
        // The window or WebView2 no longer answers: nothing else can end the process.
        Environment.Exit(FailureCode);
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (closed)
            {
                return;
            }
            closed = true;
            watchdog.Dispose();
            writer.Dispose();
        }
    }
}
