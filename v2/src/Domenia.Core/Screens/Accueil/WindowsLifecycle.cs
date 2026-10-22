using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core.Accueil;

/// <summary>End-of-service state of a Windows release (Domenia 1, Get-DomeniaWindowsRelease).</summary>
public enum LifecycleStatus
{
    Ok,
    Soon,
    Ended,
    Unknown,
}

/// <summary>Lifecycle family of a system name: LTSC, LTSB and IoT keep their own dates.</summary>
public enum WindowsFamily
{
    Pro,
    Enterprise,
    Ltsc,
    IoT,
    Server,
}

/// <summary>Release name, end of service and status of one system, as Domenia 1 computes them.</summary>
public sealed record WindowsLifecycleInfo(
    string Name,
    string Label,
    string Note,
    WindowsFamily Family,
    string Build,
    DateOnly? End,
    bool Guessed,
    LifecycleStatus Status);

/// <summary>One line of the delivered end-of-service table.</summary>
public sealed record LifecycleEntry(string Build, WindowsFamily Family, string Name, DateOnly End);

/// <summary>
/// End-of-service table of Domenia 1 (Domenia-WindowsLifecycle.json, reviewed 08/10/2026, Microsoft Lifecycle dates), delivered
/// with the application and never downloaded, and the rule that names a release and its status. A date unknown to the table is
/// never critical (decision of David, 08/10/2026). Pure: the reference day is an input.
/// </summary>
public static partial class WindowsLifecycle
{
    public const string Reviewed = "2026-10-08";

    public static ImmutableArray<LifecycleEntry> Entries { get; } = Build(
    [
        ("7601", WindowsFamily.Pro, "Windows 7", "2020-01-14"), ("7601", WindowsFamily.Enterprise, "Windows 7", "2020-01-14"),
        ("7601", WindowsFamily.Server, "Windows Server 2008 R2", "2020-01-14"), ("9200", WindowsFamily.Server, "Windows Server 2012", "2023-10-10"),
        ("9600", WindowsFamily.Pro, "Windows 8.1", "2023-01-10"), ("9600", WindowsFamily.Enterprise, "Windows 8.1", "2023-01-10"),
        ("9600", WindowsFamily.Server, "Windows Server 2012 R2", "2023-10-10"),
        ("10240", WindowsFamily.Ltsc, "Windows 10 LTSB 2015", "2025-10-14"), ("10240", WindowsFamily.IoT, "Windows 10 IoT LTSB 2015", "2025-10-14"),
        ("14393", WindowsFamily.Ltsc, "Windows 10 LTSB 2016", "2026-10-13"), ("14393", WindowsFamily.IoT, "Windows 10 IoT LTSB 2016", "2026-10-13"),
        ("14393", WindowsFamily.Server, "Windows Server 2016", "2027-01-12"),
        ("17763", WindowsFamily.Pro, "Windows 10 1809", "2020-11-10"), ("17763", WindowsFamily.Enterprise, "Windows 10 1809", "2021-05-11"),
        ("17763", WindowsFamily.Ltsc, "Windows 10 LTSC 2019", "2029-01-09"), ("17763", WindowsFamily.IoT, "Windows 10 IoT LTSC 2019", "2029-01-09"),
        ("17763", WindowsFamily.Server, "Windows Server 2019", "2029-01-09"),
        ("18363", WindowsFamily.Pro, "Windows 10 1909", "2021-05-11"), ("18363", WindowsFamily.Enterprise, "Windows 10 1909", "2022-05-10"),
        ("19041", WindowsFamily.Pro, "Windows 10 2004", "2021-12-14"), ("19041", WindowsFamily.Enterprise, "Windows 10 2004", "2021-12-14"),
        ("19042", WindowsFamily.Pro, "Windows 10 20H2", "2022-05-10"), ("19042", WindowsFamily.Enterprise, "Windows 10 20H2", "2023-05-09"),
        ("19043", WindowsFamily.Pro, "Windows 10 21H1", "2022-12-13"), ("19043", WindowsFamily.Enterprise, "Windows 10 21H1", "2022-12-13"),
        ("19044", WindowsFamily.Pro, "Windows 10 21H2", "2023-06-13"), ("19044", WindowsFamily.Enterprise, "Windows 10 21H2", "2024-06-11"),
        ("19044", WindowsFamily.Ltsc, "Windows 10 LTSC 2021", "2027-01-12"), ("19044", WindowsFamily.IoT, "Windows 10 IoT LTSC 2021", "2032-01-13"),
        ("19045", WindowsFamily.Pro, "Windows 10 22H2", "2025-10-14"), ("19045", WindowsFamily.Enterprise, "Windows 10 22H2", "2025-10-14"),
        ("20348", WindowsFamily.Server, "Windows Server 2022", "2031-10-14"),
        ("22000", WindowsFamily.Pro, "Windows 11 21H2", "2023-10-10"), ("22000", WindowsFamily.Enterprise, "Windows 11 21H2", "2024-10-08"),
        ("22621", WindowsFamily.Pro, "Windows 11 22H2", "2024-10-08"), ("22621", WindowsFamily.Enterprise, "Windows 11 22H2", "2025-10-14"),
        ("22631", WindowsFamily.Pro, "Windows 11 23H2", "2025-11-11"), ("22631", WindowsFamily.Enterprise, "Windows 11 23H2", "2026-11-10"),
        ("26100", WindowsFamily.Pro, "Windows 11 24H2", "2026-10-13"), ("26100", WindowsFamily.Enterprise, "Windows 11 24H2", "2027-10-12"),
        ("26100", WindowsFamily.Ltsc, "Windows 11 LTSC 2024", "2029-10-09"), ("26100", WindowsFamily.IoT, "Windows 11 IoT LTSC 2024", "2034-10-10"),
        ("26100", WindowsFamily.Server, "Windows Server 2025", "2034-11-14"),
        ("26200", WindowsFamily.Pro, "Windows 11 25H2", "2027-10-12"), ("26200", WindowsFamily.Enterprise, "Windows 11 25H2", "2028-10-10"),
    ]);

