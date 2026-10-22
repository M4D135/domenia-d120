using System.Collections.Immutable;

namespace Domenia.Core.Poste;

/// <summary>One process with its processor share measured between two reads (null when it cannot be measured).</summary>
public sealed record ProcessRow(int Id, string Name, double? CpuPercent, long? WorkingSetBytes, string MemoryText, string? User, DateTimeOffset? StartedAt, string? Note);

/// <summary>Result of poste.processes: two reads of Win32_Process spaced by <see cref="IntervalMs"/>.</summary>
public sealed record ProcessesResult(string Computer, DateTimeOffset At, int IntervalMs, int LogicalProcessors, double? TotalCpu, int Count, ImmutableArray<ProcessRow> Rows, string Summary, ImmutableArray<PosteFact> Facts);

/// <summary>
/// Processor share of each process between two reads (Domenia 1 Measure-DomeniaProcessLoad): CPU time difference divided by
/// the interval and the logical processors. A process started, ended or whose PID was reused between the reads gets no
/// share; the idle pseudo-process is left out; nothing is extrapolated. Pure.
/// </summary>
public static class PosteProcesses
{
    public static ProcessesResult Measure(string computer, IReadOnlyList<ProcessEntry> first, IReadOnlyList<ProcessEntry> second, int intervalMs, int logicalProcessors, DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(first);
        ArgumentNullException.ThrowIfNull(second);
        ArgumentNullException.ThrowIfNull(zone);
        var before = first.GroupBy(p => p.Id).Where(g => g.Count() == 1).ToDictionary(g => g.Key, g => g.Single());
        var rows = ImmutableArray.CreateBuilder<ProcessRow>();
        double total = 0;
        var measured = 0;
        foreach (var p in second.Where(p => p.Id != 0))
        {
            double? share = null;
            string? note = null;
            if (!before.TryGetValue(p.Id, out var old))
            {
                note = "Démarré entre les deux lectures : aucune part calculée.";
            }
            else if (!string.Equals(old.Name, p.Name, StringComparison.OrdinalIgnoreCase) || old.StartedAt != p.StartedAt)
            {
                note = "Identifiant réutilisé : aucune part calculée.";
            }
            else if (old.CpuSeconds is double c1 && p.CpuSeconds is double c2 && c2 >= c1 && intervalMs > 0 && logicalProcessors > 0)
            {
                share = Math.Round(Math.Min(100, 100d * (c2 - c1) / (intervalMs / 1000d) / logicalProcessors), 1);
                total += share.Value;
                measured++;
            }
            else
            {
                note = "Temps processeur non renseigné : aucune part calculée.";
            }
            rows.Add(new ProcessRow(p.Id, p.Name, share, p.WorkingSetBytes, p.WorkingSetBytes is long ws ? PosteText.Size(ws) : "—", p.User, p.StartedAt, note));
        }
        var ended = first.Count(p => p.Id != 0 && second.All(s => s.Id != p.Id));
        var sorted = rows.ToImmutable().OrderByDescending(r => r.CpuPercent ?? -1).ThenByDescending(r => r.WorkingSetBytes ?? 0).ThenBy(r => r.Name, StringComparer.Ordinal).ToImmutableArray();
        var busiest = sorted.FirstOrDefault(r => r.CpuPercent is not null);
        var summary = FrenchText.Count(sorted.Length, "processus lu", "processus lus") + " à " + PosteText.LocalTime(at, zone) + ", parts mesurées sur " + FrenchText.Decimal(intervalMs / 1000d, 1) + " s et "
            + FrenchText.Count(logicalProcessors, "processeur logique", "processeurs logiques") + (ended > 0 ? " ; " + FrenchText.Count(ended, "terminé", "terminés") + " entre les lectures" : "") + ".";
        var facts = ImmutableArray.Create(
            PosteText.Fact("Charge mesurée", FrenchText.Percent(Math.Min(100, total), 0) + " pour " + FrenchText.Count(measured, "processus mesuré", "processus mesurés"), FactState.Observed, "Win32_Process (deux lectures)",
                "Mesure sur un intervalle court : une photographie de quelques secondes, pas une moyenne de la journée.", at: at, tone: total >= 85 ? Tone.Warn : Tone.Ok),
            PosteText.Fact("Processus le plus actif", busiest is null ? "Aucune part mesurée" : busiest.Name + " · " + FrenchText.Percent(busiest.CpuPercent!.Value) + " · " + busiest.MemoryText, busiest is null ? FactState.Unknown : FactState.Observed,
                "Win32_Process (deux lectures)", null, at: at, tone: busiest?.CpuPercent >= 50 ? Tone.Warn : Tone.Info));
        return new ProcessesResult(computer, at, intervalMs, logicalProcessors, measured == 0 ? null : Math.Round(Math.Min(100, total), 1), sorted.Length, sorted, summary, facts);
    }
}
