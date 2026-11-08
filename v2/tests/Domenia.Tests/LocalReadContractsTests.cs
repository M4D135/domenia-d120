using System.Text;
using System.Text.Json.Nodes;
using System.Text.Json;
using Domenia.Bridge;
using System.Reflection;
using System.Runtime.InteropServices;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Store;

namespace Domenia.Tests;

internal static class LocalReadContractsTests
{
    [Test]
    public static void Native_statements_are_reused_without_binding_leakage_and_have_a_bounded_connection_lifetime()
    {
        using var database = new SqliteDatabase(":memory:", false);
        database.Script("CREATE TABLE facts(value TEXT);");
        for (var i = 0; i < 10; i++) database.Execute("INSERT INTO facts(value) VALUES(?1);", "v" + i);
        Check.Equal(1L, database.PreparedStatementCount, "une seule préparation native pour dix écritures liées");
        Check.Equal("one", database.Scalar("SELECT ?1;", "one") as string, "paramètre initial");
        Check.Null(database.Scalar("SELECT ?1;", new object?[] { null }), "pas de paramètre hérité");
        Check.Throws<ArgumentException>(() => database.Scalar("SELECT ?1;"), "paramètre absent refusé malgré le cache");
        const string sql = "SELECT ?1 AS value UNION ALL SELECT 'last';";
        using (var first = database.ReadRows(sql, "first").GetEnumerator())
        {
            Check.True(first.MoveNext(), "premier curseur ouvert");
            Check.Equal("second", database.Query(sql, "second")[0]["value"] as string, "second curseur indépendant");
            Check.Equal("first", first.Current["value"] as string, "première ligne intacte");
            Check.True(first.MoveNext(), "premier curseur reprend sa propre position");
            Check.Equal("last", first.Current["value"] as string, "aucune ligne sautée");
        }
        database.Script("CREATE TABLE unique_facts(value TEXT UNIQUE);");
        database.Execute("INSERT INTO unique_facts(value) VALUES(?1);", "same");
        Check.Throws<SqliteStoreException>(() => database.Execute("INSERT INTO unique_facts(value) VALUES(?1);", "same"), "échec natif sur une instruction réutilisée");
        database.Execute("INSERT INTO unique_facts(value) VALUES(?1);", "different");
        Check.Equal(2L, (long)database.Scalar("SELECT count(*) FROM unique_facts;")!, "reprise après finalisation du handle en échec");
        database.Query("SELECT * FROM facts;");
        database.Script("ALTER TABLE facts ADD COLUMN observed INTEGER;");
        Check.True(database.Query("SELECT * FROM facts;")[0].ContainsKey("observed"), "schéma modifié repris par sqlite3_prepare_v2");
        for (var i = 0; i < 80; i++) database.Scalar("SELECT " + i.ToString(System.Globalization.CultureInfo.InvariantCulture) + ";");
        Check.Equal(SqliteDatabase.StatementCapacity, database.CachedStatementCount, "éviction bornée des instructions inactives");
        database.Dispose();
        Check.Equal(0, database.CachedStatementCount, "aucune instruction native conservée après fermeture");
        Check.Throws<ObjectDisposedException>(() => database.Scalar("SELECT 79;"), "aucune réutilisation après fermeture");
    }

