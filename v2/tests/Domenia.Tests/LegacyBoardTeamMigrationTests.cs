using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Store;
using FleetProbes = Domenia.Core.Accueil.ProbeCatalog;

namespace Domenia.Tests;

internal static class LegacyBoardTeamMigrationTests
{
    private const string SettingsSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string TeamSha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    private const string TeamRows = "[{\"Id\":\"team-cpu\",\"Source\":\"Builtin\",\"Key\":\"computer.cpu.load\",\"Paused\":true},{\"Id\":\"team-os\",\"Source\":\"Builtin\",\"Key\":\"computer.os\"}]";
    private static readonly CancellationToken None = CancellationToken.None;
    private static JsonElement Json(string text) => JsonSerializer.Deserialize<JsonElement>(text);
    private static string Digest(string path) => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
    private static LegacyBoardConfiguration Config(object value, string board = "Computer") => new(@"C:\D1\Domenia.config.json", TeamSha,
        JsonSerializer.SerializeToElement(new { Dashboard = new Dictionary<string, object> { ["DefaultLayout" + board] = value } }));
    private static LegacyBoardPreview Preview(Dictionary<string, string> settings, LegacyBoardConfiguration config) =>
        LegacyBoardLayouts.Parse(JsonSerializer.SerializeToElement(settings), @"C:\D1\Preferences\Domenia.settings.json", SettingsSha, config);
    private static LegacyBoardProposal Computer(LegacyBoardPreview preview) => preview.Boards.Single(p => p.Board == "Computer");

    [Test]
    public static void Personal_empty_and_nonempty_dashboard_always_win_over_team_and_widgets()
    {
        foreach (var layout in new[] { "[]", TeamRows })
        {
            var preview = Preview(new() { ["Dashboard.Computer.Layout"] = layout, ["Widgets.Computer"] = "[{\"ProbeId\":\"unknown\"}]" }, Config(42));
            var chosen = Computer(preview);
            Check.Equal("ready", chosen.State, "configuration d’équipe invalide ignorée pour un choix personnel explicite");
            Check.Equal(layout == "[]" ? 0 : 2, chosen.Items.Length, "aucun élément de l’équipe ou des anciennes sondes ajouté");
            Check.Null(chosen.TeamSource, "seule la source réellement utilisée est liée");
        }
    }

    [Test]
    public static void Team_array_string_and_exported_document_keep_order_ids_and_pause()
    {
        foreach (var value in new object[] { TeamRows, Json(TeamRows), Json("{\"Format\":\"Domenia.BoardLayout.1\",\"Board\":\"Computer\",\"Layout\":" + TeamRows + "}") })
        {
            var chosen = Computer(Preview(new() { ["Widgets.Computer"] = "[]" }, Config(value)));
            Check.Equal("ready", chosen.State, "formats D1 d’équipe admis");
            Check.Equal(2, chosen.Items.Length, "équipe remplace les14défauts");
            Check.Equal("team-cpu", chosen.Items[0].Id, "ordre et identifiant de l’équipe");
            Check.True(chosen.Items[0].Paused, "pause conservée");
            Check.Equal("[]", chosen.OriginalLayout, "ancienne valeur Widgets exacte conservée séparément");
            Check.Equal(TeamSha, chosen.TeamSource!.Sha256, "empreinte de configuration distincte");
        }
    }

    [Test]
    public static void Fleet_team_precedes_real_legacy_probes_without_reinserting_catalog_defaults()
    {
        var probe = FleetProbes.All[0];
        var preview = Preview(new() { ["Widgets.Fleet"] = JsonSerializer.Serialize(new[] { new { Id = "old", ProbeId = probe.Id, Paused = true } }) },
            Config("[{\"Id\":\"team\",\"Source\":\"Builtin\",\"Key\":\"fleet.os\"}]", "Fleet"));
        var fleet = preview.Boards.Single(p => p.Board == "Fleet");
        Check.Equal("ready", fleet.State, "équipe et sonde supportées");
        Check.Equal(2, fleet.Items.Length, "une carte équipe puis une sonde, aucun défaut inséré");
        Check.Equal("team", fleet.Items[0].Id, "équipe d’abord");
        Check.Equal("p-old", fleet.Items[1].Id, "identifiant historique de sonde");
        Check.True(fleet.Items[1].Paused, "pause de l’addition conservée");
    }

