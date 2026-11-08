using System.Security.Cryptography;
using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdRelationComparisonTests
{
    private static string Dn(string name) => "CN=" + name + "," + Fixtures.People;
    private static AdEntry Edit(AdEntry entry, params (string Name, IReadOnlyList<object>? Values)[] changes)
    {
        var values = entry.AttributeNames.ToDictionary(n => n, entry.Raw, StringComparer.OrdinalIgnoreCase);
        foreach (var change in changes) { if (change.Values is null) { values.Remove(change.Name); } else { values[change.Name] = change.Values; } }
        return new(entry.DistinguishedName, values);
    }
    private static AdEntry User(string name, params string[] parents) => Edit(AdRelationDirectoryTests.User(Fixtures.User(name)),
        ("memberOf", parents.Select(p => (object)Dn(p)).ToArray()), ("primaryGroupID", [513]), ("uSNChanged", [42L]), ("userPrincipalName", [name + ".upn@test.local"]), ("company", ["Entreprise " + name]));
    private static AdEntry Group(string name, int rid, params string[] parents)
    {
        var sid = new SecurityIdentifier(Fixtures.Domain.DomainSid + "-" + rid); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
        return new(Dn(name), new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [Fixtures.IdOf("group-" + name).ToByteArray()], ["objectSid"] = [bytes], ["objectClass"] = ["top", "group"],
            ["name"] = [name], ["sAMAccountName"] = [name], ["groupType"] = [-2147483646], ["uSNChanged"] = [1L],
            ["memberOf"] = parents.Select(p => (object)Dn(p)).ToArray(),
        });
    }
    private static Func<AdSearchRequest, IReadOnlyList<AdEntry>> Answer(AdEntry alice, AdEntry bob, params AdEntry[] groups) => q =>
    {
        if (q.Scope == AdSearchScope.Base)
        {
            if (DistinguishedName.AreEqual(q.BaseDn, alice.DistinguishedName)) { return [alice]; }
            if (DistinguishedName.AreEqual(q.BaseDn, bob.DistinguishedName)) { return [bob]; }
        }
        if (q.Filter.Contains("(objectCategory=person)", StringComparison.Ordinal))
        { return q.Filter.Contains("sAMAccountName=bob", StringComparison.Ordinal) || q.Filter.Contains("userPrincipalName=bob.upn@test.local", StringComparison.Ordinal) ? [bob] : []; }
        if (q.Filter.Contains("(objectSid=", StringComparison.Ordinal))
        { return groups.Where(g => q.Filter.Contains("(objectSid=" + g.Sid("objectSid") + ")", StringComparison.Ordinal)).ToArray(); }
        return groups.Where(g => q.Filter.Contains("(distinguishedName=" + SearchText.LdapLiteral(g.DistinguishedName) + ")", StringComparison.Ordinal)).ToArray();
    };

    [Test]
    public static async Task Native_comparison_reads_nested_and_primary_groups_company_and_distinct_same_name_managers_without_saving()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var alice = Edit(User("alice", "A"), ("manager", ["CN=Chef,OU=Un," + Fixtures.Root]));
        var bob = Edit(User("bob", "B"), ("manager", ["CN=Chef,OU=Deux," + Fixtures.Root]));
        ldap.SearchAnswer = Answer(alice, bob, Group("A", 1101, "Priv"), Group("B", 1102, "Priv"), Group("Priv", 512), Group("Principal", 513));
        var before = SHA256.HashData(File.ReadAllBytes(db.Path));
        var compared = await new AdRelationsReader(source).CompareAsync(alice.DistinguishedName, "bob", CancellationToken.None);
        Check.Equal(1, compared.Counts.OnlyLeft, "A propre à alice"); Check.Equal(1, compared.Counts.OnlyRight, "B propre à bob"); Check.Equal(2, compared.Counts.Common, "parent et groupe principal communs");
        Check.True(compared.Groups.Single(g => g.Name == "Priv").Privileged, "RID privilégié reconnu"); Check.True(compared.Groups.Single(g => g.Name == "Principal").Primary, "groupe principal réel");
        Check.False(compared.Attributes.Single(a => a.Attribute == "company").Same, "sociétés réelles comparées");
        var manager = compared.Attributes.Single(a => a.Attribute == "manager"); Check.False(manager.Same, "homonymes de responsables distincts"); Check.False(manager.Left == manager.Right, "DN départagent les libellés identiques");
        Check.True(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(db.Path))), "aucune projection partielle écrite dans la base");
        Check.True(ldap.Searches.All(q => !q.Attributes.Contains("member")), "aucun membre de groupe parcouru"); Check.Contains("TEST\\operator", compared.Ticket, "compte de lecture dans le ticket");
    }

    [Test]
    public static async Task Native_comparison_resolves_the_exact_UPN_and_refuses_foreign_qualified_accounts_before_contact()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var reader = new AdRelationsReader(source); var alice = User("alice"); var bob = User("bob");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CompareAsync(alice.DistinguishedName, @"FOREIGN\bob", CancellationToken.None), "domaine étranger");
        Check.Equal(0, ldap.Calls, "aucun contact avant refus");
        ldap.SearchAnswer = Answer(alice, bob, Group("Principal", 513));
        var compared = await reader.CompareAsync(alice.DistinguishedName, "bob.upn@test.local", CancellationToken.None);
        Check.Equal("bob", compared.Right.Login, "UPN exact dont le préfixe diffère du SAM");
        Check.True(ldap.Searches.Any(q => q.Filter.Contains("(userPrincipalName=bob.upn@test.local)", StringComparison.Ordinal) && q.SizeLimit == 2), "résolution exacte et bornée");
    }

    [Test]
    public static async Task Native_comparison_does_not_assume_domain_users_when_primaryGroupID_was_not_read_and_bounds_large_paths()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var names = Enumerable.Range(1, 2001).Select(i => "G" + i).ToArray();
        var alice = Edit(User("alice", names), ("primaryGroupID", null)); var bob = Edit(User("bob"), ("primaryGroupID", null));
        ldap.SearchAnswer = Answer(alice, bob, names.Select((n, i) => Group(n, 2000 + i)).ToArray());
        var compared = await new AdRelationsReader(source).CompareAsync(alice.DistinguishedName, bob.DistinguishedName, CancellationToken.None);
        Check.Equal(2000, compared.Groups.Length, "2 000 groupes maximum par compte"); Check.False(compared.Groups.Any(g => g.Primary), "aucun RID 513 inventé");
        Check.True(compared.Limits.Any(l => l.Contains("primaryGroupID", StringComparison.Ordinal)), "attribut manquant annoncé"); Check.Contains("partielle", compared.Summary, "borne visible");
        Check.False(ldap.Searches.Any(q => q.Filter.Contains("(objectSid=", StringComparison.Ordinal)), "pas de recherche d’un groupe principal supposé");
        var deep = Enumerable.Range(1, 20).Select(i => Group("N" + i, 5000 + i, "N" + (i == 20 ? 1 : i + 1))).ToArray();
        ldap.SearchAnswer = Answer(Edit(User("alice", "N1"), ("primaryGroupID", null)), bob, deep);
        var bounded = await new AdRelationsReader(source).CompareAsync(alice.DistinguishedName, bob.DistinguishedName, CancellationToken.None);
        Check.Equal(16, bounded.Groups.Length, "profondeur arrêtée avant le dix-septième groupe");
        Check.True(bounded.Limits.Any(l => l.Contains("16 niveaux", StringComparison.Ordinal)), "profondeur partielle annoncée");
        var longDns = Enumerable.Range(1, 10).Select(i => (object)("CN=G" + i + "," + string.Concat(Enumerable.Repeat("OU=" + new string('界', 50) + ",", 50)) + Fixtures.Root)).ToArray();
        var longNames = Edit(User("alice"), ("primaryGroupID", null), ("memberOf", longDns)); var calls = ldap.Searches.Count;
        ldap.SearchAnswer = Answer(longNames, bob);
        await new AdRelationsReader(source).CompareAsync(alice.DistinguishedName, bob.DistinguishedName, CancellationToken.None);
        var filters = ldap.Searches.Skip(calls).Where(q => q.Scope == AdSearchScope.Subtree).ToArray();
        Check.True(filters.Length > 1, "longs DN répartis entre requêtes");
        Check.True(filters.All(q => System.Text.Encoding.UTF8.GetByteCount(q.Filter) <= 32_768), "taille UTF-8 bornée malgré Unicode et échappements");
    }

    [Test]
    public static async Task Different_versions_of_a_shared_group_are_not_merged_between_the_two_account_reads()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var alice = User("alice", "Commun"); var bob = User("bob", "Commun"); var group = Group("Commun", 1200); var sharedReads = 0;
        var answer = Answer(alice, bob, group, Group("Principal", 513));
        ldap.SearchAnswer = q =>
        {
            var rows = answer(q);
            if (rows.Any(r => r.DistinguishedName == group.DistinguishedName) && ++sharedReads > 1)
            { return rows.Select(r => r.DistinguishedName == group.DistinguishedName ? Edit(r, ("uSNChanged", [2L]), ("name", ["Commun modifié"])) : r).ToArray(); }
            return rows;
        };
        await Check.ThrowsAsync<DomeniaOperationException>(() => new AdRelationsReader(source).CompareAsync(alice.DistinguishedName, bob.DistinguishedName, CancellationToken.None), "versions communes incohérentes");
        var single = User("alice"); var phase = 0; var sameAccount = Answer(single, single, Group("Principal", 513));
        ldap.SearchAnswer = q =>
        {
            if (q.BaseDn == single.DistinguishedName)
            {
                if (q.Attributes.Contains("company")) { phase++; }
                return [phase > 1 ? Edit(single, ("uSNChanged", [43L]), ("company", ["Nouvelle société"])) : single];
            }
            return sameAccount(q);
        };
        await Check.ThrowsAsync<DomeniaOperationException>(() => new AdRelationsReader(source).CompareAsync(single.DistinguishedName, single.DistinguishedName, CancellationToken.None), "deux versions du même compte non comparées comme deux personnes");
    }

    [Test]
    public static async Task Ranged_memberships_are_continued_with_same_GUID_and_version_and_a_changed_version_refuses_the_comparison()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var alice = Edit(User("alice"), ("memberOf", null), ("memberOf;range=0-0", [Dn("A")])); var bob = User("bob");
        var answer = Answer(alice, bob, Group("A", 1100), Group("B", 1101), Group("Principal", 513)); var changed = false;
        ldap.SearchAnswer = q => q.Attributes.Contains("memberOf;range=1-1999")
            ? [Edit(alice, ("memberOf;range=0-0", null), ("memberOf;range=1-*", [Dn("B")]), ("uSNChanged", [changed ? 43L : 42L]))] : answer(q);
        var reader = new AdRelationsReader(source); var compared = await reader.CompareAsync(alice.DistinguishedName, bob.DistinguishedName, CancellationToken.None);
        Check.True(compared.Groups.Any(g => g.Name == "A") && compared.Groups.Any(g => g.Name == "B"), "deux plages réunies");
        changed = true;
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CompareAsync(alice.DistinguishedName, bob.DistinguishedName, CancellationToken.None), "version changée entre plages");
    }

    [Test]
    public static async Task Group_timeouts_are_explicitly_partial_and_authentication_refusals_stop_before_the_second_account()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var alice = User("alice", "A"); var bob = User("bob", "B"); var answer = Answer(alice, bob, Group("Principal", 513));
        ldap.SearchAnswer = q => q.Filter.Contains("(distinguishedName=", StringComparison.Ordinal) ? throw new DomeniaOperationException(AdErrors.Timeout, "Délai") : answer(q);
        var reader = new AdRelationsReader(source); var partial = await reader.CompareAsync(alice.DistinguishedName, bob.DistinguishedName, CancellationToken.None);
        Check.Contains("partielle", partial.Summary, "aucune fausse comparaison complète vide"); Check.Contains("Limite", partial.Ticket, "limites exportées avec le résultat");
        var before = ldap.Searches.Count;
        ldap.SearchAnswer = q => q.Filter.Contains("(objectCategory=group)", StringComparison.Ordinal) ? throw new DomeniaOperationException(AdErrors.AccessDenied, "Refus") : answer(q);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CompareAsync(alice.DistinguishedName, bob.DistinguishedName, CancellationToken.None), "refus propagé");
        Check.False(ldap.Searches.Skip(before).Any(q => q.BaseDn == bob.DistinguishedName), "second compte non interrogé après refus");
    }
}
