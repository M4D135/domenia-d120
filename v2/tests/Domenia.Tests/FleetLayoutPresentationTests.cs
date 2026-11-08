using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class FleetLayoutPresentationTests
{
    private static FleetLayoutItem Card(string key, string group) => FleetCatalog.Item(FleetCatalog.All.Single(w => w.Key == key)) with { Group = group };
    private static async Task<FleetLayoutView> View(SimulatedBridge bridge, string operation = "accueil.layout", object? args = null) =>
        SimulatedBridge.Json(await bridge.CallAsync(operation, JsonSerializer.Serialize(args ?? new { }, BridgeJson.Options))).Deserialize<FleetLayoutView>(BridgeJson.Options)!;
    private static Task<FleetLayoutView> Save(SimulatedBridge bridge, FleetLayoutItem[] items, string token) =>
        View(bridge, "accueil.layout.save", new { items, expectedChoiceToken = token });

    [Test]
    public static async Task Fleet_section_moves_dimensions_and_visibility_survive_reopening_export_and_history_without_overwriting_a_concurrent_choice()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var preferences = new FilePreferenceStore(path, new RecordingJournal());
        var bridge = new SimulatedBridge(preferences: preferences); using var context = bridge.Context;
        FleetLayoutItem[] before = [Card("fleet.machines", "Inventaire"), Card("fleet.enabled", "Inventaire"), Card("fleet.os", "Analyse")];
        var initial = await View(bridge);
        var original = await Save(bridge, before, initial.ChoiceToken);
        FleetLayoutItem[] after = [before[2] with { Group = "Priorités", Size = "L", Height = "M", Hidden = true },
            before[1] with { Group = "À suivre", Size = "M", Height = "L", Paused = true },
            before[0] with { Group = "À suivre", Size = "S", Height = "S" }];
        var saved = await Save(bridge, after, original.ChoiceToken);
        Check.True(saved.Items.SequenceEqual(after), "sections, ordre des cartes, largeur, hauteur et visibilité exactement conservés");
        Check.True(saved.Customized, "hauteur et masquage sont des choix personnels");
        Check.False(saved.Items[0].Paused, "masquer n’active pas la pause de collecte");
        Check.False(saved.Items[1].Hidden, "mettre en pause ne masque pas le widget");
        var unchanged = File.ReadAllText(path);
        var noOp = await Save(bridge, after, saved.ChoiceToken);
        Check.Equal(saved.ChoiceToken, noOp.ChoiceToken, "sauvegarde sans changement stable");
        Check.Equal(unchanged, File.ReadAllText(path), "pas d’historique supplémentaire sans modification");
        var rejected = await bridge.CallAsync("accueil.layout.save", JsonSerializer.Serialize(new { items = before, expectedChoiceToken = original.ChoiceToken }, BridgeJson.Options));
        Check.Equal("error", rejected.Kind, "un ancien écran ne peut pas écraser les déplacements");
        Check.Equal(unchanged, File.ReadAllText(path), "le rejet concurrent ne modifie aucun octet");
        using var reopenedPreferences = new FilePreferenceStore(path, new RecordingJournal());
        var reopened = new SimulatedBridge(preferences: reopenedPreferences); using var reopenedContext = reopened.Context;
        var cold = await View(reopened);
        Check.True(cold.Items.SequenceEqual(after), "réouverture fidèle du stockage réel");
        Check.Equal(saved.ChoiceToken, cold.ChoiceToken, "empreinte complète identique après réouverture");
        var exported = BoardLayoutTransfer.Export("Fleet", cold.Items, Fixtures.Now);
        Check.True(BoardLayoutTransfer.Examine("Fleet", exported).Items.SequenceEqual(after), "export et import préservent les sections et dimensions");
        var previous = cold.History.Single(h => h.Items.SequenceEqual(before));
        var restored = await View(reopened, "accueil.layout.restore", new { versionId = previous.Id, expectedChoiceToken = cold.ChoiceToken });
        Check.True(restored.Items.SequenceEqual(before), "restauration de l’ordre et des sections antérieures");
        Check.True(restored.History[0].Items.SequenceEqual(after), "le choix remplacé reste restaurable, dimensions et masque inclus");
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune collecte déclenchée par l’organisation du tableau");
    }

    [Test]
    public static void Legacy_history_hashes_remain_valid_when_height_and_hidden_were_never_stored()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        var oldItems = JsonSerializer.SerializeToElement(new[] { new { id = "b-fleet.machines", source = "builtin", key = "fleet.machines", visual = "Kpi", size = "S",
            title = (string?)null, paused = false, group = "Inventaire", queryBinding = (object?)null } }, options);
        var sha = Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(oldItems, options)));
        var previousId = Guid.NewGuid().ToString("N");
        var legacy = JsonSerializer.SerializeToElement(new { version = 2, items = oldItems, savedAt = Fixtures.Now,
            history = new[] { new { id = previousId, savedAt = Fixtures.Now, sha256 = sha, items = oldItems } } }, options);
        var state = BoardLayoutHistory.Read(legacy, FleetCatalog.DefaultLayout(), AccueilService.Clean);
        Check.Null(state.Items[0].Height, "ancienne hauteur automatique");
        Check.False(state.Items[0].Hidden, "ancienne carte visible");
        var changed = BoardLayoutHistory.Next(legacy, [state.Items[0] with { Height = "L", Hidden = true }], FleetCatalog.DefaultLayout(), AccueilService.Clean, Fixtures.Now);
        var current = BoardLayoutHistory.Read(changed, FleetCatalog.DefaultLayout(), AccueilService.Clean);
        Check.Equal(sha, current.History[0].Sha256, "empreinte historique calculée avec les mêmes octets, sans ajouter null/false");
        var restored = BoardLayoutHistory.Restore(changed, previousId, current.ChoiceToken, FleetCatalog.DefaultLayout(), AccueilService.Clean, Fixtures.Now);
        var result = BoardLayoutHistory.Read(restored, FleetCatalog.DefaultLayout(), AccueilService.Clean);
        Check.False(result.Items[0].Hidden, "restaurer une ancienne version retire le masque");
        Check.Null(result.Items[0].Height, "restaurer une ancienne version revient à la hauteur automatique");
    }

    [Test]
    public static async Task Invalid_dimensions_or_visibility_are_refused_without_partial_layout_write()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var preferences = new FilePreferenceStore(path, new RecordingJournal());
        var bridge = new SimulatedBridge(preferences: preferences); using var context = bridge.Context;
        var initial = await View(bridge); var item = Card("fleet.machines", "Mes postes") with { Height = "M", Hidden = true };
        var current = await Save(bridge, [item], initial.ChoiceToken);
        var original = File.ReadAllText(path);
        foreach (var height in new[] { "", "XL", "s", "400px", new string('X', 1000) })
        {
            var args = JsonSerializer.Serialize(new { items = new[] { item with { Height = height } }, expectedChoiceToken = current.ChoiceToken }, BridgeJson.Options);
            Check.Equal("error", (await bridge.CallAsync("accueil.layout.save", args)).Kind, "hauteur hors contrat refusée");
            Check.Equal(original, File.ReadAllText(path), "aucune écriture partielle ni correction silencieuse");
        }
        var invalid = JsonNode.Parse(JsonSerializer.Serialize(new { items = new[] { item }, expectedChoiceToken = current.ChoiceToken }, BridgeJson.Options))!;
        invalid["items"]![0]!["hidden"] = "true";
        Check.Equal("error", (await bridge.CallAsync("accueil.layout.save", invalid.ToJsonString())).Kind, "masque non booléen refusé");
        Check.Equal(original, File.ReadAllText(path), "visibilité courante conservée");
        var badFile = JsonNode.Parse(BoardLayoutTransfer.Export("Fleet", [item], Fixtures.Now))!;
        badFile["items"]![0]!["height"] = "XL";
        Check.Throws<InvalidDataException>(() => BoardLayoutTransfer.Examine("Fleet", badFile.ToJsonString()), "import hors limites refusé avant sauvegarde");
        Check.False(FleetCatalog.IsDefault([.. FleetCatalog.DefaultLayout().Select(i => i with { Height = "L" })]), "hauteur seule marque la personnalisation");
        Check.False(FleetCatalog.IsDefault([.. FleetCatalog.DefaultLayout().Select(i => i with { Hidden = true })]), "masquage seul marque la personnalisation");
    }
}
