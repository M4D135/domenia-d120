using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Store;

namespace Domenia.Tests;

internal static class LegacyBoardDeliveredMigrationTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private const string SourceSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string TeamSha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    // Exact D1 fixtures (not reconstructed from D2's current catalog).
    // dev/wad/modules/Domenia-Boards.Model.ps1 SHA-256: ffe3ec9a7e62b91f4119a6e1ece06fb3e70b295371f3731f52b365dc50a3f5ca
    private static readonly (string Board, string Text)[] Fixtures =
    [
        ("Fleet", """
        fleet.health|Vue d ensemble|Health|S
        fleet.attention|Vue d ensemble|List|L
        fleet.machines|Inventaire du perimetre|Kpi|S
        fleet.stale|Inventaire du perimetre|Kpi|S
        fleet.win10|Inventaire du perimetre|Kpi|S
        fleet.users|Inventaire du perimetre|Kpi|S
        fleet.lastcheck|Inventaire du perimetre|Kpi|S
        fleet.os|Repartition|Pie|M
        fleet.lastlogon|Repartition|Column|M
        fleet.ou|Repartition|Bar|M
        fleet.presence|Repartition|Pie|M
        fleet.models|Releves WMI|Bar|M
        fleet.releases|Releves WMI|Pie|M
        fleet.ram|Releves WMI|Column|M
        fleet.diskfree|Releves WMI|Column|M
        fleet.lowdisk|Releves WMI|Kpi|S
        fleet.uptime|Releves WMI|Kpi|S
        """),
        ("Fleet", """
        fleet.health|Santé|Health|S
        fleet.attention|Santé|List|L
        fleet.machines|Inventaire du périmètre|Kpi|S
        fleet.enabled|Inventaire du périmètre|Kpi|S
        fleet.accountstatus|Inventaire du périmètre|Pie|M
        fleet.stale|Inventaire du périmètre|Kpi|S
        fleet.disabled|Inventaire du périmètre|Kpi|S
        fleet.created|Inventaire du périmètre|Kpi|S
        fleet.pwdold|Inventaire du périmètre|Kpi|S
        fleet.laps|Sécurité|Kpi|S
        fleet.bitlocker|Sécurité|Kpi|S
        fleet.versions|Versions de Windows|Pie|M
        fleet.eos|Versions de Windows|Kpi|S
        fleet.win10|Versions de Windows|Kpi|S
        fleet.os|Répartition|Pie|M
        fleet.lastlogon|Répartition|Column|M
        fleet.ou|Répartition|Bar|M
        """),
        ("Computer", """
        computer.health|Vue d ensemble|Health|S
        computer.attention|Vue d ensemble|List|L
        computer.os|Identite du poste|Kpi|S
        computer.model|Identite du poste|Kpi|S
        computer.cpu|Identite du poste|Kpi|S
        computer.memory|Identite du poste|Kpi|S
        computer.uptime|Identite du poste|Kpi|S
        computer.user|Identite du poste|Kpi|S
        computer.ip|Identite du poste|Kpi|S
        computer.domain|Identite du poste|Kpi|S
        computer.ad.password|Compte machine dans Active Directory|Kpi|S
        computer.ad.lastlogon|Compte machine dans Active Directory|Kpi|S
        computer.ad.account|Compte machine dans Active Directory|Kpi|S
        computer.ad.ou|Compte machine dans Active Directory|Kpi|S
        computer.ad.laps|Compte machine dans Active Directory|Kpi|S
        computer.ad.managedby|Compte machine dans Active Directory|Kpi|S
        computer.ad.clock|Compte machine dans Active Directory|Kpi|S
        computer.memory.usage|Ressources|Gauge|S
        computer.cpu.load|Ressources|Gauge|S
        computer.battery|Ressources|Gauge|S
        computer.disk.system|Ressources|Pie|M
        computer.disk.volumes|Ressources|Bar|M
        computer.services|Activite|Pie|M
        computer.processes|Activite|Bar|L
        computer.events|Activite|Bar|M
        computer.antivirus|Securite et etat|Kpi|S
        computer.firewall|Securite et etat|Kpi|S
        computer.bitlocker|Securite et etat|Kpi|S
        computer.wsus|Securite et etat|Kpi|S
        computer.reboot|Securite et etat|Kpi|S
        computer.services.stopped|Securite et etat|Kpi|S
        computer.devices|Securite et etat|Kpi|S
        computer.drivers|Securite et etat|Kpi|S
        computer.admins|Securite et etat|Kpi|S
        computer.sessions|Securite et etat|Kpi|S
        computer.autostart|Securite et etat|Kpi|S
        computer.shares|Securite et etat|Kpi|S
        computer.printers|Securite et etat|Kpi|S
        computer.display|Securite et etat|Kpi|S
        computer.physicaldisk|Securite et etat|Kpi|S
        computer.certificates|Securite et etat|Kpi|S
        computer.hotfix|Securite et etat|Kpi|S
        """),
        ("Computer", """
        computer.health|Vue d ensemble|Health|S
        computer.attention|Vue d ensemble|List|L
        computer.os|Identite du poste|Kpi|S
        computer.model|Identite du poste|Kpi|S
        computer.cpu|Identite du poste|Kpi|S
        computer.memory|Identite du poste|Kpi|S
        computer.uptime|Identite du poste|Kpi|S
        computer.user|Identite du poste|Kpi|S
        computer.ip|Identite du poste|Kpi|S
        computer.domain|Identite du poste|Kpi|S
        computer.ad.password|Compte machine dans Active Directory|Kpi|S
        computer.ad.lastlogon|Compte machine dans Active Directory|Kpi|S
        computer.ad.account|Compte machine dans Active Directory|Kpi|S
        computer.ad.ou|Compte machine dans Active Directory|Kpi|S
        computer.ad.laps|Compte machine dans Active Directory|Kpi|S
        computer.ad.managedby|Compte machine dans Active Directory|Kpi|S
        computer.ad.clock|Compte machine dans Active Directory|Kpi|S
        computer.memory.usage|Ressources|Gauge|S
        computer.cpu.load|Ressources|Gauge|S
        computer.battery|Ressources|Gauge|S
        computer.disk.system|Ressources|Pie|M
        computer.disk.volumes|Ressources|Bar|M
        computer.services|Activite|Pie|M
        computer.processes|Activite|Bar|L
        computer.events|Activite|Bar|M
        computer.antivirus|Securite et etat|Kpi|S
        computer.firewall|Securite et etat|Kpi|S
        computer.bitlocker|Securite et etat|Kpi|S
        computer.secureboot|Securite et etat|Kpi|S
        computer.updates|Securite et etat|Kpi|S
        computer.wsus|Securite et etat|Kpi|S
        computer.reboot|Securite et etat|Kpi|S
        computer.services.stopped|Securite et etat|Kpi|S
        computer.devices|Securite et etat|Kpi|S
        computer.drivers|Securite et etat|Kpi|S
        computer.admins|Securite et etat|Kpi|S
        computer.sessions|Securite et etat|Kpi|S
        computer.autostart|Securite et etat|Kpi|S
        computer.shares|Securite et etat|Kpi|S
        computer.printers|Securite et etat|Kpi|S
        computer.display|Securite et etat|Kpi|S
        computer.physicaldisk|Securite et etat|Kpi|S
        computer.certificates|Securite et etat|Kpi|S
        computer.hotfix|Securite et etat|Kpi|S
        """),
    ];
    private static string Layout(string text) => JsonSerializer.Serialize(text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select((line, i) =>
    {
        var cells = line.Trim().Split('|');
        return new { Id = "operator-id-" + i, Source = "Builtin", Key = cells[0], Group = cells[1], Visual = cells[2], Size = cells[3], Title = "", Paused = false };
    }));
    private static LegacyBoardPreview Preview(string board, string layout, LegacyBoardConfiguration? config = null) =>
        LegacyBoardLayouts.Parse(JsonSerializer.SerializeToElement(new Dictionary<string, string>
        { ["Dashboard." + board + ".Layout"] = layout, ["Widgets." + board] = "[{\"ProbeId\":\"must-not-be-selected\"}]" }), @"C:\D1\Domenia.settings.json", SourceSha, config);
    private static LegacyBoardProposal Proposal(LegacyBoardPreview preview, string board) => preview.Boards.Single(p => p.Board == board);
    private static LegacyBoardConfiguration Config(string board, object value) => new(@"C:\D1\Domenia.config.json", TeamSha,
        JsonSerializer.SerializeToElement(new { Dashboard = new Dictionary<string, object> { ["DefaultLayout" + board] = value } }));
    private static string Key(string board) => board == "Fleet" ? AccueilService.LayoutPreference : PosteBoardLayouts.PreferenceKey(board);

    [Test]
    public static async Task Four_exact_old_delivered_layouts_migrate_into_the_real_consumers_and_keep_the_original()
    {
        foreach (var (board, text) in Fixtures)
        {
            var original = Layout(text); var preview = Preview(board, original); var proposal = Proposal(preview, board);
            Check.Equal("ready", proposal.State, "ancienne disposition inchangée compatible");
            Check.Contains("Ancienne disposition livrée", proposal.Summary, "remplacement explicitement annoncé dans l’aperçu");
            var expected = board == "Fleet" ? FleetCatalog.DefaultLayout() : PosteBoardLayouts.Defaults(board);
            Check.True(expected.SequenceEqual(proposal.Items), "défaut actuel réellement proposé, identifiants anciens ignorés comme D1");
            using var folder = new TemporaryFolder(); using var store = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal());
            Check.True(await LegacyBoardLayouts.ApplyAsync(preview, board, SourceSha, store, TestClock.Reference, None), "import explicite atomique");
            var bridge = new SimulatedBridge(preferences: store);
            var result = SimulatedBridge.Json(await bridge.CallAsync(board == "Fleet" ? "accueil.layout" : "poste.layout.get",
                board == "Fleet" ? "{}" : JsonSerializer.Serialize(new { board })));
            Check.True(expected.SequenceEqual(result.GetProperty("items").Deserialize<FleetLayoutItem[]>(BridgeJson.Options)!), "vrai écran lit le défaut migré");
            Check.True(store.TryGet(board == "Fleet" ? LegacyBoardLayouts.EvidenceKey : PosteBoardLayouts.EvidenceKey(board), out var proof), "preuve conservée");
            Check.Equal(original, proof.GetProperty("originalLayout").GetString(), "texte Dashboard original exact");
            Check.Equal(SourceSha, proof.GetProperty("sourceSha256").GetString(), "empreinte source exacte");
            Check.Equal("Dashboard." + board + ".Layout", proof.GetProperty("setting").GetString(), "origine non remplacée par un faux Widgets");
        }
    }

    [Test]
    public static void Any_operator_change_and_an_explicit_empty_list_prevent_the_delivered_upgrade()
    {
        foreach (var (board, text) in Fixtures)
        {
            foreach (var change in new[] { "title", "pause", "size", "visual", "group", "order", "empty" })
            {
                var rows = JsonNode.Parse(Layout(text))!.AsArray();
                if (change == "title") rows[0]!["Title"] = "Mon tableau";
                if (change == "pause") rows[0]!["Paused"] = true;
                if (change == "size") rows[0]!["Size"] = "L";
                if (change == "visual") rows[0]!["Visual"] = "Kpi";
                if (change == "group") rows[0]!["Group"] = "Ma section";
                if (change == "order") { var first = rows[0]; rows.RemoveAt(0); rows.Add(first); }
                if (change == "empty") rows.Clear();
                var original = rows.ToJsonString();
                var proposal = Proposal(Preview(board, original, Config(board, 42)), board);
                Check.Equal("ready", proposal.State, "configuration d’équipe invalide ignorée devant un vrai choix personnel : " + change);
                Check.Equal(rows.Count, proposal.Items.Length, "aucune carte par défaut ajoutée : " + change);
                Check.False(proposal.Summary.Contains("Ancienne disposition livrée", StringComparison.Ordinal), "aucune personnalisation reconnue comme défaut inchangé");
                Check.Equal(original, proposal.OriginalLayout, "source exacte préservée");
                Check.Null(proposal.TeamSource, "aucune équipe utilisée");
            }
        }
    }

    [Test]
    public static async Task Team_default_wins_for_an_unchanged_delivery_but_does_not_reinterpret_its_own_rows()
    {
        foreach (var (board, text) in Fixtures)
        {
            var original = Layout(text);
            var team = JsonSerializer.Serialize(new[] { new { Id = "team", Source = "Builtin", Key = board == "Fleet" ? "fleet.os" : "computer.os", Paused = true } });
            var preview = Preview(board, original, Config(board, team));
            var proposal = Proposal(preview, board);
            Check.Equal("team", proposal.Items.Single().Id, "équipe prioritaire, Widgets obsolète non ajouté");
            Check.True(proposal.Items[0].Paused, "pause de l’équipe gardée");
            Check.Equal(original, proposal.OriginalLayout, "source personnelle conservée séparément de l’équipe");
            Check.Equal(TeamSha, proposal.TeamSource!.Sha256, "seconde source liée à l’import");
            using var folder = new TemporaryFolder(); using var store = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal());
            await Check.ThrowsAsync<InvalidDataException>(() => LegacyBoardLayouts.ApplyAsync(preview, board, SourceSha, store, TestClock.Reference, None), "empreinte de la deuxième source obligatoirement confirmée");
            Check.True(await LegacyBoardLayouts.ApplyAsync(preview, board, SourceSha, store, TestClock.Reference, None, TeamSha), "deux sources confirmées");
            var explicitlyOldTeam = Proposal(Preview(board, original, Config(board, original)), board);
            Check.Equal("ready", explicitlyOldTeam.State, "pas de récursion de migration d’équipe");
            using var originalDocument = JsonDocument.Parse(original);
            Check.Equal(originalDocument.RootElement.GetArrayLength(), explicitlyOldTeam.Items.Length, "équipe choisie explicitement garde toutes ses cartes");
            Check.Equal("operator-id-0", explicitlyOldTeam.Items[0].Id, "identifiant défini par l’équipe conservé");
        }
    }

    [Test]
    public static async Task Old_default_migration_preserves_a_concurrent_empty_D2_choice()
    {
        foreach (var (board, text) in Fixtures)
        {
            using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
            using var stale = new FilePreferenceStore(path, new RecordingJournal());
            using var other = new FilePreferenceStore(path, new RecordingJournal());
            await other.SetAsync(Key(board), JsonSerializer.SerializeToElement(new { version = 1, items = Array.Empty<object>() }), None);
            var before = File.ReadAllBytes(path);
            Check.False(await LegacyBoardLayouts.ApplyAsync(Preview(board, Layout(text)), board, SourceSha, stale, TestClock.Reference, None), "choix D2 concurrent intact");
            Check.True(before.SequenceEqual(File.ReadAllBytes(path)), "octets inchangés, aucune preuve orpheline");
        }
    }
    [Test]
    public static async Task A_personal_fleet_section_survives_real_migration_edit_history_and_restore()
    {
        using var folder = new TemporaryFolder(); using var store = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal());
        var original = JsonSerializer.Serialize(new[] { new { Id = "personal", Source = "Builtin", Key = "fleet.machines", Group = "Mon équipe", Paused = true } });
        var preview = Preview("Fleet", original);
        Check.True(await LegacyBoardLayouts.ApplyAsync(preview, "Fleet", SourceSha, store, TestClock.Reference, None), "vrai import personnel");
        var bridge = new SimulatedBridge(preferences: store);
        var first = SimulatedBridge.Json(await bridge.CallAsync("accueil.layout", "{}"));
        var items = first.GetProperty("items").Deserialize<FleetLayoutItem[]>(BridgeJson.Options) ?? throw new TestFailureException("Cartes absentes.");
        Check.Equal("Mon équipe", items.Single().Group, "section D1 conservée dans le vrai consommateur");
        var changed = SimulatedBridge.Json(await bridge.CallAsync("accueil.layout.save", JsonSerializer.Serialize(new
        { items = new[] { items[0] with { Group = "Ma section déplacée" } }, expectedChoiceToken = first.GetProperty("choiceToken").GetString() }, BridgeJson.Options)));
        Check.Equal("Ma section déplacée", changed.GetProperty("items")[0].GetProperty("group").GetString(), "groupe choisi conservé après écriture");
        var restored = SimulatedBridge.Json(await bridge.CallAsync("accueil.layout.restore", JsonSerializer.Serialize(new
        { versionId = changed.GetProperty("history")[0].GetProperty("id").GetString(), expectedChoiceToken = changed.GetProperty("choiceToken").GetString() })));
        Check.Equal("Mon équipe", restored.GetProperty("items")[0].GetProperty("group").GetString(), "historique restaure la section personnelle");
        Check.True(restored.GetProperty("items")[0].GetProperty("paused").GetBoolean(), "pause gardée dans tous les parcours");
    }

}
