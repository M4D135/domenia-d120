using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Queries;

/// <summary>One property a probe reads, with its CIM type (schema of the delivered catalog).</summary>
public sealed record QueryProbeField(string Name, string CimType, QueryFieldKind Kind, bool IsArray, string Unit, string Description);

/// <summary>
/// Read-only WMI probe of the delivered catalog (Domenia 1 Get-DomeniaProbeCatalog and Domenia-ProbeCatalog.json): one
/// class, explicit properties, an optional filter, a reading mode (First, All, Count) and a conversion. Never a free WQL text.
/// </summary>
public sealed record QueryProbe(
    string Id,
    string Category,
    string Name,
    string Namespace,
    string Class,
    ImmutableArray<string> Properties,
    string Filter,
    string Mode,
    string Transform,
    string Visual,
    bool Slow,
    bool SkipOnDc,
    string Description,
    string Limitations,
    ImmutableArray<QueryProbeField> Fields)
{
    private static readonly FrozenSet<string> NumericTransforms = new[] { "GB", "GBfromKB", "MB", "Mbps", "Number", "DaysSince", "PercentFree", "Year" }.ToFrozenSet(StringComparer.Ordinal);

    /// <summary>True when the probe gives a number (count or numeric conversion), so it takes numeric operators.</summary>
    public bool Numeric => !Transform.StartsWith("Map:", StringComparison.Ordinal) && (Mode == "Count" || NumericTransforms.Contains(Transform));

    /// <summary>Unit shown with the values (Domenia 1 catalog rules).</summary>
    public string Unit => Id switch
    {
        "hw.cpuload" or "hw.batterylevel" => "%",
        "hw.cpumhz" => "MHz",
        "sec.signatures" or "sec.quickscan" or "sec.fullscan" => "Jours",
        _ => Transform switch
        {
            "GB" or "GBfromKB" => "Go",
            "MB" => "Mo",
            "Mbps" => "Mbit/s",
            "DaysSince" => "Jours",
            "PercentFree" => "%",
            "Year" => "Année",
            "Number" when Mode != "Count" => "Nombre",
            _ when Mode == "Count" => "Nombre",
            _ => "Texte",
        },
    };

    /// <summary>Coded values of a mapped probe (« Map:0=Sain;1=Avertissement »), each once, in the catalog order.</summary>
    public ImmutableArray<string> MapValues
    {
        get
        {
            if (!Transform.StartsWith("Map:", StringComparison.Ordinal))
            {
                return [];
            }
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var values = ImmutableArray.CreateBuilder<string>();
            foreach (var pair in Transform[4..].Split(';'))
            {
                var at = pair.IndexOf('=', StringComparison.Ordinal);
                if (at > 0 && seen.Add(pair[(at + 1)..]))
                {
                    values.Add(pair[(at + 1)..]);
                }
            }
            return values.ToImmutable();
        }
    }

    /// <summary>« Première instance », « Toutes les instances » or « Nombre d’instances ».</summary>
    public string ModeLabel => Mode switch
    {
        "Count" => "Nombre d’instances",
        "All" => "Toutes les instances",
        _ => "Première instance",
    };
}

/// <summary>One instance read by a probe: raw provider values by property name, and the properties not entirely kept.</summary>
public sealed record ProbeInstance(string Id, ImmutableDictionary<string, object?> Values, ImmutableArray<string> Incomplete);

/// <summary>
/// Last reading of one probe on one workstation (its own date: a ping never makes it fresher). Error, skipped (domain
/// controller), truncated or undated readings give no value: the information stays unknown.
/// </summary>
public sealed record ProbeReading(
    string ProbeId,
    DateTimeOffset? CheckedAt,
    string? Error,
    bool Skipped,
    bool Truncated,
    long? Count,
    bool CountComplete,
    ImmutableArray<ProbeInstance> Instances);

/// <summary>The delivered probes and the conversion of their raw values.</summary>
public static partial class QueryProbeCatalog
{
    private static readonly Lazy<ImmutableArray<QueryProbe>> All_ = new(Build, LazyThreadSafetyMode.ExecutionAndPublication);
    private static readonly Lazy<FrozenDictionary<string, QueryProbe>> ById = new(() => All_.Value.ToFrozenDictionary(p => p.Id, StringComparer.Ordinal), LazyThreadSafetyMode.ExecutionAndPublication);

    /// <summary>Classes whose provider may repair or reinstall software when read (Domenia 1 MSI guard).</summary>
    public static ImmutableArray<string> MsiProviderClasses { get; } =
        ["Win32_Product", "Win32_SoftwareFeature", "Win32_SoftwareElement", "Win32_ProductSoftwareFeatures", "Win32_SoftwareFeatureCheck",
         "Win32_SoftwareElementCheck", "Win32_InstalledSoftwareElement", "Win32_ApplicationService", "Win32_ProductResource", "CIM_Product"];

    public static ImmutableArray<QueryProbe> All => All_.Value;

    public static QueryProbe? Find(string? id) => id is not null && ById.Value.TryGetValue(id, out var probe) ? probe : null;

