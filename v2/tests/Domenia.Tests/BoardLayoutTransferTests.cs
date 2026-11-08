using System.Text;
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

internal static class BoardLayoutTransferTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static FleetLayoutItem Card(string board) => board == "Fleet" ? FleetCatalog.DefaultLayout()[0] : PosteBoardLayouts.Defaults(board)[0];
    private static string Text(JsonElement value, string field) => value.GetProperty(field).GetString() ?? throw new TestFailureException(field + " absent.");
    private static async Task<JsonElement> Call(SimulatedBridge bridge, string operation, object args) =>
        SimulatedBridge.Json(await bridge.CallAsync(operation, JsonSerializer.Serialize(args, BridgeJson.Options)));
    private static Task<JsonElement> Get(SimulatedBridge bridge, string board) => Call(bridge, board == "Fleet" ? "accueil.layout" : "poste.layout.get", board == "Fleet" ? new { } : (object)new { board });

    [Test]
    public static void Board_documents_roundtrip_three_real_catalogs_order_groups_pause_and_explicit_empty()
    {
        foreach (var board in new[] { "Fleet", "Computer", "Software" })
        {
            var rows = new[] { Card(board) with { Id = "kept", Group = "Équipe", Paused = true, Title = "Choix" }, Card(board) with { Id = "second" } };
            var text = BoardLayoutTransfer.Export(board, rows, TestClock.Reference);
            var parsed = BoardLayoutTransfer.Examine(board, text);
            Check.True(rows.SequenceEqual(parsed.Items), "tous les champs conservés, sans reconstruction du catalogue");
            Check.Equal(64, parsed.Sha256.Length, "preuve UTF8 complète");
            Check.Equal(0, BoardLayoutTransfer.Examine(board, BoardLayoutTransfer.Export(board, [], TestClock.Reference)).Items.Length, "[] intentionnel exportable et réimportable");
            Check.Equal(0, BoardLayoutTransfer.Examine(board, "[]").Items.Length, "ancien tableau vide explicite accepté");
        }
        const string d1 = "{\"Format\":\"Domenia.BoardLayout.1\",\"Board\":\"Computer\",\"Layout\":[{\"Id\":\"my-card\",\"Source\":\"Builtin\",\"Key\":\"computer.os\",\"Paused\":true,\"Group\":\"Personnel\"}]}";
        var imported = BoardLayoutTransfer.Examine("Computer", d1);
        Check.Equal("my-card", imported.Items.Single().Id, "ID de fichier D1 conservé");
        Check.Equal("Personnel", imported.Items.Single().Group, "groupe D1 conservé");
        Check.True(imported.Items.Single().Paused, "pause D1 conservée");
    }

    [Test]
    public static void Future_duplicate_foreign_or_unrepresented_documents_are_refused_whole()
    {
        var valid = BoardLayoutTransfer.Export("Computer", [Card("Computer")], TestClock.Reference);
        var future = JsonNode.Parse(valid)!.AsObject(); future["future"] = true;
        Check.Throws<JsonException>(() => BoardLayoutTransfer.Examine("Computer", future.ToJsonString()), "champ futur refusé");
        Check.Throws<InvalidDataException>(() => BoardLayoutTransfer.Examine("Software", valid), "autre tableau refusé");
        Check.Throws<InvalidDataException>(() => BoardLayoutTransfer.Examine("Computer", "{\"Layout\":[],\"layout\":[]}"), "ambiguïté refusée");
        Check.Throws<InvalidDataException>(() => BoardLayoutTransfer.Examine("Computer", "[{\"Id\":\"unknown\",\"Source\":\"Builtin\",\"Key\":\"future.card\"}]"), "pas de reprise partielle");
        Check.Throws<InvalidDataException>(() => BoardLayoutTransfer.Examine("Computer", new string(' ', BoardLayoutTransfer.MaxBytes + 1)), "allocation bornée");
        var invalidVisual = JsonNode.Parse(valid)!.AsObject(); invalidVisual["items"]![0]!["visual"] = "Future";
        Check.Throws<InvalidDataException>(() => BoardLayoutTransfer.Examine("Computer", invalidVisual.ToJsonString()), "pas de correction silencieuse d’un document D2");
    }

    [Test]
    public static async Task Real_import_handlers_preserve_empty_choice_concurrently_then_save_history_and_export_actual_choice()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using var preferences = new FilePreferenceStore(path, new RecordingJournal()); var bridge = new SimulatedBridge(preferences: preferences);
        foreach (var board in new[] { "Fleet", "Computer", "Software" })
        {
            var current = await Get(bridge, board);
            var text = BoardLayoutTransfer.Export(board, [], TestClock.Reference);
            var preview = await Call(bridge, "shell.board.import.preview", new { board, text });
            var first = await Call(bridge, "shell.board.import.apply", new { board, text, sha256 = Text(preview, "sha256"), expectedChoiceToken = Text(current, "choiceToken") });
            Check.Equal(0, first.GetProperty("items").GetArrayLength(), "vrai consommateur reçoit []");
            var bytes = File.ReadAllText(path);
            var replacement = BoardLayoutTransfer.Export(board, [Card(board)], TestClock.Reference);
            var p2 = await Call(bridge, "shell.board.import.preview", new { board, text = replacement });
            var refused = await bridge.CallAsync("shell.board.import.apply", JsonSerializer.Serialize(new { board, text = replacement, sha256 = Text(p2, "sha256"), expectedChoiceToken = Text(current, "choiceToken") }));
            Check.Equal("error", refused.Kind, "ancien choix ne peut remplacer le vide concurrent");
            Check.Equal(bytes, File.ReadAllText(path), "document entier inchangé");
            var saved = await Call(bridge, "shell.board.import.apply", new { board, text = replacement, sha256 = Text(p2, "sha256"), expectedChoiceToken = Text(first, "choiceToken") });
            Check.Equal(0, saved.GetProperty("history")[0].GetProperty("items").GetArrayLength(), "vide précédent restaurable");
            var export = await Call(bridge, "shell.board.export", new { board, expectedChoiceToken = Text(saved, "choiceToken") });
            Check.False(export.GetProperty("saved").GetBoolean(), "magasin mémoire ne prétend pas avoir écrit un fichier");
            Check.Equal(Card(board), BoardLayoutTransfer.Examine(board, Text(export, "text")).Items.Single(), "export du vrai choix sauvegardé");
        }
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune écriture AD");
    }

    [Test]
    public static async Task Real_presets_keep_custom_cards_pause_and_refuse_overflow_without_replacement()
    {
        var store = new MemoryPreferenceStore(); var bridge = new SimulatedBridge(preferences: store);
        foreach (var board in new[] { "Computer", "Software" })
        {
            var initial = Card(board) with { Id = "custom", Title = "Personnel", Group = "Choisi", Paused = true };
            var view = await PosteBoardLayouts.SaveAsync(store, board, [initial], None);
            var saved = await Call(bridge, "poste.layout.preset", new { board, preset = "inventory", expectedChoiceToken = view.ChoiceToken });
            var rows = saved.GetProperty("items").Deserialize<FleetLayoutItem[]>(BridgeJson.Options)!;
            Check.Equal(initial, rows.Single(i => i.Id == "custom"), "carte personnelle jamais reconstruite");
            Check.True(BoardLayoutPresets.Keys(board, "inventory").All(key => rows.Any(i => i.Key == key)), "vraies priorités ajoutées");
        }
        var full = Enumerable.Range(0, 64).Select(i => Card("Computer") with { Id = "c" + i }).ToArray();
        var complete = await PosteBoardLayouts.SaveAsync(store, "Computer", full, None);
        store.TryGet(PosteBoardLayouts.PreferenceKey("Computer"), out var before);
        Check.Equal("error", (await bridge.CallAsync("poste.layout.preset", JsonSerializer.Serialize(new { board = "Computer", preset = "support", expectedChoiceToken = complete.ChoiceToken }))).Kind, "pas de troncature pour faire de la place");
        store.TryGet(PosteBoardLayouts.PreferenceKey("Computer"), out var after);
        Check.Equal(before.GetRawText(), after.GetRawText(), "document et historique conservés");
    }

    [Test]
    public static async Task Team_default_is_local_qualified_and_rechecked_inside_destination_commit()
    {
        using var folder = new TemporaryFolder(); var source = folder.File(LegacyConfiguration.FileName); var preferences = new MemoryPreferenceStore();
        var delivered = BoardLayoutDefaultsFile.Read(folder.Path, "Computer", None);
        Check.True(delivered.Items.Length > 0, "absence réelle livre les cartes du catalogue");
        File.WriteAllText(source, "{\"Dashboard\":{\"DefaultLayoutComputer\":[]}}");
        Check.True(BoardLayoutDefaultsFile.Read(folder.Path, "Computer", None).Items.Length > 0, "défaut d’équipe vide suit le défaut livré D1");
        File.WriteAllText(source, "{\"Dashboard\":{\"DefaultLayoutComputer\":[{\"Id\":\"team\",\"Source\":\"Builtin\",\"Key\":\"computer.os\",\"Paused\":true}]}}");
        var preview = BoardLayoutDefaultsFile.Read(folder.Path, "Computer", None);
        var current = await PosteBoardLayouts.SaveAsync(preferences, "Computer", [], None);
        File.WriteAllText(source, "{\"Dashboard\":{\"DefaultLayoutComputer\":[]}}");
        await Check.ThrowsAsync<InvalidDataException>(() => PosteBoardLayouts.SaveAsync(preferences, "Computer", preview.Items, None, current.ChoiceToken, TestClock.Reference,
            ct => BoardLayoutDefaultsFile.Hold(folder.Path, "Computer", preview.SourceSha256, ct)), "source modifiée refusée sous verrou destination");
        Check.Equal(0, PosteBoardLayouts.Read(preferences, "Computer").Items.Length, "[] courant intact");
        var latest = BoardLayoutDefaultsFile.Read(folder.Path, "Computer", None);
        using (BoardLayoutDefaultsFile.Hold(folder.Path, "Computer", latest.SourceSha256, None))
            Check.Throws<IOException>(() => File.WriteAllText(source, "{}"), "source existante tenue jusqu’au commit");
        File.WriteAllText(source, "{\"Dashboard\":false}");
        Check.Throws<InvalidDataException>(() => BoardLayoutDefaultsFile.Read(folder.Path, "Computer", None), "section illisible ne devient pas défaut silencieux");
    }

    [Test]
    public static async Task Query_file_requires_explicit_revision_consent_and_revalidation_after_destination_lock()
    {
        var preferences = new InterleavingPreferences(); var bridge = new SimulatedBridge(preferences: preferences);
        var session = await bridge.Source.GetSessionAsync(None); var root = session.Domain?.RootDn ?? throw new TestFailureException("Domaine absent.");
        var library = RequetesServices.Library(bridge.Context);
        var recipe = QueryRecipe.Empty() with { Name = "Tous les postes" };
        var record = await library.SaveAsync(root, recipe, null, null, 0, "update", null, None);
        var text = JsonSerializer.Serialize(new { Format = "Domenia.BoardLayout.1", Board = "Computer", Layout = new[] { new { Id = "fromD1", Source = "Query", Key = record.Record.Id } } });
        var current = await PosteBoardLayouts.SaveAsync(preferences, "Computer", [], None);
        var preview = await Call(bridge, "shell.board.import.preview", new { board = "Computer", text });
        Check.True(preview.GetProperty("needsQueryConsent").GetBoolean(), "liaison absente seulement proposée");
        object Args(bool consent) => new { board = "Computer", text, sha256 = Text(preview, "sha256"), expectedChoiceToken = current.ChoiceToken,
            queryBindingsSha256 = Text(preview, "queryBindingsSha256"), sessionStamp = Text(preview, "sessionStamp"), allowQueryProposal = consent };
        Check.Equal("error", (await bridge.CallAsync("shell.board.import.apply", JsonSerializer.Serialize(Args(false)))).Kind, "pas de liaison implicite");
        preferences.BeforeUpdate = () => library.SaveAsync(root, record.Record.Recipe, "Révision concurrente", null, 1, "update", null, None).GetAwaiter().GetResult();
        Check.Equal("error", (await bridge.CallAsync("shell.board.import.apply", JsonSerializer.Serialize(Args(true)))).Kind, "révision modifiée après aperçu et avant mutex refusée");
        Check.Equal(0, PosteBoardLayouts.Read(preferences, "Computer").Items.Length, "aucune liaison ou carte partiellement écrite");
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune permission ni exécution réseau ajoutée");
    }

    private sealed class InterleavingPreferences : IAtomicPreferenceStore
    {
        private readonly MemoryPreferenceStore inner = new();
        public Action? BeforeUpdate { get; set; }
        public bool Persistent => false;
        public bool TryGet(string key, out JsonElement value) => inner.TryGet(key, out value);
        public Task SetAsync(string key, JsonElement? value, CancellationToken cancellationToken) => inner.SetAsync(key, value, cancellationToken);
        public Task<JsonElement?> ReadLatestAsync(string key, CancellationToken token) => inner.ReadLatestAsync(key, token);
        public Task<JsonElement?> UpdateAsync(string key, Func<JsonElement?, JsonElement?> update, CancellationToken token) => inner.UpdateAsync(key, current =>
        { var mutate = BeforeUpdate; BeforeUpdate = null; mutate?.Invoke(); return update(current); }, token);
    }
}
