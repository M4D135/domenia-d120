using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Bridge;
using Domenia.Bridge.Operations.Requetes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Store;

namespace Domenia.Tests;

internal static class BoardLayoutHistoryTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static string Key(string board) => board == "Fleet" ? AccueilService.LayoutPreference : PosteBoardLayouts.PreferenceKey(board);
    private static string Text(JsonElement value, string field) => value.GetProperty(field).GetString() ?? throw new TestFailureException("Champ absent : " + field);
    private static FleetLayoutItem Card(string board, string title) => new("one", FleetWidgetSource.Builtin,
        board == "Fleet" ? "fleet.machines" : board == "Software" ? "software.count" : "computer.os", "Kpi", "S", title, false, "");
    private static async Task<JsonElement> Ok(SimulatedBridge bridge, string op, object? args = null) =>
        SimulatedBridge.Json(await bridge.CallAsync(op, JsonSerializer.Serialize(args ?? new { }, BridgeJson.Options)));
    private static Task<JsonElement> Get(SimulatedBridge bridge, string board) => Ok(bridge, board == "Fleet" ? "accueil.layout" : "poste.layout.get", board == "Fleet" ? new { } : (object)new { board });
    private static Task<JsonElement> Save(SimulatedBridge bridge, string board, FleetLayoutItem[] items, string token) =>
        Ok(bridge, board == "Fleet" ? "accueil.layout.save" : "poste.layout.save", board == "Fleet" ? new { items, expectedChoiceToken = token } : (object)new { board, items, expectedChoiceToken = token });
    private static Task<JsonElement> Restore(SimulatedBridge bridge, string board, string id, string token) =>
        Ok(bridge, board == "Fleet" ? "accueil.layout.restore" : "poste.layout.restore", board == "Fleet" ? new { versionId = id, expectedChoiceToken = token } : (object)new { board, versionId = id, expectedChoiceToken = token });

    [Test]
    public static async Task All_three_real_handlers_keep_five_versions_and_restore_empty_choice_with_previous_choice_kept()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var preferences = new FilePreferenceStore(path, new RecordingJournal());
        var bridge = new SimulatedBridge(preferences: preferences);
        foreach (var board in new[] { "Fleet", "Computer", "Software" })
        {
            await preferences.SetAsync(Key(board), JsonSerializer.SerializeToElement(new { version = 1, items = Array.Empty<object>() }), None);
            var view = await Get(bridge, board);
            Check.Equal(0, view.GetProperty("items").GetArrayLength(), "version 1 vide reprise réellement");
            for (var n = 0; n < 7; n++) view = await Save(bridge, board, n == 4 ? [] : [Card(board, "Étape " + n)], Text(view, "choiceToken"));
            var history = view.GetProperty("history");
            Check.Equal(5, history.GetArrayLength(), "exactement cinq anciennes versions, pas de liste illimitée");
            Check.Equal(5, history.EnumerateArray().Select(h => Text(h, "id")).Distinct().Count(), "identités distinctes même avec une horloge fixe");
            Check.True(history.EnumerateArray().All(h => Text(h, "sha256").Length == 64), "empreintes complètes");
            var before = File.ReadAllText(path);
            var unchanged = await Save(bridge, board, [Card(board, "Étape 6")], Text(view, "choiceToken"));
            Check.Equal(before, File.ReadAllText(path), "un changement sans effet n’écrit ni n’empile rien");
            Check.Equal(Text(view, "choiceToken"), Text(unchanged, "choiceToken"), "jeton inchangé");
            var empty = history.EnumerateArray().Single(h => h.GetProperty("items").GetArrayLength() == 0);
            var restored = await Restore(bridge, board, Text(empty, "id"), Text(view, "choiceToken"));
            Check.Equal(0, restored.GetProperty("items").GetArrayLength(), "restauration explicite de []");
            Check.Equal("Étape 6", restored.GetProperty("history")[0].GetProperty("items")[0].GetProperty("title").GetString(), "choix remplacé restaurable à son tour");
            using var fresh = new FilePreferenceStore(path, new RecordingJournal());
            var reopened = new SimulatedBridge(preferences: fresh);
            var actual = await Get(reopened, board);
            Check.Equal(Text(restored, "choiceToken"), Text(actual, "choiceToken"), "réouverture du vrai document fidèle");
            Check.Equal(0, actual.GetProperty("items").GetArrayLength(), "pas de défauts après réouverture");
            Check.True(fresh.TryGet(Key(board), out var raw), "préférence présente");
            Check.Equal(2, raw.GetProperty("version").GetInt32(), "enveloppe versionnée effective");
        }
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune collecte ou écriture distante");
    }

    [Test]
    public static async Task Restoration_with_stale_choice_token_never_overwrites_another_instances_current_choice()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var first = new FilePreferenceStore(path, new RecordingJournal());
        using var second = new FilePreferenceStore(path, new RecordingJournal());
        var a = new SimulatedBridge(preferences: first); var b = new SimulatedBridge(preferences: second);
        foreach (var board in new[] { "Fleet", "Computer", "Software" })
        {
            var current = await Get(a, board);
            var old = await Save(a, board, [Card(board, "Initial")], Text(current, "choiceToken"));
            var version = Text(old.GetProperty("history")[0], "id");
            var other = await Get(b, board);
            await Save(b, board, [], Text(other, "choiceToken"));
            var original = File.ReadAllText(path);
            var op = board == "Fleet" ? "accueil.layout.restore" : "poste.layout.restore";
            var args = board == "Fleet" ? (object)new { versionId = version, expectedChoiceToken = Text(old, "choiceToken") }
                : new { board, versionId = version, expectedChoiceToken = Text(old, "choiceToken") };
            Check.Equal("error", (await a.CallAsync(op, JsonSerializer.Serialize(args))).Kind, "jeton ancien refusé");
            Check.Equal(original, File.ReadAllText(path), "aucune perte du tableau vide concurrent");
            Check.Equal(0, (await Get(a, board)).GetProperty("items").GetArrayLength(), "relecture actualisée montre le choix concurrent");
        }
    }

    [Test]
    public static async Task A_real_fleet_edit_and_history_restore_keep_the_D1_query_binding_and_pause()
    {
        using var folder = new TemporaryFolder();
        using var preferences = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal());
        var bridge = new SimulatedBridge(preferences: preferences);
        var session = await bridge.Source.GetSessionAsync(None);
        var root = session.Domain?.RootDn ?? throw new TestFailureException("Domaine simulé absent.");
        await WorkingScope.From(bridge.Context).SetAsync(session, await RequetesOperationsTests.WorkstationsOuAsync(bridge), true, None);
        var library = RequetesServices.Library(bridge.Context);
        var saved = await library.SaveAsync(root, QueryRecipe.Empty() with { Name = "Tous mes postes" }, null, null, 0, "update", null, None);
        var raw = JsonSerializer.SerializeToElement(new Dictionary<string, string> { ["Dashboard.Fleet.Layout"] = JsonSerializer.Serialize(new[] { new { Id = "fromD1", Source = "Query", Key = saved.Record.Id } }) });
        var preview = LegacyBoardLayouts.BindQueries(LegacyBoardLayouts.Parse(raw, @"C:\D1\Preferences\Domenia.settings.json", new string('a', 64)), await library.ReadAsync(root, None), root);
        var proposal = preview.Boards.Single(p => p.Board == "Fleet");
        Check.True(await LegacyBoardLayouts.ApplyAsync(preview, "Fleet", new string('a', 64), preferences, TestClock.Reference, None,
            expectedQueryBindingsSha256: proposal.QueryBindingsSha256), "migration D1 réelle");
        var view = await Get(bridge, "Fleet");
        var original = view.GetProperty("items").Deserialize<FleetLayoutItem[]>(BridgeJson.Options) ?? throw new TestFailureException("Cartes absentes.");
        view = await Save(bridge, "Fleet", [original[0] with { Paused = true, Title = "Titre choisi" }], Text(view, "choiceToken"));
        Check.Equal(1L, view.GetProperty("items")[0].GetProperty("queryBinding").GetProperty("revision").GetInt64(), "vrai Bridge conserve la liaison lors de la pause");
        await library.SaveAsync(root, saved.Record.Recipe, "Révision plus récente", null, 1, "update", null, None);
        var restored = await Restore(bridge, "Fleet", Text(view.GetProperty("history")[0], "id"), Text(view, "choiceToken"));
        Check.False(restored.GetProperty("items")[0].GetProperty("paused").GetBoolean(), "pause restaurée exactement");
        Check.Equal(saved.Record.Fingerprint, restored.GetProperty("items")[0].GetProperty("queryBinding").GetProperty("fingerprint").GetString(), "empreinte D1 inchangée");
        var board = await AccueilService.From(bridge.Context).BoardAsync(None);
        var item = AccueilService.From(bridge.Context).Layout().Items.Single();
        Check.Contains("Révision 1", board.Entries["query:" + item.Key].Subtitle, "vrai calcul utilise toujours la révision importée");
        Check.True(preferences.TryGet(LegacyBoardLayouts.EvidenceKey, out var proof), "provenance D1 non remplacée par l’historique D2");
        Check.Equal(new string('a', 64), proof.GetProperty("sourceSha256").GetString(), "preuve source conservée");
    }

    [Test]
    public static async Task Future_fields_versions_corrupt_history_and_overflow_are_preserved_without_replacement()
    {
        foreach (var board in new[] { "Fleet", "Computer", "Software" })
        {
            var preferences = new MemoryPreferenceStore(); var bridge = new SimulatedBridge(preferences: preferences);
            var initial = await Get(bridge, board);
            await Save(bridge, board, [], Text(initial, "choiceToken"));
            Check.True(preferences.TryGet(Key(board), out var valid), "document créé");
            for (var n = 0; n < 4; n++)
            {
                var node = JsonNode.Parse(valid.GetRawText())!.AsObject();
                if (n == 0) node["future"] = true;
                if (n == 1) node["version"] = 3;
                if (n == 2) node["history"]![0]!["sha256"] = new string('0', 64);
                if (n == 3)
                {
                    var entry = node["history"]![0]!.DeepClone();
                    var rows = new JsonArray(); for (var i = 0; i < 6; i++) rows.Add(entry.DeepClone()); node["history"] = rows;
                }
                var future = JsonSerializer.SerializeToElement(node);
                await preferences.SetAsync(Key(board), future, None);
                var view = await Get(bridge, board);
                Check.False(view.GetProperty("valid").GetBoolean(), "version future ou historique corrompu signalé");
                var op = board == "Fleet" ? "accueil.layout.save" : "poste.layout.save";
                var args = board == "Fleet" ? (object)new { items = new[] { Card(board, "Nouvelle") }, expectedChoiceToken = Text(view, "choiceToken") }
                    : new { board, items = new[] { Card(board, "Nouvelle") }, expectedChoiceToken = Text(view, "choiceToken") };
                Check.Equal("error", (await bridge.CallAsync(op, JsonSerializer.Serialize(args, BridgeJson.Options))).Kind, "pas de remplacement par défaut");
                Check.True(preferences.TryGet(Key(board), out var preserved), "document toujours présent");
                Check.Equal(future.GetRawText(), preserved.GetRawText(), "aucun champ ni historique futur perdu");
            }
        }
    }

    [Test]
    public static async Task The_real_handlers_refuse_unknown_or_65_cards_without_dropping_any_choice_or_history()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var preferences = new FilePreferenceStore(path, new RecordingJournal());
        var bridge = new SimulatedBridge(preferences: preferences);
        foreach (var board in new[] { "Fleet", "Computer", "Software" })
        {
            var initial = await Get(bridge, board);
            var current = await Save(bridge, board, [], Text(initial, "choiceToken"));
            var before = File.ReadAllText(path);
            foreach (var items in new[]
            {
                new[] { Card(board, "Inconnue") with { Key = "future.unknown" } },
                Enumerable.Range(0, 65).Select(n => Card(board, "Carte") with { Id = "card" + n }).ToArray(),
            })
            {
                var op = board == "Fleet" ? "accueil.layout.save" : "poste.layout.save";
                var args = board == "Fleet" ? (object)new { items, expectedChoiceToken = Text(current, "choiceToken") }
                    : new { board, items, expectedChoiceToken = Text(current, "choiceToken") };
                Check.Equal("error", (await bridge.CallAsync(op, JsonSerializer.Serialize(args, BridgeJson.Options))).Kind, "aucune carte perdue silencieusement");
                Check.Equal(before, File.ReadAllText(path), "choix et historique strictement intacts après refus");
            }
        }
    }

    [Test]
    public static async Task Failed_atomic_file_commit_keeps_real_fleet_view_and_history_at_previous_choice()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var preferences = new FilePreferenceStore(path, new RecordingJournal());
        var bridge = new SimulatedBridge(preferences: preferences); var service = AccueilService.From(bridge.Context);
        var initial = await service.SaveLayoutAsync([Card("Fleet", "Ancien")], None);
        var before = File.ReadAllText(path);
        using (var held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var failure = await Check.ThrowsAsync<Exception>(() => service.SaveLayoutAsync([], None, initial.ChoiceToken), "remplacement disque refusé");
            Check.True(failure is IOException or UnauthorizedAccessException,
                "le handle Windows provoque un refus de partage ou d’accès au remplacement, sans masquer une erreur métier");
        }
        Check.Equal(before, File.ReadAllText(path), "choix et historique anciens ensemble");
        Check.Equal(0, Directory.GetFiles(folder.Path, "*.tmp").Length, "temporaire de la tentative refusée supprimé");
        var actual = await service.LayoutLatestAsync(None);
        Check.Equal("Ancien", actual.Items.Single().Title, "aucun état optimiste dans le vrai service");
        Check.Equal(initial.ChoiceToken, actual.ChoiceToken, "preuve du choix inchangée");
    }
}