    private static readonly FrozenDictionary<string, string> ClientNames = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["26200"] = "Windows 11 25H2", ["26100"] = "Windows 11 24H2", ["22631"] = "Windows 11 23H2", ["22621"] = "Windows 11 22H2",
        ["22000"] = "Windows 11 21H2", ["19045"] = "Windows 10 22H2", ["19044"] = "Windows 10 21H2", ["19043"] = "Windows 10 21H1",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    private static readonly FrozenDictionary<string, string> ServerNames = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["26100"] = "Windows Server 2025", ["20348"] = "Windows Server 2022", ["17763"] = "Windows Server 2019", ["14393"] = "Windows Server 2016",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    /// <summary>Build number of « 10.0 (19045) », « 10.0.19045 » or « 19045 »; empty when absent.</summary>
    public static string BuildOf(string? version)
    {
        var text = (version ?? "").Trim();
        var paren = ParenBuild().Match(text);
        if (paren.Success)
        {
            return paren.Groups[1].Value;
        }
        var dotted = DottedBuild().Match(text);
        if (dotted.Success)
        {
            return dotted.Groups[1].Value;
        }
        return BareBuild().IsMatch(text) ? text : "";
    }

    /// <summary>Family of a system name (AD operatingSystem or CIM caption).</summary>
    public static WindowsFamily FamilyOf(string? caption)
    {
        var c = caption ?? "";
        if (Has(c, "server"))
        {
            return WindowsFamily.Server;
        }
        if (LtsPattern().IsMatch(c))
        {
            return IotPattern().IsMatch(c) ? WindowsFamily.IoT : WindowsFamily.Ltsc;
        }
        if (ProPattern().IsMatch(c))
        {
            return WindowsFamily.Pro;
        }
        if (Has(c, "entreprise") || Has(c, "enterprise") || Has(c, "education") || Has(c, "éducation"))
        {
            return WindowsFamily.Enterprise;
        }
        return IotPattern().IsMatch(c) ? WindowsFamily.Enterprise : WindowsFamily.Pro;
    }

