using System.Collections.Immutable;
using System.Text.RegularExpressions;

namespace Domenia.Core.Poste;

/// <summary>Stored state of one probe for one workstation (last success and last attempt are distinct).</summary>
public enum ProbeState
{
    Read,
    Partial,
    Refused,
    Absent,
    Failed,
    NotRead,
}

public sealed record ProbeStatus(string ProbeId, ProbeState State, DateTimeOffset? LastSuccess, DateTimeOffset? LastAttempt, string? Error, int Rows)
{
    public DateTimeOffset? DataAt { get; init; }
}

/// <summary>Exact catalog columns, primitive JSON cells only; no invented instance identifiers or flattened arrays.</summary>
public sealed record ProbeValues(DateTimeOffset At, bool Complete, ImmutableArray<ImmutableArray<System.Text.Json.JsonElement>> Rows);

/// <summary>One stored sample of a volume (Domenia 1 disk.volumes history: one every 6 h, 60 at most, 400 days).</summary>
public sealed record VolumeSample(DateTimeOffset At, long SizeBytes, long FreeBytes);

/// <summary>One stored change of the displays (hw.monitors history: 20 changes at most).</summary>
public sealed record MonitorChange(DateTimeOffset At, string Text);

/// <summary>
/// Probe readings stored for one workstation (local base in directory mode, memory of the session in simulation): the last
/// typed data, the state of every probe, and the bounded histories. Nothing here queries the workstation.
/// </summary>
public sealed record ProbeStore(
    string Computer,
    InventorySnapshot? Data,
    ImmutableArray<ProbeStatus> Probes,
    ImmutableArray<VolumeSample> SystemVolumeHistory,
    ImmutableArray<MonitorChange> MonitorHistory,
    ImmutableArray<string> DockHints,
    DateTimeOffset? CollectedAt)
{
    public string? ReportedName { get; init; }
    public ImmutableDictionary<string, ProbeValues> Values { get; init; } = ImmutableDictionary<string, ProbeValues>.Empty;
    public string? MonitorSignature { get; init; }
    public DateTimeOffset? MonitorAt { get; init; }
}

public sealed record ReadingProbe(string Id, string Name, ProbeState State, string StateLabel, DateTimeOffset? LastSuccess, DateTimeOffset? LastAttempt, string? Error);

/// <summary>Linear forecast of the free space of a volume (Domenia 1 Get-DomeniaVolumeSaturationForecast) with its samples.</summary>
public sealed record VolumeForecast(
    string Volume,
    string Status,
    int Count,
    double SpanDays,
    DateTimeOffset? First,
    DateTimeOffset? Last,
    double? SlopeBytesPerDay,
    double? InterceptBytes,
    double? Fit,
    double? DaysLeft,
    DateTimeOffset? SaturationAt,
    long? SizeBytes,
    ImmutableArray<VolumeSample> Samples,
    string Text,
    Tone Tone);

/// <summary>Approved BIOS version of one model, kept as a local setting of one domain.</summary>
public sealed record BiosReference(string Manufacturer, string Model, string Version, DateTimeOffset ApprovedAt);

/// <summary>Comparison of the BIOS of the workstation with the approved version of its model.</summary>
public sealed record BiosCompare(string Manufacturer, string Model, string Observed, string? Reference, DateTimeOffset? ApprovedAt, string Result, string Text, Tone Tone, bool CanApprove, bool CanRemove);

/// <summary>One interpreted reading (Domenia 1 Invoke-DomeniaReading): dated facts, probes read, freshness.</summary>
public sealed record ReadingView(
    string Id,
    string Title,
    string Icon,
    Tone State,
    string StateLabel,
    DateTimeOffset? At,
    int StaleAfterSeconds,
    ImmutableArray<PosteFact> Facts,
    ImmutableArray<ReadingProbe> Probes,
    VolumeForecast? Forecast,
    BiosCompare? Bios);

/// <summary>Result of poste.readings and poste.probes.collect.</summary>
public sealed record ReadingsResult(
    string Computer,
    DateTimeOffset? CollectedAt,
    ImmutableArray<ReadingView> Readings,
    ImmutableArray<ProbeInfo> Catalog,
    string Summary,
    int Fresh,
    int Aging,
    int Stale,
    int Unread,
    int StaleAfterSeconds);

