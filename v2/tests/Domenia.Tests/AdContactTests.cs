using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdContactTests
{
    [Test]
    public static async Task A_contact_without_a_SID_does_not_break_a_mixed_search_or_become_an_account()
    {
        var contact = Entry("Élodie Contact");
        var ou = new AdEntry("OU=Atelier," + Fixtures.Postes, new Dictionary<string, IReadOnlyList<object>>
        { ["objectGUID"] = [Fixtures.IdOf("contact-ou").ToByteArray()], ["name"] = ["Atelier"], ["objectClass"] = ["top", "organizationalUnit"] });
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.SortAttribute is not null ? [ou, contact] : [] };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdSearchReader(source);
        var query = new SearchQuery(SearchListKind.Browse, SearchText.BrowsePlan(SearchTypeFilter.All), SearchTypeFilter.All,
            Fixtures.Postes, true, null, null, new HashSet<string>(), 10);
        var page = await reader.FindAsync(query, CancellationToken.None);
        Check.Equal(2, page.Rows.Length, "les deux types sont conservés");
        var row = page.Rows.Single(r => r.Kind == SearchObjectKind.Contact);
        Check.Equal("elodie@example.net", row.Mail, "courriel du contact");
        Check.Null(row.Login, "aucun compte inventé");
        Check.Equal("contact", row.State.Key, "aucun état actif ou désactivé inventé");
        Check.Null(row.Presence, "aucune présence réseau attribuée au contact");
        var calls = ldap.Calls;
        var local = await reader.CachedAsync(query with { Type = SearchTypeFilter.Contacts, Plan = SearchText.BrowsePlan(SearchTypeFilter.Contacts) }, CancellationToken.None);
        Check.Equal(1, local.Rows.Length, "filtre local propre aux contacts");
        Check.True(await reader.PreviewAsync(Guid.Parse(row.Id), CancellationToken.None) is not null, "aperçu disponible");
        Check.Equal(calls, ldap.Calls, "aucun réseau à l’ouverture de l’aperçu");
        Check.False(AdObjectAccess.Attributes.Any(FicheAttributeRules.IsSensitive), "aucun secret demandé");
    }

    [Test]
    public static async Task Exact_GUID_rereads_preserve_contact_identity_and_do_not_require_a_SID()
    {
        var entry = Entry("Contact");
        var id = entry.Guid("objectGUID")!.Value;
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.Filter.Contains("(objectGUID=", StringComparison.Ordinal) ? [entry] : [] };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var read = await new AdObjectAccess(source).ReadAsync([id], CancellationToken.None);
        Check.Equal(id, read.Contacts!.Value.Single().ObjectGuid, "GUID exact conservé");
        Check.Equal(0, read.Users.Length, "le contact ne gonfle pas les comptes");
        Check.Equal(1, read.ObjectCount, "le contact compte dans la base");
    }

    [Test]
    public static async Task A_contact_limit_or_missing_identity_marks_the_selected_census_incomplete()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.Filter == AdDirectoryMapper.ContactFilter ? [Entry("A"), Entry("B")] : [] };
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", false);
        var read = await AdDirectoryReader.ReadSnapshotAsync(ldap, Fixtures.Domain, scope, 1, TestClock.Fixed(), CancellationToken.None);
        Check.False(read.Complete, "troncature des contacts visible");
        Check.Equal(1, read.Contacts!.Value.Length, "limite de contacts respectée");
        Check.True(ldap.Searches.All(q => q.BaseDn == scope.Dn && q.Scope == AdSearchScope.OneLevel), "aucune extension du périmètre");
        ldap.SearchAnswer = q => q.Filter == AdDirectoryMapper.ContactFilter ? [new AdEntry("CN=Absent," + Fixtures.Postes, new Dictionary<string, IReadOnlyList<object>>())] : [];
        read = await AdDirectoryReader.ReadSnapshotAsync(ldap, Fixtures.Domain, scope, 10, TestClock.Fixed(), CancellationToken.None);
        Check.False(read.Complete, "identité manquante signalée");
        Check.Equal(0, read.ObjectCount, "aucune identité synthétique");
    }

    [Test]
    public static async Task Contact_cache_roundtrip_retains_dates_and_rejects_older_values()
    {
        using var folder = new TemporaryFolder();
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(folder.File("contacts.db"), Fixtures.Root, TestClock.Fixed()));
        var entry = Entry("Élodie Contact");
        var contact = AdDirectoryMapper.Contact(entry)!;
        var first = Fixtures.Snapshot() with { Complete = false, Contacts = ImmutableArray.Create(contact) };
        var newer = first with { ReadAt = first.ReadAt.AddMinutes(1), Contacts = ImmutableArray.Create(contact with { Description = "corrigé" }) };
        await cache.SaveObjectsAsync(newer, "dc.test.local", CancellationToken.None);
        await cache.SaveObjectsAsync(first, "dc.test.local", CancellationToken.None);
        var stored = (await cache.ReadKnownAsync(CancellationToken.None))!;
        Check.Equal("corrigé", stored.Contacts!.Value.Single().Description, "un relevé tardif n’efface pas la correction");
        Check.Equal(newer.ReadAt, stored.ObjectReadAt![contact.ObjectGuid], "date individuelle conservée");
        var candidate = SearchRowFactory.Candidates(stored).Single();
        Check.Null(candidate.Sid, "pas de SID fabriqué au rechargement");
        Check.True(SearchMatcher.Compile(SearchText.Plan("elodie", SearchTypeFilter.Contacts, SearchMatchMode.Prefix), SearchTypeFilter.Contacts)(candidate), "recherche locale avec accents");
        Check.False(SearchMatcher.OfType(candidate, SearchTypeFilter.Users), "aucun compte dans le filtre des contacts");
    }

    private static AdEntry Entry(string name) => new("CN=" + name + "," + Fixtures.Postes,
        new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [Fixtures.IdOf("contact-" + name).ToByteArray()], ["objectClass"] = ["top", "person", "organizationalPerson", "contact"],
            ["name"] = [name], ["displayName"] = [name], ["mail"] = ["elodie@example.net"], ["givenName"] = ["Élodie"],
        });
}