    [Test]
    public static async Task Future_preferences_cannot_be_downgraded_by_an_ordinary_setting_change()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        const string original = """{"format":"domenia.preferences","version":99,"values":{"future.data":{"important":true}}}""";
        await File.WriteAllTextAsync(path, original);
        var journal = new RecordingJournal();
        using var preferences = new FilePreferenceStore(path, journal);
        Check.False(preferences.TryGet("future.data", out _), "aucune projection future");
        using var value = JsonDocument.Parse("true");
        await Check.ThrowsAsync<IOException>(() => preferences.SetAsync("screen.setting", value.RootElement, default), "écriture future protégée");
        Check.Equal(original, await File.ReadAllTextAsync(path), "source conservée à l’identique");
        Check.False(File.Exists(path + ".illisible"), "une version future n’est pas un document corrompu");
    }

    [Test]
    public static void Text_document_reads_are_bounded_strict_UTF8_and_HTML_stays_inert()
    {
        using var folder = new TemporaryFolder();
        var browser = new LocalFileBrowser([new("Documents", folder.Path)], _ => DriveType.Fixed);
        foreach (var kind in new[] { "html", "txt" })
        {
            var path = folder.File("read." + kind);
            const string content = "<script>throw new Error('must stay text')</script>État du poste";
            File.WriteAllText(path, content, new UTF8Encoding(true));
            var request = JsonSerializer.SerializeToElement(new { path, kind });
            Check.Equal((path, kind), ShellHostArguments.Read(request), "type admis par la frontière hôte");
            var read = browser.Read(path, kind);
            Check.Equal(content, read.Text, "HTML/texte transmis comme texte, sans exécution ni substitution");
            Check.Equal(kind, read.Kind, "nature conservée");
            Check.True(read.Rows.IsEmpty, "aucune interprétation CSV implicite");
            File.WriteAllBytes(path, [0xC3, 0x28]);
            Check.Equal(ShellErrors.FileUnreadable, Check.Throws<DomeniaOperationException>(() => browser.Read(path, kind), "UTF-8 invalide").Code, "aucun remplacement silencieux");
            File.WriteAllBytes(path, new byte[LocalFileBrowser.MaxFileBytes + 1]);
            Check.Equal(ShellErrors.FileUnreadable, Check.Throws<DomeniaOperationException>(() => browser.Read(path, kind), "lecture bornée").Code, "budget avant allocation");
        }
    }

    [Test]
    public static void Native_sqlite_imports_have_one_owner_and_load_only_from_windows()
    {
        var imports = typeof(DomeniaDatabase).Assembly.GetTypes().SelectMany(t => t.GetMethods(BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic))
            .Select(m => (Method: m, Import: m.GetCustomAttribute<DllImportAttribute>()))
            .Where(x => x.Import?.Value.Contains("sqlite", StringComparison.OrdinalIgnoreCase) == true).ToArray();
        Check.True(imports.Length >= 10, "vraie couche native embarquée");
        Check.Equal(1, imports.Select(x => x.Method.DeclaringType).Distinct().Count(), "une seule couche de bindings, aucun worker parallèle");
        Check.True(imports.All(x => x.Import!.Value == "winsqlite3.dll"), "DLL système unique");
        Check.True(imports.All(x => x.Method.GetCustomAttribute<DefaultDllImportSearchPathsAttribute>()?.Paths == DllImportSearchPath.System32), "résolution exclusivement Windows, pas DLL du dossier courant");
    }

    [Test]
    public static async Task Document_receipt_follows_complete_readback_and_refusals_never_replace_existing_files()
    {
        using var folder = new TemporaryFolder();
        var exports = folder.File("new/exports");
        var store = new FileDocumentStore(exports, new RecordingJournal(), (_, _) => { });
        var bytes = Encoding.UTF8.GetBytes("État du poste\n\u20ac");
        var saved = await store.SaveFileAsync("releve.txt", bytes, default);
        Check.True(saved.Saved, "reçu après relecture");
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(saved.Path!)), "octets UTF-8 intacts");
        foreach (var name in new[] { "../x.txt", "x.txt.", "CON.txt", "aux.txt", "LPT1.csv", "x.exe", "x.txt " })
            await Check.ThrowsAsync<ArgumentException>(() => store.SaveFileAsync(name, bytes, default), "nom non publiable refusé : " + name);
        await Check.ThrowsAsync<ArgumentException>(() => store.SaveFolderAsync("double", [new("a.txt", bytes), new("A.TXT", bytes)], default), "doublon Windows refusé avant création");
        using var stop = new CancellationTokenSource(); stop.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => store.SaveFileAsync("cancel.txt", bytes, stop.Token), "annulation avant écriture");
        Check.Equal(1, Directory.EnumerateFileSystemEntries(exports).Count(), "aucun résidu ni dossier publié par refus");
        var next = await store.SaveFileAsync("releve.txt", Encoding.UTF8.GetBytes("autre"), default);
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(saved.Path!)), "original jamais remplacé");
        Check.True(next.Path != saved.Path, "nom distinct confirmé");
        Check.True(FileDocumentStore.CheckLocalFolder("relative") is not null, "chemin relatif refusé sans résolution implicite");
    }

    [Test]
    public static async Task Linked_ancestor_of_a_document_is_refused_before_creating_a_child()
    {
        using var folder = new TemporaryFolder();
        Directory.CreateDirectory(folder.File("target"));
        // Windows CI is administrative; this scenario requires its ordinary symlink privilege.
        Directory.CreateSymbolicLink(folder.File("alias"), folder.File("target"));
        try
        {
            var store = new FileDocumentStore(folder.File("alias/exports"), new RecordingJournal());
            await Check.ThrowsAsync<DocumentStoreException>(() => store.SaveFileAsync("read.txt", new byte[] { 1, 2 }, default), "parent redirigé refusé");
            Check.False(Directory.Exists(folder.File("target/exports")), "aucune écriture à travers l’ancêtre redirigé");
            Check.False(await store.RevealAsync("read.txt", default), "aucune ouverture à travers le lien");
        }
        finally { Directory.Delete(folder.File("alias")); }
    }

    [Test]
    public static async Task Location_uses_actual_selection_and_never_creates_a_database_while_displaying_it()
    {
        using var folder = new TemporaryFolder();
        foreach (var mode in new[] { "UserLocal", "Portable", "Compatible" })
        {
            var app = folder.File(mode + "/wad"); var user = folder.File(mode + "/profile"); Directory.CreateDirectory(app);
            await File.WriteAllTextAsync(Path.Combine(app, "Domenia.config.json"), "{\"LocalStore\":{\"Mode\":\"" + mode + "\"}}");
            if (mode == "Compatible") { Directory.CreateDirectory(Path.Combine(app, "data")); await File.WriteAllTextAsync(Path.Combine(app, "data", "kept.txt"), "original"); }
            var cache = new CompatibleDirectoryCache(app, user, "test.local", TestClock.Fixed());
            var location = await cache.LocationAsync(default); var database = await cache.DatabaseAsync(default);
            Check.Equal(database.Path, location.Path, "emplacement exact sélectionné");
            Check.Contains(mode, location.Mode, "mode demandé visible");
            Check.Contains(mode == "UserLocal" ? "profil utilisateur" : "portable", location.Mode, "emplacement effectif annoncé");
            Check.Equal("À créer", location.State, "absence annoncée sans création");
            Check.False(File.Exists(database.Path), "lecture seule");
            await database.InitializeAsync(default);
            Check.Equal("Lecture disponible", (await cache.LocationAsync(default)).State, "accessibilité réellement lue");
        }
        var policy = DataPolicyRules.Build(StoragePolicyRules.Default, false,
            new(null, null, null, null, null, null, null, false, false) { StorageMode = "Non vérifié" });
        Check.True(policy.Rows.Any(r => r.Category == "configuration") && policy.Rows.Any(r => r.Category == "exports"), "catégories distinctes");
        Check.Contains("non déterminé", policy.Rows.Single(r => r.Category == "directory").Location, "chemin inconnu jamais inventé");
    }

    [Test]
    public static async Task Native_locked_read_is_an_error_and_a_missing_database_remains_absent()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("actual.db"), Fixtures.Root, TestClock.Fixed());
        Check.Null(await database.ReadDirectoryAsync(default), "base absente seulement : aucun relevé");
        Check.False(File.Exists(database.Path), "la consultation ne crée rien");
        var wrongPath = folder.File("directory.db"); Directory.CreateDirectory(wrongPath);
        var wrong = new DomeniaDatabase(wrongPath, Fixtures.Root, TestClock.Fixed());
        await Check.ThrowsAsync<IOException>(() => wrong.ReadDirectoryAsync(default), "chemin occupé par un dossier : erreur, pas absence");
        await database.InitializeAsync(default);
        var activity = new OperationActivity(TestClock.Fixed(), new RecordingJournal(), false); activity.ConfigureSqliteTimeout(100);
        database.ConfigureSession(activity);
        using (var blocker = new SqliteDatabase(database.Path, false))
        {
            blocker.Script("BEGIN EXCLUSIVE;");
            var error = await Check.ThrowsAsync<SqliteStoreException>(() => database.ReadDirectoryAsync(default), "verrou jamais traduit en null ou liste vide");
            Check.True(error.Busy, "cause occupée reconnue");
            Check.Equal(1, activity.SqliteBusy.Count, "attente attribuée à la session");
            blocker.Script("ROLLBACK;");
        }
        Check.Null(await database.ReadDirectoryAsync(default), "relecture explicite après libération");
        Check.True(new SqliteStoreException(517, "snapshot").Busy && new SqliteStoreException(262, "shared cache").Busy, "codes étendus de contention reconnus");
        using var read = new SqliteDatabase(database.Path, true);
        Check.Throws<SqliteStoreException>(() => read.Execute("CREATE TABLE unexpected(value TEXT);"), "connexion de lecture incapable de modifier la base");
        const string input = "'); DROP TABLE schema_info; --";
        Check.Equal(input, read.Scalar("SELECT ?1;", input) as string, "valeur liée et jamais exécutée");
        Check.Equal(1L, (long)read.Scalar("SELECT count(*) FROM sqlite_master WHERE name=?1;", "schema_info")!, "schéma intact");
    }

    [Test]
    public static async Task Future_library_and_wrong_contracts_are_refused_before_any_projection_or_write()
    {
        Check.Equal(ContractCatalog.All.Length, ContractCatalog.All.Select(c => c.Id).Distinct().Count(), "catalogue fermé sans identifiants ambigus");
        foreach (var contract in ContractCatalog.All)
            Check.Equal(ContractReadDecision.Read, ContractCatalog.Decide(contract.Id, contract.Current).Decision, "version courante : " + contract.Id);
        Check.Equal(ContractReadDecision.Newer, ContractCatalog.Decide("query", "Domenia.Query/999").Decision, "version future");
        Check.Equal(ContractReadDecision.TooOld, ContractCatalog.Decide("board", "Domenia.BoardLayout.0").Decision, "ancienne version inconnue");
        Check.Equal(ContractReadDecision.Unexpected, ContractCatalog.Decide("board", "Domenia.Query/4").Decision, "autre famille");
        Check.Equal(ContractReadDecision.Unknown, ContractCatalog.Decide("absent", "x/1").Decision, "contrat hors catalogue");
        Check.Equal(ContractReadDecision.Unreadable, ContractCatalog.Decide("query", "\n").Decision, "en-tête invalide");
        Check.Equal(ContractReadDecision.Migrate, ContractCatalog.Decide("query", "Domenia.Query/1").Decision, "reprise explicitement déclarée");
        using var store = new MemoryQueryLibraryStore(); using var library = QueryLibrarySnapshotTests.Library(store);
        var recipe = QueryLibrarySnapshotTests.Recipe("version.test");
        await library.SaveAsync(Fixtures.Root, recipe, null, null, 0, "update", null, default);
        var key = QueryLibrary.RootKey(Fixtures.Root); var original = (await store.ReadAsync(key, default))!;
        var future = JsonNode.Parse(original)!.AsObject(); future["version"] = 99;
        var bytes = Encoding.UTF8.GetBytes(future.ToJsonString()); await store.UpdateAsync(key, _ => new(bytes, false), default);
        await Check.ThrowsAsync<QueryDefinitionException>(() => library.ReadAsync(Fixtures.Root, default), "aucune ligne d’une version future publiée");
        await Check.ThrowsAsync<QueryDefinitionException>(() => library.SaveAsync(Fixtures.Root, recipe, null, null, 1, "update", null, default), "aucune rétrogradation par mutation");
        var after = await store.ReadAsync(key, default); Check.True(bytes.SequenceEqual(after!), "original futur inchangé");
    }
}