/// <summary>Result of poste.probe.details: the stored values of one probe, 100 rows a page, never a new query.</summary>
public sealed record ProbeDetailsResult(
    ProbeInfo Probe,
    ProbeStatus Status,
    string StatusLabel,
    ImmutableArray<string> Columns,
    ImmutableArray<ImmutableArray<string?>> Rows,
    int Page,
    int Pages,
    int Total,
    string Provenance,
    ImmutableArray<PosteFact> Interpreted);

/// <summary>Local book of the approved BIOS versions of one domain (500 models at most).</summary>
public static partial class BiosReferences
{
    public const int MaxModels = 500;

    [GeneratedRegex(@"\d+", RegexOptions.CultureInvariant, 200)]
    private static partial Regex Digits();

    /// <summary>
    /// Equal, Older, Newer, Different (formats that cannot be ordered) or Unknown (Compare-DomeniaBiosVersion): two versions
    /// are ordered only when they share the same skeleton once their digit runs are masked.
    /// </summary>
    public static string Compare(string? observed, string? reference)
    {
        var left = Regex.Replace(observed ?? "", @"\s+", " ", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(200)).Trim();
        var right = Regex.Replace(reference ?? "", @"\s+", " ", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(200)).Trim();
        if (left.Length == 0 || right.Length == 0)
        {
            return "Unknown";
        }
        if (string.Equals(left, right, StringComparison.OrdinalIgnoreCase))
        {
            return "Equal";
        }
        if (!string.Equals(Digits().Replace(left, "#"), Digits().Replace(right, "#"), StringComparison.OrdinalIgnoreCase))
        {
            return "Different";
        }
        var a = Digits().Matches(left).Select(m => m.Value).ToList();
        var b = Digits().Matches(right).Select(m => m.Value).ToList();
        for (var i = 0; i < a.Count && i < b.Count; i++)
        {
            if (a[i].Length > 9 || b[i].Length > 9)
            {
                return "Different";
            }
            var x = long.Parse(a[i], System.Globalization.CultureInfo.InvariantCulture);
            var y = long.Parse(b[i], System.Globalization.CultureInfo.InvariantCulture);
            if (x < y)
            {
                return "Older";
            }
            if (x > y)
            {
                return "Newer";
            }
        }
        return "Different";
    }

    /// <summary>Valid entry: model and version of 1 to 128 characters, maker of 128 at most, one line, no control character.</summary>
    public static bool IsValid(BiosReference reference)
    {
        ArgumentNullException.ThrowIfNull(reference);
        bool Ok(string text, int min) => text.Length >= min && text.Length <= 128 && !text.Any(char.IsControl);
        return Ok(reference.Model, 1) && Ok(reference.Version, 1) && Ok(reference.Manufacturer, 0);
    }

    public static BiosReference? Find(IEnumerable<BiosReference> book, string manufacturer, string model) =>
        book.FirstOrDefault(r => string.Equals(r.Manufacturer, manufacturer, StringComparison.OrdinalIgnoreCase) && string.Equals(r.Model, model, StringComparison.OrdinalIgnoreCase));

    /// <summary>Book with the version of a model approved (replaced if the model is known), bounded to 500 models.</summary>
    public static ImmutableArray<BiosReference> Approve(ImmutableArray<BiosReference> book, BiosReference reference)
    {
        ArgumentNullException.ThrowIfNull(reference);
        if (!IsValid(reference))
        {
            throw new ArgumentException("Référence BIOS invalide.", nameof(reference));
        }
        var others = book.Where(r => !(string.Equals(r.Manufacturer, reference.Manufacturer, StringComparison.OrdinalIgnoreCase) && string.Equals(r.Model, reference.Model, StringComparison.OrdinalIgnoreCase))).ToList();
        if (others.Count >= MaxModels)
        {
            throw new InvalidOperationException("500 modèles au plus dans les références BIOS.");
        }
        return [.. others, reference];
    }

    public static ImmutableArray<BiosReference> Remove(ImmutableArray<BiosReference> book, string manufacturer, string model) =>
        [.. book.Where(r => !(string.Equals(r.Manufacturer, manufacturer, StringComparison.OrdinalIgnoreCase) && string.Equals(r.Model, model, StringComparison.OrdinalIgnoreCase)))];
}
