namespace Domenia.Core;

public enum NativeIdentityState { Unconfirmed, Confirmed, Inconsistent }
public enum NativeIdentityDomainKind { Membership, PrimaryDnsSuffix }

/// <summary>Values returned by Windows, kept apart from the requested host and the AD display name.
/// A CIM Domain is membership, not the primary DNS suffix: disjoint namespaces are supported.</summary>
public sealed record NativeWorkstationIdentity(string RequestedHost, string? Name, string? DnsHostName, string? Domain)
{
    public NativeIdentityDomainKind DomainKind { get; init; }
    public string? FullyQualifiedDns => Dns(DnsHostName) is { } host
        ? host.Contains('.') ? host : DomainKind == NativeIdentityDomainKind.PrimaryDnsSuffix && Dns(Domain) is { } suffix ? host + "." + suffix : null : null;
    public NativeIdentityState State
    {
        get
        {
            if (!Enum.IsDefined(DomainKind) || HostLabel(Name) is not { } name || Dns(DnsHostName) is not { } dns
                || Dns(RequestedHost) is not { } requested || Dns(Domain) is null) return NativeIdentityState.Unconfirmed;
            var dnsLabel = dns.Split('.')[0];
            // Windows derives NetBIOS from the first DNS label (15 OEM bytes). Accepted names are ASCII,
            // so 15 bytes == 15 characters. Truncation alone never proves the machine: AD DNS is checked as well.
            if (!Same(name, dnsLabel) && !(dnsLabel.Length > 15 && Same(name, dnsLabel[..15]))) return NativeIdentityState.Inconsistent;
            if (!Same(requested.Split('.')[0], dnsLabel) && !(!requested.Contains('.') && dnsLabel.Length > 15 && Same(requested, name)))
                return NativeIdentityState.Inconsistent;
            if (DomainKind == NativeIdentityDomainKind.PrimaryDnsSuffix && dns.Contains('.') && !Same(dns[(dns.IndexOf('.') + 1)..], Dns(Domain)))
                return NativeIdentityState.Inconsistent;
            if (requested.Contains('.') && FullyQualifiedDns is { } full && !Same(requested, full)) return NativeIdentityState.Inconsistent;
            return NativeIdentityState.Confirmed;
        }
    }
    public string Label => State switch { NativeIdentityState.Confirmed => "Confirmée", NativeIdentityState.Inconsistent => "Incohérente", _ => "Non confirmée" };
    public bool Matches(DirectoryComputer computer)
    {
        if (State != NativeIdentityState.Confirmed || computer.ObjectGuid == Guid.Empty || computer.SamAccountName is not { Length: > 1 and <= 64 } sam || !sam.EndsWith('$')) return false;
        var adDns = Dns(computer.DnsHostName); var returned = Dns(DnsHostName); var requested = Dns(RequestedHost);
        if (adDns is null || returned is null || requested is null || !adDns.Contains('.')) return false;
        if (requested.Contains('.') && !Same(requested, adDns) || !Same(returned.Split('.')[0], adDns.Split('.')[0])) return false;
        if (FullyQualifiedDns is { } full && !Same(adDns, full)) return false;
        if (DomainKind == NativeIdentityDomainKind.Membership && !Same(Dns(Domain), DirectoryDomain(computer.DistinguishedName))) return false;
        var samName = sam[..^1]; var dnsLabel = adDns.Split('.')[0];
        return Same(samName, Name) || Same(samName, dnsLabel) && dnsLabel.Length > 15 && Same(Name, dnsLabel[..15]);
    }
    private static string? DirectoryDomain(string dn)
    {
        try
        {
            var parts = DistinguishedName.Parse(dn); var first = 0;
            while (first < parts.Length && !Same(parts[first].Type, "DC")) first++;
            if (first == parts.Length || parts.Skip(first).Any(p => !Same(p.Type, "DC") || HostLabel(p.Value) is null)) return null;
            return Dns(string.Join('.', parts.Skip(first).Select(p => p.Value)));
        }
        catch (FormatException) { return null; }
    }
    private static bool Same(string? a, string? b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
    private static string? HostLabel(string? value) => value is { Length: > 0 and <= 63 }
        && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_') ? value : null;
    private static string? Dns(string? value)
    {
        var name = value?.TrimEnd('.');
        return name is { Length: > 0 and <= 253 } && name.Split('.').All(part => HostLabel(part) is not null) ? name : null;
    }
}
