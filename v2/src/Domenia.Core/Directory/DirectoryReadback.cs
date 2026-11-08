using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Only the identities of this acknowledged pass can become its published census. Retained absences are not
/// counted, and a newer/tombstoned/moved object refuses the publication instead of relabelling old LDAP data as saved.</summary>
public static class DirectoryReadback
{
    public static DirectorySnapshot Retained(DirectorySnapshot stored, ScopeSelection scope, DateTimeOffset attemptAt)
    {
        bool Within(string dn) => ScopeRules.Contains(scope, dn) || scope.Subtree && DistinguishedName.AreEqual(scope.Dn, dn);
        var ous = stored.OrganizationalUnits.Where(x => Within(x.DistinguishedName)).ToImmutableArray();
        var users = stored.Users.Where(x => Within(x.DistinguishedName)).ToImmutableArray();
        var computers = stored.Computers.Where(x => Within(x.DistinguishedName)).ToImmutableArray();
        var groups = stored.Groups.Where(x => Within(x.DistinguishedName)).ToImmutableArray();
        var contacts = (stored.Contacts ?? []).Where(x => Within(x.DistinguishedName)).ToImmutableArray();
        var ids = ous.Select(x => x.ObjectGuid).Concat(users.Select(x => x.ObjectGuid)).Concat(computers.Select(x => x.ObjectGuid))
            .Concat(groups.Select(x => x.ObjectGuid)).Concat(contacts.Select(x => x.ObjectGuid));
        var dates = ids.ToImmutableDictionary(id => id, id => stored.ObjectReadAt?.GetValueOrDefault(id) ?? stored.ReadAt);
        return new(stored.Domain, attemptAt, false, ous, users, computers, groups)
        { Contacts = stored.Contacts is null ? null : contacts, Coverage = scope, ObjectReadAt = dates, ReaderLogin = stored.ReaderLogin };
    }

    public static DirectorySnapshot Select(DirectorySnapshot submitted, DirectorySnapshot? stored)
    {
        if (stored is null || !DistinguishedName.AreEqual(submitted.Domain.RootDn, stored.Domain.RootDn)
            || submitted.Domain.DomainSid != stored.Domain.DomainSid)
            throw new InvalidDataException("Projection durable du relevé absente ou d’un autre domaine.");
        var dates = ImmutableDictionary.CreateBuilder<Guid, DateTimeOffset>();
        ImmutableArray<T> Select<T>(ImmutableArray<T> wanted, ImmutableArray<T> actual, Func<T, Guid> id, Func<T, string> dn)
        {
            var identities = wanted.ToDictionary(id);
            var result = ImmutableArray.CreateBuilder<T>(identities.Count);
            foreach (var item in actual)
            {
                var guid = id(item);
                if (!identities.TryGetValue(guid, out var original)) continue;
                var observed = stored.ObjectReadAt?.GetValueOrDefault(guid, DateTimeOffset.MinValue) ?? stored.ReadAt;
                if (!DistinguishedName.AreEqual(dn(item), dn(original)) || observed != submitted.ReadAt || dates.ContainsKey(guid))
                    throw new InvalidDataException("Le relevé durable a changé avant sa publication ; relisez le périmètre.");
                dates.Add(guid, observed); result.Add(item);
            }
            if (result.Count != identities.Count) throw new InvalidDataException("Relecture durable incomplète ; aucun relevé neuf n’est publié.");
            return result.ToImmutable();
        }
        var ous = Select(submitted.OrganizationalUnits, stored.OrganizationalUnits, x => x.ObjectGuid, x => x.DistinguishedName);
        var users = Select(submitted.Users, stored.Users, x => x.ObjectGuid, x => x.DistinguishedName);
        var computers = Select(submitted.Computers, stored.Computers, x => x.ObjectGuid, x => x.DistinguishedName);
        var groups = Select(submitted.Groups, stored.Groups, x => x.ObjectGuid, x => x.DistinguishedName);
        var contacts = Select(submitted.Contacts ?? [], stored.Contacts ?? [], x => x.ObjectGuid, x => x.DistinguishedName);
        return new(submitted.Domain, submitted.ReadAt, submitted.Complete, ous, users, computers, groups)
        { Contacts = submitted.Contacts is null ? null : contacts, Coverage = submitted.Coverage, ObjectReadAt = dates.ToImmutable(), ReaderLogin = submitted.ReaderLogin };
    }
}
