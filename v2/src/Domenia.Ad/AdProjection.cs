using System.Collections.Immutable;

namespace Domenia.Ad;

/// <summary>What a read asks the directory for (Domenia 1 Get-DomeniaProjection): the attributes follow the purpose.</summary>
public enum AdProjectionPurpose
{
    Identity,
    List,
    Groups,
    Security,
    Presence,
}

/// <summary>
/// The named projections of a read and their minimality test (TRV-136, Domenia 1 Get-DomeniaProjection and
/// Test-DomeniaProjectionMinimal). No projection is ever empty, an empty projection being refused by the controller
/// (<see cref="AdConnection.ValidateReadRequest"/>), and a projection that asks a heavy attribute is named instead of being
/// sent silently: member, memberOf, nTSecurityDescriptor, tokenGroups, photos, replication metadata, certificates and « * ».
/// Their cost is the size of the values, not the number of objects: groups and security ask them on purpose, a list never
/// should. Pure.
/// </summary>
public static class AdProjection
{
    /// <summary>The attributes no projection asks by default, whatever the case or a range hint on them.</summary>
    public static ImmutableArray<string> HeavyAttributes { get; } =
    [
        "member", "memberOf", "nTSecurityDescriptor", "tokenGroups", "thumbnailPhoto", "thumbnailLogo", "photo",
        "msDS-ReplAttributeMetaData", "msDS-ReplValueMetaData", "replPropertyMetaData",
        "userCertificate", "cACertificate", "crossCertificatePair", "*",
    ];

    /// <summary>Who the object is: enough to name it and to find it again, nothing more.</summary>
    public static ImmutableArray<string> Identity { get; } = ["distinguishedName", "objectGUID", "objectSid", "name", "objectClass"];

    /// <summary>The columns of a list: nineteen attributes, uSNChanged among them, no member, no photo, no descriptor.</summary>
    public static ImmutableArray<string> List { get; } =
    [
        "name", "cn", "sAMAccountName", "userPrincipalName", "displayName", "mail", "description", "distinguishedName",
        "objectGUID", "objectSid", "objectClass", "objectCategory", "userAccountControl", "operatingSystem",
        "operatingSystemVersion", "whenCreated", "whenChanged", "uSNChanged", "primaryGroupID",
    ];

    /// <summary>Who belongs to a group: the membership is the purpose, so the two heavy lists are asked here.</summary>
    public static ImmutableArray<string> Groups { get; } = [.. Identity, "cn", "sAMAccountName", "groupType", "adminCount", "member", "memberOf"];

    /// <summary>Who may do what and with which effective groups: the descriptor and tokenGroups are the purpose.</summary>
    public static ImmutableArray<string> Security { get; } = [.. Identity, "userAccountControl", "adminCount", "nTSecurityDescriptor", "tokenGroups"];

    /// <summary>What the presence and the last contact of a workstation need, without any membership nor descriptor.</summary>
    public static ImmutableArray<string> Presence { get; } =
    [
        "distinguishedName", "objectGUID", "name", "dNSHostName", "operatingSystem", "operatingSystemVersion",
        "userAccountControl", "lastLogonTimestamp", "whenCreated", "whenChanged", "uSNChanged",
    ];

    // Live directory-index projections compose the named purposes. The exclusions keep the exact old
    // per-kind attribute sets: this does not silently remove membership or request extra sensitive fields.
    public static ImmutableArray<string> DirectoryOus { get; } = Compose(Identity,
        ["ou", "description", "managedBy", "whenCreated", "whenChanged", "uSNChanged"], ["objectSid"]);

    public static ImmutableArray<string> DirectoryUsers { get; } = Compose(List,
        ["givenName", "sn", "department", "title", "physicalDeliveryOfficeName", "telephoneNumber", "manager", "employeeID",
         "msDS-User-Account-Control-Computed", "lockoutTime", "badPwdCount", "pwdLastSet", "msDS-UserPasswordExpiryTimeComputed",
         "lastLogonTimestamp", "accountExpires", "memberOf", "adminCount"], ["operatingSystem", "operatingSystemVersion"]);

    public static ImmutableArray<string> DirectoryComputers { get; } = Compose(Presence,
        ["cn", "sAMAccountName", "objectSid", "description", "location", "managedBy", "pwdLastSet",
         "msLAPS-PasswordExpirationTime", "ms-Mcs-AdmPwdExpirationTime", "memberOf", "primaryGroupID"]);

    public static ImmutableArray<string> DirectoryGroups { get; } = Compose(Groups,
        ["description", "managedBy", "mail", "whenCreated", "whenChanged", "uSNChanged"], ["objectClass"]);

    public static ImmutableArray<string> DirectoryContacts { get; } = Compose(List,
        ["givenName", "sn", "title", "department", "physicalDeliveryOfficeName", "telephoneNumber", "manager", "memberOf"],
        ["sAMAccountName", "userPrincipalName", "objectSid", "userAccountControl", "operatingSystem", "operatingSystemVersion", "primaryGroupID"]);

    private static ImmutableArray<string> Compose(ImmutableArray<string> basis, ImmutableArray<string> extra, ImmutableArray<string> excluded = default) =>
        [.. basis.Where(name => excluded.IsDefaultOrEmpty || !excluded.Contains(name, StringComparer.OrdinalIgnoreCase))
            .Concat(extra).Distinct(StringComparer.OrdinalIgnoreCase)];

    /// <summary>The attributes of a purpose; never empty, whatever the purpose.</summary>
    public static ImmutableArray<string> Attributes(AdProjectionPurpose purpose) => purpose switch
    {
        AdProjectionPurpose.Identity => Identity,
        AdProjectionPurpose.List => List,
        AdProjectionPurpose.Groups => Groups,
        AdProjectionPurpose.Security => Security,
        AdProjectionPurpose.Presence => Presence,
        _ => throw new ArgumentOutOfRangeException(nameof(purpose)),
    };

    /// <summary>The heavy attributes a projection asks, in the order asked, once each, whatever the case or a range hint.</summary>
    public static ImmutableArray<string> Heavy(IReadOnlyList<string> attributes)
    {
        ArgumentNullException.ThrowIfNull(attributes);
        var heavy = ImmutableArray.CreateBuilder<string>();
        foreach (var name in attributes)
        {
            var plain = AdAttributeRange.TryParse(name, out var range) ? range!.Attribute : name;
            if (HeavyAttributes.Contains(plain, StringComparer.OrdinalIgnoreCase) && !heavy.Contains(plain, StringComparer.OrdinalIgnoreCase))
            {
                heavy.Add(plain);
            }
        }
        return heavy.ToImmutable();
    }

    /// <summary>True when the projection asks nothing heavy and is not empty; a minimal projection is what a list must send.</summary>
    public static bool IsMinimal(IReadOnlyList<string> attributes) => attributes.Count > 0 && Heavy(attributes).IsEmpty;

    /// <summary>Why a projection is not minimal, naming the heavy attributes; null when it is minimal.</summary>
    public static string? NonMinimalReason(IReadOnlyList<string> attributes)
    {
        ArgumentNullException.ThrowIfNull(attributes);
        if (attributes.Count == 0)
        {
            return "projection vide : la lecture serait refusée par le contrôleur";
        }
        var heavy = Heavy(attributes);
        return heavy.IsEmpty ? null : "attributs lourds demandés : " + string.Join(", ", heavy);
    }
}
