using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdPageBufferTests
{
    private static AdSearchRequest Request(int limit = 0, bool retained = true) => new(Fixtures.Postes, "(objectClass=*)", AdSearchScope.Subtree, ["objectGUID", "name"])
    { SizeLimit = limit, RetainEntries = retained, PageReceived = retained ? null : (_, _) => Task.CompletedTask };
    private static AdEntry Entry(int n, string? dn = null, string? description = null) => new(dn ?? "CN=PC" + n + "," + Fixtures.Postes,
        new Dictionary<string, IReadOnlyList<object>> { ["objectGUID"] = [Fixtures.IdOf("buffer" + n).ToByteArray()], ["name"] = ["PC" + n], ["description"] = description is null ? [] : [description] });

    [Test]
    public static void Retained_searches_fail_explicitly_at_the_default_bound_without_dropping_previously_accepted_entries()
    {
        var buffer = new AdPageBuffer(Request());
        for (var i = 0; i < 2000; i++) { if (i % 500 == 0) buffer.BeginPage(); buffer.Add(Entry(i)); }
        buffer.BeginPage();
        var error = Check.Throws<DomeniaOperationException>(() => buffer.Add(Entry(2000)), "capacité sans réussite vide");
        Check.Equal("ad.bufferLimit", error.Code, "échec de lecture explicite");
        Check.Equal(2000, buffer.Accepted, "lignes déjà acceptées conservées");
        Check.Equal(2000, buffer.Retained.Count, "aucune éviction silencieuse");
        Check.Equal(1, buffer.Refused, "refus réel compté");
        Check.Contains("Aucune fin complète", error.Message, "aucune absence inventée");
    }

    [Test]
    public static void Explicit_streaming_census_accepts_one_hundred_thousand_rows_without_a_second_full_result_or_mutating_acknowledged_pages()
    {
        var buffer = new AdPageBuffer(Request(100001, retained: false));
        IReadOnlyList<AdEntry>? first = null;
        for (var page = 0; page < 200; page++)
        {
            buffer.BeginPage();
            for (var i = 0; i < 500; i++) buffer.Add(Entry(page * 500 + i));
            Check.Equal(500, buffer.Page.Count, "une seule page courante");
            first ??= buffer.Page;
            Check.Equal(0, buffer.Retained.Count, "aucune copie complète de la collecte paginée");
        }
        Check.Equal(100000, buffer.Accepted, "plafond demandé conservé, pas de limite2000 sur la collecte");
        var acknowledged = first ?? throw new TestFailureException("première page réellement reçue");
        Check.Equal("CN=PC0," + Fixtures.Postes, acknowledged[0].DistinguishedName, "page acquittée jamais recyclée/mutée");
        Check.Equal(500, acknowledged.Count, "page précédente toujours cohérente pour son propriétaire");
    }

    [Test]
    public static void Duplicates_malformed_identities_and_oversized_pages_are_refused_without_arbitrary_selection()
    {
        foreach (var duplicate in new[] { Entry(0, "CN=Other," + Fixtures.Postes), Entry(1, "cn=pc0," + Fixtures.Postes.ToLowerInvariant()) })
        {
            var buffer = new AdPageBuffer(Request()); buffer.BeginPage(); buffer.Add(Entry(0)); buffer.BeginPage();
            Check.Throws<DomeniaOperationException>(() => buffer.Add(duplicate), "doublon de GUID ou de DN sur une autre page");
            Check.Equal(1, buffer.Accepted, "pas de doublon accepté"); Check.Equal(1, buffer.Duplicates, "doublon compté");
        }
        var invalid = new AdPageBuffer(Request()); invalid.BeginPage();
        foreach (var dn in new[] { "bad-dn", "", "CN=Wrong," })
            Check.Equal("ad.bufferLimit", Check.Throws<DomeniaOperationException>(() => invalid.Add(Entry(2, dn)), "identité refusée").Code, "erreur bornée");
        var bytes = new AdPageBuffer(Request()); bytes.BeginPage();
        Check.Throws<DomeniaOperationException>(() => bytes.Add(Entry(0, description: new string('é', 8 * 1024 * 1024))), "limite en octets UTF8");
        Check.Equal(0, bytes.Accepted, "aucune entrée surdimensionnée livrée");
        var page = new AdPageBuffer(Request() with { PageSize = 2 }); page.BeginPage(); page.Add(Entry(0)); page.Add(Entry(1));
        Check.Throws<DomeniaOperationException>(() => page.Add(Entry(2)), "page plus grande que celle demandée");
    }

    [Test]
    public static void Schema_rows_need_no_GUID_and_only_an_explicit_RootDSE_base_search_accepts_the_empty_DN()
    {
        var schema = new AdPageBuffer(Request()); schema.BeginPage();
        schema.Add(new("CN=Test,CN=Schema,CN=Configuration," + Fixtures.Root, new Dictionary<string, IReadOnlyList<object>> { ["lDAPDisplayName"] = ["test"] }));
        Check.Equal(1, schema.Accepted, "schéma sans objectGUID demandé conservé");
        var root = new AdPageBuffer(new("", "(objectClass=*)", AdSearchScope.Base, ["defaultNamingContext"]) { SizeLimit = 1 });
        root.BeginPage(); root.Add(new("", new Dictionary<string, IReadOnlyList<object>> { ["defaultNamingContext"] = [Fixtures.Root] }));
        Check.Equal(1, root.Accepted, "RootDSE explicite compatible");
        Check.Throws<DomeniaOperationException>(() => new AdPageBuffer(Request(AdPageBuffer.MaximumRows + 1)), "plafond explicite fermé");
    }
}
