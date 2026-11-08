using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class DirectoryProgressiveStorageTests
{
    private static readonly ScopeSelection Scope = new(Fixtures.Postes, "Postes", true);

    [Test]
    public static async Task Pages_are_really_committed_and_reread_before_the_next_page_and_a_later_failure_keeps_them()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var database = new DomeniaDatabase(folder.File("pages.db"), Fixtures.Root, clock); await database.InitializeAsync(default);
        var cache = new SqliteDirectoryCache(database);
        using var ldap = new PageConnection { Computers = [.. Enumerable.Range(0, 235).Select(i => Fixtures.Computer("PC" + i))], FailAfterPage = 1 };
        ldap.AfterPage = async page =>
        {
            var cold = new DomeniaDatabase(database.Path, Fixtures.Root, clock);
            var known = await cold.ReadDirectoryAsync(default, true);
            Check.Equal(120 * page, known!.Computers.Length, "toutes les tranches de la page précédente sont durables avant la suite LDAP");
            Check.False(known.Complete, "une page n’est pas un recensement complet");
            using var read = new SqliteDatabase(database.Path, true);
            Check.True(read.Query("SELECT items FROM domenia_v2_batches;").All(row => (long)row["items"]! <= 100), "tranches réelles de cent objets maximum");
        };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: ldap, localStore: cache);
        await Check.ThrowsAsync<IOException>(() => source.RefreshAsync(MeasureFamily.Directory, Scope, default), "perte de la deuxième page LDAP");
        var local = await source.ReadLocalAsync(default);
        Check.Equal(120, local.Directory.Computers.Length, "pages acquittées accessibles sans recommencer la collecte");
        Check.False(local.Directory.Complete, "relevé interrompu explicitement incomplet");
        Check.Null(local.DirectoryCommit, "pas de reçu de recensement final inventé");
        Check.Equal(1, ldap.Pages, "la panne ne déclenche aucune reprise implicite");
    }

    [Test]
    public static async Task Final_publication_reads_committed_fields_and_excludes_retained_absences()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var database = new DomeniaDatabase(folder.File("readback.db"), Fixtures.Root, clock); await database.InitializeAsync(default);
        var computer = Fixtures.Computer("PC1") with { Description = "Valeur AD antérieure non redemandée", Location = "Atelier" };
        var absent = Fixtures.Computer("PC-ABSENT");
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [computer, absent]), new(Fixtures.Root, "", true), "DC1", default);
        clock.Advance(TimeSpan.FromMinutes(1));
        using var ldap = new PageConnection { Computers = [computer] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: ldap, localStore: new SqliteDirectoryCache(database));
        var result = await source.RefreshAsync(MeasureFamily.Directory, Scope, default);
        Check.True(result.Directory.Complete, "le passage terminé et relu porte sa complétude");
        Check.Equal(1, result.Directory.Computers.Length, "l’absence conservée en base ne gonfle pas le nouveau recensement");
        Check.Equal(computer.Description, result.Directory.Computers.Single().Description, "valeur de la fusion SQLite, absente de la réponse LDAP de fixture");
        Check.True(result.DirectoryCommit!.Receipt.Matches(database.StoreId, Fixtures.Root, Scope, result.Directory, clock.GetUtcNow()), "reçu global qualifié contre la projection réellement relue");
        Check.Equal(2, (await database.ReadDirectoryAsync(default, true))!.Computers.Length, "absence conservée dans l’historique local");
    }

    [Test]
    public static async Task Stored_read_refuses_a_forged_receipt_or_a_newer_object_instead_of_publishing_the_old_ldap_value()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var database = new DomeniaDatabase(folder.File("proof.db"), Fixtures.Root, clock); var cache = new SqliteDirectoryCache(database);
        var submitted = Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]) with { Coverage = Scope };
        var receipt = await cache.SaveWithReceiptAsync(submitted, Scope, "DC1", default);
        await Check.ThrowsAsync<InvalidDataException>(() => cache.ReadStoredAsync(submitted, receipt with { Revision = receipt.Revision + 1 }, default), "vrai reçu relu depuis SQLite");
        clock.Advance(TimeSpan.FromMinutes(1));
        await cache.SaveObjectsAsync(submitted with { ReadAt = clock.GetUtcNow(), Complete = false }, "DC1", default);
        await Check.ThrowsAsync<InvalidDataException>(() => cache.ReadStoredAsync(submitted, receipt, default), "valeur plus récente non réétiquetée avec l’ancienne date");
    }

    [Test]
    public static async Task Opening_the_real_OU_picker_stores_its_read_before_publishing_a_tree()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var database = new DomeniaDatabase(folder.File("tree.db"), Fixtures.Root, clock);
        using var ldap = new AdBoundaryTests.RecordingAdConnection { Ous = [new(Fixtures.Postes,
            new Dictionary<string, IReadOnlyList<object>> { ["objectGUID"] = [Guid.NewGuid().ToByteArray()], ["ou"] = ["Postes"] })] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: ldap, localStore: new SqliteDirectoryCache(database));
        using var picker = new AdDirectoryTreeReader(source);
        _ = await picker.RootAsync(default);
        var stored = await new DomeniaDatabase(database.Path, Fixtures.Root, clock).ReadDirectoryAsync(default, true);
        Check.True(stored!.OrganizationalUnits.Any(o => o.DistinguishedName == Fixtures.Postes), "OU issue du sélecteur réellement conservée après réouverture");
        Check.False(stored.Complete, "l’arbre n’est pas une lecture complète de comptes et postes");
    }

    [Test]
    public static async Task Empty_batch_identity_and_oversized_preexisting_stage_refuse_without_any_local_mutation()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var database = new DomeniaDatabase(folder.File("stage.db"), Fixtures.Root, clock); await database.InitializeAsync(default);
        var snapshot = Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]) with { Coverage = Scope };
        await Check.ThrowsAsync<ArgumentException>(() => database.SaveDirectoryAsync(Guid.Empty.ToString("D"), snapshot, Scope, "DC1", default), "lot sans identité refusé avant staging");
        Check.False(Directory.Exists(folder.File("Staging")), "aucun stage sans identité");
        var id = Guid.NewGuid().ToString("D"); Directory.CreateDirectory(folder.File("Staging"));
        var path = folder.File("Staging/" + id + ".jsonl");
        using (var stage = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) stage.SetLength(64L * 1024 * 1024);
        await Check.ThrowsAsync<InvalidDataException>(() => database.SaveDirectoryAsync(id, snapshot, Scope, "DC1", default), "taille réelle différente refusée avant hachage du stage étranger");
        using var sql = new SqliteDatabase(database.Path, true);
        Check.Equal(0L, (long)sql.Scalar("SELECT count(*) FROM domenia_v2_batches;")!, "aucun reçu erroné");
        Check.Equal(0L, (long)sql.Scalar("SELECT count(*) FROM domenia_v2_objects;")!, "aucun objet partiellement inséré");
        Check.Equal(64L * 1024 * 1024, new FileInfo(path).Length, "stage antérieur conservé pour examen");
    }

    [Test]
    public static async Task Several_native_pages_share_one_verified_backup_handle_and_release_it_after_final_readback()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var database = new DomeniaDatabase(folder.File("many-pages.db"), Fixtures.Root, clock);
        using var ldap = new PageConnection { Computers = [.. Enumerable.Range(0, 601).Select(i => Fixtures.Computer("PC" + i))] };
        var checkedPages = 0; string? backupPath = null;
        ldap.AfterPage = page =>
        {
            Check.True(database.HasOperationsLease, "preuve détenue pendant chaque page");
            backupPath ??= Directory.GetFiles(folder.File("Backups"), "*.db").Single();
            Check.Throws<IOException>(() => { using var denied = new FileStream(backupPath, FileMode.Open, FileAccess.Write, FileShare.ReadWrite); },
                "la sauvegarde vérifiée ne peut pas changer pendant la réutilisation de son empreinte");
            checkedPages++; return Task.CompletedTask;
        };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: ldap, localStore: new SqliteDirectoryCache(database));
        var state = await source.RefreshAsync(MeasureFamily.Directory, Scope, default);
        Check.Equal(6, checkedPages, "plusieurs pages réellement remises");
        Check.Equal(601, state.Directory.Computers.Length, "aucun objet perdu entre tranches et publication finale");
        Check.True(state.Directory.CoversScope(Scope), "reçu final complet dans le périmètre");
        Check.False(database.HasOperationsLease, "lease rendue après dernière relecture");
        using var released = new FileStream(backupPath ?? throw new TestFailureException("Sauvegarde jamais observée."), FileMode.Open, FileAccess.ReadWrite, FileShare.None);
    }

    [Test]
    public static async Task Incomplete_account_status_read_keeps_local_history_without_publishing_a_zero_or_a_complete_receipt()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var database = new DomeniaDatabase(folder.File("status.db"), Fixtures.Root, clock); var cache = new SqliteDirectoryCache(database);
        var pc = Fixtures.Computer("PC1");
        var captured = Fixtures.Snapshot(computers: [pc]) with { Coverage = Scope };
        await cache.SaveAsync(captured, Scope, "DC1", default);
        clock.Advance(TimeSpan.FromMinutes(1));
        var entry = AdPosteNetworkTests.Entry(pc);
        var missing = new AdEntry(entry.DistinguishedName, entry.AttributeNames.Where(name => !name.Equals("userAccountControl", StringComparison.OrdinalIgnoreCase))
            .ToDictionary(name => name, name => entry.Raw(name)), ["objectGUID", "objectSid", "userAccountControl"]);
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = request => request.Filter == AdDirectoryMapper.ComputerFilter ? [missing] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: ldap, localStore: cache);
        var state = await source.RefreshAsync(MeasureFamily.Directory, Scope, default);
        Check.Equal(1, state.Directory.Computers.Length, "historique conservé même si aucun objet de cette page n’est qualifié");
        Check.False(state.Directory.CoversScope(Scope), "pas de couverture complète inventée");
        Check.Null(state.DirectoryCommit, "aucune preuve de recensement complet");
        Check.Equal(captured.ReadAt, state.Directory.ObjectReadAt![pc.ObjectGuid], "ancienne date de mesure non rajeunie");
    }

    private sealed class PageConnection : IAdConnection
    {
        private readonly AdBoundaryTests.RecordingAdConnection inner = new();
        internal ImmutableArray<DirectoryComputer> Computers = [];
        internal int FailAfterPage = int.MaxValue;
        internal int Pages;
        internal Func<int, Task>? AfterPage;
        public string? Server => inner.Server;
        public Task<AdRootDse> RootDseAsync(CancellationToken token) => inner.RootDseAsync(token);
        public Task<AdEntry?> ReadAsync(string dn, IReadOnlyList<string> attributes, CancellationToken token) => inner.ReadAsync(dn, attributes, token);
        public async Task<IReadOnlyList<AdEntry>> SearchAsync(AdSearchRequest request, CancellationToken token)
        {
            if (request.Filter != AdDirectoryMapper.ComputerFilter) return [];
            var entries = Computers.Select(AdPosteNetworkTests.Entry).ToArray();
            if (request.PageReceived is null) return entries;
            Check.False(request.RetainEntries, "pas de deuxième tableau LDAP intégral quand les pages sont consommées");
            foreach (var page in entries.Chunk(120))
            {
                await request.PageReceived(page, token);
                Pages++;
                if (AfterPage is not null) await AfterPage(Pages);
                if (Pages == FailAfterPage) throw new IOException("Interruption LDAP de fixture après page acquittée.");
            }
            return [];
        }
        public Task ModifyAsync(string dn, IReadOnlyList<AdModification> modifications, CancellationToken token) => throw new InvalidOperationException();
        public Task RenameAsync(string dn, string parent, string rdn, CancellationToken token) => throw new InvalidOperationException();
        public Task AddAsync(string dn, IReadOnlyDictionary<string, IReadOnlyList<object>> attributes, CancellationToken token) => throw new InvalidOperationException();
        public Task DeleteAsync(string dn, CancellationToken token) => throw new InvalidOperationException();
        public void Dispose() => inner.Dispose();
    }
}