    /// <summary>
    /// Values of one probe reading after its conversion (Domenia 1 Get-DomeniaProbeValues): texts or decimal numbers. An
    /// error, a skipped or truncated reading gives none; a value outside a map keeps its raw text, nothing is invented.
    /// </summary>
    public static IReadOnlyList<object> Values(QueryProbe probe, ProbeReading reading, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(probe);
        ArgumentNullException.ThrowIfNull(reading);
        if (reading.Error is not null || reading.Skipped || (probe.Mode != "Count" && reading.Truncated))
        {
            return [];
        }
        var first = probe.Properties.Length > 0 ? probe.Properties[0] : "";
        IEnumerable<object?> raw = probe.Mode switch
        {
            "Count" => reading.Count is long count ? [count] : [],
            "All" => reading.Instances.Select(i => i.Values.GetValueOrDefault(first)),
            _ => reading.Instances.Length > 0 ? [reading.Instances[0].Values.GetValueOrDefault(first)] : [],
        };
        var result = new List<object>();
        foreach (var value in raw)
        {
            var text = Invariant(value);
            if (string.IsNullOrWhiteSpace(text) && !probe.Transform.StartsWith("Map:", StringComparison.Ordinal))
            {
                continue;
            }
            var converted = Convert(probe, text, reading, now);
            if (converted is not null)
            {
                result.Add(converted);
            }
        }
        return result;
    }

    private static object? Convert(QueryProbe probe, string text, ProbeReading reading, DateTimeOffset now)
    {
        switch (probe.Transform)
        {
            case "GB":
                return Number(text) is decimal gb ? Math.Round(gb / (1024m * 1024m * 1024m), 1) : null;
            case "GBfromKB":
                return Number(text) is decimal kb ? Math.Round(kb / (1024m * 1024m), 1) : null;
            case "MB":
                return Number(text) is decimal mb ? Math.Round(mb / (1024m * 1024m)) : null;
            case "Mbps":
                return Number(text) is decimal bps ? Math.Round(bps / 1000000m) : null;
            case "Number":
                return Number(text);
            case "DaysSince":
                return Date(text) is DateTimeOffset since ? (decimal)Math.Round((now - since).TotalDays) : null;
            case "Year":
                return Date(text) is DateTimeOffset year ? year.Year.ToString(CultureInfo.InvariantCulture) : null;
            case "PercentFree":
                {
                    var row = reading.Instances.Length > 0 ? reading.Instances[0] : null;
                    if (row is null || probe.Properties.Length < 2)
                    {
                        return null;
                    }
                    var free = Number(Invariant(row.Values.GetValueOrDefault(probe.Properties[0])));
                    var size = Number(Invariant(row.Values.GetValueOrDefault(probe.Properties[1])));
                    return free is decimal f && size is decimal s && s > 0 ? Math.Round(100m * f / s) : null;
                }
            case "Release":
                {
                    var row = reading.Instances.Length > 0 ? reading.Instances[0] : null;
                    var productType = row is not null && probe.Properties.Length >= 2 ? Invariant(row.Values.GetValueOrDefault(probe.Properties[1])) : "";
                    var server = productType is not ("" or "1");
                    var build = int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var b) ? b : (int?)null;
                    var caption = server ? "Windows Server" : build >= 22000 ? "Windows 11" : "Windows 10";
                    return build is int known ? WindowsRelease.Describe(caption, "10.0 (" + known.ToString(CultureInfo.InvariantCulture) + ")")?.Label ?? "Build " + text : "Build " + text;
                }
            default:
                if (probe.Transform.StartsWith("Map:", StringComparison.Ordinal))
                {
                    foreach (var pair in probe.Transform[4..].Split(';'))
                    {
                        var at = pair.IndexOf('=', StringComparison.Ordinal);
                        if (at > 0 && string.Equals(pair[..at], text, StringComparison.Ordinal))
                        {
                            return pair[(at + 1)..];
                        }
                    }
                    return text;
                }
                return text.Trim();
        }
    }

    /// <summary>Invariant text of a raw provider value (numbers without grouping, booleans as True/False).</summary>
    public static string Invariant(object? value) => value switch
    {
        null => "",
        string s => s,
        bool b => b ? "True" : "False",
        decimal d => d.ToString("G29", CultureInfo.InvariantCulture),
        double f => f.ToString("R", CultureInfo.InvariantCulture),
        long l => l.ToString(CultureInfo.InvariantCulture),
        int i => i.ToString(CultureInfo.InvariantCulture),
        DateTimeOffset t => t.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture),
        _ => System.Convert.ToString(value, CultureInfo.InvariantCulture) ?? "",
    };

    /// <summary>Invariant decimal of a raw value; null when it is not a finite number (never 0).</summary>
    public static decimal? Number(string? text) =>
        decimal.TryParse((text ?? "").Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var number) ? number : null;

    private static DateTimeOffset? Date(string text)
    {
        // CIM datetime (yyyymmddHHMMSS.mmmmmmsUUU) or ISO 8601.
        if (text.Length >= 14 && text[..14].All(char.IsAsciiDigit)
            && DateTime.TryParseExact(text[..14], "yyyyMMddHHmmss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var cim))
        {
            return new DateTimeOffset(cim, TimeSpan.Zero);
        }
        return DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var iso) ? iso : null;
    }
}
