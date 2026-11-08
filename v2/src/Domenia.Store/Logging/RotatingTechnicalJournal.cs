using System.Text;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>Bounded queue, rotation and visible local fallback. The host owns the 500 ms flush cadence.</summary>
public sealed class RotatingTechnicalJournal(string? primaryPath, string? fallbackPath, TimeProvider clock)
{
    public const int MaximumPending = 2048;
    public const long MaximumBytes = 5 * 1024 * 1024;
    private readonly Lock gate = new();
    private readonly Lock flushing = new();
    private readonly Queue<(long Id, string Text)> pending = new();
    private string? activePath;
    private string state = "pending";
    private string? problem;
    private long sequence;
    private long dropped;
    private long reportedDropped;

    public TechnicalJournalStatus Status { get { lock (gate) { return new(state, activePath ?? primaryPath ?? fallbackPath, pending.Count, dropped, problem); } } }

    public void Enqueue(string level, string? message)
    {
        var line = TechnicalJournalRecord.Format(clock.GetUtcNow(), level, message);
        lock (gate)
        {
            if (pending.Count == MaximumPending) { pending.Dequeue(); dropped++; }
            pending.Enqueue((++sequence, line));
        }
    }

    public void Flush()
    {
        lock (flushing)
        {
            (long Id, string Text)[] lines; string? first; long losses; long lossesBefore;
            lock (gate)
            {
                if (pending.Count == 0) { return; }
                lines = pending.ToArray(); first = activePath; losses = dropped; lossesBefore = reportedDropped;
            }
            var loss = losses > lossesBefore ? TechnicalJournalRecord.Format(clock.GetUtcNow(), "ATTENTION",
                (losses - lossesBefore) + " ligne(s) perdue(s) pendant l’indisponibilité du journal.") : null;
            var records = lines.Select(l => l.Text); if (loss is not null) { records = new[] { loss }.Concat(records); }
            foreach (var path in new[] { first, primaryPath, fallbackPath }.OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase))
            {
                try
                {
                    Write(path, records);
                    lock (gate)
                    {
                        while (pending.TryPeek(out var line) && line.Id <= lines[^1].Id) { pending.Dequeue(); }
                        reportedDropped = losses; activePath = path;
                        state = string.Equals(path, primaryPath, StringComparison.OrdinalIgnoreCase) ? "ready" : "fallback";
                        problem = state == "fallback" ? "Le journal utilise le dossier temporaire de secours ; le dossier principal est indisponible." : null;
                    }
                    return;
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
                {
                    lock (gate) { problem = "Journal non confirmé (" + ex.GetType().Name + "). Les lignes restent en mémoire dans la limite annoncée."; }
                }
            }
            lock (gate) { state = "unavailable"; }
        }
    }

    private static void Write(string path, IEnumerable<string> records)
    {
        foreach (var candidate in new[] { path, path + ".1", path + ".lock" }) { CompatibleDirectoryCache.ValidateLocalPath(candidate); }
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        using var lease = new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        FileStream? output = null;
        try
        {
            foreach (var record in records)
            {
                var bytes = Encoding.UTF8.GetBytes(record);
                var length = output?.Length ?? (File.Exists(path) ? new FileInfo(path).Length : 0);
                if (length + bytes.Length > MaximumBytes)
                {
                    output?.Flush(flushToDisk: true); output?.Dispose(); output = null;
                    File.Move(path, path + ".1", overwrite: true);
                }
                output ??= new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
                output.Write(bytes);
            }
            output?.Flush(flushToDisk: true);
        }
        finally { output?.Dispose(); }
    }
}
