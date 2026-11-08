using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Bridge;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Store;

namespace Domenia.Tests;

internal static class QueryReferencePatchTests
{
    private static QueryRecipe Recipe(string id = "personal.reference", string name = "Référence") => QueryRecipe.Empty(id: id) with { Name = name };
    private static string Patch(QueryRecipe? recipe = null, long version = 1, string? root = null) => QueryReferenceCodec.Write("Références équipe", version,
        QueryLibrary.RootKey(root ?? Fixtures.Root), Fixtures.Now, [new(recipe ?? Recipe(), "Équipe", "Valeurs +33 ; alias|source ; O'Brian ; -12,34")]);
    private static QueryLibrary Library(IQueryLibraryStore store, TimeProvider? clock = null) => new(store, new OperationJournal(), clock ?? TestClock.Fixed(), new RecordingJournal());
    private static EngineContext Context() => new(new(AppMode.Directory, ModeReason.Argument, "Fixture locale sans réseau", null, "test.local", []),
        new LocalSource(), new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal());
    private sealed class LocalSource : IDirectorySource
    {
        public DirectorySourceKind Kind => DirectorySourceKind.ActiveDirectory;
        public Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken) => throw new TestFailureException("Aucune session réseau autorisée par cette fixture de stockage.");
        public Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken) => throw new TestFailureException("Aucune lecture annuaire dans un patch.");
        public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken cancellationToken) => throw new TestFailureException("Aucune collecte dans un patch.");
    }

    [Test]
    public static void Reference_codec_round_trips_literal_values_without_legacy_accent_or_CSV_rewriting()
    {
        var original = Recipe(name: "Alias | équipe ; +33 O'Brian") with
        {
            Clauses = [new("ldap:description", QueryOperator.Equal, QueryValue.FromText("Sans reponse | +33 ; O'Brian ; -12.34"))],
        };
        var patch = QueryReferenceCodec.Read(Patch(original), Fixtures.Now);
        Check.Equal(QueryRecipeJson.Write(original), QueryRecipeJson.Write(patch.Items.Single().Recipe), "toutes les valeurs de la définition sont conservées exactement");
        Check.Equal("Valeurs +33 ; alias|source ; O'Brian ; -12,34", patch.Items.Single().Description, "description conservée sans échappement tableur");
        Check.Equal(original.Id, patch.Items.Single().Recipe.Id, "identifiant stable");
    }

    [Test]
    public static void Reference_codec_refuses_unknown_fields_duplicates_wrong_application_modified_payload_and_oversize()
    {
        var text = Patch(); var root = JsonNode.Parse(text)!.AsObject();
        root["application"] = "AnotherProduct";
        Check.Contains("Application", Check.Throws<QueryDefinitionException>(() => QueryReferenceCodec.Read(root.ToJsonString(), Fixtures.Now), "autre application refusée").Message, "motif exact");
        root = JsonNode.Parse(text)!.AsObject(); root["payload"] = root["payload"]!.GetValue<string>() + " ";
        Check.Contains("SHA-256", Check.Throws<QueryDefinitionException>(() => QueryReferenceCodec.Read(root.ToJsonString(), Fixtures.Now), "octets modifiés refusés").Message, "le hash porte aussi les octets de métadonnées");
        foreach (var bad in new[] { text[..^1] + ",\"script\":\"anything\"}", text[..^1] + ",\"format\":\"Domenia.ReferencePatch/1\"}" })
        { Check.Contains("inconnu ou dupliqué", Check.Throws<QueryDefinitionException>(() => QueryReferenceCodec.Read(bad, Fixtures.Now), "contrat fermé").Message, "motif précis"); }
        Check.Contains("16 Mio", Check.Throws<QueryDefinitionException>(() => QueryReferenceCodec.Read(new string(' ', QueryReferenceCodec.MaxBytes + 1), Fixtures.Now), "borne avant parsing").Message, "limite réelle");
        Check.Contains("GUID", Check.Throws<QueryDefinitionException>(() => Patch(Recipe() with { ObjectIds = [Guid.NewGuid().ToString("D")] }), "pas de sélection d’identités de production").Message, "identités interdites");
        Check.Contains("500", Check.Throws<QueryDefinitionException>(() => QueryReferenceCodec.Write("Références équipe", 1, QueryLibrary.RootKey(Fixtures.Root), Fixtures.Now,
            Enumerable.Range(0, 501).Select(i => new QueryReferenceItem(Recipe("r" + i), "", ""))), "borne des recettes").Message, "limite exacte");
    }

    [Test]
    public static async Task Reference_SQLite_receipt_and_full_original_survive_restart_and_replay_preserves_local_corrections()
    {
        using var folder = new TemporaryFolder(); using var context = Context(); var access = new QueryReferenceAccess(context, () => { });
        var database = new DomeniaDatabase(folder.File("references.db"), Fixtures.Root, TestClock.Fixed()); await database.InitializeAsync(default);
        IQueryLibraryStore store = new SqliteDirectoryCache(database); using var library = Library(store);
        await library.SaveAsync(Fixtures.Root, Recipe("personal.unrelated", "Hors patch"), "Privé", "À conserver", 0, "update", null, default);
        var before = (await store.ReadAsync(QueryLibrary.RootKey(Fixtures.Root), default))!;
        var plan = await library.ExamineReferencePatchAsync(Fixtures.Root, Patch(), access, default);
        Check.Equal("new", plan.Items.Single().Status, "aperçu ajout réel");
        var result = await library.ApplyReferencePatchAsync(Fixtures.Root, plan.ExaminationId, new Dictionary<string, string> { ["personal.reference"] = "create" }, default);
        Check.True(result.ReadBack && result.Persisted && !result.AlreadyApplied, "preuve relue dans SQLite");
        using (var raw = new SqliteDatabase(database.Path, true))
        {
            var saved = raw.Query("SELECT document,sha256 FROM domenia_v2_query_library_archive;").Single();
            Check.True(((byte[])saved["document"]!).AsSpan().SequenceEqual(before), "original complet réellement sauvegardé, pas seulement métadonnées");
            Check.Equal(QueryReferenceCodec.Hash(before), saved["sha256"] as string, "SHA sauvegarde relu");
        }
        var record = (await library.FindAsync(Fixtures.Root, "personal.reference", default))!;
        await library.SaveAsync(Fixtures.Root, record.Recipe with { Name = "Correction locale après import" }, null, null, record.Revision, "update", null, default);
        var current = (await store.ReadAsync(QueryLibrary.RootKey(Fixtures.Root), default))!;
        using var reopened = Library(new SqliteDirectoryCache(new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed())));
        var again = await reopened.ExamineReferencePatchAsync(Fixtures.Root, Patch(), access, default);
        Check.True(again.AlreadyApplied, "reçu retrouvé après redémarrage, malgré correction locale");
        var replay = await reopened.ApplyReferencePatchAsync(Fixtures.Root, again.ExaminationId, new Dictionary<string, string>(), default);
        Check.True(replay.AlreadyApplied && replay.ReadBack, "relecture du reçu sans nouvelle application");
        Check.Equal(result.Receipt.Id, replay.Receipt.Id, "même reçu durable");
        Check.True((await store.ReadAsync(QueryLibrary.RootKey(Fixtures.Root), default))!.AsSpan().SequenceEqual(current), "aucun octet de bibliothèque changé par le replay");
        Check.Equal(1, (await reopened.ReferenceHistoryAsync(Fixtures.Root, access, default)).Length, "pas de second reçu");
    }

    [Test]
    public static async Task Reference_preview_conflicts_preserve_IDs_links_and_records_absent_from_patch()
    {
        using var context = Context(); var access = new QueryReferenceAccess(context, () => { }); using var store = new MemoryQueryLibraryStore(); using var library = Library(store);
        var first = await library.SaveAsync(Fixtures.Root, Recipe(), "Mes corrections", "Locale", 0, "update", new("fleet", "kpi", "Mesure"), default);
        await library.SaveAsync(Fixtures.Root, Recipe("unrelated"), "Autre", "Pas dans le patch", 0, "update", null, default);
        var plan = await library.ExamineReferencePatchAsync(Fixtures.Root, Patch(Recipe(name: "Nom modifié explicitement")), access, default);
        Check.Equal("conflict", plan.Items.Single().Status, "renommage et métadonnées visibles comme conflit");
        Check.Equal("ignore", plan.Items.Single().DefaultAction, "aucun remplacement silencieux");
        Check.False(plan.Items.Single().AllowedActions.Contains("copy"), "l’identifiant de référence ne se duplique pas");
        await library.ApplyReferencePatchAsync(Fixtures.Root, plan.ExaminationId, new Dictionary<string, string> { [first.Record.Id] = "replace" }, default);
        var content = await library.ReadAsync(Fixtures.Root, default);
        Check.Equal(2, content.Records.Count, "absence du patch ne supprime rien");
        var after = content.Records.Single(r => r.Id == first.Record.Id);
        Check.Equal(2L, after.Revision, "même identifiant, révision suivante");
        Check.Equal(1L, content.Widgets.Single().BoundRevision, "pas de migration silencieuse d’une sonde liée");
        Check.Equal(first.Record.Name, QueryLibrary.RevisionRecipe(after, 1)!.Name, "ancienne définition toujours disponible pour la sonde");
        Check.Equal(1, store.KeptAside, "conservation demandée au support atomique");
    }

    [Test]
    public static async Task Reference_CAS_rejects_even_an_unrelated_concurrent_edit_without_partial_write()
    {
        using var folder = new TemporaryFolder(); using var context = Context(); var access = new QueryReferenceAccess(context, () => { });
        var database = new DomeniaDatabase(folder.File("cas.db"), Fixtures.Root, TestClock.Fixed()); await database.InitializeAsync(default);
        IQueryLibraryStore store = new SqliteDirectoryCache(database); using var library = Library(store);
        var plan = await library.ExamineReferencePatchAsync(Fixtures.Root, Patch(), access, default);
        await library.SaveAsync(Fixtures.Root, Recipe("different"), null, null, 0, "update", null, default);
        var before = (await store.ReadAsync(QueryLibrary.RootKey(Fixtures.Root), default))!.ToArray();
        var ex = await Check.ThrowsAsync<QueryDefinitionException>(() => library.ApplyReferencePatchAsync(Fixtures.Root, plan.ExaminationId,
            new Dictionary<string, string> { ["personal.reference"] = "create" }, default), "CAS document complet");
        Check.Contains("modifiée depuis l’aperçu", ex.Message, "motif discriminant");
        var after = await store.ReadAsync(QueryLibrary.RootKey(Fixtures.Root), default);
        Check.True(before.AsSpan().SequenceEqual(after), "échec sans état partiel");
        Check.Equal(0, (await library.ReferenceHistoryAsync(Fixtures.Root, access, default)).Length, "aucun faux reçu");
    }

    [Test]
    public static async Task Reference_SQLite_cancellation_at_commit_and_source_change_are_atomic()
    {
        using var folder = new TemporaryFolder(); using var context = Context(); using var stop = new CancellationTokenSource();
        var calls = 0; var cancelAtCommit = false;
        var access = new QueryReferenceAccess(context, () => { if (cancelAtCommit && ++calls == 4) { stop.Cancel(); } });
        var db = new DomeniaDatabase(folder.File("cancel.db"), Fixtures.Root, TestClock.Fixed()); await db.InitializeAsync(default);
        IQueryLibraryStore store = new SqliteDirectoryCache(db); using var library = Library(store);
        var plan = await library.ExamineReferencePatchAsync(Fixtures.Root, Patch(), access, default);
        calls = 0; cancelAtCommit = true;
        await Check.ThrowsAsync<OperationCanceledException>(() => library.ApplyReferencePatchAsync(Fixtures.Root, plan.ExaminationId,
            new Dictionary<string, string> { ["personal.reference"] = "create" }, stop.Token), "annulation à la vraie frontière SQLite");
        Check.Equal(4, calls, "le callback de commit a réellement été atteint");
        Check.True(await store.ReadAsync(QueryLibrary.RootKey(Fixtures.Root), default) is null, "aucune définition ni reçu après rollback");
        var stale = false; var changed = new QueryReferenceAccess(context, () => { if (stale) { throw new QueryDefinitionException("source changée fixture"); } });
        var preview = await library.ExamineReferencePatchAsync(Fixtures.Root, Patch(), changed, default); stale = true;
        var ex = await Check.ThrowsAsync<QueryDefinitionException>(() => library.ApplyReferencePatchAsync(Fixtures.Root, preview.ExaminationId, new Dictionary<string, string>(), default), "source périmée");
        Check.Contains("source changée fixture", ex.Message, "refus source exact");
    }

    [Test]
    public static async Task Reference_late_cancellation_after_SQLite_commit_keeps_and_rereads_the_receipt()
    {
        using var folder = new TemporaryFolder(); using var context = Context(); using var stop = new CancellationTokenSource();
        var database = new DomeniaDatabase(folder.File("late.db"), Fixtures.Root, TestClock.Fixed()); await database.InitializeAsync(default);
        var store = new CancelAfterCommit(new SqliteDirectoryCache(database), stop); using var library = Library(store);
        var access = new QueryReferenceAccess(context, () => { });
        var preview = await library.ExamineReferencePatchAsync(Fixtures.Root, Patch(), access, default);
        var result = await library.ApplyReferencePatchAsync(Fixtures.Root, preview.ExaminationId, new Dictionary<string, string> { ["personal.reference"] = "create" }, stop.Token);
        Check.True(store.Committed && stop.IsCancellationRequested, "annulation injectée après retour du commit réel");
        Check.True(result.ReadBack && result.Persisted, "preuve relue malgré l’annulation tardive");
        using var reopened = Library(new SqliteDirectoryCache(new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed())));
        Check.Equal(result.Receipt.Id, (await reopened.ReferenceHistoryAsync(Fixtures.Root, access, default)).Single().Id, "preuve durable conservée");
    }

    private sealed class CancelAfterCommit(IQueryLibraryStore inner, CancellationTokenSource stop) : IQueryLibraryStore
    {
        public bool Persistent => inner.Persistent;
        public bool Committed { get; private set; }
        public Task<byte[]?> ReadAsync(string rootKey, CancellationToken cancellationToken) => inner.ReadAsync(rootKey, cancellationToken);
        public async Task<QueryStoreWrite?> UpdateAsync(string rootKey, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken)
        {
            var result = await inner.UpdateAsync(rootKey, update, cancellationToken);
            Committed = result?.ReadBack == true; stop.Cancel(); return result;
        }
    }

    [Test]
    public static async Task Reference_old_versions_foreign_domain_expired_preview_and_cancelled_choice_write_nothing()
    {
        using var context = Context(); var access = new QueryReferenceAccess(context, () => { }); using var store = new MemoryQueryLibraryStore(); var clock = TestClock.Fixed(); using var library = Library(store, clock);
        var first = await library.ExamineReferencePatchAsync(Fixtures.Root, Patch(version: 2), access, default);
        await library.ApplyReferencePatchAsync(Fixtures.Root, first.ExaminationId, new Dictionary<string, string> { ["personal.reference"] = "create" }, default);
        var before = (await store.ReadAsync(QueryLibrary.RootKey(Fixtures.Root), default))!.ToArray();
        Check.Contains("périmée", (await Check.ThrowsAsync<QueryDefinitionException>(() => library.ExamineReferencePatchAsync(Fixtures.Root, Patch(version: 1), access, default), "ancien patch refusé")).Message, "version réelle");
        Check.Contains("autre domaine", (await Check.ThrowsAsync<QueryDefinitionException>(() => library.ExamineReferencePatchAsync(Fixtures.Root, Patch(root: "DC=elsewhere,DC=invalid"), access, default), "autre destination")).Message, "domaine exact");
        var fresh = await library.ExamineReferencePatchAsync(Fixtures.Root, Patch(version: 3), access, default);
        await library.DiscardReferencePreviewAsync(fresh.ExaminationId, default);
        await Check.ThrowsAsync<QueryDefinitionException>(() => library.ApplyReferencePatchAsync(Fixtures.Root, fresh.ExaminationId, new Dictionary<string, string>(), default), "annulation retire seulement l’aperçu");
        var expires = await library.ExamineReferencePatchAsync(Fixtures.Root, Patch(version: 3), access, default); clock.Advance(TimeSpan.FromMinutes(31));
        Check.Contains("expiré", (await Check.ThrowsAsync<QueryDefinitionException>(() => library.ApplyReferencePatchAsync(Fixtures.Root, expires.ExaminationId, new Dictionary<string, string>(), default), "expiration")).Message, "pas une erreur de contenu");
        var after = await store.ReadAsync(QueryLibrary.RootKey(Fixtures.Root), default);
        Check.True(before.AsSpan().SequenceEqual(after), "tous ces refus conservent les octets");
    }

    [Test]
    public static async Task Reference_demo_refuses_direct_bridge_and_service_calls_before_real_storage_access()
    {
        var bridge = new SimulatedBridge();
        foreach (var (operation, arguments) in new[]
        {
            ("requetes.pack.export", JsonSerializer.Serialize(new { reference = true, name = "Références équipe", version = 1, ids = new[] { "personal.reference" } })),
            ("requetes.pack.examine", JsonSerializer.Serialize(new { content = Patch() })),
            ("requetes.pack.apply", JsonSerializer.Serialize(new { reference = true, examinationId = new string('a', 32), choices = new { } })),
            ("requetes.reference.distribution.list", "{}"),
            ("requetes.reference.distribution.read", JsonSerializer.Serialize(new { id = new string('a', 32) })),
        })
        {
            var result = await bridge.CallAsync(operation, arguments);
            Check.Equal("error", result.Kind, "commande directe refusée : " + operation);
            if (operation.StartsWith("requetes.reference.distribution.", StringComparison.Ordinal))
            {
                Check.Equal(DomeniaErrors.SimulationUnavailable, result.Error!.Code, "le répartiteur refuse la lecture réelle avant le gestionnaire");
                Check.Equal(DomeniaErrors.SimulationUnavailableMessage, result.Error.Message, "motif exact de la garde d’admission");
            }
            else
            {
                Check.Equal(QueryErrors.Invalid, result.Error!.Code, "refus du moteur de références");
                Check.Contains("démonstration", result.Error.Message, "garde moteur réellement atteinte");
            }
        }
        // Also bypass the dispatcher: the service itself must still reject the simulated source before reading preferences or files.
        var distribution = QueryReferenceDistribution.From(bridge.Context);
        Check.Contains("démonstration", (await Check.ThrowsAsync<QueryDefinitionException>(() => distribution.ListAsync(default), "service de diffusion protégé sans répartiteur")).Message, "garde de mode avant lecture du dossier");
        Check.Contains("démonstration", (await Check.ThrowsAsync<QueryDefinitionException>(() => distribution.ReadAsync(new string('a', 32), default), "fichier réel refusé sans répartiteur")).Message, "garde de mode avant lecture du fichier");
        var guardReached = false;
        Check.Throws<QueryDefinitionException>(() => new QueryReferenceAccess(bridge.Context, () => { guardReached = true; }), "service protégé même sans pont");
        Check.False(guardReached, "aucun callback source ou stockage réel avant refus du mode");
    }

    [Test]
    public static async Task Reference_file_store_retains_actual_displaced_bytes_and_blocks_ambiguous_replay_after_restart()
    {
        using var folder = new TemporaryFolder(); using var context = Context();
        var store = new QueryLibraryFiles(folder.Path, false, new RecordingJournal()); using var library = Library(store);
        await library.SaveAsync(Fixtures.Root, Recipe("initial"), "Locale", null, 0, "update", null, default);
        var path = store.PathOf(QueryLibrary.RootKey(Fixtures.Root)); var original = File.ReadAllBytes(path);
        var raced = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(original) + " "); var calls = 0; var enabled = false;
        var access = new QueryReferenceAccess(context, () => { if (enabled && ++calls == 4) { File.WriteAllBytes(path, raced); } });
        var preview = await library.ExamineReferencePatchAsync(Fixtures.Root, Patch(), access, default); calls = 0; enabled = true;
        var ex = await Check.ThrowsAsync<QueryDefinitionException>(() => library.ApplyReferencePatchAsync(Fixtures.Root, preview.ExaminationId,
            new Dictionary<string, string> { ["personal.reference"] = "create" }, default), "écrivain non coopératif au dernier instant");
        Check.Equal(4, calls, "interleaving atteint juste avant remplacement physique");
        Check.Contains("réellement remplacé diffère", ex.Message, "fichier effectivement déplacé contrôlé");
        var backup = Directory.GetFiles(folder.Path, "*.previous").Single();
        Check.True(File.ReadAllBytes(backup).AsSpan().SequenceEqual(raced), "tous les octets concurrents conservés, aucune compensation");
        Check.Equal(1, Directory.GetFiles(folder.Path, "*.intent").Length, "intention durable encore présente");
        Check.Equal(0, Directory.GetFiles(folder.Path, "*.verified").Length, "aucun faux reçu de publication");
        enabled = false; using var restarted = Library(new QueryLibraryFiles(folder.Path, false, new RecordingJournal()));
        Check.Contains("non confirmée", (await Check.ThrowsAsync<QueryDefinitionException>(() => restarted.ExamineReferencePatchAsync(Fixtures.Root, Patch(), access, default), "reprise ambiguë bloquée après redémarrage")).Message, "aucun succès déduit du seul document final");
        Check.True(File.ReadAllBytes(backup).AsSpan().SequenceEqual(raced), "preuve encore intacte après refus");
    }

    [Test]
    public static async Task Reference_file_store_confirmed_write_has_reread_backup_and_durable_evidence()
    {
        using var folder = new TemporaryFolder(); using var context = Context(); var access = new QueryReferenceAccess(context, () => { });
        var store = new QueryLibraryFiles(folder.Path, false, new RecordingJournal()); using var library = Library(store);
        await library.SaveAsync(Fixtures.Root, Recipe("initial"), null, null, 0, "update", null, default);
        var before = File.ReadAllBytes(store.PathOf(QueryLibrary.RootKey(Fixtures.Root)));
        var preview = await library.ExamineReferencePatchAsync(Fixtures.Root, Patch(), access, default);
        var result = await library.ApplyReferencePatchAsync(Fixtures.Root, preview.ExaminationId, new Dictionary<string, string> { ["personal.reference"] = "create" }, default);
        Check.True(result.ReadBack, "publication vérifiée par relecture");
        Check.True(File.ReadAllBytes(Directory.GetFiles(folder.Path, "*.previous").Single()).AsSpan().SequenceEqual(before), "sauvegarde exacte");
        Check.Equal(1, Directory.GetFiles(folder.Path, "*.verified").Length, "preuve de vérification durable");
        using var reopened = Library(new QueryLibraryFiles(folder.Path, false, new RecordingJournal()));
        Check.Equal(result.Receipt.Id, (await reopened.ReferenceHistoryAsync(Fixtures.Root, access, default)).Single().Id, "reçu après réouverture");
    }

    [Test]
    public static async Task Reference_file_quota_includes_interrupted_preparations_and_never_cleans_them()
    {
        using var folder = new TemporaryFolder(); using var context = Context(); var access = new QueryReferenceAccess(context, () => { });
        var store = new QueryLibraryFiles(folder.Path, false, new RecordingJournal()); using var library = Library(store);
        var preview = await library.ExamineReferencePatchAsync(Fixtures.Root, Patch(), access, default);
        var path = store.PathOf(QueryLibrary.RootKey(Fixtures.Root));
        for (var i = 0; i < 509; i++) { File.WriteAllBytes(path + ".reference-" + i.ToString("D4") + ".prepared", [42]); }
        var ex = await Check.ThrowsAsync<QueryDefinitionException>(() => library.ApplyReferencePatchAsync(Fixtures.Root, preview.ExaminationId,
            new Dictionary<string, string> { ["personal.reference"] = "create" }, default), "admission bornée avant création supplémentaire");
        Check.Contains("512 preuves", ex.Message, "motif quota exact");
        Check.Equal(509, Directory.GetFiles(folder.Path).Length, "aucun ancien fichier effacé ni nouveau artefact créé");
        Check.False(File.Exists(path), "aucune bibliothèque partiellement publiée");
    }
}
