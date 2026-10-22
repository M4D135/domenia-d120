using System.Collections.Concurrent;
using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>
/// Activity of the session for the « Opérations » button (shell.activity): read counters of the home page service, write
/// receipts of the mode and the operations journal. Local only: nothing is read from the directory or the network.
/// </summary>
public sealed class ShellActivityService
{
    /// <summary>Journal lines returned at most.</summary>
    public const int MaxJournalLines = 50;

    private readonly DashboardService dashboard;
    private readonly IReceiptStore receipts;
    private readonly OperationJournal journal;
    private readonly TimeProvider clock;
    private readonly ITechnicalJournal log;
    private int unreadableTraced;

    public ShellActivityService(DashboardService dashboard, IReceiptStore receipts, OperationJournal journal, TimeProvider clock, ITechnicalJournal log)
    {
        ArgumentNullException.ThrowIfNull(dashboard);
        ArgumentNullException.ThrowIfNull(receipts);
        ArgumentNullException.ThrowIfNull(journal);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        this.dashboard = dashboard;
        this.receipts = receipts;
        this.journal = journal;
        this.clock = clock;
        this.log = log;
    }

    /// <summary>The service shared by every module of the context.</summary>
    public static ShellActivityService From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new ShellActivityService(DashboardService.From(c), c.Receipts, c.Journal, c.Clock, c.Log));
    }

    public async Task<ShellActivity> GetAsync(CancellationToken cancellationToken)
    {
        var session = await dashboard.GetSessionInfoAsync(cancellationToken).ConfigureAwait(false);
        ShellReceiptCounts counts;
        try
        {
            var all = await receipts.ReadAllAsync(cancellationToken).ConfigureAwait(false);
            counts = new ShellReceiptCounts(true, all.Receipts.Length, all.Receipts.Count(WriteReceipts.IsPending), all.Unreadable);
        }
        catch (IOException ex)
        {
            // Unreadable for now (locked by a backup or an antivirus): said once, the button says it too.
            if (Interlocked.Exchange(ref unreadableTraced, 1) == 0)
            {
                log.Warning($"Activité : reçus d’écriture illisibles pour l’instant ({ex.GetType().Name}).");
            }
            counts = new ShellReceiptCounts(false, 0, 0, 0);
        }
        var active = session.Tasks.Running + session.Tasks.Queued + counts.Pending;
        var lines = journal.Snapshot().Take(MaxJournalLines).Select(e => new ShellJournalLine(e.At, e.Label, e.Tone)).ToImmutableArray();
        return new ShellActivity(session.Tasks, counts, active, ShellTexts.Counter(active), ShellTexts.ActivityDetail(session.Tasks, counts), lines, clock.GetUtcNow());
    }
}

/// <summary>
/// Faults of the interface reported by the page (shell.fault, Domenia 1 TRV-064): counted, and traced in the technical journal
/// at most once a minute per kind, screen and place. Only the kind, the screen name, the place in the code (an identifier of
/// the page code, never a text) and counts are written: never a message of the page, which may quote what the operator typed.
/// Errors swallowed on purpose (« swallowed », Domenia 1 Write-DomeniaSwallowed) are traced the same way but are not faults:
/// they are not counted in <see cref="Total"/>.
/// </summary>
public sealed class ShellFaultTracer
{
    /// <summary>Shortest gap between two lines of the same kind, screen and place.</summary>
    public static readonly TimeSpan Interval = TimeSpan.FromMinutes(1);

    private readonly ConcurrentDictionary<string, (DateTimeOffset At, int Silenced)> last = new(StringComparer.Ordinal);
    private readonly ITechnicalJournal log;
    private readonly TimeProvider clock;
    private int total;
    private int swallowed;

    public ShellFaultTracer(ITechnicalJournal log, TimeProvider clock)
    {
        ArgumentNullException.ThrowIfNull(log);
        ArgumentNullException.ThrowIfNull(clock);
        this.log = log;
        this.clock = clock;
    }

