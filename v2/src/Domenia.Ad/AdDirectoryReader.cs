using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Ad;

/// <summary>
/// Reads of the directory mode through <see cref="IAdConnection"/>: the domain (identity, controllers, password policy, default
/// containers), read once at the connection of the session, and the directory picture (OUs, users, computers, groups), read on
/// an explicit gesture only. Every search is paged and bounded (number of objects per kind, delay per page); a picture cut by
/// a bound or holding an unreadable object says so (<see cref="DirectorySnapshot.Complete"/> false) instead of hiding it.
/// Read only: nothing here modifies the directory.
/// </summary>
public static class AdDirectoryReader
{
    /// <summary>Page size of the picture searches (the MaxPageSize of Active Directory by default).</summary>
    public const int PageSize = 1_000;

    /// <summary>Hard bound of one kind of the picture, whatever the caller asks.</summary>
    public const int MaxObjectsPerKindLimit = 1_000_000;

    private const int MaxContainers = 500;
    private const int MaxServers = 2_000;

    private static readonly TimeSpan PageTimeout = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan SmallTimeout = TimeSpan.FromSeconds(15);

    private static readonly string[] DomainAttributes =
    [
        "objectSid", "maxPwdAge", "minPwdLength", "pwdHistoryLength", "lockoutThreshold", "lockoutDuration",
        "lockOutObservationWindow", "pwdProperties",
    ];

    private static readonly string[] CrossRefAttributes = ["nETBIOSName", "dnsRoot"];
    private static readonly string[] ServerAttributes = ["dNSHostName", "serverReference"];
    private static readonly string[] ContainerAttributes = ["distinguishedName"];

    /// <summary>Bit 0x1 of pwdProperties (DOMAIN_PASSWORD_COMPLEX).</summary>
    private const int PasswordComplex = 0x1;

    /// <summary>
    /// The domain of the connection: RootDSE, domain object (SID, password policy), names (crossRef of the configuration
    /// partition), controllers (server objects of the sites that reference a computer of this domain) and default containers.
    /// A few small bounded searches; the same refusal codes as the connection (<see cref="AdErrors"/>).
    /// </summary>
    public static async Task<DomainInfo> ReadDomainAsync(IAdConnection connection, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        var rootDse = await connection.RootDseAsync(cancellationToken).ConfigureAwait(false);
        var rootDn = rootDse.DefaultNamingContext;
        if (string.IsNullOrWhiteSpace(rootDn))
        {
            throw new DomeniaOperationException(AdErrors.Failed, AdErrors.FailedMessage);
        }
        var domainEntry = await connection.ReadAsync(rootDn, DomainAttributes, cancellationToken).ConfigureAwait(false)
            ?? throw new DomeniaOperationException(AdErrors.NoSuchObject, AdErrors.NoSuchObjectMessage);
        var sid = domainEntry.Sid("objectSid") ?? throw new DomeniaOperationException(AdErrors.AccessDenied, AdErrors.AccessDeniedMessage);
        var (dnsName, netbiosName) = await ReadNamesAsync(connection, rootDse, rootDn, cancellationToken).ConfigureAwait(false);
        var controllers = await ReadControllersAsync(connection, rootDse, rootDn, cancellationToken).ConfigureAwait(false);
        var containers = await ReadContainersAsync(connection, rootDn, cancellationToken).ConfigureAwait(false);
        return new DomainInfo(dnsName, netbiosName, rootDn, sid, controllers, Policy(domainEntry), containers);
    }

