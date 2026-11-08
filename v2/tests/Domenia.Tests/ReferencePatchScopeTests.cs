using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.Tests;

internal static class ReferencePatchScopeTests
{
    private static string Text(string root, DateTimeOffset at) => QueryReferenceCodec.Write("Fixture", 1, QueryLibrary.RootKey(root), at,
        [new(QueryRecipe.Empty(id: "personal.fixture") with { Name = "Référence fixture" }, "Fixture", "Valeurs fictives")]);
    private static QueryLibrary Library(IQueryLibraryStore store, TimeProvider clock) => new(store, new OperationJournal(), clock, new RecordingJournal());
    private static string Hash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    [Test]
    public static async Task Reference_preview_expiring_at_the_commit_boundary_never_publishes_SQLite()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed(); using var source = new LocalDirectoryFixture(clock);
        using var context = Context(source, new MemoryPreferenceStore(), clock);
        var database = new DomeniaDatabase(folder.File("expires.db"), source.Root, clock); await database.InitializeAsync(default);
        IQueryLibraryStore store = new SqliteDirectoryCache(database); using var library = Library(store, clock);
        var enabled = false; var guards = 0;
        var access = new QueryReferenceAccess(context, () => { if (enabled && ++guards == 4) clock.Advance(TimeSpan.FromMinutes(31)); });
        var preview = await library.ExamineReferencePatchAsync(source.Root, Text(source.Root, clock.GetUtcNow()), access, default);
        enabled = true;
        var failure = await Check.ThrowsAsync<QueryDefinitionException>(() => library.ApplyReferencePatchAsync(source.Root, preview.ExaminationId,
            new Dictionary<string, string> { ["personal.fixture"] = "create" }, default), "préparation suspendue au-delà de la durée de l’aperçu");
        Check.Equal(4, guards, "frontière de commit effectivement atteinte"); Check.Contains("expiré pendant", failure.Message, "motif exact");
        Check.True(await store.ReadAsync(QueryLibrary.RootKey(source.Root), default) is null, "ni définition ni reçu commité après expiration");
    }

    [Test]
    public static void Reference_file_handles_pin_real_ancestors_and_refuse_wrong_types()
    {
        using var folder = new TemporaryFolder(); var parent = folder.File("parent"); Directory.CreateDirectory(parent);
        var path = Path.Combine(parent, "data.json"); File.WriteAllText(path, "{}");
        using (var pins = ReferenceFileAccess.PinParents(path))
        {
            Check.Throws<IOException>(() => Directory.Move(parent, folder.File("moved")), "parent réellement épinglé sans partage Delete");
            using var file = ReferenceFileAccess.OpenRead(path)!;
            Check.Throws<IOException>(() => File.WriteAllText(path, "changed"), "écrivain concurrent bloqué par le handle de lecture");
            Check.Throws<IOException>(() => File.Delete(path), "suppression concurrente bloquée");
        }
        Check.Throws<IOException>(() => ReferenceFileAccess.OpenRead(parent), "un répertoire n’est pas une copie de fichier");
        Check.True(ReferenceFileAccess.OpenRead(folder.File("absent"), allowMissing: true) is null, "absence qualifiée par ouverture native, pas File.Exists");
        Check.Equal("{}", File.ReadAllText(path), "octets conservés après refus");
        var moved = folder.File("released");
        Directory.Move(parent, moved);
        Check.Equal("{}", File.ReadAllText(Path.Combine(moved, "data.json")), "renommage permis après libération réelle des handles, sans modification des droits");
    }

    [Test]
    public static async Task Reference_demo_uses_real_preview_apply_and_receipt_in_the_same_memory_library()
    {
        var bridge = new SimulatedBridge(); var before = JsonSerializer.Serialize(bridge.Source.CurrentDirectory); var writes = ((MemoryPreferenceStore)bridge.Preferences).Writes;
        var prepared = await bridge.CallAsync("requetes.reference.demo.prepare", "{}");
        Check.Equal("result", prepared.Kind, "adaptateur de démonstration réel"); var plan = SimulatedBridge.Json(prepared);
        Check.True(plan.GetProperty("demonstration").GetBoolean(), "provenance fictive explicite");
        Check.Equal(2, plan.GetProperty("items").GetArrayLength(), "conflit et ajout proposés");
        Check.True(plan.GetProperty("items").EnumerateArray().Any(i => i.GetProperty("status").GetString() == "conflict"), "correction fictive existante à protéger");
        var choices = new Dictionary<string, string> { ["demo.reference.local"] = "replace", ["demo.reference.new"] = "create" };
        var applied = await bridge.CallAsync("requetes.pack.apply", JsonSerializer.Serialize(new { reference = true, examinationId = plan.GetProperty("examinationId").GetString(), choices }));
        Check.Equal("result", applied.Kind, "application par la même route de confirmation");
        var receipt = SimulatedBridge.Json(applied).GetProperty("receipt"); Check.True(receipt.GetProperty("readBack").GetBoolean(), "preuve relue en mémoire");
        Check.False(receipt.GetProperty("persisted").GetBoolean(), "aucune persistance réelle annoncée"); Check.Contains("données fictives", receipt.GetProperty("text").GetString(), "reçu qualifié");
        var library = RequetesServices.Library(bridge.Context); var root = bridge.Source.CurrentSession.Domain!.RootDn!;
        Check.Equal("Fictif — proposition de l’équipe", (await library.FindAsync(root, "demo.reference.local", default))!.Name, "la bibliothèque réellement affichée est modifiée");
        Check.True((await QueryReferenceDemo.HistoryAsync(bridge.Context, library, default)).Single().Simulated, "registre explicitement fictif");
        bridge.Clock.Advance(TimeSpan.FromDays(5));
        var replay = await bridge.CallAsync("requetes.reference.demo.prepare", "{}");
        Check.True(SimulatedBridge.Json(replay).GetProperty("alreadyApplied").GetBoolean(), "réensemencement stable malgré changement de date");
        Check.Equal(before, JsonSerializer.Serialize(bridge.Source.CurrentDirectory), "aucune mutation de l’annuaire même fictif par l’import");
        Check.Equal(writes, ((MemoryPreferenceStore)bridge.Preferences).Writes, "aucune préférence ni source de diffusion réelle utilisée");
    }

    [Test]
    public static async Task Reference_demo_cannot_reuse_its_capability_on_another_store_or_accept_external_input()
    {
        var bridge = new SimulatedBridge(); using var firstStore = new MemoryQueryLibraryStore(); using var secondStore = new MemoryQueryLibraryStore();
        using var first = Library(firstStore, bridge.Clock); using var second = Library(secondStore, bridge.Clock);
        var access = first.DemonstrationAccess(bridge.Context); var root = bridge.Source.CurrentSession.Domain!.RootDn!;
        var failure = await Check.ThrowsAsync<QueryDefinitionException>(() => second.ExamineReferencePatchAsync(root, Text(root, bridge.Clock.GetUtcNow()), access, default), "capacité liée à une instance mémoire précise");
        Check.Contains("autre magasin", failure.Message, "pas seulement Persistent=false");
        var input = await bridge.CallAsync("requetes.reference.demo.prepare", "{\"content\":\"external\",\"folder\":\"C:\\\\real\"}");
        Check.Equal("error", input.Kind, "adaptateur sans entrée libre");
        var spy = new NoReadStore(); using var real = Library(spy, bridge.Clock);
        await Check.ThrowsAsync<QueryDefinitionException>(() => QueryReferenceDemo.PrepareAsync(bridge.Context, real, default), "autre implémentation même déclarée non persistante refusée");
        Check.Equal(0, spy.Accesses, "aucun accès à un magasin réel déguisé");
    }
    private sealed class NoReadStore : IQueryLibraryStore
    {
        public bool Persistent => false; public int Accesses;
        public Task<byte[]?> ReadAsync(string rootKey, CancellationToken cancellationToken) { Accesses++; throw new TestFailureException("Lecture interdite"); }
        public Task<QueryStoreWrite?> UpdateAsync(string rootKey, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken) { Accesses++; throw new TestFailureException("Écriture interdite"); }
    }

    [Test]
    public static void Reference_distribution_checksum_contract_rejects_duplicates_traversal_and_partial_catalogs()
    {
        var sha = new string('a', 64);
        var valid = QueryReferenceDistribution.Checksums(Encoding.UTF8.GetBytes(sha + "  Domenia-reference-fixture-v1.json\n" + sha + " *Domenia_1.2.3_PROD_Windows-x64.zip\r\n"));
        Check.Equal(2, valid.Count, "même manifeste que les ZIP, empreintes strictes");
        foreach (var text in new[] { sha + "  ../escape.json\n", sha + "  CON.json\n", sha + "  patch.json\n" + sha + "  PATCH.json\n", sha + " patch.json\n" })
        { Check.Throws<QueryDefinitionException>(() => QueryReferenceDistribution.Checksums(Encoding.UTF8.GetBytes(text)), "catalogue ambigu ou invalide refusé"); }
        Check.Throws<QueryDefinitionException>(() => QueryReferenceDistribution.QualifiedFolder(@"C:\real\..\other"), "aucune normalisation de parcours ambigu");
    }

    [Test]
    public static async Task Reference_distribution_reads_exact_local_file_checks_catalog_CAS_and_writes_nothing_to_source()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed(); using var source = new LocalDirectoryFixture(clock); var preferences = new MemoryPreferenceStore();
        await preferences.SetAsync("updates.distributionFolder", JsonSerializer.SerializeToElement(folder.Path), default);
        using var context = Context(source, preferences, clock); var service = QueryReferenceDistribution.From(context);
        const string name = "Domenia-reference-fixture-v1.json"; var text = Text(source.Root, clock.GetUtcNow());
        File.WriteAllText(folder.File(name), text, new UTF8Encoding(false)); var sums = Hash(text) + "  " + name + "\n";
        File.WriteAllText(folder.File("SHA256SUMS.txt"), sums, new UTF8Encoding(false));
        var listed = await service.ListAsync(default); Check.Equal(1, listed.Offers.Length, "patch présent dans le catalogue réel");
        var preview = await service.ReadAsync(listed.Offers.Single().Id, default); Check.Equal(QueryReferenceCodec.Format, preview.Format, "fichier reçu et vérifié par le vrai codec");
        Check.Equal(2, Directory.GetFiles(folder.Path).Length, "aucune copie, preuve ou fichier temporaire sur la diffusion");
        Check.Equal(text, File.ReadAllText(folder.File(name)), "source intacte");
        await RequetesServices.Library(context).DiscardReferencePreviewAsync(preview.ExaminationId, default);
        listed = await service.ListAsync(default); File.AppendAllText(folder.File(name), " ");
        Check.Contains("SHA-256 du fichier", (await Check.ThrowsAsync<QueryDefinitionException>(() => service.ReadAsync(listed.Offers.Single().Id, default), "octets changés depuis liste")).Message, "SHA brut comparé au sidecar");
        File.WriteAllText(folder.File(name), text, new UTF8Encoding(false)); listed = await service.ListAsync(default);
        File.AppendAllText(folder.File("SHA256SUMS.txt"), "\n");
        Check.Contains("modifié depuis", (await Check.ThrowsAsync<QueryDefinitionException>(() => service.ReadAsync(listed.Offers.Single().Id, default), "catalogue changé sans changer ses entrées")).Message, "CAS catalogue octet pour octet");
        Check.Equal(0, (await RequetesServices.Library(context).ReadAsync(source.Root, default)).Records.Count, "lecture et refus ne publient aucune référence");
    }

    private static EngineContext Context(IDirectorySource source, IPreferenceStore preferences, TimeProvider clock)
        => new(new(AppMode.Directory, ModeReason.Argument, "Source locale de test", null, "example.local", []), source, preferences, clock, new RecordingJournal());
    private sealed class LocalDirectoryFixture(TimeProvider clock) : IDirectorySource, IDirectoryWriteLeaseSource, IDisposable
    {
        private readonly SimulatedDirectorySource inner = new(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        public string Root => inner.CurrentSession.Domain!.RootDn!;
        public DirectorySourceKind Kind => DirectorySourceKind.ActiveDirectory;
        public Task<SessionSnapshot> GetSessionAsync(CancellationToken token) => inner.GetSessionAsync(token);
        public Task<DirectoryState> ReadLocalAsync(CancellationToken token) => inner.ReadLocalAsync(token);
        public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken token) => throw new TestFailureException("Aucun accès réseau autorisé");
        public IDisposable AcquireWriteLease(SessionSnapshot expected)
        { if (expected.Epoch != inner.CurrentSession.Epoch) throw new QueryDefinitionException("epoch fixture changé"); return new Lease(); }
        private sealed class Lease : IDisposable { public void Dispose() { } }
        public void Dispose() { } // SimulatedDirectorySource owns only in-memory state and has no disposable contract.
    }
}
