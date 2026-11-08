using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdSearchScopeTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static SearchQuery Browse(bool subtree = true, int take = 10) =>
        new(SearchListKind.Browse, SearchText.BrowsePlan(SearchTypeFilter.All), SearchTypeFilter.All,
            Fixtures.Postes, subtree, null, null, new HashSet<string>(), take);

    private static AdEntry Entry(string dn, string name, bool ou = false)
    {
        var attributes = new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [Fixtures.IdOf(dn).ToByteArray()],
            ["objectClass"] = ou ? ["top", "organizationalUnit"] : ["top", "user", "computer"],
            ["name"] = [name], ["sAMAccountName"] = [name + "$"], ["userAccountControl"] = ["4096"],
        };
        if (!ou)
        {
            // A computer's identity requires its binary SID as well as its GUID; OUs have no SID.
            var sid = new SecurityIdentifier(Fixtures.Computer(name).Sid);
            var bytes = new byte[sid.BinaryLength];
            sid.GetBinaryForm(bytes, 0);
            attributes["objectSid"] = [bytes];
        }
        return new(dn, attributes);
    }

    [Test]
    public static async Task Subtree_base_is_valid_but_never_replaces_the_child_continuation_sentinel()
    {
        var ou = Entry(Fixtures.Postes, "Postes", ou: true);
        var first = Entry("CN=POSTE-01," + Fixtures.Postes, "POSTE-01");
        var second = Entry("CN=POSTE-02," + Fixtures.Postes, "POSTE-02");
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = request =>
        {
            if (request.SortAttribute is null) return [];
            Check.Equal(AdSearchScope.Subtree, request.Scope, "sous-arbre explicitement demandé");
            Check.True(request.SizeLimit >= 3, "place pour la base, une ligne et la sentinelle enfant");
            var entries = new[] { ou, first, second }.Take(request.SizeLimit).ToArray();
            foreach (var entry in entries) request.EntryReceived!.Invoke(entry);
            return entries;
        } };
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap);
        var page = await new AdSearchReader(source).FindAsync(Browse(take: 1), None);
        Check.Equal(1, page.Rows.Length, "une ligne demandée");
        Check.Equal("POSTE-01", page.Rows[0].Name, "la base n’est pas un résultat enfant");
        Check.True(page.More, "la seconde ligne prouve la suite");
        Check.Equal("p:POSTE-01", page.LastKey, "curseur porté par le dernier enfant affiché");
        Check.False(page.Interrupted, "réponse LDAP valide terminée");
    }

    [Test]
    public static async Task A_subtree_containing_only_its_base_is_an_empty_complete_child_list()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = request => request.SortAttribute is null ? [] : [Entry(Fixtures.Postes, "Postes", ou: true)],
        };
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap);
        var page = await new AdSearchReader(source).FindAsync(Browse(), None);
        Check.Equal(0, page.Rows.Length, "aucun enfant de l’OU vide");
        Check.False(page.More, "aucune suite inventée");
        Check.False(page.Interrupted, "fin réellement reçue");
    }

    [Test]
    public static async Task One_level_rejects_the_base_and_grandchildren_but_accepts_a_direct_child()
    {
        foreach (var dn in new[] { Fixtures.Postes, "CN=POSTE,OU=Sous," + Fixtures.Postes })
        {
            using var ldap = new AdBoundaryTests.RecordingAdConnection
            {
                SearchAnswer = request => request.SortAttribute is null ? [] : [Entry(dn, "POSTE", ou: dn == Fixtures.Postes)],
            };
            using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap);
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => new AdSearchReader(source).FindAsync(Browse(subtree: false), None), "profondeur OneLevel gardée");
            Check.Equal(DomeniaErrors.ArgumentsInvalid, error.Code, "réponse incohérente refusée");
        }
        using var direct = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = request => request.SortAttribute is null ? [] : [Entry("CN=POSTE," + Fixtures.Postes, "POSTE")],
        };
        using var directSource = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: direct);
        Check.Equal(1, (await new AdSearchReader(directSource).FindAsync(Browse(subtree: false), None)).Rows.Length, "enfant direct accepté");
    }

    [Test]
    public static async Task Subtree_still_rejects_foreign_rows_and_duplicate_base_identities()
    {
        var ou = Entry(Fixtures.Postes, "Postes", ou: true);
        foreach (var entries in new[]
        {
            new[] { ou, Entry("CN=POSTE,OU=Autre," + Fixtures.Root, "POSTE") },
            new[] { ou, ou },
        })
        {
            using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = request => request.SortAttribute is null ? [] : entries };
            using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap);
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => new AdSearchReader(source).FindAsync(Browse(), None), "aucune réponse hors périmètre ou ambiguë");
            Check.Equal(DomeniaErrors.ArgumentsInvalid, error.Code, "garde conservée");
            Check.True(source.CurrentDirectory is null || source.CurrentDirectory.ObjectCount == 0, "aucun résultat publié après refus");
        }
    }

    [Test]
    public static async Task Recent_view_sends_the_supported_object_types_with_its_date_filter()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = request =>
        {
            if (request.SortAttribute is null) return [];
            Check.Contains(SearchText.TypeLdapFilter(SearchTypeFilter.All), request.Filter, "types de la recherche inclus dans le filtre transmis");
            Check.True(request.Filter.StartsWith("(&", StringComparison.Ordinal), "le type et la date sont requis ensemble");
            Check.Contains("(whenChanged>=", request.Filter, "borne temporelle conservée");
            return [Entry("CN=POSTE," + Fixtures.Postes, "POSTE")];
        } };
        var clock = TestClock.Fixed();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", clock, connection: ldap);
        await source.DomainAsync(None);
        using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Annuaire de test", null, "test.local", []), source,
            new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(AdDirectorySource).Assembly]));
        var result = await SearchService.From(context).ViewAsync("recent", null, true, true, 10, None);
        Check.Equal(1, result.Loaded, "vue projetée après filtrage LDAP");
        Check.True(result.Complete, "fin qualifiée dans les types pris en charge");
    }
}