    /// <summary>
    /// Release, end of service and status of one system on <paramref name="today"/> (local day). Ended past the date, Soon at
    /// 90 days or less, Ok otherwise, Unknown without a line in the table. A Windows 10 or 11 build that was not read is ended
    /// « at the latest » only when every release of its family is already past its date.
    /// </summary>
    public static WindowsLifecycleInfo Evaluate(string? build, string? caption, DateOnly today)
    {
        var key = BuildOf(build);
        var family = FamilyOf(caption);
        var match = key.Length == 0 ? null : Entries.LastOrDefault(e => e.Build == key && e.Family == family);
        string name;
        if (match is not null)
        {
            name = match.Name;
        }
        else if (family == WindowsFamily.Server)
        {
            name = ServerNames.GetValueOrDefault(key) ?? ServerCaption(caption);
        }
        else
        {
            name = ClientNames.GetValueOrDefault(key) ?? "";
        }
        var label = name;
        if (name.Length > 0 && family is WindowsFamily.Pro or WindowsFamily.Enterprise && name.StartsWith("Windows 1", StringComparison.Ordinal) && !name.Contains("LTS", StringComparison.Ordinal))
        {
            label = name + (family == WindowsFamily.Pro ? " Pro" : " Entreprise");
        }
        DateOnly? end = match?.End;
        var guessed = false;
        if (end is null && key.Length == 0 && family is WindowsFamily.Pro or WindowsFamily.Enterprise)
        {
            var product = ProductPattern().Match(caption ?? "");
            if (product.Success)
            {
                var prefix = "Windows " + product.Groups[1].Value + " ";
                var latest = Entries.Where(e => e.Family == family && e.Name.StartsWith(prefix, StringComparison.Ordinal)).Select(e => (DateOnly?)e.End).Max();
                if (latest is DateOnly last && last < today)
                {
                    end = last;
                    guessed = true;
                    if (name.Length == 0)
                    {
                        name = prefix.TrimEnd();
                        label = name + " (version non lue)";
                    }
                }
            }
        }
        var status = end switch
        {
            null => LifecycleStatus.Unknown,
            DateOnly e when today > e => LifecycleStatus.Ended,
            DateOnly e when e.DayNumber - today.DayNumber <= 90 => LifecycleStatus.Soon,
            _ => LifecycleStatus.Ok,
        };
        var endText = end is DateOnly d ? FrenchText.ShortDate(d) : "";
        var buildText = key.Length > 0 ? "Build " + key : "";
        var note = status switch
        {
            LifecycleStatus.Ended => (guessed ? "Fin de service au plus tard le " : "Fin de service le ") + endText + FrenchText.Colon + "à migrer",
            LifecycleStatus.Soon => "Fin de service le " + endText,
            LifecycleStatus.Ok => string.Join(" · ", new[] { buildText, "fin de service le " + endText }.Where(s => s.Length > 0)),
            _ => name.Length > 0 || key.Length > 0 ? string.Join(" · ", new[] { buildText, "date de fin inconnue" }.Where(s => s.Length > 0)) : "",
        };
        return new WindowsLifecycleInfo(name, label, note, family, key, end, guessed, status);
    }

    private static string ServerCaption(string? caption)
    {
        var text = ServerSuffix().Replace(MicrosoftPrefix().Replace(caption ?? "", ""), "").Trim();
        return text.StartsWith("Windows", StringComparison.Ordinal) ? text : "Windows Server";
    }

    private static bool Has(string text, string part) => text.Contains(part, StringComparison.OrdinalIgnoreCase);

    private static ImmutableArray<LifecycleEntry> Build((string Build, WindowsFamily Family, string Name, string End)[] rows) =>
        [.. rows.Select(r => new LifecycleEntry(r.Build, r.Family, r.Name, DateOnly.ParseExact(r.End, "yyyy-MM-dd", CultureInfo.InvariantCulture)))];

    [GeneratedRegex(@"\((\d{3,6})\)")]
    private static partial Regex ParenBuild();

    [GeneratedRegex(@"^\d+\.\d+\.(\d{3,6})")]
    private static partial Regex DottedBuild();

    [GeneratedRegex(@"^\d{3,6}$")]
    private static partial Regex BareBuild();

    [GeneratedRegex(@"LTS[BC]", RegexOptions.IgnoreCase)]
    private static partial Regex LtsPattern();

    [GeneratedRegex(@"\bIoT\b", RegexOptions.IgnoreCase)]
    private static partial Regex IotPattern();

    [GeneratedRegex(@"\bPro\b|professionnel|professional", RegexOptions.IgnoreCase)]
    private static partial Regex ProPattern();

    [GeneratedRegex(@"windows\s+(\d+)", RegexOptions.IgnoreCase)]
    private static partial Regex ProductPattern();

    [GeneratedRegex(@"^Microsoft\s+", RegexOptions.IgnoreCase)]
    private static partial Regex MicrosoftPrefix();

    [GeneratedRegex(@"\s+(Standard|Datacenter|Essentials|Evaluation).*$", RegexOptions.IgnoreCase)]
    private static partial Regex ServerSuffix();
}