    /// <summary>The tracer shared by every module of the context.</summary>
    public static ShellFaultTracer From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new ShellFaultTracer(c.Log, c.Clock));
    }

    /// <summary>Faults reported during the session (errors swallowed on purpose excluded).</summary>
    public int Total => Volatile.Read(ref total);

    /// <summary>Errors swallowed on purpose reported during the session.</summary>
    public int Swallowed => Volatile.Read(ref swallowed);

    /// <summary>A place of the page code: an identifier of 64 characters at most (« board.copy », « help-panel »).</summary>
    public static bool IsPlace(string? place) =>
        !string.IsNullOrEmpty(place) && place.Length <= 64 && char.IsAsciiLetter(place[0])
        && place.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-');

    /// <summary>Counts the faults; returns true when a line was written to the technical journal.</summary>
    public bool Report(string kind, string route, int count, string? place = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(kind);
        ArgumentException.ThrowIfNullOrEmpty(route);
        var n = Math.Max(1, count);
        if (kind == "swallowed")
        {
            Interlocked.Add(ref swallowed, n);
        }
        else
        {
            Interlocked.Add(ref total, n);
        }
        var key = kind + "|" + route + "|" + (place ?? "");
        var now = clock.GetUtcNow();
        var write = false;
        var silenced = 0;
        last.AddOrUpdate(key,
            _ =>
            {
                write = true;
                return (now, 0);
            },
            (_, previous) =>
            {
                if (now - previous.At >= Interval)
                {
                    write = true;
                    silenced = previous.Silenced;
                    return (now, 0);
                }
                write = false;
                return (previous.At, previous.Silenced + n);
            });
        if (write)
        {
            var label = kind switch
            {
                "rejection" => "promesse rejetée sans traitement",
                "nested" => "erreur survenue pendant le traitement d’une autre",
                "swallowed" => "erreur volontairement ignorée",
                _ => "exception non interceptée",
            };
            var where = string.IsNullOrEmpty(place) ? "" : " (" + place + ")";
            var more = silenced > 0 ? $" ({silenced.ToString(CultureInfo.InvariantCulture)} autre(s) depuis la ligne précédente)" : "";
            log.Warning($"Interface : {label}{where} sur l’écran {route} ({n.ToString(CultureInfo.InvariantCulture)} fois){more}.");
        }
        return write;
    }
}

/// <summary>
/// Time the interface stayed blocked by a modal panel (Domenia 1 TRV-056: « le temps bloqué est mesuré »), reported by the
/// page (shell.metric): summed for the session and traced in the technical journal at most once a minute per screen, with
/// the number of panels and the time they held. Counts only.
/// </summary>
public sealed class ShellMetricTracer
{
    /// <summary>Longest time counted for one panel (a panel left open over a night counts as one hour).</summary>
    public const int MaxMilliseconds = 3_600_000;

    private readonly ConcurrentDictionary<string, (DateTimeOffset At, int Count, long Milliseconds)> pending = new(StringComparer.Ordinal);
    private readonly ITechnicalJournal log;
    private readonly TimeProvider clock;
    private long totalMilliseconds;
    private int panels;

    public ShellMetricTracer(ITechnicalJournal log, TimeProvider clock)
    {
        ArgumentNullException.ThrowIfNull(log);
        ArgumentNullException.ThrowIfNull(clock);
        this.log = log;
        this.clock = clock;
    }

    /// <summary>The tracer shared by every module of the context.</summary>
    public static ShellMetricTracer From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new ShellMetricTracer(c.Log, c.Clock));
    }

    /// <summary>Modal panels closed during the session.</summary>
    public int Panels => Volatile.Read(ref panels);

    /// <summary>Time the interface stayed blocked during the session.</summary>
    public long TotalMilliseconds => Interlocked.Read(ref totalMilliseconds);

    /// <summary>Adds closed panels and their blocked time; returns true when a line was written.</summary>
    public bool Report(string route, int count, long milliseconds)
    {
        ArgumentException.ThrowIfNullOrEmpty(route);
        var n = Math.Max(1, count);
        var ms = Math.Clamp(milliseconds, 0, (long)MaxMilliseconds * n);
        Interlocked.Add(ref panels, n);
        Interlocked.Add(ref totalMilliseconds, ms);
        var now = clock.GetUtcNow();
        var write = false;
        (int Count, long Milliseconds) sum = (0, 0);
        pending.AddOrUpdate(route,
            _ =>
            {
                write = true;
                sum = (n, ms);
                return (now, 0, 0);
            },
            (_, previous) =>
            {
                if (now - previous.At >= ShellFaultTracer.Interval)
                {
                    write = true;
                    sum = (previous.Count + n, previous.Milliseconds + ms);
                    return (now, 0, 0);
                }
                write = false;
                return (previous.At, previous.Count + n, previous.Milliseconds + ms);
            });
        if (write)
        {
            log.Info($"Interface : {sum.Count.ToString(CultureInfo.InvariantCulture)} panneau(x) modal(aux) fermé(s) sur l’écran {route}, interface bloquée {(sum.Milliseconds / 1000.0).ToString("0.0", CultureInfo.InvariantCulture)} s.");
        }
        return write;
    }
}
