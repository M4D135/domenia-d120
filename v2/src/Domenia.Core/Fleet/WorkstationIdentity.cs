namespace Domenia.Core;

/// <summary>The AD display CN can be renamed independently of Windows. Match a native name against SAM and DNS instead.</summary>
public static class WorkstationIdentity
{
    public static string? ExpectedName(DirectoryComputer computer)
    {
        ArgumentNullException.ThrowIfNull(computer);
        var sam = computer.SamAccountName;
        if (computer.ObjectGuid == Guid.Empty || sam is not { Length: > 1 and <= 64 } || !sam.EndsWith('$')) { return null; }
        var name = sam[..^1];
        if (!name.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_')) { return null; }
        if (computer.DnsHostName is { Length: > 0 } dns && !string.Equals(dns.Split('.')[0], name, StringComparison.OrdinalIgnoreCase)
            && !(name.Length == 15 && dns.Split('.')[0].Length > 15 && string.Equals(dns.Split('.')[0][..15], name, StringComparison.OrdinalIgnoreCase))) { return null; }
        return name;
    }

    public static bool Matches(DirectoryComputer computer, string? reportedName, NativeWorkstationIdentity? native = null) => native is not null && native.Matches(computer)
        && string.Equals(reportedName, native.Name, StringComparison.OrdinalIgnoreCase);

    /// <summary>Legacy observations remain viewable under their existing GUID provenance, never a fresh native proof.</summary>
    public static bool MatchesHistorical(DirectoryComputer computer, string? name, NativeWorkstationIdentity? native = null) => native is not null
        ? Matches(computer, name, native) : ExpectedName(computer) is { } expected && string.Equals(name, expected, StringComparison.OrdinalIgnoreCase);
}
