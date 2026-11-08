using System.Collections.Frozen;
using System.Globalization;
using System.Text;

namespace Domenia.Core;

/// <summary>Grouped Windows release: editions of one version share the same key and label.</summary>
public sealed record WindowsReleaseInfo(string Key, string Label, bool IsServer);

/// <summary>Names the Windows release from operatingSystem and operatingSystemVersion with a small build table.</summary>
public static class WindowsRelease
{
    private static readonly FrozenDictionary<int, string> Windows11 = new Dictionary<int, string>
    {
        [22000] = "21H2",
        [22621] = "22H2",
        [22631] = "23H2",
        [26100] = "24H2",
        [26200] = "25H2",
    }.ToFrozenDictionary();

    private static readonly FrozenDictionary<int, string> Windows10 = new Dictionary<int, string>
    {
        [10240] = "1507",
        [14393] = "1607",
        [17763] = "1809",
        [19041] = "2004",
        [19042] = "20H2",
        [19043] = "21H1",
        [19044] = "21H2",
        [19045] = "22H2",
    }.ToFrozenDictionary();

    private static readonly FrozenDictionary<int, string> Windows10Ltsc = new Dictionary<int, string>
    {
        [14393] = "LTSB 2016",
        [17763] = "LTSC 2019",
        [19044] = "LTSC 2021",
    }.ToFrozenDictionary();

    private static readonly FrozenDictionary<int, string> Servers = new Dictionary<int, string>
    {
        [14393] = "2016",
        [17763] = "2019",
        [20348] = "2022",
        [26100] = "2025",
    }.ToFrozenDictionary();

    /// <summary>Grouped release, or null when the operating system is not filled in.</summary>
    public static WindowsReleaseInfo? Describe(string? operatingSystem, string? operatingSystemVersion)
    {
        if (string.IsNullOrWhiteSpace(operatingSystem))
        {
            return null;
        }
        var os = operatingSystem.Trim();
        var build = ParseBuild(operatingSystemVersion);
        var ltsc = os.Contains("LTSC", StringComparison.OrdinalIgnoreCase) || os.Contains("LTSB", StringComparison.OrdinalIgnoreCase);

        if (os.Contains("Server", StringComparison.OrdinalIgnoreCase))
        {
            return build is int sb && Servers.TryGetValue(sb, out var year)
                ? new WindowsReleaseInfo("ws-" + year, "Windows Server " + year, true)
                : new WindowsReleaseInfo(Slug(os), os, true);
        }
        if (os.Contains("Windows 11", StringComparison.OrdinalIgnoreCase))
        {
            if (ltsc && build == 26100)
            {
                return new WindowsReleaseInfo("w11-ltsc-2024", "Windows 11 LTSC 2024", false);
            }
            return build is int b11 && Windows11.TryGetValue(b11, out var release11)
                ? new WindowsReleaseInfo("w11-" + release11.ToLowerInvariant(), "Windows 11 " + release11, false)
                : new WindowsReleaseInfo("w11", "Windows 11", false);
        }
        if (os.Contains("Windows 10", StringComparison.OrdinalIgnoreCase))
        {
            if (ltsc && build is int bl && Windows10Ltsc.TryGetValue(bl, out var channel))
            {
                return new WindowsReleaseInfo("w10-" + Slug(channel), "Windows 10 " + channel, false);
            }
            return build is int b10 && Windows10.TryGetValue(b10, out var release10)
                ? new WindowsReleaseInfo("w10-" + release10.ToLowerInvariant(), "Windows 10 " + release10, false)
                : new WindowsReleaseInfo("w10", "Windows 10", false);
        }
        return new WindowsReleaseInfo(Slug(os), os, false);
    }

    /// <summary>Build number from « 10.0 (26100) » or « 10.0.26100 ».</summary>
    public static int? ParseBuild(string? version)
    {
        if (string.IsNullOrWhiteSpace(version))
        {
            return null;
        }
        var open = version.IndexOf('(', StringComparison.Ordinal);
        var close = version.IndexOf(')', StringComparison.Ordinal);
        string candidate;
        if (open >= 0 && close > open)
        {
            candidate = version[(open + 1)..close];
        }
        else
        {
            var lastDot = version.LastIndexOf('.');
            candidate = lastDot >= 0 ? version[(lastDot + 1)..] : version;
        }
        return int.TryParse(candidate.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var build) ? build : null;
    }

    /// <summary>Lower-case ASCII key: accents removed, any other character becomes a hyphen.</summary>
    public static string Slug(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var decomposed = text.Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(decomposed.Length);
        var pendingHyphen = false;
        foreach (var c in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.NonSpacingMark)
            {
                continue;
            }
            if (char.IsAsciiLetterOrDigit(c))
            {
                if (pendingHyphen && builder.Length > 0)
                {
                    builder.Append('-');
                }
                pendingHyphen = false;
                builder.Append(char.ToLowerInvariant(c));
            }
            else
            {
                pendingHyphen = true;
            }
        }
        return builder.Length == 0 ? "autre" : builder.ToString();
    }
}
