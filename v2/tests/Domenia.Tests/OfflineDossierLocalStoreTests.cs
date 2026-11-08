using System.Security.Cryptography;
using Domenia.App;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.Tests;

internal static class OfflineDossierLocalStoreTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static ModeDecision Decision => new(AppMode.Directory, ModeReason.DomainJoined, "test", null, "test.local", []);

    [Test]
    public static async Task Real_local_dossier_writes_verified_files_without_connecting_or_mutating_the_database()
    {
        using var folder = new TemporaryFolder();
        var store = await SeedAsync(folder);
        var before = Digest(store.Path);
        using var context = await OpenAsync(folder);
        var session = await context.Source.GetSessionAsync(None);
        Check.Equal(ConnectionState.Disconnected, session.Connection, "aucune connexion annoncée");
        Check.Equal(Fixtures.Root, session.Domain!.RootDn, "domaine du relevé local");
        var found = await context.Index.ComputersNamedAsync(["PC-LOCAL", "ABSENT"], None);
        Check.Equal(1, found.Length, "poste réellement relu dans SQLite");
        Check.Equal(Fixtures.Computer("PC-LOCAL").ObjectGuid, found[0].Guid, "identité exacte");
        var perimeter = Perimeter(found[0].Guid);
        var data = await context.Index.DossierDataAsync(new(perimeter, OfflineDossiers.Sections(["observations", "associations", "requetes"]), 1000), None);
        Check.Equal(1, data.Computers.Count, "setup positif du dossier");
        Check.False(data.Source["Simulation"]!.GetValue<bool>(), "provenance annuaire local");
        var documents = new FileDocumentStore(folder.File("exports"), new RecordingJournal(), static (_, _) => { });
        var result = await OfflineDossierRunner.RunAsync(context.Index, documents, perimeter, ["observations", "associations", "requetes"],
            "PC-LOCAL", "test", TestClock.Fixed(), 1, context.EnsureCurrentAsync, None);
        Check.True(result.Saved, "dossier réellement écrit");
        Check.True(result.Files.Length >= 7, "sections et preuves présentes");
        foreach (var file in result.Files)
        { Check.Equal(file.Sha256, Digest(Path.Combine(result.Path!, file.Name)), "empreinte physiquement relue " + file.Name); }
        Check.Equal(before, Digest(store.Path), "octets de la base inchangés après fermeture des lecteurs");
        Check.Equal(ConnectionState.Disconnected, (await context.Source.GetSessionAsync(None)).Connection, "reste déconnecté");
    }

    [Test]
    public static async Task Command_OU_index_comes_from_stored_OUs_without_opening_a_picker()
    {
        using var folder = new TemporaryFolder();
        await SeedAsync(folder);
        using var context = await OpenAsync(folder);
        var ou = await context.OrganizationalUnits.FindLocalAsync(Fixtures.Postes, None);
        Check.True(ou is not null, "OU enregistrée accessible dans une nouvelle commande");
        Check.Null(await context.OrganizationalUnits.FindLocalAsync("OU=Inconnue," + Fixtures.Root, None), "OU non inventée");
        var perimeter = OfflineDossiers.Perimeter(DossierScope.Branch, null, null, Fixtures.Root, [], new ScopeSelection(ou!.Dn, ou.Name, true));
        var data = await context.Index.DossierDataAsync(new(perimeter, OfflineDossiers.Sections([]), 1000), None);
        Check.Equal(1, data.Computers.Count, "dossier OU contient le poste connu");
        Check.False(OfflineDossiers.Perimeter(DossierScope.Branch, null, null, Fixtures.Root, [], new ScopeSelection(Fixtures.Root, "test", true)).Valid,
            "racine de domaine toujours refusée");
    }

    [Test]
    public static async Task Readonly_capabilities_refuse_mutations_and_an_accidental_connection()
    {
        using var folder = new TemporaryFolder();
        var store = await SeedAsync(folder);
        var cache = await ReadOnlyDirectoryCache.OpenAsync(folder.File("app"), folder.File("profile"), "test.local", TestClock.Fixed(), None);
        Check.Equal(1, (await cache.ReadKnownAsync(None))!.Computers.Length, "cache valide avant les refus");
        var before = Digest(store.Path);
        await Check.ThrowsAsync<NotSupportedException>(() => ((IDirectoryCache)cache).SaveAsync(Snapshot(), Scope(), "DC1", None), "écriture entière refusée");
        await Check.ThrowsAsync<NotSupportedException>(() => ((IObjectDirectoryCache)cache).SaveObjectsAsync(Snapshot(), "DC1", None), "écriture ciblée refusée");
        var called = false;
        await Check.ThrowsAsync<NotSupportedException>(() => ((IQueryLibraryStore)cache).UpdateAsync(QueryLibrary.RootKey(Fixtures.Root), _ => { called = true; return null; }, None), "bibliothèque non modifiable");
        Check.False(called, "callback de mutation jamais invoqué");
        using var context = await OpenAsync(folder);
        var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => context.Source.ConnectAsync(None), "transport fermé");
        Check.Equal(DomeniaErrors.SourceUnavailable, refusal.Code, "refus explicite avant LDAP");
        Check.True(refusal.Message.Contains("accès réseau interdit", StringComparison.Ordinal), "refus du transport de la CLI");
        Check.Equal(before, Digest(store.Path), "aucune mutation locale");
    }

    [Test]
    public static async Task Missing_local_base_is_not_created_and_does_not_become_simulation()
    {
        using var folder = new TemporaryFolder();
        Directory.CreateDirectory(folder.File("app"));
        var refusal = await Check.ThrowsAsync<InvalidDataException>(() => OpenAsync(folder), "absence signalée");
        Check.True(refusal.Message.Contains("absente", StringComparison.Ordinal), "absence réelle qualifiée");
        Check.False(Directory.Exists(folder.File("profile")), "aucun profil ni base de remplacement créé");
        using var stop = new CancellationTokenSource(); stop.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => OfflineDossierContext.CreateAsync(Decision, folder.File("app"), folder.File("profile"), "TEST\\adm", TestClock.Fixed(), stop.Token), "annulation avant toute lecture");
        Check.False(Directory.Exists(folder.File("profile")), "annulation sans création");
    }

    [Test]
    public static async Task Legacy_database_without_local_projection_is_refused_without_migration()
    {
        using var folder = new TemporaryFolder();
        var store = await SeedAsync(folder);
        using (var legacy = new SqliteDatabase(store.Path, false))
        { legacy.Script("DROP TABLE domenia_v2_objects; DROP TABLE domenia_v2_metadata; DROP TABLE domenia_v2_batches; DELETE FROM schema_info WHERE key='domenia_schema';"); }
        var before = Digest(store.Path);
        var files = Directory.GetFiles(Path.GetDirectoryName(store.Path)!, "*", SearchOption.AllDirectories).Order(StringComparer.Ordinal).ToArray();
        var refusal = await Check.ThrowsAsync<InvalidDataException>(() => OpenAsync(folder), "projection absente");
        Check.True(refusal.Message.Contains("aucune migration", StringComparison.Ordinal), "refus explicite de migration");
        Check.Equal(before, Digest(store.Path), "base historique conservée");
        Check.True(files.SequenceEqual(Directory.GetFiles(Path.GetDirectoryName(store.Path)!, "*", SearchOption.AllDirectories).Order(StringComparer.Ordinal)), "aucune sauvegarde ou base créée");
    }

    [Test]
    public static async Task Revision_change_after_rows_are_read_refuses_export_before_any_output()
    {
        using var folder = new TemporaryFolder();
        var store = await SeedAsync(folder);
        using var context = await OpenAsync(folder);
        var perimeter = Perimeter(Fixtures.Computer("PC-LOCAL").ObjectGuid);
        Check.Equal(1, (await context.Index.DossierDataAsync(new(perimeter, OfflineDossiers.Sections([]), 1000), None)).Computers.Count, "lignes réellement disponibles avant interleaving");
        var documents = new FileDocumentStore(folder.File("exports"), new RecordingJournal(), static (_, _) => { });
        var guardReached = false;
        var refusal = await Check.ThrowsAsync<InvalidDataException>(() => OfflineDossierRunner.RunAsync(context.Index, documents, perimeter, [], "PC-LOCAL", "test", TestClock.Fixed(), 0,
            async token =>
            {
                guardReached = true;
                await store.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Snapshot() with { ReadAt = Fixtures.Now }, Scope(), "DC1", token);
                await context.EnsureCurrentAsync(token);
            }, None), "révision modifiée entre lecture et écriture");
        Check.True(guardReached, "point avant export effectivement atteint");
        Check.True(refusal.Message.Contains("a changé", StringComparison.Ordinal), "refus de cohérence exact");
        Check.False(Directory.Exists(folder.File("exports")), "aucun dossier partiel produit");
    }

    [Test]
    public static async Task Simulation_never_resolves_real_profile_or_configuration_paths()
    {
        using var context = await OfflineDossierContext.CreateAsync(Decision with { Mode = AppMode.Simulation }, "\0", "\0", "TEST\\adm", TestClock.Fixed(), None);
        Check.True(context.Source is SimulatedDirectorySource, "source fictive explicite");
        await context.EnsureCurrentAsync(None);
        Check.True((await context.Source.ReadLocalAsync(None)).Directory.Computers.Length > 0, "monde fictif utilisable malgré chemins réels invalides");
    }

    private static Task<OfflineDossierContext> OpenAsync(TemporaryFolder folder) =>
        OfflineDossierContext.CreateAsync(Decision, folder.File("app"), folder.File("profile"), "TEST\\adm", TestClock.Fixed(), None);
    private static DirectorySnapshot Snapshot() => Fixtures.Snapshot(computers: [Fixtures.Computer("PC-LOCAL")]) with
    { OrganizationalUnits = [new DirectoryOu(Fixtures.IdOf("local-ou"), Fixtures.Postes, "Postes", null, null, Fixtures.Now.AddDays(-1), Fixtures.Now.AddDays(-1), 1)] };
    private static ScopeSelection Scope() => new(Fixtures.Postes, "Postes", true);
    private static DossierPerimeter Perimeter(Guid id) => OfflineDossiers.Perimeter(DossierScope.List, null, null, Fixtures.Root, [],
        listed: [new OfflineDossiers.Workstation(id.ToString("D"), "PC-LOCAL")]);
    private static async Task<DomeniaDatabase> SeedAsync(TemporaryFolder folder)
    {
        Directory.CreateDirectory(folder.File("app"));
        var store = await new CompatibleDirectoryCache(folder.File("app"), folder.File("profile"), "test.local", TestClock.Fixed()).DatabaseAsync(None);
        await store.InitializeAsync(None);
        await store.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Snapshot(), Scope(), "DC1.test.local", None);
        Check.Equal(1, (await store.ReadDirectoryAsync(None))!.Computers.Length, "fixture SQLite enregistrée et relue");
        return store;
    }
    private static string Digest(string path) => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
}
