using System.DirectoryServices.Protocols;
using System.Globalization;
using System.Text;
using Domenia.Core;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Ad;

/// <summary>
/// Bounded reads of single objects, shared by the readers of the screens and by the write executors: one base search per object
/// on the connection of the session, the attributes the contract of the screen asks for, and nothing else. Every value the
/// operator may have typed is escaped before it reaches a filter (<see cref="LdapFilterText.Escape"/>), and a DN that the parser
/// refuses is never searched. Read only: this class never modifies anything.
/// </summary>
internal static class AdObjectAccess
{
    /// <summary>Delay of one base read (docs/ops/fiche.md § 5.1: 10 s).</summary>
    public static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(10);

    /// <summary>Delay of one bounded search (docs/ops/comptes.md § 7.1: 30 s for the list).</summary>
    public static readonly TimeSpan SearchTimeout = TimeSpan.FromSeconds(30);

    /// <summary>Attributes of one row of the account list (docs/ops/comptes.md § 7.1).</summary>
    public static IReadOnlyList<string> AccountAttributes { get; } =
    [
        "distinguishedName", "objectGUID", "objectSid", "sAMAccountName", "userPrincipalName", "displayName", "cn", "name",
        "objectClass", "objectCategory", "title", "department", "physicalDeliveryOfficeName", "userAccountControl",
        "msDS-User-Account-Control-Computed", "lockoutTime", "badPwdCount", "pwdLastSet",
        "msDS-UserPasswordExpiryTimeComputed", "lastLogonTimestamp", "accountExpires", "adminCount",
    ];

    /// <summary>Attributes of the detail of one account (docs/ops/comptes.md § 7.1: those of the list plus these).</summary>
    public static IReadOnlyList<string> DetailAttributes { get; } =
    [
        .. AccountAttributes,
        "givenName", "sn", "mail", "telephoneNumber", "employeeID", "manager", "description", "whenCreated", "whenChanged",
        "uSNChanged", "memberOf", "primaryGroupID",
    ];

    /// <summary>Attributes of the fiche of one object (docs/ops/fiche.md § 5.1). Never a secret: no unicodePwd, no LAPS value.</summary>
    public static IReadOnlyList<string> FicheAttributes { get; } =
    [
        "objectClass", "objectGUID", "objectSid", "distinguishedName", "name", "cn", "displayName", "givenName", "sn",
        "sAMAccountName", "userPrincipalName", "mail", "telephoneNumber", "mobile", "ipPhone", "homePhone",
        "facsimileTelephoneNumber", "wWWHomePage", "physicalDeliveryOfficeName", "streetAddress", "l", "st", "postalCode",
        "c", "co", "title", "department", "company", "employeeID", "description", "info", "manager", "managedBy", "memberOf",
        "member", "primaryGroupID", "userAccountControl", "msDS-User-Account-Control-Computed", "lockoutTime", "badPwdCount",
        "badPasswordTime", "pwdLastSet", "msDS-UserPasswordExpiryTimeComputed", "accountExpires", "lastLogonTimestamp",
        "logonCount", "logonHours", "userWorkstations", "profilePath", "scriptPath", "homeDirectory", "homeDrive",
        "adminCount", "isCriticalSystemObject", "groupType", "gPLink", "dNSHostName", "operatingSystem",
        "operatingSystemVersion", "servicePrincipalName", "ms-Mcs-AdmPwdExpirationTime", "msLAPS-PasswordExpirationTime",
        "whenCreated", "whenChanged", "uSNChanged",
    ];

    /// <summary>Attributes of one group read by its DN (docs/ops/fiche.md § 5.1, fiche.groups).</summary>
    public static IReadOnlyList<string> GroupAttributes { get; } =
    [
        "name", "cn", "sAMAccountName", "groupType", "objectSid", "objectGUID", "distinguishedName", "objectClass",
        "adminCount", "description", "memberOf",
    ];

