using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Only attributes already recorded in the typed local directory. No synthetic AD values.</summary>
internal static class AdFicheProjection
{
    internal static IEnumerable<FicheLocalRead> All(DirectorySnapshot directory)
    {
        foreach (var value in directory.OrganizationalUnits.Cast<object>().Concat(directory.Users).Concat(directory.Computers).Concat(directory.Groups).Concat((directory.Contacts ?? []).Cast<object>()))
        {
            var entry = Entry(value);
            yield return new(entry, directory.ObjectReadAt?.GetValueOrDefault(entry.ObjectGuid, directory.ReadAt) ?? directory.ReadAt);
        }
    }

    internal static FicheEntry Entry(object value)
    {
        var attrs = new Dictionary<string, IEnumerable<string?>>(StringComparer.OrdinalIgnoreCase);
        void Add(string key, object? item)
        {
            if (item is null || item is DateTimeOffset date && date == DateTimeOffset.MinValue) { return; }
            attrs[key] = [item is DateTimeOffset at ? at.UtcDateTime.ToString("yyyyMMddHHmmss.0'Z'", CultureInfo.InvariantCulture) : Convert.ToString(item, CultureInfo.InvariantCulture)];
        }
        void Many(string key, ImmutableArray<string> items) { if (!items.IsDefaultOrEmpty) { attrs[key] = items; } }
        void Dates(DateTimeOffset created, DateTimeOffset changed, long usn) { Add("whenCreated", created); Add("whenChanged", changed); Add("uSNChanged", usn); }
        Guid id; string dn, name; FicheKind kind;
        switch (value)
        {
            case DirectoryUser u:
                (id, dn, name, kind) = (u.ObjectGuid, u.DistinguishedName, u.Cn, FicheKind.User);
                Add("objectSid", u.Sid); Add("sAMAccountName", u.SamAccountName); Add("userPrincipalName", u.UserPrincipalName);
                Add("displayName", u.DisplayName); Add("givenName", u.GivenName); Add("sn", u.Surname); Add("mail", u.Mail);
                Add("title", u.Title); Add("department", u.Department); Add("physicalDeliveryOfficeName", u.Office); Add("telephoneNumber", u.TelephoneNumber);
                Add("manager", u.ManagerDn); Add("description", u.Description); Add("employeeID", u.EmployeeId); Add("userAccountControl", u.UserAccountControl);
                Add("msDS-User-Account-Control-Computed", u.ComputedAccountControl); Add("lockoutTime", u.LockoutTime); Add("badPwdCount", u.BadPasswordCount);
                Add("pwdLastSet", u.PasswordLastSet); Add("msDS-UserPasswordExpiryTimeComputed", u.PasswordExpiryComputed); Add("lastLogonTimestamp", u.LastLogonTimestamp);
                Add("accountExpires", u.AccountExpires); Add("adminCount", u.AdminCount); Add("primaryGroupID", u.PrimaryGroupId); Many("memberOf", u.MemberOf);
                Dates(u.WhenCreated, u.WhenChanged, u.UsnChanged); break;
            case DirectoryComputer c:
                (id, dn, name, kind) = (c.ObjectGuid, c.DistinguishedName, c.Name, FicheKind.Computer);
                Add("objectSid", c.Sid); Add("dNSHostName", c.DnsHostName); Add("sAMAccountName", c.SamAccountName); Add("description", c.Description);
                Add("location", c.Location); Add("managedBy", c.ManagedByDn); Add("operatingSystem", c.OperatingSystem); Add("operatingSystemVersion", c.OperatingSystemVersion);
                Add("userAccountControl", c.UserAccountControl); Add("lastLogonTimestamp", c.LastLogonTimestamp); Add("pwdLastSet", c.PasswordLastSet);
                if (c.Laps != LapsKind.None) { Add(c.Laps == LapsKind.Legacy ? "ms-Mcs-AdmPwdExpirationTime" : "msLAPS-PasswordExpirationTime", c.LapsExpiration); }
                Add("primaryGroupID", c.PrimaryGroupId); Many("memberOf", c.MemberOf); Dates(c.WhenCreated, c.WhenChanged, c.UsnChanged); break;
            case DirectoryGroup g:
                (id, dn, name, kind) = (g.ObjectGuid, g.DistinguishedName, g.Name, FicheKind.Group);
                Add("objectSid", g.Sid); Add("sAMAccountName", g.SamAccountName); Add("groupType", g.GroupType); Add("description", g.Description);
                Add("mail", g.Mail); Add("managedBy", g.ManagedByDn); Add("adminCount", g.AdminCount); Many("member", g.Members); Many("memberOf", g.MemberOf);
                Dates(g.WhenCreated, g.WhenChanged, g.UsnChanged); break;
            case DirectoryContact c:
                (id, dn, name, kind) = (c.ObjectGuid, c.DistinguishedName, c.Name, FicheKind.Contact);
                Add("displayName", c.DisplayName); Add("givenName", c.GivenName); Add("sn", c.Surname); Add("mail", c.Mail); Add("description", c.Description);
                Add("title", c.Title); Add("department", c.Department); Add("physicalDeliveryOfficeName", c.Office); Add("telephoneNumber", c.TelephoneNumber);
                Add("manager", c.ManagerDn); Many("memberOf", c.MemberOf); Dates(c.WhenCreated, c.WhenChanged, c.UsnChanged); break;
            case DirectoryOu o:
                (id, dn, name, kind) = (o.ObjectGuid, o.DistinguishedName, o.Name, o.DistinguishedName.StartsWith("OU=", StringComparison.OrdinalIgnoreCase) ? FicheKind.Ou : FicheKind.Container);
                Add("description", o.Description); Add("managedBy", o.ManagedByDn); Dates(o.WhenCreated, o.WhenChanged, o.UsnChanged); break;
            default: throw new ArgumentException("Type de projection inconnu.", nameof(value));
        }
        Add("objectGUID", id.ToString("D")); Add("distinguishedName", dn); Add("name", name);
        return FicheEntry.Create(kind, id, dn, name, attrs);
    }
}
