using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;
using System.Security.Principal;

namespace Domenia.Tests;

internal static class DirectoryBranchCompositionTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private const string BranchFilter = "(|(objectClass=organizationalUnit)(objectClass=container)(objectClass=builtinDomain))";

    [Test]
    public static async Task Application_deferred_cache_publishes_a_branch_and_reopens_its_durable_snapshot()
    {
        using var folder = new TemporaryFolder();
        // Same cache composition as App.Composition; only the LDAP transport is replaced by a recording fixture.
        var cache = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", TestClock.Fixed(), isolated: true);
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.DomainAsync(CancellationToken.None);
        ldap.SearchAnswer = _ => [new AdEntry(Fixtures.Postes, new Dictionary<string, IReadOnlyList<object>>
        { ["name"] = ["Postes"], ["objectClass"] = ["top", "organizationalUnit"] })];
        using var readers = ScreenReaders.Discover(source, [typeof(AdDirectoryBranchReader).Assembly]);
        var result = await readers.Require<IDirectoryBranchReader>().ReadBranchAsync(null, CancellationToken.None);
        Check.Equal(Fixtures.Postes, result.Children.Single().Dn, "lecture de branche publiée par la composition réelle");
        var reopened = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", TestClock.Fixed(), isolated: true);
        var persisted = await reopened.ReadBranchAsync(Fixtures.Root, CancellationToken.None);
        Check.Equal(result.ReadId, persisted!.ReadId, "même snapshot après une nouvelle découverte locale");
        Check.Equal(result.Children.Single(), persisted.Children.Single(), "enfant réellement relu depuis SQLite");
    }

    [Test]
    public static async Task A_visible_nested_OU_or_container_on_a_cold_profile_is_a_real_search_base_without_loading_the_OU_picker()
    {
        const string parent = @"OU=Équipe\, Sud," + Fixtures.Root;
        const string ou = "OU=Windows 10," + parent;
        const string container = "CN=Équipements," + ou;
        foreach (var selected in new[] { ou, container })
        {
            using var folder = new TemporaryFolder();
            var clock = TestClock.Fixed();
            var cache = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", clock, isolated: true);
            using var ldap = new AdBoundaryTests.RecordingAdConnection();
            using var source = new AdDirectorySource("test.local", () => @"TEST\adm", clock, connection: ldap, localStore: cache);
            await source.DomainAsync(None);
            var expected = new[] { Computer("POSTE-01", selected), Computer("POSTE-02", selected) };
            ldap.SearchAnswer = request =>
            {
                if (request.Filter == BranchFilter)
                {
                    Check.Equal(AdSearchScope.OneLevel, request.Scope, "navigation par branche directe uniquement");
                    return request.BaseDn == Fixtures.Root ? [Navigation(parent, "organizationalUnit")]
                        : request.BaseDn == parent ? [Navigation(ou, "organizationalUnit")]
                        : request.BaseDn == ou ? [Navigation(container, "container")] : [];
                }
                if (request.SortAttribute is not null)
                {
                    Check.Equal(selected, request.BaseDn, "requête d’objets dans la branche exacte sélectionnée");
                    return expected;
                }
                Check.Equal("(objectClass=container)", request.Filter, "aucun chargement global de l’index des OU");
                Check.Equal(AdSearchScope.OneLevel, request.Scope, "ancien repli conteneurs limité à la racine");
                return [];
            };
            using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Annuaire de test", null, "test.local", []), source,
                new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(AdDirectorySource).Assembly]));
            var branches = context.Readers.Require<IDirectoryBranchReader>();
            await branches.ReadBranchAsync(null, None);
            var visible = await branches.ReadBranchAsync(parent, None);
            if (selected == container) { visible = await branches.ReadBranchAsync(ou, None); }
            Check.Equal(selected, visible.Children.Single().Dn, "base réellement affichée par le lecteur de l’arbre");
            Check.Null(await context.Readers.Require<IOrganizationalUnitIndex>().FindLocalAsync(selected, None), "l’index OU reste froid et n’admet pas un conteneur");
            var before = ldap.Calls;
            var local = await context.Readers.Require<IDirectoryBranchIndex>().FindLocalAsync(selected.ToLowerInvariant(), None);
            Check.Equal(selected, local!.Dn, "DN canonique retrouvé avec espace, accent, virgule échappée et autre casse");
            Check.Equal(before, ldap.Calls, "admission de la branche sans aucun contact LDAP");
            var database = await cache.DatabaseAsync(None);
            using (var raw = new SqliteDatabase(database.Path, true))
            { Check.Equal(0L, (long)raw.Scalar("SELECT COUNT(*) FROM domenia_v2_objects;")!, "la navigation ne remplit pas l’inventaire d’objets"); }
            var initial = await source.ReadLocalAsync(None);
            Check.Equal(0, initial.Directory.ObjectCount, "profil sans inventaire au moment de choisir la base");
            Check.False(initial.Directory.Complete, "navigation ne certifie aucune couverture d’inventaire");

            ldap.Searches.Clear();
            var service = SearchService.From(context);
            var browsed = await service.BrowseAsync(selected.ToLowerInvariant(), true, SearchTypeFilter.Computers, 100, None);
            var found = await service.RunAsync("POSTE*", selected, SearchTypeFilter.Computers, 100, SearchMatchMode.Prefix, None);
            foreach (var result in new[] { browsed, found })
            {
                Check.Equal(selected, result.Scope.Dn, "périmètre rendu identique à la branche choisie");
                Check.True(result.Rows.Select(row => row.Id).Order(StringComparer.Ordinal).SequenceEqual(
                    expected.Select(entry => entry.Guid("objectGUID")!.Value.ToString("D")).Order(StringComparer.Ordinal)), "deux identités exactes lues dans cette branche");
                Check.True(result.Rows.All(row => DistinguishedName.IsWithin(row.Dn, selected, true)), "aucun objet d’une autre base");
                Check.Equal(2, result.Loaded, "liste réellement remplie");
                Check.True(result.Complete, "réponse terminée dans sa limite");
            }
            Check.True(ldap.Searches.Count == 2 && ldap.Searches.All(request => request.BaseDn == selected && request.SortAttribute == "name"),
                "seules les deux lectures d’objets demandées sont envoyées, jamais tout l’arbre");

            ldap.Searches.Clear();
            var foreign = await Check.ThrowsAsync<DomeniaOperationException>(() => service.BrowseAsync("OU=A,DC=foreign,DC=local", true, SearchTypeFilter.All, 100, None), "hors domaine");
            Check.Equal(DomeniaErrors.OuUnknown, foreign.Code, "base étrangère refusée");
            Check.Equal(0, ldap.Searches.Count, "refus hors domaine avant toute lecture de conteneurs");
            var invented = await Check.ThrowsAsync<DomeniaOperationException>(() => service.BrowseAsync("OU=Inventée," + parent, true, SearchTypeFilter.All, 100, None), "branche inventée");
            Check.Equal(DomeniaErrors.OuUnknown, invented.Code, "une simple appartenance au domaine ne suffit pas");
            Check.False(ldap.Searches.Any(request => request.SortAttribute is not null), "aucune liste d’objets lancée pour une branche inconnue");
            Check.Null(await context.Readers.Require<IOrganizationalUnitIndex>().FindLocalAsync(container, None), "les autres opérations conservent leur contrat OU uniquement");
        }
    }

    [Test]
    public static async Task A_removed_navigation_child_is_not_admitted_and_corrupt_branch_cache_never_falls_back_to_object_reads()
    {
        using var folder = new TemporaryFolder();
        var clock = TestClock.Fixed();
        var cache = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", clock, isolated: true);
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", clock, connection: ldap, localStore: cache);
        await source.DomainAsync(None);
        ldap.SearchAnswer = request => request.Filter == BranchFilter ? [Navigation(Fixtures.Postes, "organizationalUnit")] : [];
        using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Annuaire de test", null, "test.local", []), source,
            new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(AdDirectorySource).Assembly]));
        var reader = context.Readers.Require<IDirectoryBranchReader>();
        var index = context.Readers.Require<IDirectoryBranchIndex>();
        await reader.ReadBranchAsync(null, None);
        Check.NotNull(await index.FindLocalAsync(Fixtures.Postes, None), "enfant de la branche durable connu");
        ldap.SearchAnswer = _ => [];
        await reader.ReadBranchAsync(null, None);
        Check.Null(await index.FindLocalAsync(Fixtures.Postes, None), "la nouvelle branche vide ne ressuscite pas l’ancien enfant");
        var database = await cache.DatabaseAsync(None);
        using (var raw = new SqliteDatabase(database.Path, false)) { raw.Execute("UPDATE domenia_v2_directory_branches SET sha256='changed';"); }
        ldap.Searches.Clear();
        await Check.ThrowsAsync<InvalidDataException>(() => SearchService.From(context).BrowseAsync(Fixtures.Postes, true, SearchTypeFilter.All, 100, None), "cache corrompu refusé");
        Check.Equal(0, ldap.Searches.Count, "aucun repli réseau après une erreur de lecture locale");
    }

    [Test]
    public static async Task The_local_branch_index_rejects_session_replacement_and_substituted_branches_without_contacting_LDAP()
    {
        var child = new DirectoryBranchEntry(Fixtures.Postes, "Postes", "test.local / Postes", "ou", true, new(null, null, null));
        var branch = new DirectoryBranch(new(Fixtures.Root, "test.local", "test.local"), [child], Fixtures.Now, Guid.NewGuid());
        var cache = new ObservedBranchCache { Branch = branch };
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: ldap, localStore: cache);
        var index = new AdDirectoryBranchReader(source);
        Check.Null(await index.FindLocalAsync(Fixtures.Postes, None), "aucune branche admise sans domaine établi");
        Check.Equal(0, ldap.Calls, "l’index local ne connecte jamais implicitement");
        await source.DomainAsync(None);
        var calls = ldap.Calls;
        Check.Null(await index.FindLocalAsync("OU=Autre,DC=foreign,DC=local", None), "DN étranger refusé avant accès au cache");
        Check.Equal(0, cache.Reads, "pas de lecture du cache pour un autre domaine");
        Check.Equal(child, await index.FindLocalAsync(Fixtures.Postes, None), "enfant exact admis");

        cache.Branch = branch with { Parent = new(Fixtures.Postes, "Postes", "test.local / Postes"),
            Children = [child with { Dn = "OU=Autre," + Fixtures.Postes }] };
        await Check.ThrowsAsync<InvalidDataException>(() => index.FindLocalAsync(Fixtures.Postes, None), "un autre parent n’est pas la branche demandée");
        cache.Branch = branch with { Parent = new("DC=foreign,DC=local", "foreign.local", "foreign.local"), Children = [] };
        await Check.ThrowsAsync<InvalidDataException>(() => index.FindLocalAsync(Fixtures.Postes, None), "branche cache d’un autre domaine refusée");
        cache.Branch = branch;
        cache.AfterRead = () => source.Reset();
        var changed = await Check.ThrowsAsync<DomeniaOperationException>(() => index.FindLocalAsync(Fixtures.Postes, None), "session remplacée pendant l’accès local");
        Check.Equal(AdErrors.NotConnected, changed.Code, "le résultat de l’ancienne session n’est pas publié");
        Check.Equal(calls, ldap.Calls, "admissions et refus purement locaux, sans lecture LDAP de substitution");
    }

    private static AdEntry Navigation(string dn, string kind) => new(dn, new Dictionary<string, IReadOnlyList<object>>
    { ["name"] = [DistinguishedName.Parse(dn)[0].Value], ["objectClass"] = ["top", kind] });

    private static AdEntry Computer(string name, string parent)
    {
        var dn = "CN=" + name + "," + parent;
        var sid = new SecurityIdentifier(Fixtures.Computer(name).Sid);
        var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
        return new(dn, new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [Fixtures.IdOf(dn).ToByteArray()], ["objectSid"] = [bytes], ["objectClass"] = ["top", "user", "computer"],
            ["name"] = [name], ["sAMAccountName"] = [name + "$"], ["dNSHostName"] = [name.ToLowerInvariant() + ".test.local"], ["userAccountControl"] = ["4096"],
        });
    }

    private sealed class ObservedBranchCache : IDirectoryCache, IDirectoryBranchCache
    {
        public DirectoryBranch? Branch { get; set; }
        public Action? AfterRead { get; set; }
        public int Reads { get; private set; }
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) => Task.FromResult<DirectorySnapshot?>(null);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken)
            => throw new InvalidOperationException("Aucun inventaire attendu.");
        public Task<DirectoryBranch> SaveBranchAsync(DirectoryBranch branch, CancellationToken cancellationToken)
            => throw new InvalidOperationException("Aucune écriture de branche attendue.");
        public Task<DirectoryBranch?> ReadBranchAsync(string dn, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); Reads++; var result = Branch; AfterRead?.Invoke(); return Task.FromResult(result); }
    }
}
