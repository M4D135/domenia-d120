using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    /// <summary>Only an explicitly restored D1 copy has this marker. Original rows remain the authority until a real AD
    /// read replaces their GUID; no synthetic SID, host name, account flags, domain policy or collection date is asserted.</summary>
    private DirectorySnapshot? ReadLegacyDirectory(SqliteDatabase db, DirectorySnapshot? current, bool allKnown = true)
    {
        if (db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='legacy.directory';") as string != "1") return current;
        if ((long)db.Scalar("SELECT count(*) FROM ad_objects WHERE object_type IN ('Machine','Utilisateur');")! > SyncRowsLimit)
            throw new InvalidDataException("Plus de 300 000 comptes historiques ; lecture locale interrompue sans résultat tronqué.");
        var rows = IndexRows(db, null, legacyOnly: true);
        var users = (current?.Users ?? []).ToBuilder();
        var computers = (current?.Computers ?? []).ToBuilder();
        var dates = (current?.ObjectReadAt ?? ImmutableDictionary<Guid, DateTimeOffset>.Empty).ToBuilder();
        var seen = current is null ? new HashSet<Guid>() : DirectoryIdentities(current).ToHashSet();
        var dns = LegacyRules.DomainOf(DomainDn) ?? throw new InvalidDataException("Domaine historique illisible.");
        var domain = current?.Domain ?? new DomainInfo(dns, "", DomainDn, "", [], new(TimeSpan.Zero, 0, 0, 0, TimeSpan.Zero, TimeSpan.Zero, false), []);
        foreach (var row in rows)
        {
            if (!seen.Add(row.ObjectGuid)) throw new InvalidDataException("Identité historique ambiguë ; aucune projection inventée.");
            if (!allKnown && current?.Coverage is { } scope && !InReadScope(scope, row.Dn)) continue;
            var observed = row.ObservedAt <= clock.GetUtcNow().AddMinutes(2) ? row.ObservedAt : DateTimeOffset.MinValue;
            dates.Add(row.ObjectGuid, observed);
            var attributes = ImmutableArray.CreateBuilder<string>();
            attributes.Add("objectGUID"); attributes.Add("distinguishedName"); attributes.Add("objectClass"); attributes.Add("name");
            void Known(string name, object? value) { if (value is not null) attributes.Add(name); }
            Known("sAMAccountName", row.Login); Known("description", row.Description);
            Known("whenChanged", row.WhenChanged); Known("lastLogonTimestamp", row.LastLogon);
            // D1 preserves only the enabled bit, not the complete UAC. Keep that display state without claiming an LDAP UAC read.
            var uac = row.Enabled ? 0 : 2;
            var changed = row.WhenChanged ?? DateTimeOffset.MinValue;
            long? FileTime(DateTimeOffset? date) => date is { Year: >= 1601 } value ? value.UtcDateTime.ToFileTimeUtc() : null;
            if (row.Type == IndexObjectType.Computer)
            {
                computers.Add(new DirectoryComputer(row.ObjectGuid, "", row.Dn, row.Name, null, row.Login ?? "", row.Description,
                    null, null, null, null, uac, FileTime(row.LastLogon), null, DateTimeOffset.MinValue, changed, row.Usn,
                    row.Laps, FileTime(row.LapsExpiration), 0, []) { ObservedAttributes = attributes.ToImmutable(), LegacyIndexOnly = true });
            }
            else
            {
                Known("userPrincipalName", row.Upn); Known("displayName", row.DisplayName);
                users.Add(new DirectoryUser(ObjectGuid: row.ObjectGuid, Sid: "", DistinguishedName: row.Dn, Cn: row.Name,
                    SamAccountName: row.Login ?? "", UserPrincipalName: row.Upn, DisplayName: row.DisplayName,
                    GivenName: null, Surname: null, Mail: null, Title: null, Department: null, Office: null, TelephoneNumber: null,
                    ManagerDn: null, Description: row.Description, EmployeeId: null, UserAccountControl: uac,
                    ComputedAccountControl: null, LockoutTime: null, BadPasswordCount: null, PasswordLastSet: null,
                    PasswordExpiryComputed: null, LastLogonTimestamp: FileTime(row.LastLogon), AccountExpires: null,
                    WhenCreated: DateTimeOffset.MinValue, WhenChanged: changed, UsnChanged: row.Usn, AdminCount: null,
                    PrimaryGroupId: 0, MemberOf: []) { ObservedAttributes = attributes.ToImmutable(), LegacyIndexOnly = true });
            }
        }
        var at = current?.ReadAt ?? (dates.Count == 0 ? DateTimeOffset.MinValue : dates.Values.Max());
        return new(domain, at, false, current?.OrganizationalUnits ?? [], users.ToImmutable(), computers.ToImmutable(), current?.Groups ?? [])
        { Coverage = current?.Coverage ?? new(DomainDn, dns, true), ObjectReadAt = dates.ToImmutable(), Contacts = current?.Contacts,
            ReaderLogin = current?.ReaderLogin };
    }
}
