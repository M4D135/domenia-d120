using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class FicheCacheContractTests
{
    private const string Dn = "CN=Élodie," + Fixtures.People;
    private static FicheLocalRead Qualified(string reader = @"TEST\test", Guid? id = null, long usn = 1)
    {
        var entry = AdFicheObjects.Project(AdFicheReaderTests.Entry(Dn, "user", new()
        {
            ["objectGUID"] = [(id ?? Fixtures.IdOf(Dn)).ToByteArray()], ["uSNChanged"] = [usn.ToString(System.Globalization.CultureInfo.InvariantCulture)],
            ["description"] = ["Relevé conservé"],
        }));
        return new(entry, Fixtures.Now)
        { Provenance = new(Fixtures.Root, entry.ObjectGuid, FicheCacheProvenance.ReaderKey(reader), "dc.test.local", Guid.Parse("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"), usn) };
    }

    [Test]
    public static async Task Native_fiche_and_its_provenance_are_reopened_together_and_old_attempts_cannot_replace_them()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("fiche.db");
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(path, Fixtures.Root, TestClock.Fixed()));
        var item = Qualified();
        await cache.SaveFicheAsync(item, CancellationToken.None);
        var old = item with { ReadAt = item.ReadAt.AddMinutes(-1), Provenance = item.Provenance! with { ReaderHash = FicheCacheProvenance.ReaderKey("old") } };
        var retained = await cache.SaveFicheAsync(old, CancellationToken.None);
        Check.Equal(item.Provenance, retained.Provenance, "tentative ancienne sans remplacement de provenance");
        IFicheCache cold = new SqliteDirectoryCache(new DomeniaDatabase(path, Fixtures.Root, TestClock.Fixed()));
        var read = (await cold.ReadFicheByGuidAsync(item.Entry.ObjectGuid, CancellationToken.None))!;
        Check.Equal(item.Provenance, read.Provenance, "preuve conservée après réouverture native");
        Check.Equal(item.ReadAt, read.ReadAt, "date non rajeunie");
        Check.Equal(item.Provenance!.ReaderHash, (await cold.ReadFicheIndexAsync(CancellationToken.None)).Single().ReaderHash, "résumé qualifié par le même lecteur");
        using (var sql = new SqliteDatabase(path, readOnly: false))
        {
            Check.Equal(item.Provenance.ReaderHash, sql.Scalar("SELECT reader FROM domenia_provenance;"), "table historique réellement alimentée");
            sql.Execute("UPDATE domenia_provenance SET source_dc='other.test.local';");
        }
        await Check.ThrowsAsync<InvalidDataException>(() => cold.ReadFicheByGuidAsync(item.Entry.ObjectGuid, CancellationToken.None), "table altérée refusée");
    }

    [Test]
    public static async Task A_recreated_DN_is_ambiguous_even_at_different_dates_but_explicit_GUID_reads_keep_both_histories()
    {
        using var folder = new TemporaryFolder();
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(folder.File("fiche.db"), Fixtures.Root, TestClock.Fixed()));
        var first = Qualified();
        var next = Qualified(id: Guid.NewGuid()) with { ReadAt = Fixtures.Now.AddMinutes(1) };
        await cache.SaveFicheAsync(first, CancellationToken.None);
        await cache.SaveFicheAsync(next, CancellationToken.None);
        await Check.ThrowsAsync<InvalidDataException>(() => cache.ReadFicheAsync(Dn, CancellationToken.None), "DN seul ne choisit pas l’identité la plus récente");
        Check.Equal(first.Entry.ObjectGuid, (await cache.ReadFicheByGuidAsync(first.Entry.ObjectGuid, CancellationToken.None))!.Entry.ObjectGuid, "ancienne identité conservée");
        Check.Equal(next.Entry.ObjectGuid, (await cache.ReadFicheByGuidAsync(next.Entry.ObjectGuid, CancellationToken.None))!.Entry.ObjectGuid, "nouvelle identité indépendante");
    }

    [Test]
    public static async Task The_real_AD_reader_refuses_another_reader_cache_without_contacting_AD_and_preserves_the_local_record()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("fiche.db");
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(path, Fixtures.Root, TestClock.Fixed()));
        var item = Qualified();
        await cache.SaveFicheAsync(item, CancellationToken.None);
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var other = new AdDirectorySource("test.local", () => @"TEST\other", TestClock.Fixed(), connection: ldap, localStore: cache);
        var reader = new AdFicheReader(other);
        Check.Null(await reader.PreviewAsync(Dn, CancellationToken.None), "pas de projection d’un autre lecteur");
        Check.Equal(0, (await reader.IndexAsync([Dn], CancellationToken.None)).Count, "index également isolé");
        Check.Null(await reader.LocalByIdAsync(item.Entry.ObjectGuid.ToString("D"), CancellationToken.None), "GUID du sélecteur également isolé");
        Check.Equal(0, ldap.Calls, "aucun repli réseau implicite");
        Check.NotNull(await cache.ReadFicheByGuidAsync(item.Entry.ObjectGuid, CancellationToken.None), "historique non effacé par changement de compte");
        using var ownerLdap = new AdBoundaryTests.RecordingAdConnection();
        using var owner = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ownerLdap, localStore: cache);
        Check.NotNull(await new AdFicheReader(owner).PreviewAsync(Dn, CancellationToken.None), "le lecteur d’origine retrouve son historique");
        Check.Equal(0, ownerLdap.Calls, "lecture locale seulement");
    }

    [Test]
    public static async Task An_expired_memory_visit_falls_back_to_the_same_dated_native_fiche_and_never_invents_an_invocation()
    {
        using var folder = new TemporaryFolder();
        var clock = TestClock.Fixed();
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(folder.File("fiche.db"), Fixtures.Root, clock));
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        { SearchAnswer = q => q.Scope == AdSearchScope.Base && q.BaseDn == Dn ? [AdFicheReaderTests.Entry(Dn, "user", new() { ["allowedAttributes"] = ["description"], ["description"] = ["Lu"] })] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", clock, connection: ldap, localStore: cache);
        var reader = new AdFicheReader(source);
        var fresh = await reader.ReadAsync(Dn, CancellationToken.None);
        Check.NotNull(fresh.Provenance, "identité du lecteur réel conservée");
        Check.Null(fresh.Provenance!.InvocationId, "invocation inconnue reste inconnue");
        Check.False(fresh.Provenance.VersionQualified, "pas de preuve de version DC inventée");
        Check.Equal(1, reader.ObjectVisits.Count, "visite conservée");
        var calls = ldap.Calls;
        clock.Advance(TimeSpan.FromSeconds(46));
        var historical = (await reader.PreviewAsync(Dn, CancellationToken.None))!;
        Check.Equal(0, reader.ObjectVisits.Count, "expiration mémoire effective");
        Check.Equal(1L, reader.ObjectVisits.Expired, "expiration comptabilisée");
        Check.Equal(fresh.ReadAt, historical.ReadAt, "relecture locale ne rajeunit pas le relevé");
        Check.Equal(fresh.Provenance, historical.Provenance, "provenance durable identique");
        Check.Equal(calls, ldap.Calls, "aucune sonde de fraîcheur implicite");
    }

    [Test]
    public static async Task Invalid_identity_or_version_proofs_cannot_replace_the_valid_fiche()
    {
        using var folder = new TemporaryFolder();
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(folder.File("fiche.db"), Fixtures.Root, TestClock.Fixed()));
        var item = Qualified();
        await cache.SaveFicheAsync(item, CancellationToken.None);
        foreach (var proof in new[] { item.Provenance! with { ObjectGuid = Guid.NewGuid() }, item.Provenance! with { DomainDn = "DC=elsewhere" }, item.Provenance! with { UsnChanged = 42 } })
            await Check.ThrowsAsync<InvalidDataException>(() => cache.SaveFicheAsync(item with { Provenance = proof }, CancellationToken.None), "preuve discordante refusée avant écriture");
        Check.Equal(item.Provenance, (await cache.ReadFicheAsync(Dn, CancellationToken.None))!.Provenance, "dernière preuve cohérente intacte");
        Check.False(item.Provenance!.SameVersion(item.Provenance! with { Controller = "other.test.local" }), "même USN sur un autre DC n’est pas la même version");
        Check.False(item.Provenance!.SameVersion(item.Provenance! with { InvocationId = Guid.NewGuid() }), "une nouvelle invocation invalide la version");
    }
}