    [Test]
    public static void Empty_team_cannot_empty_a_board_and_unsupported_team_is_never_partially_migrated()
    {
        var empty = Computer(Preview(new() { ["Widgets.Computer"] = "[]" }, Config("[]")));
        Check.Equal(14, empty.Items.Length, "équipe vide signifie défauts livrés, comme D1");
        Check.Null(empty.TeamSource, "équipe vide non utilisée");
        foreach (var text in new[] { "[{\"Source\":\"Builtin\",\"Key\":\"computer.unknown\"}]", "[{\"Source\":\"Query\",\"Key\":\"personal\"}]",
            "{\"Format\":\"Domenia.BoardLayout.1\",\"Board\":\"Software\",\"Layout\":" + TeamRows + "}", "{", new string('x', LegacyBoardLayouts.MaxLayoutBytes + 1) })
        {
            var rejected = Computer(Preview(new() { ["Widgets.Computer"] = "[]" }, Config(text)));
            Check.Equal("incompatible", rejected.State, "configuration incompatible refusée entière");
            Check.Equal(0, rejected.Items.Length, "pas de faux défaut substitué");
        }
    }

    [Test]
    public static async Task Two_real_local_sources_are_imported_atomically_and_originals_remain_unchanged()
    {
        using var folder = new TemporaryFolder();
        var app = folder.File("app"); var user = folder.File("user");
        Directory.CreateDirectory(app); Directory.CreateDirectory(Path.Combine(user, "Data", "Preferences"));
        var configPath = Path.Combine(app, "Domenia.config.json");
        File.WriteAllText(configPath, JsonSerializer.Serialize(new { LocalStore = new { Mode = "UserLocal" },
            Dashboard = new { DefaultLayoutComputer = TeamRows }, UnrelatedCredential = "NEVER-COPY-CONFIG-SECRET" }));
        var settingsPath = Path.Combine(user, "Data", "Preferences", "Domenia.settings.json");
        File.WriteAllText(settingsPath, "{\"Widgets.Computer\":\"[]\"}");
        var beforeConfig = Digest(configPath); var beforeSettings = Digest(settingsPath);
        var preview = LegacyBoardLayoutFile.Read(app, user, None);
        var path = folder.File("preferences.json");
        using (var store = new FilePreferenceStore(path, new RecordingJournal()))
        {
            Check.True(await LegacyBoardLayouts.ApplyAsync(preview, "Computer", beforeSettings, store, TestClock.Reference, None, beforeConfig,
                token => LegacyBoardLayoutFile.HoldSources(preview, "Computer", token)), "deux empreintes acceptées et tenues pendant le commit");
        }
        using var fresh = new FilePreferenceStore(path, new RecordingJournal());
        Check.Equal("team-cpu", PosteBoardLayouts.Read(fresh, "Computer").Items[0].Id, "vrai consommateur relit l’équipe importée");
        Check.True(fresh.TryGet(PosteBoardLayouts.EvidenceKey("Computer"), out var proof), "preuve atomique présente");
        Check.Equal(beforeSettings, proof.GetProperty("sourceSha256").GetString(), "empreinte primaire settings inchangée de sens");
        Check.Equal("[]", proof.GetProperty("originalLayout").GetString(), "original Widgets");
        var configuration = proof.GetProperty("configuration");
        Check.Equal(beforeConfig, configuration.GetProperty("sourceSha256").GetString(), "empreinte exacte de configuration");
        Check.Equal(JsonSerializer.Serialize(TeamRows), configuration.GetProperty("originalLayout").GetString(), "valeur JSON de l’équipe conservée exactement");
        Check.False(proof.GetRawText().Contains("NEVER-COPY-CONFIG-SECRET", StringComparison.Ordinal), "aucune copie de champs de configuration étrangers");
        Check.Equal(beforeSettings, Digest(settingsPath), "settings D1 inchangés");
        Check.Equal(beforeConfig, Digest(configPath), "configuration D1 inchangée");
    }

