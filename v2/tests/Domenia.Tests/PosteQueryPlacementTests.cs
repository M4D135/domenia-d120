using System.Text.Json;
using Domenia.Bridge;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Store;

namespace Domenia.Tests;

internal static class PosteQueryPlacementTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static QueryRecipe Recipe(string name = "Tous les postes") => QueryRecipe.Empty() with { Name = name };
    private static QueryLibrary Library() => new(new MemoryQueryLibraryStore(), new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
    private static QueryWidgetLink Widget(QuerySaveResult saved) => saved.Widget ?? throw new TestFailureException("Lien attendu.");
    private static Task<PosteQueryPlacement> Place(IPreferenceStore prefs, QueryLibrary library, QuerySaveResult saved) =>
        PosteQueryLayout.PlaceAsync(prefs, Fixtures.Root, Widget(saved), saved.Record.Fingerprint, () => library.ReadAsync(Fixtures.Root, None).GetAwaiter().GetResult(), None);
    private static async Task<JsonElement> Ok(SimulatedBridge bridge, string op, object args) =>
        SimulatedBridge.Json(await bridge.CallAsync(op, JsonSerializer.Serialize(args, BridgeJson.Options)));
    private static object SaveArgs(QueryRecipe recipe, string visual = "text") => new
    {
        recipe = JsonSerializer.Deserialize<JsonElement>(QueryRecipeJson.Write(recipe)), board = "computer", visual, title = "Ma carte", expectedRevision = 0,
    };

    [Test]
    public static async Task Explicit_empty_choice_gets_only_requested_card_and_retry_preserves_pause_order_and_title()
    {
        using var library = Library(); var prefs = new MemoryPreferenceStore();
        var older = await library.SaveAsync(Fixtures.Root, Recipe("Déjà liée"), null, null, 0, "update", new("computer", "kpi", "Ancienne"), None);
        var saved = await library.SaveAsync(Fixtures.Root, Recipe(), null, null, 0, "update", new("computer", "text", "Nouvelle"), None);
        await PosteBoardLayouts.SaveAsync(prefs, "Computer", [], None);
        Check.True((await Place(prefs, library, saved)).Applied, "ajout explicite");
        var item = PosteBoardLayouts.Read(prefs, "Computer").Items.Single();
        Check.Equal(Widget(saved).Id, item.QueryBinding!.LibraryWidgetId, "[] n’adopte aucun autre lien de la bibliothèque");
        Check.Equal("Text", item.Visual, "présentation réellement affichée");
        await PosteBoardLayouts.SaveAsync(prefs, "Computer", [item with { Paused = true, Title = "Mon titre", Group = "Dernier", Size = "L" }], None);
        await Place(prefs, library, saved);
        var again = PosteBoardLayouts.Read(prefs, "Computer").Items.Single();
        Check.True(again.Paused, "réessai ne reprend pas une carte en pause");
        Check.Equal("Mon titre", again.Title, "titre manuel conservé");
        Check.Equal("Dernier", again.Group, "section conservée");
        Check.Equal("L", again.Size, "taille conservée");
        var untouched = new MemoryPreferenceStore();
        await Place(untouched, library, saved);
        var initial = PosteBoardLayouts.Read(untouched, "Computer").Items;
        Check.Equal(PosteBoardLayouts.Defaults("Computer").Length + 2, initial.Length, "premier placement conserve les liens déjà affichés par la page sans disposition");
        Check.True(initial.Any(i => i.QueryBinding?.LibraryWidgetId == Widget(older).Id), "ancienne carte visible conservée");
    }

    [Test]
    public static async Task Latest_disk_choice_and_other_preferences_survive_stale_instances_and_concurrent_appends()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var first = new FilePreferenceStore(path, new RecordingJournal());
        using var second = new FilePreferenceStore(path, new RecordingJournal());
        await PosteBoardLayouts.SaveAsync(first, "Computer", [], None);
        Check.Equal(0, PosteBoardLayouts.Read(second, "Computer").Items.Length, "cache volontairement antérieur");
        var builtin = new FleetLayoutItem("mine", FleetWidgetSource.Builtin, "computer.os", "Text", "S", "Choix concurrent", true, "Section");
        await PosteBoardLayouts.SaveAsync(first, "Computer", [builtin], None);
        await first.SetAsync("other.choice", JsonSerializer.SerializeToElement("Préservé"), None);
        using var library = Library();
        var a = await library.SaveAsync(Fixtures.Root, Recipe("A"), null, null, 0, "update", new("computer", "kpi", "A"), None);
        var b = await library.SaveAsync(Fixtures.Root, Recipe("B"), null, null, 0, "update", new("computer", "text", "B"), None);
        await Task.WhenAll(Place(second, library, a), Place(first, library, b));
        using var fresh = new FilePreferenceStore(path, new RecordingJournal());
        var items = PosteBoardLayouts.Read(fresh, "Computer").Items;
        Check.Equal(3, items.Length, "deux ajouts plus le choix concurrent, aucun perdu");
        Check.Equal(builtin, items[0], "ordre et pause du dernier choix disque intacts");
        Check.True(fresh.TryGet("other.choice", out var other), "clé extérieure conservée");
        Check.Equal("Préservé", other.GetString(), "valeur extérieure intacte");
        Check.Equal(2, items.Count(i => i.QueryBinding is not null), "pas de doublon ni de recette inventée");
    }

    [Test]
    public static async Task An_open_editor_cannot_erase_a_concurrent_append_and_latest_read_allows_an_explicit_new_choice()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var editor = new FilePreferenceStore(path, new RecordingJournal());
        using var writer = new FilePreferenceStore(path, new RecordingJournal());
        await PosteBoardLayouts.SaveAsync(editor, "Computer", [], None);
        var opened = await PosteBoardLayouts.ReadLatestAsync(editor, "Computer", None);
        using var library = Library();
        var saved = await library.SaveAsync(Fixtures.Root, Recipe(), null, null, 0, "update", new("computer", "kpi", "Carte"), None);
        await Place(writer, library, saved);
        var before = File.ReadAllText(path);
        await Check.ThrowsAsync<InvalidDataException>(() => PosteBoardLayouts.SaveAsync(editor, "Computer", [], None, opened.ChoiceToken), "ancien éditeur refuse de perdre l’ajout");
        Check.Equal(before, File.ReadAllText(path), "choix concurrent intact");
        var current = await PosteBoardLayouts.ReadLatestAsync(editor, "Computer", None);
        Check.Equal(1, current.Items.Length, "relire affiche réellement la nouvelle carte disque");
        var removed = await PosteBoardLayouts.SaveAsync(editor, "Computer", [], None, current.ChoiceToken);
        Check.Equal(0, removed.Items.Length, "nouveau geste explicite peut vider le tableau");
        Check.Equal(removed.ChoiceToken, (await PosteBoardLayouts.ReadLatestAsync(writer, "Computer", None)).ChoiceToken, "jeton stable après sérialisation indentée et réouverture");
    }

    [Test]
    public static async Task Real_bridge_places_evaluates_pinned_then_explicitly_migrated_revision_and_removes_the_card()
    {
        var bridge = new SimulatedBridge();
        await PosteBoardLayouts.SaveAsync(bridge.Context.Preferences, "Computer", [], None);
        var saved = await Ok(bridge, "requetes.widget.save", SaveArgs(Recipe()));
        Check.True(saved.GetProperty("placement").GetProperty("applied").GetBoolean(), "vrai geste Atelier relié à Poste");
        var item = PosteBoardLayouts.Read(bridge.Context.Preferences, "Computer").Items.Single();
        var local = await bridge.Source.ReadLocalAsync(None); var pc = local.Directory.Computers.First();
        var root = local.Directory.Domain.RootDn; var library = RequetesServices.Library(bridge.Context);
        var record = (await library.ReadAsync(root, None)).Records.Single();
        await library.SaveAsync(root, record.Recipe, "Révision suivante", null, 1, "update", null, None);
        var args = new { dn = pc.DistinguishedName, computer = pc.ObjectGuid, item = item.Id };
        var result = await Ok(bridge, "poste.layout.query", args);
        Check.Equal(1L, result.GetProperty("revision").GetInt64(), "nouvelle version jamais adoptée sans geste");
        Check.Equal(2L, result.GetProperty("currentRevision").GetInt64(), "évolution annoncée");
        await library.SaveAsync(root, record.Recipe, "Migration explicite", null, 2, "migrate", null, None);
        result = await Ok(bridge, "poste.layout.query", args);
        Check.Equal(3L, result.GetProperty("revision").GetInt64(), "migration explicite de la bibliothèque utilisée par le vrai consommateur");
        var before = await bridge.Context.Readers.Require<IQueryWorkshopReader>().DatasetAsync(None);
        var defaultConsumer = await Ok(bridge, "requetes.widget.evaluate", new { id = item.QueryBinding!.LibraryWidgetId, computer = pc.ObjectGuid });
        Check.Equal(JsonValueKind.Null, defaultConsumer.GetProperty("counts").ValueKind, "pas de distribution superflue pour un poste");
        Check.Equal(before.Version, (await bridge.Context.Readers.Require<IQueryWorkshopReader>().DatasetAsync(None)).Version, "aucune collecte");
        await PosteBoardLayouts.SaveAsync(bridge.Context.Preferences, "Computer", [item with { Paused = true }], None);
        Check.Equal("error", (await bridge.CallAsync("poste.layout.query", JsonSerializer.Serialize(args))).Kind, "pause refusée avant calcul");
        await Ok(bridge, "requetes.widget.remove", new { id = item.QueryBinding!.LibraryWidgetId });
        Check.Equal(0, PosteBoardLayouts.Read(bridge.Context.Preferences, "Computer").Items.Length, "retrait conserve [] et la recette");
        Check.Equal(1, (await library.ReadAsync(root, None)).Records.Count, "recette non supprimée");
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucun effet distant");
    }

    [Test]
    public static async Task Refused_layout_returns_separate_receipt_and_explicit_retry_works_without_another_recipe_write()
    {
        var prefs = new MemoryPreferenceStore(); var bridge = new SimulatedBridge(preferences: prefs);
        var bad = JsonSerializer.SerializeToElement(new { version = 99, items = Array.Empty<object>(), future = "intact" });
        await prefs.SetAsync(PosteBoardLayouts.PreferenceKey("Computer"), bad, None);
        var saved = await Ok(bridge, "requetes.widget.save", SaveArgs(Recipe()));
        Check.False(saved.GetProperty("placement").GetProperty("applied").GetBoolean(), "bibliothèque réussie ne signifie pas tableau réussi");
        Check.True(prefs.TryGet(PosteBoardLayouts.PreferenceKey("Computer"), out var preserved), "choix présent");
        Check.Equal(bad.GetRawText(), preserved.GetRawText(), "choix incompatible intact");
        var link = saved.GetProperty("widget");
        // A future document cannot be overwritten by the editor. Model an explicit repair outside this flow.
        await prefs.SetAsync(PosteBoardLayouts.PreferenceKey("Computer"), JsonSerializer.SerializeToElement(new { version = 1, items = Array.Empty<object>() }), None);
        var placed = await Ok(bridge, "requetes.widget.place", new { id = link.GetProperty("id").GetString(), revision = link.GetProperty("boundRevision").GetInt64(), fingerprint = saved.GetProperty("fingerprint").GetString() });
        Check.True(placed.GetProperty("applied").GetBoolean(), "réessai explicite place la même révision");
        Check.Equal(1, PosteBoardLayouts.Read(prefs, "Computer").Items.Length, "une seule carte");
        Check.Equal("error", (await bridge.CallAsync("requetes.widget.save", JsonSerializer.Serialize(SaveArgs(Recipe("Interdit"), "pie"), BridgeJson.Options))).Kind, "graphique de population non proposé pour un poste");
    }

    [Test]
    public static async Task Library_change_after_lock_and_capacity_or_future_fields_never_overwrite_the_layout()
    {
        using var library = Library();
        var saved = await library.SaveAsync(Fixtures.Root, Recipe(), null, null, 0, "update", new("computer", "kpi", "Carte"), None);
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var prefs = new FilePreferenceStore(path, new RecordingJournal());
        await PosteBoardLayouts.SaveAsync(prefs, "Computer", [], None);
        var original = File.ReadAllText(path); var revalidated = false;
        await Check.ThrowsAsync<InvalidDataException>(() => PosteQueryLayout.PlaceAsync(prefs, Fixtures.Root, Widget(saved), saved.Record.Fingerprint, () =>
        {
            revalidated = true;
            library.SaveAsync(Fixtures.Root, saved.Record.Recipe, "Changed", null, 1, "migrate", null, None).GetAwaiter().GetResult();
            return library.ReadAsync(Fixtures.Root, None).GetAwaiter().GetResult();
        }, None), "liaison modifiée au moment de la mutation refusée");
        Check.True(revalidated, "source requalifiée par le callback atomique");
        Check.Equal(original, File.ReadAllText(path), "aucun état disque partiel");
        var updated = (await library.ReadAsync(Fixtures.Root, None)).Widgets.Single();
        var record = (await library.ReadAsync(Fixtures.Root, None)).Records.Single();
        async Task Append() { await PosteQueryLayout.PlaceAsync(prefs, Fixtures.Root, updated, record.Fingerprint, () => library.ReadAsync(Fixtures.Root, None).GetAwaiter().GetResult(), None); }
        await PosteBoardLayouts.SaveAsync(prefs, "Computer", Enumerable.Range(0, 64).Select(n => new FleetLayoutItem("b" + n, FleetWidgetSource.Builtin, "computer.os", "Kpi", "S", null, false, "")).ToArray(), None);
        original = File.ReadAllText(path);
        await Check.ThrowsAsync<InvalidDataException>(Append, "65e carte refusée sans troncature");
        Check.Equal(original, File.ReadAllText(path), "quota préserve le document");
        await prefs.SetAsync(PosteBoardLayouts.PreferenceKey("Computer"), JsonSerializer.SerializeToElement(new { version = 1, items = Array.Empty<object>(), future = true }), None);
        original = File.ReadAllText(path);
        await Check.ThrowsAsync<JsonException>(Append, "champ futur conservé même en version 1");
        Check.Equal(original, File.ReadAllText(path), "aucune perte de champ inconnu");
    }
}