    /// <summary>Attributes of one computer read by its DN (the workstation writes of the fiche and of the Poste screen).</summary>
    public static IReadOnlyList<string> ComputerAttributes { get; } =
    [
        "name", "cn", "dNSHostName", "sAMAccountName", "distinguishedName", "objectGUID", "objectSid", "description",
        "location", "managedBy", "operatingSystem", "operatingSystemVersion", "userAccountControl", "lastLogonTimestamp",
        "pwdLastSet", "whenCreated", "whenChanged", "uSNChanged", "memberOf", "primaryGroupID", "objectClass",
        "servicePrincipalName", "ms-Mcs-AdmPwdExpirationTime", "msLAPS-PasswordExpirationTime",
    ];

    /// <summary>One base search on the DN; null when the object does not exist (code 32) or the DN is not a DN.</summary>
    public static async Task<AdEntry?> ReadAsync(IAdConnection connection, string distinguishedName, IReadOnlyList<string> attributes, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(attributes);
        if (!IsDn(distinguishedName))
        {
            return null;
        }

        return await connection.ReadAsync(distinguishedName, attributes, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>The user at this DN, with the attributes of the detail; null when no user account has this DN.</summary>
    public static async Task<DirectoryUser?> ReadUserAsync(IAdConnection connection, string distinguishedName, CancellationToken cancellationToken)
    {
        var entry = await ReadAsync(connection, distinguishedName, DetailAttributes, cancellationToken).ConfigureAwait(false);
        return entry is null || !IsUser(entry) ? null : AdDirectoryMapper.User(entry);
    }

    /// <summary>The user at this DN with the attributes of the list only (preconditions of the account writes).</summary>
    public static async Task<DirectoryUser?> ReadUserLightAsync(IAdConnection connection, string distinguishedName, CancellationToken cancellationToken)
    {
        var entry = await ReadAsync(connection, distinguishedName, AccountAttributes, cancellationToken).ConfigureAwait(false);
        return entry is null || !IsUser(entry) ? null : AdDirectoryMapper.User(entry);
    }

    /// <summary>The computer at this DN; null when no computer account has this DN.</summary>
    public static async Task<DirectoryComputer?> ReadComputerAsync(IAdConnection connection, string distinguishedName, CancellationToken cancellationToken)
    {
        var entry = await ReadAsync(connection, distinguishedName, ComputerAttributes, cancellationToken).ConfigureAwait(false);
        return entry is null || !IsComputer(entry) ? null : AdDirectoryMapper.Computer(entry);
    }

    /// <summary>The group at this DN; null when no group has this DN.</summary>
    public static async Task<DirectoryGroup?> ReadGroupAsync(IAdConnection connection, string distinguishedName, CancellationToken cancellationToken)
    {
        var entry = await ReadAsync(connection, distinguishedName, GroupAttributes, cancellationToken).ConfigureAwait(false);
        return entry is null || !IsGroup(entry) ? null : AdDirectoryMapper.Group(entry);
    }

    /// <summary>The object with this GUID, searched in the whole subtree of <paramref name="baseDn"/> (identity check of a fiche).</summary>
    public static async Task<AdEntry?> ReadByGuidAsync(IAdConnection connection, string baseDn, Guid objectGuid, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        if (!IsDn(baseDn))
        {
            return null;
        }

        var found = await connection.SearchAsync(new AdSearchRequest(baseDn, "(objectGUID=" + Hex(objectGuid.ToByteArray()) + ")", AdSearchScope.Subtree, FicheAttributes)
        {
            PageSize = 2,
            SizeLimit = 2,
            Timeout = ReadTimeout,
        }, cancellationToken).ConfigureAwait(false);
        return found.Count == 0 ? null : found[0];
    }

    /// <summary>
    /// The groups of these DNs, read by packets of 40 exact DNs (docs/ops/fiche.md § 5.1). At most
    /// <paramref name="limit"/> groups; a DN the directory does not know is simply absent.
    /// </summary>
    public static async Task<IReadOnlyList<DirectoryGroup>> ReadGroupsAsync(IAdConnection connection, string baseDn, IReadOnlyList<string> dns, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(dns);
        if (!IsDn(baseDn))
        {
            return [];
        }

        var wanted = dns.Where(IsDn).Distinct(StringComparer.OrdinalIgnoreCase).Take(Math.Max(0, limit)).ToList();
        var result = new List<DirectoryGroup>(wanted.Count);
        for (var start = 0; start < wanted.Count && result.Count < limit; start += 40)
        {
            var packet = wanted.GetRange(start, Math.Min(40, wanted.Count - start));
            var filter = packet.Count == 1
                ? "(distinguishedName=" + LdapFilterText.Escape(packet[0]) + ")"
                : "(|" + string.Concat(packet.Select(dn => "(distinguishedName=" + LdapFilterText.Escape(dn) + ")")) + ")";
            var found = await connection.SearchAsync(new AdSearchRequest(baseDn, filter, AdSearchScope.Subtree, GroupAttributes)
            {
                PageSize = 200,
                SizeLimit = limit - result.Count,
                Timeout = SearchTimeout,
            }, cancellationToken).ConfigureAwait(false);
            foreach (var entry in found)
            {
                if (AdDirectoryMapper.Group(entry) is DirectoryGroup group)
                {
                    result.Add(group);
                }
            }
        }

        return result;
    }

    /// <summary>
    /// The constructed attributes (<c>msDS-User-Account-Control-Computed</c>, <c>msDS-UserPasswordExpiryTimeComputed</c>,
    /// <c>memberOf</c>, <c>primaryGroupID</c>) are answered by a base search only. A paged subtree search may come back without
    /// them: they are then read object by object, within <paramref name="limit"/>. An account still without its computed state
    /// stays « to check », never « locked » (docs/ops/comptes.md § 7.1).
    /// </summary>
    public static async Task<IReadOnlyList<DirectoryUser>> FillConstructedAsync(IAdConnection connection, IReadOnlyList<DirectoryUser> users, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(users);
        if (users.Count == 0)
        {
            return users;
        }

        var result = new List<DirectoryUser>(users.Count);
        var filled = 0;
        foreach (var user in users)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var needsRead = user.ComputedAccountControl is null || user.PasswordExpiryComputed is null;
            if (!needsRead || filled >= Math.Max(0, limit))
            {
                result.Add(user);
                continue;
            }

            filled++;
            var entry = await ReadAsync(connection, user.DistinguishedName, ["msDS-User-Account-Control-Computed", "msDS-UserPasswordExpiryTimeComputed"], cancellationToken).ConfigureAwait(false);
            result.Add(entry is null
                ? user
                : user with
                {
                    ComputedAccountControl = user.ComputedAccountControl ?? entry.Int("msDS-User-Account-Control-Computed"),
                    PasswordExpiryComputed = user.PasswordExpiryComputed ?? entry.Long("msDS-UserPasswordExpiryTimeComputed"),
                });
        }

        return result;
    }

    /// <summary>True when the text parses as a DN: nothing malformed is ever sent to the controller.</summary>
    public static bool IsDn(string? distinguishedName)
    {
        if (string.IsNullOrWhiteSpace(distinguishedName))
        {
            return false;
        }

        try
        {
            return DistinguishedName.Parse(distinguishedName).Length > 0;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    /// <summary>Filter value of a DN, escaped for an equality assertion.</summary>
    public static string Escape(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return LdapFilterText.Escape(value);
    }

    /// <summary>Binary value of a filter (objectGUID): « \XX\XX… », the encoding Active Directory expects.</summary>
    public static string Hex(byte[] value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var builder = new StringBuilder(value.Length * 3);
        foreach (var b in value)
        {
            builder.Append('\\').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }

        return builder.ToString();
    }

    public static bool IsUser(AdEntry entry) =>
        entry.Strings("objectClass").Any(c => string.Equals(c, "user", StringComparison.OrdinalIgnoreCase))
        && !IsComputer(entry);

    public static bool IsComputer(AdEntry entry) =>
        entry.Strings("objectClass").Any(c => string.Equals(c, "computer", StringComparison.OrdinalIgnoreCase));

    public static bool IsGroup(AdEntry entry) =>
        entry.Strings("objectClass").Any(c => string.Equals(c, "group", StringComparison.OrdinalIgnoreCase));

    public static bool IsOu(AdEntry entry) =>
        entry.Strings("objectClass").Any(c => string.Equals(c, "organizationalUnit", StringComparison.OrdinalIgnoreCase));

    public static bool IsContainer(AdEntry entry) =>
        entry.Strings("objectClass").Any(c => string.Equals(c, "container", StringComparison.OrdinalIgnoreCase));
}