    [Test]
    public static async Task Changed_added_or_removed_team_source_refuses_stale_preview_without_any_write()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using var store = new FilePreferenceStore(path, new RecordingJournal());
        var settings = new Dictionary<string, string> { ["Widgets.Computer"] = "[]" };
        var old = Preview(settings, Config(TeamRows));
        var changed = Preview(settings, Config(TeamRows) with { Sha256 = new string('c', 64) });
        await Check.ThrowsAsync<InvalidDataException>(() => LegacyBoardLayouts.ApplyAsync(changed, "Computer", SettingsSha, store, TestClock.Reference, None, TeamSha), "configuration modifiée");
        await Check.ThrowsAsync<InvalidDataException>(() => LegacyBoardLayouts.ApplyAsync(old, "Computer", SettingsSha, store, TestClock.Reference, None), "configuration ajoutée après aperçu sans équipe");
        var removed = LegacyBoardLayouts.Parse(JsonSerializer.SerializeToElement(settings), @"C:\settings.json", SettingsSha);
        await Check.ThrowsAsync<InvalidDataException>(() => LegacyBoardLayouts.ApplyAsync(removed, "Computer", SettingsSha, store, TestClock.Reference, None, TeamSha), "configuration retirée depuis l’aperçu");
        await Check.ThrowsAsync<InvalidDataException>(() => LegacyBoardLayouts.ApplyAsync(old, "Computer", new string('d', 64), store, TestClock.Reference, None, TeamSha), "settings modifiés aussi comparés");
        Check.False(File.Exists(path), "aucun document ni preuve écrit");
    }

    [Test]
    public static async Task Config_only_source_is_local_and_can_fill_an_absent_software_choice()
    {
        using var folder = new TemporaryFolder();
        var app = folder.File("app"); var user = folder.File("user");
        Directory.CreateDirectory(app); Directory.CreateDirectory(user);
        var configPath = Path.Combine(app, "Domenia.config.json");
        File.WriteAllText(configPath, "{\"Dashboard\":{\"DefaultLayoutSoftware\":[{\"Source\":\"Builtin\",\"Key\":\"software.count\",\"Id\":\"team-soft\"}]}}");
        var preview = LegacyBoardLayoutFile.Read(app, user, None);
        Check.Equal("configuration", preview.SourceKind, "source primaire annoncée");
        Check.Equal(configPath, preview.SourcePath, "aucun fichier settings créé pour simuler une source");
        var sha = Digest(configPath);
        using var store = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal());
        Check.True(await LegacyBoardLayouts.ApplyAsync(preview, "Software", sha, store, TestClock.Reference, None, sha), "équipe seule importée explicitement");
        Check.Equal("team-soft", PosteBoardLayouts.Read(store, "Software").Items.Single().Id, "vrai consommateur logiciels");
        Check.False(File.Exists(Path.Combine(app, "Domenia.settings.json")), "aucune création D1");
    }

    [Test]
    public static async Task Team_import_preserves_a_concurrent_empty_d2_choice_and_is_cancellable()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using var stale = new FilePreferenceStore(path, new RecordingJournal());
        using var other = new FilePreferenceStore(path, new RecordingJournal());
        var preview = Preview(new(), Config(TeamRows));
        using var canceled = new CancellationTokenSource(); canceled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => LegacyBoardLayouts.ApplyAsync(preview, "Computer", SettingsSha, stale, TestClock.Reference, canceled.Token, TeamSha), "annulation avant écriture");
        await PosteBoardLayouts.SaveAsync(other, "Computer", [], None);
        var before = Digest(path);
        Check.False(await LegacyBoardLayouts.ApplyAsync(preview, "Computer", SettingsSha, stale, TestClock.Reference, None, TeamSha), "choix D2 concurrent prioritaire sur l’équipe");
        Check.Equal(before, Digest(path), "octets du choix D2 inchangés");
    }

    [Test]
    public static async Task Sources_are_rechecked_after_waiting_for_the_destination_and_failure_writes_no_proof()
    {
        using var folder = new TemporaryFolder();
        var configPath = folder.File("Domenia.config.json");
        var settingsPath = folder.File("Domenia.settings.json");
        File.WriteAllText(configPath, "{\"Dashboard\":{\"DefaultLayoutComputer\":" + TeamRows + "}}");
        File.WriteAllText(settingsPath, "{\"Widgets.Computer\":\"[]\"}");
        var config = new LegacyBoardConfiguration(configPath, Digest(configPath), Json(File.ReadAllText(configPath)));
        var preview = LegacyBoardLayoutFile.ReadCandidates([settingsPath], None, config);
        var destination = folder.File("preferences.json");
        using var store = new FilePreferenceStore(destination, new RecordingJournal());
        var invoked = false;
        await Check.ThrowsAsync<InvalidDataException>(() => LegacyBoardLayouts.ApplyAsync(preview, "Computer", preview.SourceSha256!, store,
            TestClock.Reference, None, config.Sha256, token =>
            {
                invoked = true;
                File.AppendAllText(configPath, " "); // a byte change after the preview, at the actual import boundary
                return LegacyBoardLayoutFile.HoldSources(preview, "Computer", token);
            }), "modification tardive de la deuxième source détectée");
        Check.True(invoked, "qualification appelée dans la phase réelle d’import");
        Check.False(File.Exists(destination), "aucune écriture ni preuve avant vérification des deux sources");
        Check.False(store.TryGet(PosteBoardLayouts.PreferenceKey("Computer"), out _), "aucun choix optimiste en mémoire");
        // Opening the first source did not leak its handle when checking the second failed.
        File.AppendAllText(settingsPath, " ");
    }

    [Test]
    public static void Source_lease_holds_both_files_only_until_dispose_and_never_modifies_them()
    {
        using var folder = new TemporaryFolder();
        var configPath = folder.File("Domenia.config.json");
        var settingsPath = folder.File("Domenia.settings.json");
        File.WriteAllText(configPath, "{\"Dashboard\":{\"DefaultLayoutComputer\":" + TeamRows + "}}");
        File.WriteAllText(settingsPath, "{\"Widgets.Computer\":\"[]\"}");
        var config = new LegacyBoardConfiguration(configPath, Digest(configPath), Json(File.ReadAllText(configPath)));
        var preview = LegacyBoardLayoutFile.ReadCandidates([settingsPath], None, config);
        using (LegacyBoardLayoutFile.HoldSources(preview, "Computer", None))
        {
            Check.Throws<IOException>(() => File.WriteAllText(settingsPath, "changed"), "settings tenus en lecture pendant l’écriture atomique");
            Check.Throws<IOException>(() => File.WriteAllText(configPath, "changed"), "configuration tenue aussi");
            Check.Equal(config.Sha256, Digest(configPath), "original intact");
        }
        File.AppendAllText(settingsPath, " ");
        File.AppendAllText(configPath, " ");
    }

    [Test]
    public static void Team_and_legacy_additions_share_one_bound_without_truncation()
    {
        var team = JsonSerializer.Serialize(Enumerable.Range(0, 64).Select(n => new { Id = "t" + n, Source = "Builtin", Key = "fleet.os" }));
        var preview = Preview(new() { ["Widgets.Fleet"] = JsonSerializer.Serialize(new[] { new { ProbeId = FleetProbes.All[0].Id } }) }, Config(team, "Fleet"));
        var fleet = preview.Boards.Single(p => p.Board == "Fleet");
        Check.Equal("incompatible", fleet.State, "65 cartes cumulées refusées");
        Check.Equal(0, fleet.Items.Length, "aucune troncature silencieuse");
    }
}
