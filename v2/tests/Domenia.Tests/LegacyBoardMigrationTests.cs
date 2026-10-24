using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class LegacyBoardMigrationTests
{
    private const string Sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private static readonly CancellationToken None = CancellationToken.None;
    private const string TwoItems = """
        [{"Id":"kept-second","Source":"Builtin","Key":"fleet.os","Visual":"Bar","Size":"L","Title":"Mon parc","Paused":true},
         {"Id":"kept-first","Source":"Builtin","Key":"fleet.health","Visual":"Health","Size":"S","Paused":false}]
        """;

    private static JsonElement Json(string text) => JsonSerializer.Deserialize<JsonElement>(text);
    private static LegacyBoardPreview Preview(string layout) => LegacyBoardLayouts.Parse(
        JsonSerializer.SerializeToElement(new Dictionary<string, string> { ["Dashboard.Fleet.Layout"] = layout }), @"C:\D1\Preferences\Domenia.settings.json", Sha);
    private static LegacyBoardProposal Fleet(LegacyBoardPreview preview) => preview.Boards.Single(b => b.Board == "Fleet");
    private static string Digest(string path) => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));

    [Test]
    public static void Dashboard_layout_wins_over_widgets_and_preserves_order_ids_and_pauses()
    {
        var settings = JsonSerializer.SerializeToElement(new Dictionary<string, string>
        {
            ["Dashboard.Fleet.Layout"] = TwoItems, ["Widgets.Fleet"] = "[{\"ProbeId\":\"unknown\"}]",
        });
        var fleet = Fleet(LegacyBoardLayouts.Parse(settings, @"C:\D1\Domenia.settings.json", Sha));
        Check.Equal("ready", fleet.State, "la disposition explicite prime sur l’ancien champ Widgets");
        Check.Equal("kept-second", fleet.Items[0].Id, "ordre exact et identifiant conservés");
        Check.Equal("kept-first", fleet.Items[1].Id, "aucun tri alphabétique");
        Check.True(fleet.Items[0].Paused, "pause conservée");
        Check.False(fleet.Items[1].Paused, "actif conservé");
        Check.Equal(TwoItems, fleet.OriginalLayout, "texte original exact gardé pour la provenance");
    }

    [Test]
    public static void Empty_dashboard_is_explicit_and_never_falls_back_to_legacy_widgets()
    {
        var settings = JsonSerializer.SerializeToElement(new Dictionary<string, string>
        {
            ["Dashboard.Fleet.Layout"] = "[]", ["Widgets.Fleet"] = "[{\"ProbeId\":\"unknown\"}]",
        });
        var fleet = Fleet(LegacyBoardLayouts.Parse(settings, @"C:\D1\Domenia.settings.json", Sha));
        Check.Equal("ready", fleet.State, "tableau vide valide");
        Check.Equal(0, fleet.Items.Length, "aucun défaut ni ancien widget ajouté");
        Check.Equal("Dashboard.Fleet.Layout", fleet.Setting, "provenance de la valeur explicite");
    }

    [Test]
    public static void Only_unset_dashboard_uses_widgets_and_the_delivered_fleet_layout()
    {
        var probe = ProbeCatalog.All[0];
        var settings = JsonSerializer.SerializeToElement(new Dictionary<string, string>
        {
            ["Dashboard.Fleet.Layout"] = "", ["Widgets.Fleet"] = JsonSerializer.Serialize(new[] { new { Id = "historical", ProbeId = probe.Id, Paused = true } }),
        });
        var fleet = Fleet(LegacyBoardLayouts.Parse(settings, @"C:\D1\Domenia.settings.json", Sha));
        Check.Equal("ready", fleet.State, "l’ancien champ Widgets est repris seulement faute de disposition");
        Check.Equal(FleetCatalog.DefaultLayout().Length + 1, fleet.Count, "comme D1 : disposition livrée suivie des sondes historiques");
        Check.Equal("p-historical", fleet.Items[^1].Id, "préfixe historique D1");
        Check.Equal(probe.Id, fleet.Items[^1].Key, "sonde réelle du catalogue");
        Check.True(fleet.Items[^1].Paused, "pause de sonde conservée");
    }

    [Test]
    public static void Invalid_explicit_layout_does_not_fall_back_or_import_partially()
    {
        var settings = JsonSerializer.SerializeToElement(new Dictionary<string, string>
        {
            ["Dashboard.Fleet.Layout"] = "not-json", ["Widgets.Fleet"] = "[]",
        });
        Check.Equal("incompatible", Fleet(LegacyBoardLayouts.Parse(settings, @"C:\D1\settings.json", Sha)).State, "pas de repli malgré un ancien champ valide");
        var unknown = Preview("[{\"Source\":\"Builtin\",\"Key\":\"removed-widget\"}]");
        Check.Equal("incompatible", Fleet(unknown).State, "widget inconnu signalé sans conversion partielle");
        Check.Equal(0, Fleet(unknown).Items.Length, "aucune disposition partielle produite");
    }

    [Test]
    public static void Missing_and_duplicate_identifiers_are_stable_and_distinct()
    {
        var text = "[{\"Id\":\"same\",\"Source\":\"Builtin\",\"Key\":\"fleet.os\"},{\"Id\":\"same\",\"Source\":\"Builtin\",\"Key\":\"fleet.os\"},{\"Source\":\"Builtin\",\"Key\":\"fleet.os\"}]";
        var a = Fleet(Preview(text)).Items;
        var b = Fleet(Preview(text)).Items;
        Check.Equal("same", a[0].Id, "premier identifiant conservé");
        Check.Equal(3, a.Select(i => i.Id).Distinct().Count(), "identifiants uniques");
        Check.True(a.Select(i => i.Id).SequenceEqual(b.Select(i => i.Id)), "conversion déterministe");
    }

    [Test]
    public static void Computer_and_software_are_visible_but_never_reported_importable()
    {
        var settings = JsonSerializer.SerializeToElement(new Dictionary<string, string>
        {
            ["Dashboard.Fleet.Layout"] = "[]", ["Dashboard.Computer.Layout"] = "[]", ["Dashboard.Software.Layout"] = "[]",
        });
        var preview = LegacyBoardLayouts.Parse(settings, @"C:\D1\settings.json", Sha);
        Check.Equal(3, preview.Boards.Length, "les trois tableaux sont expliqués");
        Check.Equal("unsupported", preview.Boards.Single(b => b.Board == "Computer").State, "aucun faux consommateur Computer");
        Check.Equal("unsupported", preview.Boards.Single(b => b.Board == "Software").State, "aucun faux consommateur Software");
    }

    [Test]
    public static void Duplicates_and_oversized_layouts_are_refused()
    {
        Check.Throws<InvalidDataException>(() => LegacyBoardLayouts.Parse(Json("{\"Dashboard.Fleet.Layout\":\"[]\",\"dashboard.fleet.layout\":\"[]\"}"), @"C:\settings.json", Sha), "clé ambiguë refusée");
        Check.Equal("incompatible", Fleet(Preview(new string(' ', LegacyBoardLayouts.MaxLayoutBytes + 1))).State, "borne avant parsing");
        var rows = JsonSerializer.Serialize(Enumerable.Range(0, FleetCatalog.MaxItems + 1).Select(_ => new { Source = "Builtin", Key = "fleet.os" }));
        Check.Equal("incompatible", Fleet(Preview(rows)).State, "65 widgets refusés plutôt que tronqués");
    }

    [Test]
    public static void Local_reader_prefers_preferences_then_bak_and_preserves_original_bytes()
    {
        using var folder = new TemporaryFolder();
        var preferred = Path.Combine(folder.Path, "Preferences", "Domenia.settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(preferred)!);
        File.WriteAllText(preferred, "broken-json");
        File.WriteAllText(preferred + ".bak", JsonSerializer.Serialize(new Dictionary<string, string> { ["Dashboard.Fleet.Layout"] = "[]" }));
        var previous = folder.File("Domenia.settings.json");
        File.WriteAllText(previous, JsonSerializer.Serialize(new Dictionary<string, string> { ["Dashboard.Fleet.Layout"] = TwoItems }));
        var before = Digest(preferred);
        var backupBefore = Digest(preferred + ".bak");
        var preview = LegacyBoardLayoutFile.ReadCandidates([preferred, previous], None);
        Check.Equal(preferred + ".bak", preview.SourcePath, "le .bak de l’emplacement préféré précède l’ancien root");
        Check.Equal(backupBefore, preview.SourceSha256, "SHA des octets réellement lus");
        Check.Equal(0, Fleet(preview).Count, "[] du .bak conservé");
        Check.Equal(1, preview.Warnings.Length, "document rejeté expliqué");
        Check.Equal(before, Digest(preferred), "original incompatible inchangé");
        Check.Equal(backupBefore, Digest(preferred + ".bak"), "backup historique inchangé");
    }

    [Test]
    public static void Source_discovery_respects_portable_and_user_local_roots_without_database_access()
    {
        using var folder = new TemporaryFolder();
        var app = folder.File("app");
        var user = folder.File("user");
        Directory.CreateDirectory(Path.Combine(app, "data", "Preferences"));
        Directory.CreateDirectory(Path.Combine(user, "Data", "Preferences"));
        var portable = Path.Combine(app, "data", "Preferences", "Domenia.settings.json");
        var local = Path.Combine(user, "Data", "Preferences", "Domenia.settings.json");
        File.WriteAllText(portable, JsonSerializer.Serialize(new Dictionary<string, string> { ["Dashboard.Fleet.Layout"] = TwoItems }));
        File.WriteAllText(local, JsonSerializer.Serialize(new Dictionary<string, string> { ["Dashboard.Fleet.Layout"] = "[]" }));
        Check.Equal(portable, LegacyBoardLayoutFile.Read(app, user, None).SourcePath, "Compatible retient data portable existant non vide");
        File.WriteAllText(Path.Combine(app, "Domenia.config.json"), "{\"LocalStore\":{\"Mode\":\"UserLocal\"}}");
        Check.Equal(local, LegacyBoardLayoutFile.Read(app, user, None).SourcePath, "UserLocal sélectionné sans ouvrir de SQLite");
        Check.False(Directory.EnumerateFiles(folder.Path, "*.db", SearchOption.AllDirectories).Any(), "aucune base créée");
    }

    [Test]
    public static void Reader_refuses_oversize_non_directory_parents_unc_and_precancellation()
    {
        using var folder = new TemporaryFolder();
        var large = folder.File("large.json");
        File.WriteAllBytes(large, new byte[LegacyBoardLayoutFile.MaxBytes + 1]);
        Check.Throws<InvalidDataException>(() => LegacyBoardLayoutFile.ReadCandidates([large], None), "lecture bornée");
        var parent = folder.File("parent-file");
        File.WriteAllText(parent, "kept");
        Check.Throws<InvalidDataException>(() => LegacyBoardLayoutFile.ReadCandidates([Path.Combine(parent, "settings.json")], None), "ancêtre fichier n’est pas absence");
        Check.Throws<InvalidDataException>(() => LegacyBoardLayoutFile.ReadCandidates([@"\\server\share\settings.json"], None), "aucun réseau implicite");
        using var canceled = new CancellationTokenSource();
        canceled.Cancel();
        Check.Throws<OperationCanceledException>(() => LegacyBoardLayoutFile.ReadCandidates([large], canceled.Token), "annulation avant lecture");
    }

    [Test]
    public static async Task Import_is_consumed_by_accueil_preserves_evidence_and_survives_a_fresh_instance()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using var preferences = new FilePreferenceStore(path, new RecordingJournal());
        var bridge = new SimulatedBridge(preferences: preferences);
        var service = AccueilService.From(bridge.Context);
        Check.True(service.Layout().Items.Length > 0, "le consommateur avait chargé les défauts");
        Check.True(await LegacyBoardLayouts.ApplyFleetAsync(Preview(TwoItems), Sha, preferences, TestClock.Reference, None), "import appliqué");
        service.ReloadStoredLayout();
        Check.Equal("kept-second", service.Layout().Items[0].Id, "le véritable consommateur Fleet utilise la disposition importée");
        Check.True(service.Layout().Items[0].Paused, "pause présente dans le consommateur");
        using var again = new FilePreferenceStore(path, new RecordingJournal());
        var fresh = new SimulatedBridge(preferences: again);
        Check.Equal("kept-first", AccueilService.From(fresh.Context).Layout().Items[1].Id, "ordre relu après redémarrage");
        Check.True(again.TryGet(LegacyBoardLayouts.EvidenceKey, out var evidence), "preuve écrite avec le layout");
        Check.Equal(Sha, evidence.GetProperty("sourceSha256").GetString(), "provenance SHA");
        Check.Equal(TwoItems, evidence.GetProperty("originalLayout").GetString(), "texte original exact");
        await service.SaveLayoutAsync([], None);
        Check.True(preferences.TryGet(LegacyBoardLayouts.EvidenceKey, out _), "modifier sa disposition ne supprime pas la provenance");
    }

    [Test]
    public static async Task Imported_empty_layout_stays_empty_in_a_new_accueil_consumer()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using (var store = new FilePreferenceStore(path, new RecordingJournal()))
        { Check.True(await LegacyBoardLayouts.ApplyFleetAsync(Preview("[]"), Sha, store, TestClock.Reference, None), "[] importé"); }
        using var again = new FilePreferenceStore(path, new RecordingJournal());
        var bridge = new SimulatedBridge(preferences: again);
        Check.Equal(0, AccueilService.From(bridge.Context).Layout().Items.Length, "[] ne recharge jamais les défauts");
    }

    [Test]
    public static async Task Existing_empty_or_incompatible_d2_choice_is_never_overwritten()
    {
        foreach (var choice in new[] { "{\"version\":1,\"items\":[]}", "{\"version\":99,\"items\":[]}" })
        {
            using var folder = new TemporaryFolder();
            var path = folder.File("preferences.json");
            using var store = new FilePreferenceStore(path, new RecordingJournal());
            await store.SetAsync(AccueilService.LayoutPreference, Json(choice), None);
            var before = Digest(path);
            Check.False(await LegacyBoardLayouts.ApplyFleetAsync(Preview(TwoItems), Sha, store, TestClock.Reference, None), "choix D2 présent respecté quelle que soit sa forme");
            Check.Equal(before, Digest(path), "document D2 inchangé");
            Check.False(store.TryGet(LegacyBoardLayouts.EvidenceKey, out _), "aucune fausse preuve d’importation");
        }
    }

    [Test]
    public static async Task Latest_other_instance_choice_wins_and_other_preferences_are_preserved()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using var stale = new FilePreferenceStore(path, new RecordingJournal());
        using var other = new FilePreferenceStore(path, new RecordingJournal());
        Check.False(stale.TryGet(AccueilService.LayoutPreference, out _), "premier cache vide");
        await other.SetAsync("futur.choice", Json("{\"keep\":true}"), None);
        await other.SetAsync(AccueilService.LayoutPreference, Json("{\"version\":1,\"items\":[]}"), None);
        var before = Digest(path);
        Check.False(await LegacyBoardLayouts.ApplyFleetAsync(Preview(TwoItems), Sha, stale, TestClock.Reference, None), "dernier état disque lu sous verrou");
        Check.Equal(before, Digest(path), "choix concurrent et autres clés conservés octet pour octet");
    }

    [Test]
    public static async Task Two_imports_admit_one_complete_layout_and_evidence_pair()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using var a = new FilePreferenceStore(path, new RecordingJournal());
        using var b = new FilePreferenceStore(path, new RecordingJournal());
        var results = await Task.WhenAll(LegacyBoardLayouts.ApplyFleetAsync(Preview(TwoItems), Sha, a, TestClock.Reference, None),
            LegacyBoardLayouts.ApplyFleetAsync(Preview(TwoItems), Sha, b, TestClock.Reference, None));
        Check.Equal(1, results.Count(applied => applied), "un seul import gagne");
        using var read = new FilePreferenceStore(path, new RecordingJournal());
        Check.True(read.TryGet(AccueilService.LayoutPreference, out _), "disposition persistée");
        Check.True(read.TryGet(LegacyBoardLayouts.EvidenceKey, out _), "preuve persistée dans le même document atomique");
    }

    [Test]
    public static async Task A_d2_choice_racing_the_import_is_the_final_choice()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using var importer = new FilePreferenceStore(path, new RecordingJournal());
        using var operatorStore = new FilePreferenceStore(path, new RecordingJournal());
        var migration = LegacyBoardLayouts.ApplyFleetAsync(Preview(TwoItems), Sha, importer, TestClock.Reference, None);
        var choice = operatorStore.SetAsync(AccueilService.LayoutPreference, Json("{\"version\":1,\"items\":[]}"), None);
        await Task.WhenAll(migration, choice);
        using var fresh = new FilePreferenceStore(path, new RecordingJournal());
        Check.True(fresh.TryGet(AccueilService.LayoutPreference, out var final), "le choix est enregistré");
        Check.Equal(0, final.GetProperty("items").GetArrayLength(), "le choix explicite D2 gagne quel que soit l’ordre du verrou");
    }

    [Test]
    public static async Task A_pending_d2_choice_after_a_failed_write_also_blocks_migration()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using var store = new FilePreferenceStore(path, new RecordingJournal());
        await store.SetAsync("other.setting", Json("true"), None);
        using (var held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            await Check.ThrowsAsync<IOException>(() => store.SetAsync(AccueilService.LayoutPreference, Json("{\"version\":1,\"items\":[]}"), None), "échec de persistance observé, choix conservé en mémoire");
        }
        var before = Digest(path);
        Check.False(await LegacyBoardLayouts.ApplyFleetAsync(Preview(TwoItems), Sha, store, TestClock.Reference, None), "choix en attente prioritaire sur D1");
        Check.Equal(before, Digest(path), "pas de modification du disque");
        Check.True(store.TryGet(AccueilService.LayoutPreference, out var choice), "choix de session toujours présent");
        Check.Equal(0, choice.GetProperty("items").GetArrayLength(), "[] de session intact");
    }

    [Test]
    public static async Task Version_one_d2_document_with_unknown_root_fields_is_preserved()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        File.WriteAllText(path, "{\"format\":\"domenia.preferences\",\"version\":1,\"values\":{\"other.setting\":true},\"futureMetadata\":{\"keep\":true}}");
        var before = Digest(path);
        using var store = new FilePreferenceStore(path, new RecordingJournal());
        await Check.ThrowsAsync<InvalidDataException>(() => LegacyBoardLayouts.ApplyFleetAsync(Preview(TwoItems), Sha, store, TestClock.Reference, None), "extension de racine inconnue refusée, pas supprimée");
        Check.Equal(before, Digest(path), "document D2 original conservé octet pour octet");
        Check.False(store.TryGet(AccueilService.LayoutPreference, out _), "aucun choix migré en mémoire");
        Check.False(store.TryGet(LegacyBoardLayouts.EvidenceKey, out _), "aucune fausse preuve");
    }

    [Test]
    public static async Task Changed_source_precancellation_and_invalid_destination_do_not_create_a_choice()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using var store = new FilePreferenceStore(path, new RecordingJournal());
        await Check.ThrowsAsync<InvalidDataException>(() => LegacyBoardLayouts.ApplyFleetAsync(Preview(TwoItems), new string('b', 64), store, TestClock.Reference, None), "SHA périmé refusé");
        Check.False(File.Exists(path), "aucune écriture avec SHA périmé");
        using var canceled = new CancellationTokenSource();
        canceled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => LegacyBoardLayouts.ApplyFleetAsync(Preview(TwoItems), Sha, store, TestClock.Reference, canceled.Token), "annulation avant écriture");
        Check.False(File.Exists(path), "aucune écriture annulée");
        File.WriteAllText(path, "{\"format\":\"unknown\",\"version\":1,\"values\":{}}");
        var before = Digest(path);
        await Check.ThrowsAsync<InvalidDataException>(() => LegacyBoardLayouts.ApplyFleetAsync(Preview(TwoItems), Sha, store, TestClock.Reference, None), "document D2 incompatible refusé");
        Check.Equal(before, Digest(path), "document incompatible intact sans mise de côté ni remplacement");
    }
}