    /// <summary>
    /// The directory picture under <paramref name="baseDn"/> (subtree): one paged search per kind, at most
    /// <paramref name="maxObjectsPerKind"/> objects each. Complete only when no kind reached its bound and every entry was
    /// converted. <see cref="DirectorySnapshot.ReadAt"/> is the start of the read (the picture is at least that fresh).
    /// </summary>
    public static async Task<DirectorySnapshot> ReadSnapshotAsync(IAdConnection connection, DomainInfo domain, string baseDn, int maxObjectsPerKind, TimeProvider clock, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(domain);
        ArgumentException.ThrowIfNullOrWhiteSpace(baseDn);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxObjectsPerKind);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(maxObjectsPerKind, MaxObjectsPerKindLimit);
        var readAt = clock.GetUtcNow();
        // One kind after the other: a single connection, never several large searches at once on the controller.
        var ous = await ReadKindAsync(connection, baseDn, AdDirectoryMapper.OuFilter, AdDirectoryMapper.OuAttributes, maxObjectsPerKind, AdDirectoryMapper.Ou, cancellationToken).ConfigureAwait(false);
        var users = await ReadKindAsync(connection, baseDn, AdDirectoryMapper.UserFilter, AdDirectoryMapper.UserAttributes, maxObjectsPerKind, AdDirectoryMapper.User, cancellationToken).ConfigureAwait(false);
        var computers = await ReadKindAsync(connection, baseDn, AdDirectoryMapper.ComputerFilter, AdDirectoryMapper.ComputerAttributes, maxObjectsPerKind, AdDirectoryMapper.Computer, cancellationToken).ConfigureAwait(false);
        var groups = await ReadKindAsync(connection, baseDn, AdDirectoryMapper.GroupFilter, AdDirectoryMapper.GroupAttributes, maxObjectsPerKind, AdDirectoryMapper.Group, cancellationToken).ConfigureAwait(false);
        var complete = ous.Complete && users.Complete && computers.Complete && groups.Complete;
        return new DirectorySnapshot(domain, readAt, complete, ous.Items, users.Items, computers.Items, groups.Items);
    }

    /// <summary>
    /// AD intervals (maxPwdAge, lockoutDuration…) are negative counts of 100 ns; 0 and the smallest value (« never ») mean no
    /// limit, given as <see cref="TimeSpan.Zero"/> like the rules of Domenia.Core expect.
    /// </summary>
    internal static TimeSpan Interval(long? value) =>
        value is long ticks && ticks < 0 && ticks != long.MinValue ? TimeSpan.FromTicks(-ticks) : TimeSpan.Zero;

    /// <summary>DNS name built from the DC= components of a naming context (« DC=example,DC=local » → « example.local »).</summary>
    internal static string DnsNameOf(string rootDn)
    {
        var labels = DistinguishedName.Parse(rootDn)
            .Where(n => string.Equals(n.Type, "DC", StringComparison.OrdinalIgnoreCase))
            .Select(n => n.Value)
            .ToArray();
        return labels.Length == 0 ? rootDn : string.Join('.', labels);
    }

    private static DomainPasswordPolicy Policy(AdEntry domain) =>
        new(
            Interval(domain.Long("maxPwdAge")),
            domain.Int("minPwdLength") ?? 0,
            domain.Int("pwdHistoryLength") ?? 0,
            domain.Int("lockoutThreshold") ?? 0,
            Interval(domain.Long("lockoutDuration")),
            Interval(domain.Long("lockOutObservationWindow")),
            // Unreadable: complexity is assumed, so Domenia never asks for less than the controller may require.
            ((domain.Int("pwdProperties") ?? PasswordComplex) & PasswordComplex) != 0);

    private static async Task<(string DnsName, string NetbiosName)> ReadNamesAsync(IAdConnection connection, AdRootDse rootDse, string rootDn, CancellationToken cancellationToken)
    {
        var fallbackDns = DnsNameOf(rootDn);
        var fallbackNetbios = FallbackNetbios(fallbackDns);
        if (string.IsNullOrWhiteSpace(rootDse.ConfigurationNamingContext))
        {
            return (fallbackDns, fallbackNetbios);
        }
        var request = new AdSearchRequest(
            "CN=Partitions," + rootDse.ConfigurationNamingContext,
            "(&(objectClass=crossRef)(nCName=" + LdapFilterText.Escape(rootDn) + "))",
            AdSearchScope.OneLevel,
            CrossRefAttributes)
        {
            PageSize = 1,
            SizeLimit = 1,
            Timeout = SmallTimeout,
        };
        var found = await connection.SearchAsync(request, cancellationToken).ConfigureAwait(false);
        if (found.Count == 0)
        {
            return (fallbackDns, fallbackNetbios);
        }
        var crossRef = found[0];
        var dns = crossRef.String("dnsRoot");
        var netbios = crossRef.String("nETBIOSName");
        return (string.IsNullOrWhiteSpace(dns) ? fallbackDns : dns, string.IsNullOrWhiteSpace(netbios) ? fallbackNetbios : netbios);
    }

    /// <summary>First DNS label in capitals, cut to 15 characters (rule of NetBIOS names), when the crossRef is not readable.</summary>
    private static string FallbackNetbios(string dnsName)
    {
        var first = dnsName.Split('.')[0].ToUpperInvariant();
        return first.Length > 15 ? first[..15] : first;
    }

    /// <summary>
    /// Controllers of the domain: server objects of the configuration sites whose serverReference is a computer of this domain;
    /// the site is the parent of their « Servers » container. The controller of the connection is always listed.
    /// </summary>
    private static async Task<ImmutableArray<DomainController>> ReadControllersAsync(IAdConnection connection, AdRootDse rootDse, string rootDn, CancellationToken cancellationToken)
    {
        var controllers = new Dictionary<string, DomainController>(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(rootDse.ConfigurationNamingContext))
        {
            var request = new AdSearchRequest("CN=Sites," + rootDse.ConfigurationNamingContext, "(objectClass=server)", AdSearchScope.Subtree, ServerAttributes)
            {
                PageSize = PageSize,
                SizeLimit = MaxServers,
                Timeout = SmallTimeout,
            };
            var servers = await connection.SearchAsync(request, cancellationToken).ConfigureAwait(false);
            foreach (var server in servers)
            {
                var host = server.String("dNSHostName");
                var reference = server.String("serverReference");
                if (string.IsNullOrWhiteSpace(host) || reference is null || !IsWithin(reference, rootDn))
                {
                    continue;
                }
                controllers[host] = new DomainController(host, SiteOf(server.DistinguishedName));
            }
        }
        if (!string.IsNullOrWhiteSpace(rootDse.DnsHostName) && !controllers.ContainsKey(rootDse.DnsHostName))
        {
            controllers[rootDse.DnsHostName] = new DomainController(rootDse.DnsHostName, null);
        }
        return [.. controllers.Values.OrderBy(c => c.DnsName, StringComparer.OrdinalIgnoreCase)];
    }

    /// <summary>Default containers right under the root (CN=Users, CN=Computers, CN=Builtin…), which are not OUs.</summary>
    private static async Task<ImmutableArray<string>> ReadContainersAsync(IAdConnection connection, string rootDn, CancellationToken cancellationToken)
    {
        var request = new AdSearchRequest(rootDn, "(|(objectClass=container)(objectClass=builtinDomain))", AdSearchScope.OneLevel, ContainerAttributes)
        {
            PageSize = MaxContainers,
            SizeLimit = MaxContainers,
            Timeout = SmallTimeout,
        };
        var found = await connection.SearchAsync(request, cancellationToken).ConfigureAwait(false);
        return [.. found.Select(e => e.DistinguishedName).OrderBy(dn => dn, StringComparer.OrdinalIgnoreCase)];
    }

    private static async Task<(ImmutableArray<T> Items, bool Complete)> ReadKindAsync<T>(IAdConnection connection, string baseDn, string filter, IReadOnlyList<string> attributes, int max, Func<AdEntry, T?> map, CancellationToken cancellationToken)
        where T : class
    {
        // One more than the bound: reaching it proves that objects were left out, never a guess.
        var request = new AdSearchRequest(baseDn, filter, AdSearchScope.Subtree, attributes)
        {
            PageSize = PageSize,
            SizeLimit = max + 1,
            Timeout = PageTimeout,
        };
        var entries = await connection.SearchAsync(request, cancellationToken).ConfigureAwait(false);
        var truncated = entries.Count > max;
        IReadOnlyList<AdEntry> kept = truncated ? [.. entries.Take(max)] : entries;
        var items = AdDirectoryMapper.Convert(kept, map, out var skipped);
        return (items, !truncated && skipped == 0);
    }

    private static bool IsWithin(string dn, string rootDn)
    {
        try
        {
            return DistinguishedName.IsWithin(dn, rootDn, subtree: true);
        }
        catch (FormatException)
        {
            // A malformed reference cannot be a computer of this domain: the server object is left out.
            return false;
        }
    }

    /// <summary>« CN=DC01,CN=Servers,CN=Paris,CN=Sites,… » → « Paris ».</summary>
    private static string? SiteOf(string serverDn)
    {
        try
        {
            var names = DistinguishedName.Parse(serverDn);
            return names.Length > 3 && string.Equals(names[1].Value, "Servers", StringComparison.OrdinalIgnoreCase) ? names[2].Value : null;
        }
        catch (FormatException)
        {
            // Unknown site rather than a wrong one.
            return null;
        }
    }
}
