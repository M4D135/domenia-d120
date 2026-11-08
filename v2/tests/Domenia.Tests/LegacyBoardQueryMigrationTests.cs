using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Store;

namespace Domenia.Tests;

internal static class LegacyBoardQueryMigrationTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private const string Sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private static QueryRecipe Recipe() => QueryRecipe.Empty() with { Name = "Postes activés", Clauses = [new("active", QueryOperator.Equal, QueryValue.FromBoolean(true))] };
    private static QueryLibrary Library() => new(new MemoryQueryLibraryStore(), new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
    private static LegacyBoardPreview Preview(string board, string id, string consumer = "d1", bool paused = false) => LegacyBoardLayouts.Parse(
        JsonSerializer.SerializeToElement(new Dictionary<string, string> { ["Dashboard." + board + ".Layout"] =
            JsonSerializer.Serialize(new[] { new { Id = consumer, Source = "Query", Key = id, Paused = paused } }) }), @"C:\D1\Preferences\Domenia.settings.json", Sha);
    private static LegacyBoardProposal Selected(LegacyBoardPreview p, string board) => p.Boards.Single(b => b.Board == board);

    [Test]
    public static async Task Library_alone_never_creates_widgets_and_queries_without_a_binding_require_explicit_confirmation()
    {
        using var library = Library();
        var saved = await library.SaveAsync(Fixtures.Root, Recipe(), null, null, 0, "update", null, None);
        var content = await library.ReadAsync(Fixtures.Root, None);
        var empty = LegacyBoardLayouts.Parse(JsonSerializer.SerializeToElement(new Dictionary<string, string> { ["Dashboard.Computer.Layout"] = "[]" }), @"C:\D1\settings.json", Sha);
        Check.Equal(0, Selected(LegacyBoardLayouts.BindQueries(empty, content, Fixtures.Root), "Computer").Count, "aucune carte déduite de la bibliothèque");
        foreach (var board in new[] { "Computer", "Fleet" })
        {
            var before = Preview(board, saved.Record.Id);
            Check.Equal("needsQueryBinding", Selected(before, board).State, "pas de ready trompeur");
            var ready = LegacyBoardLayouts.BindQueries(before, content, Fixtures.Root);
            var proposal = Selected(ready, board);
            Check.Equal("ready", proposal.State, "révision réelle proposée");
            Check.True(proposal.Items[0].QueryBinding!.CurrentRevisionProposed, "absence de liaison D1 explicitée");
            using var folder = new TemporaryFolder();
            var path = folder.File("preferences.json");
            using var store = new FilePreferenceStore(path, new RecordingJournal());
            await Check.ThrowsAsync<InvalidDataException>(() => LegacyBoardLayouts.ApplyAsync(ready, board, Sha, store, TestClock.Reference, None), "empreinte de liaison non confirmée");
            Check.False(File.Exists(path), "simple aperçu et refus n’écrivent rien");
            Check.True(await LegacyBoardLayouts.ApplyAsync(ready, board, Sha, store, TestClock.Reference, None,
                expectedQueryBindingsSha256: proposal.QueryBindingsSha256), "geste explicite lie seulement la révision proposée");
            var key = board == "Fleet" ? LegacyBoardLayouts.EvidenceKey : PosteBoardLayouts.EvidenceKey(board);
            Check.True(store.TryGet(key, out var evidence), "preuve atomique de liaison");
            Check.Equal(proposal.QueryBindingsSha256, evidence.GetProperty("queryBindingsSha256").GetString(), "empreinte confirmée persistée");
        }
        Check.Equal(0, (await library.ReadAsync(Fixtures.Root, None)).Widgets.Count, "aucun widget ni droit créé dans la bibliothèque");
    }

    [Test]
    public static async Task Exact_legacy_consumer_keeps_its_old_revision_and_two_revisions_never_share_a_render_key()
    {
        using var library = Library();
        var first = await library.SaveAsync(Fixtures.Root, Recipe(), null, null, 0, "update", null, None);
        await library.SaveAsync(Fixtures.Root, first.Record.Recipe, "Révisée", null, 1, "update", null, None);
        var content = await library.ReadAsync(Fixtures.Root, None);
        content = content with { Consumers = [new("legacyComputer", "old", first.Record.Id, 1, "Ancienne", null, TestClock.Reference)] };
        var old = Selected(LegacyBoardLayouts.BindQueries(Preview("Computer", first.Record.Id, "old"), content, Fixtures.Root), "Computer").Items[0];
        var current = Selected(LegacyBoardLayouts.BindQueries(Preview("Computer", first.Record.Id, "new"), content, Fixtures.Root), "Computer").Items[0];
        Check.Equal(1L, old.QueryBinding!.Revision, "liaison exacte par ID de carte");
        Check.False(old.QueryBinding.CurrentRevisionProposed, "aucune substitution par la plus récente");
        Check.Equal(2L, current.QueryBinding!.Revision, "carte sans lien propose explicitement la révision actuelle");
        Check.False(old.Key == current.Key, "deux révisions ont deux clés de calcul");
        Check.Equal(2, PosteBoardLayouts.Normalize("Computer", [old, current]).Length, "les deux vrais consommateurs coexistent");
    }

    [Test]
    public static async Task Changed_library_after_preview_is_refused_inside_the_destination_mutex_without_any_preference_commit()
    {
        using var library = Library();
        var first = await library.SaveAsync(Fixtures.Root, Recipe(), null, null, 0, "update", null, None);
        var source = Preview("Computer", first.Record.Id);
        var preview = LegacyBoardLayouts.BindQueries(source, await library.ReadAsync(Fixtures.Root, None), Fixtures.Root);
        await library.SaveAsync(Fixtures.Root, first.Record.Recipe, "Autre révision", null, 1, "update", null, None);
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var store = new FilePreferenceStore(path, new RecordingJournal());
        var checkedUnderLock = false;
        await Check.ThrowsAsync<InvalidDataException>(() => LegacyBoardLayouts.ApplyAsync(preview, "Computer", Sha, store, TestClock.Reference, None,
            qualifySources: token =>
            {
                checkedUnderLock = true;
                var current = LegacyBoardLayouts.BindQueries(source, library.ReadAsync(Fixtures.Root, token).GetAwaiter().GetResult(), Fixtures.Root);
                LegacyBoardLayouts.ConfirmPreview(preview, current, "Computer");
                throw new TestFailureException("empreinte changée non détectée");
            }, expectedQueryBindingsSha256: Selected(preview, "Computer").QueryBindingsSha256), "changement pendant l’attente refusé");
        Check.True(checkedUnderLock, "qualification réellement invoquée par FilePreferenceStore");
        Check.False(File.Exists(path), "aucune disposition ni preuve partielle");
        Check.False(store.TryGet(PosteBoardLayouts.PreferenceKey("Computer"), out _), "aucun état mémoire optimiste");
    }

    [Test]
    public static async Task Binding_refuses_other_domain_missing_archived_or_corrupt_revision_and_pause()
    {
        using var library = Library();
        var saved = await library.SaveAsync(Fixtures.Root, Recipe(), null, null, 0, "update", null, None);
        var content = await library.ReadAsync(Fixtures.Root, None);
        var ready = LegacyBoardLayouts.BindQueries(Preview("Computer", saved.Record.Id), content, Fixtures.Root);
        var item = Selected(ready, "Computer").Items[0];
        Check.Throws<InvalidDataException>(() => BoardQueryBindings.Resolve(item.QueryBinding!, item.Key, content, "DC=other,DC=test", "Computer"), "autre domaine refusé");
        Check.Throws<InvalidDataException>(() => BoardQueryBindings.Resolve(item.QueryBinding! with { Fingerprint = Sha }, item.Key, content, Fixtures.Root, "Computer"), "hash différent refusé");
        Check.Equal("incompatible", Selected(LegacyBoardLayouts.BindQueries(Preview("Computer", "absent"), content, Fixtures.Root), "Computer").State, "recette absente non inventée");
        var frozen = QueryRefreshRules.Freeze(content, [item], [], Fixtures.Root).Single();
        Check.Equal(item.QueryBinding!.Revision, frozen.Revision, "actualisation explicite garde la même révision");
        Check.Throws<DomeniaOperationException>(() => QueryRefreshRules.Confirm(content, frozen, "DC=other,DC=test"), "domaine requalifié au moment de l’actualisation");
        Check.Equal(0, QueryRefreshRules.Freeze(content, [item with { Paused = true }], [], Fixtures.Root).Length, "pause ne prépare aucune collecte");
        await library.ArchiveAsync(Fixtures.Root, saved.Record.Id, 1, None);
        Check.Equal("incompatible", Selected(LegacyBoardLayouts.BindQueries(Preview("Computer", saved.Record.Id), await library.ReadAsync(Fixtures.Root, None), Fixtures.Root), "Computer").State, "archive refusée entière");
    }

    [Test]
    public static async Task Real_computer_and_fleet_consumers_keep_pinned_revision_after_library_change_and_preference_roundtrip()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var store = new FilePreferenceStore(path, new RecordingJournal());
        var bridge = new SimulatedBridge(preferences: store);
        var session = await bridge.Source.GetSessionAsync(None);
        var root = session.Domain?.RootDn ?? throw new TestFailureException("Domaine de simulation absent pour la reprise Query.");
        await WorkingScope.From(bridge.Context).SetAsync(session, await RequetesOperationsTests.WorkstationsOuAsync(bridge), true, None);
        var library = RequetesServices.Library(bridge.Context);
        var saved = await library.SaveAsync(root, Recipe(), null, null, 0, "update", null, None);
        foreach (var board in new[] { "Computer", "Fleet" })
        {
            var ready = LegacyBoardLayouts.BindQueries(Preview(board, saved.Record.Id), await library.ReadAsync(root, None), root);
            Check.True(await LegacyBoardLayouts.ApplyAsync(ready, board, Sha, store, TestClock.Reference, None,
                expectedQueryBindingsSha256: Selected(ready, board).QueryBindingsSha256), "import explicite");
        }
        await library.SaveAsync(root, saved.Record.Recipe, "Nouvelle catégorie", null, 1, "update", null, None);
        var fleet = AccueilService.From(bridge.Context); fleet.ReloadStoredLayout();
        await fleet.SaveLayoutAsync(fleet.Layout().Items, None); fleet.ReloadStoredLayout();
        var item = fleet.Layout().Items.Single();
        Check.Equal(1L, item.QueryBinding!.Revision, "StoredItem conserve la liaison lors de toute sauvegarde");
        var boardResult = await fleet.BoardAsync(None);
        var entry = boardResult.Entries["query:" + item.Key];
        Check.True(entry.Measured, "vrai moteur du parc calcule la révision importée");
        Check.Contains("Révision 1", entry.Subtitle, "révision ancienne gardée");
        var pc = (await bridge.Source.ReadLocalAsync(None)).Directory.Computers.First();
        var arguments = JsonSerializer.Serialize(new { dn = pc.DistinguishedName, computer = pc.ObjectGuid, item = "d1" });
        var one = SimulatedBridge.Json(await bridge.CallAsync("poste.layout.query", arguments));
        Check.Equal(1L, one.GetProperty("revision").GetInt64(), "vrai handler Poste utilise la révision figée");
        Check.Equal(2L, one.GetProperty("currentRevision").GetInt64(), "nouvelle révision signalée sans adoption");
        await PosteBoardLayouts.SaveAsync(store, "Computer", PosteBoardLayouts.Read(store, "Computer").Items.Select(i => i with { Paused = true }).ToArray(), None);
        Check.Equal("error", (await bridge.CallAsync("poste.layout.query", arguments)).Kind, "pause appliquée côté serveur avant calcul");
        using var fresh = new FilePreferenceStore(path, new RecordingJournal());
        Check.Equal(1L, PosteBoardLayouts.Read(fresh, "Computer").Items.Single().QueryBinding!.Revision, "réouverture fidèle");
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune permission ou écriture réseau");
    }
}
