using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdObjectAccessTests
{
    [Test]
    public static async Task Exact_identity_reads_are_batched_and_do_not_browse_the_domain()
    {
        var ids = Enumerable.Range(0, 83).Select(i => Fixtures.IdOf("object-" + i.ToString(System.Globalization.CultureInfo.InvariantCulture))).ToArray();
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var snapshot = await new AdObjectAccess(source).ReadAsync(ids, CancellationToken.None);
        var reads = ldap.Searches.Where(q => q.Filter.StartsWith("(|(objectGUID=", StringComparison.Ordinal)).ToArray();
        Check.Equal(3, reads.Length, "paquets de quarante identités");
        Check.Equal(41, reads[0].SizeLimit, "borne et sentinelle");
        Check.Equal(4, reads[2].SizeLimit, "dernier paquet précis");
        Check.True(reads.All(q => q.PageSize == 40 && q.Timeout == TimeSpan.FromSeconds(30)), "budgets explicites");
        Check.True(ids.All(id => reads.Any(q => q.Filter.Contains(AdObjectAccess.GuidFilter(id), StringComparison.Ordinal))), "toutes les identités exactes");
        Check.False(snapshot.Complete, "sélection distincte d’un recensement");
    }

    [Test]
    public static async Task Invalid_identity_batches_are_refused_before_connection()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdObjectAccess(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadAsync([Guid.Empty], CancellationToken.None), "GUID vide");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadAsync(Enumerable.Repeat(Fixtures.IdOf("one"), 501).ToArray(), CancellationToken.None), "volume hors borne");
        Check.Equal(0, ldap.Calls, "aucune recherche globale de repli");
    }

    [Test]
    public static async Task An_unrequested_identity_in_the_response_is_never_published()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = q => q.Filter.StartsWith("(|(objectGUID=", StringComparison.Ordinal) ? [Computer("other")] : [],
        };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        await Check.ThrowsAsync<DomeniaOperationException>(() => new AdObjectAccess(source).ReadAsync([Fixtures.IdOf("wanted")], CancellationToken.None), "identité différente du lot demandé");
    }

    [Test]
    public static void Object_projection_rejects_foreign_duplicate_and_missing_SID_entries()
    {
        var entry = Computer("PC1");
        var projected = AdObjectAccess.Project([entry], Fixtures.Domain, Fixtures.Now);
        Check.Equal(1, projected.Computers.Length, "ordinateur reconnu avant sa classe user héritée");
        Check.False(projected.Complete, "projection partielle");
        foreach (var entries in new IReadOnlyList<AdEntry>[] { new[] { entry, entry }, new[] { Computer("PC2", "CN=PC2,DC=elsewhere,DC=local") }, new[] { Computer("PC3", sid: false) } })
        {
            try { AdObjectAccess.Project(entries, Fixtures.Domain, Fixtures.Now); throw new InvalidOperationException("Une projection invalide a été acceptée."); }
            catch (DomeniaOperationException) { }
        }
    }

    [Test]
    public static void Guid_filter_uses_AD_binary_order_and_missing_dates_stay_unknown_in_rows()
    {
        var id = Guid.Parse("00112233-4455-6677-8899-aabbccddeeff");
        Check.Equal("(objectGUID=\\33\\22\\11\\00\\55\\44\\77\\66\\88\\99\\aa\\bb\\cc\\dd\\ee\\ff)", AdObjectAccess.GuidFilter(id), "ordre des octets Windows");
        var snapshot = AdObjectAccess.Project([Computer("PC1")], Fixtures.Domain, Fixtures.Now);
        var row = new SearchRowFactory(snapshot, [], null, Fixtures.Now).Computer(snapshot.Computers.Single());
        Check.Null(row.Created, "date de création absente");
        Check.Null(row.Changed, "date de modification absente");
    }

    private static AdEntry Computer(string name, string? dn = null, bool sid = true)
    {
        var attrs = new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [Fixtures.IdOf(name).ToByteArray()], ["name"] = [name], ["sAMAccountName"] = [name + "$"],
            ["objectClass"] = ["top", "person", "organizationalPerson", "user", "computer"],
            ["userAccountControl"] = [AdValues.WorkstationTrustAccount.ToString(System.Globalization.CultureInfo.InvariantCulture)],
        };
        if (sid)
        {
            var identity = new SecurityIdentifier("S-1-5-21-1-2-3-99");
            var bytes = new byte[identity.BinaryLength];
            identity.GetBinaryForm(bytes, 0);
            attrs["objectSid"] = [bytes];
        }
        return new(dn ?? "CN=" + name + "," + Fixtures.Postes, attrs);
    }
}
