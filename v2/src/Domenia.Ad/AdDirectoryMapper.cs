using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>
/// Conversion of LDAP entries to the directory models of Domenia.Core, with the attributes Domenia 1 reads
/// (docs/SIMULATION.md § 3.3): flags stay integers and dates stay FILETIME values, so the same pure rules serve the simulation
/// and the real directory. Pure: no network, no clock. An entry without its identity (objectGUID, objectSid) is not converted
/// (null): the reader then marks the picture incomplete instead of inventing a value. Never a password: LAPS and BitLocker
/// are only dates and presence.
/// </summary>
public static class AdDirectoryMapper
{
    public static IReadOnlyList<string> OuAttributes { get; } =
    [
        "name", "ou", "distinguishedName", "objectGUID", "objectClass", "description", "managedBy",
        "whenCreated", "whenChanged", "uSNChanged",
    ];

    public static IReadOnlyList<string> UserAttributes { get; } =
    [
        "name", "cn", "sAMAccountName", "userPrincipalName", "displayName", "givenName", "sn", "mail", "description",
        "department", "title", "physicalDeliveryOfficeName", "telephoneNumber", "manager", "employeeID", "distinguishedName",
        "objectGUID", "objectSid", "objectClass", "objectCategory", "userAccountControl", "msDS-User-Account-Control-Computed",
        "lockoutTime", "badPwdCount", "pwdLastSet", "msDS-UserPasswordExpiryTimeComputed", "lastLogonTimestamp",
        "accountExpires", "whenCreated", "whenChanged", "uSNChanged", "memberOf", "primaryGroupID", "adminCount",
    ];

    public static IReadOnlyList<string> ComputerAttributes { get; } =
    [
        "name", "cn", "dNSHostName", "sAMAccountName", "distinguishedName", "objectGUID", "objectSid", "description",
        "location", "managedBy", "operatingSystem", "operatingSystemVersion", "userAccountControl", "lastLogonTimestamp",
        "pwdLastSet", "whenCreated", "whenChanged", "uSNChanged", LapsWindowsExpiration, LapsLegacyExpiration, "memberOf",
        "primaryGroupID",
    ];

    public static IReadOnlyList<string> GroupAttributes { get; } =
    [
        "name", "cn", "sAMAccountName", "distinguishedName", "objectGUID", "objectSid", "groupType", "member", "memberOf",
        "adminCount", "description", "managedBy", "mail", "whenCreated", "whenChanged", "uSNChanged",
    ];

    public static IReadOnlyList<string> ContactAttributes { get; } =
    [
        "name", "cn", "objectGUID", "distinguishedName", "objectClass", "objectCategory", "displayName", "givenName", "sn",
        "mail", "description", "title", "department", "physicalDeliveryOfficeName", "telephoneNumber", "manager",
        "memberOf", "whenCreated", "whenChanged", "uSNChanged",
    ];

    /// <summary>LDAP filters of the kinds of the directory picture.</summary>
    public const string OuFilter = "(objectClass=organizationalUnit)";
    public const string UserFilter = "(&(objectCategory=person)(objectClass=user))";
    public const string ComputerFilter = "(objectCategory=computer)";
    public const string GroupFilter = "(objectCategory=group)";
    public const string ContactFilter = "(objectClass=contact)";

    private const string LapsWindowsExpiration = "msLAPS-PasswordExpirationTime";
    private const string LapsLegacyExpiration = "ms-Mcs-AdmPwdExpirationTime";

    // Primary groups by default (Domain Users, Domain Computers) when the attribute is not readable.
    private const int DomainUsersRid = 513;
    private const int DomainComputersRid = 515;

    public static DirectoryOu? Ou(AdEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (entry.Guid("objectGUID") is not Guid guid)
        {
            return null;
        }
        var dn = entry.DistinguishedName;
        return new DirectoryOu(
            guid,
            dn,
            entry.String("ou") ?? entry.String("name") ?? LeafValue(dn),
            entry.String("description"),
            entry.String("managedBy"),
            entry.Time("whenCreated") ?? DateTimeOffset.MinValue,
            entry.Time("whenChanged") ?? DateTimeOffset.MinValue,
            entry.Long("uSNChanged") ?? 0);
    }

    public static DirectoryContact? Contact(AdEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (entry.Guid("objectGUID") is not Guid guid || guid == Guid.Empty) { return null; }
        return new(guid, entry.DistinguishedName, entry.String("name") ?? entry.String("cn") ?? LeafValue(entry.DistinguishedName),
            entry.String("displayName"), entry.String("givenName"), entry.String("sn"), entry.String("mail"),
            entry.String("description"), entry.String("title"), entry.String("department"), entry.String("physicalDeliveryOfficeName"),
            entry.String("telephoneNumber"), entry.String("manager"), [.. entry.Strings("memberOf")],
            entry.Time("whenCreated") ?? DateTimeOffset.MinValue, entry.Time("whenChanged") ?? DateTimeOffset.MinValue,
            entry.Long("uSNChanged") ?? 0);
    }

