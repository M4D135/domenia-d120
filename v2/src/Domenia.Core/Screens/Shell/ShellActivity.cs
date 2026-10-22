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
/// at most once a minute per kind and screen. Only the kind, the screen name and counts are written: never a message of the
/// page, which may quote what the operator typed.
/// </summary>
public sealed class ShellFaultTracer
{
    /// <summary>Shortest gap between two lines of the same kind and screen.</summary>
    public static readonly TimeSpan Interval = TimeSpan.FromMinutes(1);

    private readonly ConcurrentDictionary<string, (DateTimeOffset At, int Silenced)> last = new(StringComparer.Ordinal);
    private readonly ITechnicalJournal log;
    private readonly TimeProvider clock;
    private int total;

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

    /// <summary>Faults reported during the session.</summary>
    public int Total => Volatile.Read(ref total);

    /// <summary>Counts the faults; returns true when a line was written to the technical journal.</summary>
    public bool Report(string kind, string route, int count)
    {
        ArgumentException.ThrowIfNullOrEmpty(kind);
        ArgumentException.ThrowIfNullOrEmpty(route);
        var n = Math.Max(1, count);
        Interlocked.Add(ref total, n);
        var key = kind + "|" + route;
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
            var label = kind == "rejection" ? "promesse rejetée sans traitement" : "exception non interceptée";
            var more = silenced > 0 ? $" ({silenced.ToString(CultureInfo.InvariantCulture)} autre(s) depuis la ligne précédente)" : "";
            log.Warning($"Interface : {label} sur l’écran {route} ({n.ToString(CultureInfo.InvariantCulture)} fois){more}.");
        }
        return write;
    }
}
