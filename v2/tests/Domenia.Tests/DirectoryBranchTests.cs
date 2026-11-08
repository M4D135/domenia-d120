using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class DirectoryBranchTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static DirectoryBranch Branch(params DirectoryBranchEntry[] children) =>
        new(new(Fixtures.Root, "test.local", "test.local"), [.. children], Fixtures.Now, Guid.NewGuid());
    private static DirectoryBranchEntry Ou => new(Fixtures.Postes, "Postes", "test.local / Postes", "ou", true, new(null, null, null));
    private static AdEntry Entry(string dn, string kind) => new(dn, new Dictionary<string, IReadOnlyList<object>>
    {
        ["name"] = [DistinguishedName.Parse(dn)[0].Value], ["objectClass"] = ["top", kind],
    });

    [Test]
    public static async Task Branch_commit_reopens_sqlite_and_empty_success_replaces_old_children()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(database);
        var first = Branch(Ou);
        Check.Equal(first.ReadId, (await cache.SaveBranchAsync(first, None)).ReadId, "réponse issue du commit relu");
        var reopened = new SqliteDirectoryCache(new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed()));
        var read = await reopened.ReadBranchAsync(Fixtures.Root.ToLowerInvariant(), None);
        Check.Equal(Fixtures.Postes, read!.Children.Single().Dn, "branche durable après réouverture, DN insensible à la casse");
        var empty = Branch();
        await reopened.SaveBranchAsync(empty, None);
        var after = await cache.ReadBranchAsync(Fixtures.Root, None);
        Check.Equal(empty.ReadId, after!.ReadId, "la lecture vide est un nouvel instantané");
        Check.Equal(0, after.Children.Length, "aucun ancien enfant réinjecté");
        using var raw = new SqliteDatabase(database.Path, true);
        Check.Equal(0L, (long)raw.Scalar("SELECT COUNT(*) FROM domenia_v2_objects;")!, "la navigation ne prétend pas avoir récolté les objets");
    }

    [Test]
    public static async Task Branch_cache_rejects_foreign_children_duplicates_and_corruption_without_replacing_prior_read()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(database);
        var good = Branch(Ou);
        await cache.SaveBranchAsync(good, None);
        foreach (var bad in new[] { Branch(Ou with { Dn = "OU=Elsewhere,DC=foreign,DC=local" }), Branch(Ou, Ou), Branch(Ou with { Kind = "user" }) })
        {
            await Check.ThrowsAsync<InvalidDataException>(() => cache.SaveBranchAsync(bad, None), "branche incohérente refusée");
            Check.Equal(good.ReadId, (await cache.ReadBranchAsync(Fixtures.Root, None))!.ReadId, "instantané précédent préservé");
        }
        using (var raw = new SqliteDatabase(database.Path, false)) { raw.Execute("UPDATE domenia_v2_directory_branches SET sha256='changed';"); }
        await Check.ThrowsAsync<InvalidDataException>(() => cache.ReadBranchAsync(Fixtures.Root, None), "corruption refusée, jamais une branche vide");
    }

    [Test]
    public static async Task Branch_read_is_one_level_pages_250_typed_and_published_after_sqlite()
    {
        using var folder = new TemporaryFolder();
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed()));
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.DomainAsync(None);
        ldap.Searches.Clear();
        ldap.SearchAnswer = _ => [Entry(Fixtures.Postes, "organizationalUnit"), Entry("CN=Users," + Fixtures.Root, "container")];
        var reader = new AdDirectoryBranchReader(source);
        var result = await reader.ReadBranchAsync(null, None);
        Check.Equal(2, result.Children.Length, "OU et conteneur publiés ensemble");
        Check.True(result.Children.Select(c => c.Kind).SequenceEqual(["ou", "container"]), "types distincts");
        var request = ldap.Searches.Single();
        Check.Equal(Fixtures.Root, request.BaseDn, "racine explicite");
        Check.Equal(AdSearchScope.OneLevel, request.Scope, "aucun balayage subtree pour ouvrir une branche");
        Check.Equal(250, request.PageSize, "pages de 250");
        Check.Equal(100_001, request.SizeLimit, "sentinelle de dépassement");
        Check.True(request.Budget <= TimeSpan.FromSeconds(60), "budget total borné");
        Check.Equal(result.ReadId, (await cache.ReadBranchAsync(Fixtures.Root, None))!.ReadId, "publication durable vérifiée");
        ldap.SearchAnswer = _ => [];
        Check.Equal(0, (await reader.ReadBranchAsync(null, None)).Children.Length, "vide réseau remplacé dans SQLite");
        ldap.Searches.Clear();
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadBranchAsync("OU=No,DC=other,DC=local", None), "hors domaine refusé");
        Check.Equal(0, ldap.Searches.Count, "aucun LDAP hors domaine");
    }

    [Test]
    public static async Task Branch_read_rejects_changed_session_and_never_returns_old_cache_on_failure()
    {
        using var folder = new TemporaryFolder();
        var cache = new SqliteDirectoryCache(new DomeniaDatabase(folder.File("Domenia.db"), Fixtures.Root, TestClock.Fixed()));
        var old = Branch(Ou);
        await cache.SaveBranchAsync(old, None);
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.DomainAsync(None);
        var reader = new AdDirectoryBranchReader(source);
        ldap.SearchAnswer = _ => { source.Reset(); return []; };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadBranchAsync(null, None), "session remplacée : aucune publication");
        Check.Equal(old.ReadId, (await cache.ReadBranchAsync(Fixtures.Root, None))!.ReadId, "base inchangée après le changement de session");
        ldap.SearchAnswer = null;
        await source.DomainAsync(None);
        ldap.SearchAnswer = _ => throw new IOException("lecture interrompue");
        await Check.ThrowsAsync<IOException>(() => reader.ReadBranchAsync(null, None), "erreur réseau propagée");
        Check.Equal(old.ReadId, (await cache.ReadBranchAsync(Fixtures.Root, None))!.ReadId, "pas de substitution de l’ancien instantané");
    }

    [Test]
    public static async Task Dedicated_branch_operation_preserves_the_OU_only_picker_contract()
    {
        var bridge = new SimulatedBridge();
        var branch = SimulatedBridge.Json(await bridge.CallAsync("directory.branch.children", "{}"));
        Check.True(branch.GetProperty("children").EnumerateArray().Any(c => c.GetProperty("kind").GetString() == "container"), "conteneurs accessibles dans Rechercher");
        var picker = SimulatedBridge.Json(await bridge.CallAsync("directory.ou.children", "{}"));
        Check.Equal(7, picker.GetProperty("children").GetArrayLength(), "picker inchangé : sept OU");
        Check.False(picker.GetProperty("children")[0].TryGetProperty("kind", out _), "contrat du picker conservé");
    }
}