    public static DirectoryUser? User(AdEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (entry.Guid("objectGUID") is not Guid guid || entry.Sid("objectSid") is not string sid)
        {
            return null;
        }
        var dn = entry.DistinguishedName;
        return new DirectoryUser(
            guid,
            sid,
            dn,
            entry.String("cn") ?? entry.String("name") ?? LeafValue(dn),
            entry.String("sAMAccountName") ?? "",
            entry.String("userPrincipalName"),
            entry.String("displayName"),
            entry.String("givenName"),
            entry.String("sn"),
            entry.String("mail"),
            entry.String("title"),
            entry.String("department"),
            entry.String("physicalDeliveryOfficeName"),
            entry.String("telephoneNumber"),
            entry.String("manager"),
            entry.String("description"),
            entry.String("employeeID"),
            entry.Int("userAccountControl") ?? 0,
            entry.Int("msDS-User-Account-Control-Computed"),
            entry.Long("lockoutTime"),
            entry.Int("badPwdCount"),
            entry.Long("pwdLastSet"),
            entry.Long("msDS-UserPasswordExpiryTimeComputed"),
            entry.Long("lastLogonTimestamp"),
            entry.Long("accountExpires"),
            entry.Time("whenCreated") ?? DateTimeOffset.MinValue,
            entry.Time("whenChanged") ?? DateTimeOffset.MinValue,
            entry.Long("uSNChanged") ?? 0,
            entry.Int("adminCount"),
            entry.Int("primaryGroupID") ?? DomainUsersRid,
            [.. entry.Strings("memberOf")]);
    }

    public static DirectoryComputer? Computer(AdEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (entry.Guid("objectGUID") is not Guid guid || entry.Sid("objectSid") is not string sid)
        {
            return null;
        }
        var dn = entry.DistinguishedName;
        var name = entry.String("name") ?? entry.String("cn") ?? LeafValue(dn);
        var (laps, expiration) = entry.Has(LapsWindowsExpiration)
            ? (LapsKind.Windows, entry.Long(LapsWindowsExpiration))
            : entry.Has(LapsLegacyExpiration)
                ? (LapsKind.Legacy, entry.Long(LapsLegacyExpiration))
                : (LapsKind.None, (long?)null);
        return new DirectoryComputer(
            guid,
            sid,
            dn,
            name,
            entry.String("dNSHostName"),
            entry.String("sAMAccountName") ?? name + "$",
            entry.String("description"),
            entry.String("location"),
            entry.String("managedBy"),
            entry.String("operatingSystem"),
            entry.String("operatingSystemVersion"),
            entry.Int("userAccountControl") ?? 0,
            entry.Long("lastLogonTimestamp"),
            entry.Long("pwdLastSet"),
            entry.Time("whenCreated") ?? DateTimeOffset.MinValue,
            entry.Time("whenChanged") ?? DateTimeOffset.MinValue,
            entry.Long("uSNChanged") ?? 0,
            laps,
            expiration,
            entry.Int("primaryGroupID") ?? DomainComputersRid,
            [.. entry.Strings("memberOf")]);
    }

    public static DirectoryGroup? Group(AdEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (entry.Guid("objectGUID") is not Guid guid || entry.Sid("objectSid") is not string sid)
        {
            return null;
        }
        var dn = entry.DistinguishedName;
        var name = entry.String("name") ?? entry.String("cn") ?? LeafValue(dn);
        return new DirectoryGroup(
            guid,
            sid,
            dn,
            name,
            entry.String("sAMAccountName") ?? name,
            entry.Int("groupType") ?? 0,
            entry.String("description"),
            entry.String("mail"),
            entry.String("managedBy"),
            entry.Int("adminCount"),
            [.. entry.Strings("member")],
            [.. entry.Strings("memberOf")],
            entry.Time("whenCreated") ?? DateTimeOffset.MinValue,
            entry.Time("whenChanged") ?? DateTimeOffset.MinValue,
            entry.Long("uSNChanged") ?? 0);
    }

    /// <summary>Value of the first relative name of a DN (« PC-01 » for « CN=PC-01,OU=Postes,… »), or the DN itself.</summary>
    internal static string LeafValue(string dn)
    {
        try
        {
            var names = DistinguishedName.Parse(dn);
            return names.IsDefaultOrEmpty ? dn : names[0].Value;
        }
        catch (FormatException)
        {
            // A DN the parser refuses keeps its raw text as name: the operator still sees which object it is.
            return dn;
        }
    }

    /// <summary>Converts the entries of one kind; <paramref name="skipped"/> counts the entries that could not be converted.</summary>
    internal static ImmutableArray<T> Convert<T>(IReadOnlyList<AdEntry> entries, Func<AdEntry, T?> map, out int skipped)
        where T : class
    {
        var result = ImmutableArray.CreateBuilder<T>(entries.Count);
        skipped = 0;
        foreach (var entry in entries)
        {
            if (map(entry) is T item)
            {
                result.Add(item);
            }
            else
            {
                skipped++;
            }
        }
        return result.DrainToImmutable();
    }
}
