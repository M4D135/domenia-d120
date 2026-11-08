using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>Real preference consumers and explicit local D1 import. Written for the final Windows VM run; no remote reads.</summary>
internal static class PosteBoardLayoutTests
{
    private const string Sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private static readonly CancellationToken None = CancellationToken.None;
    private static JsonElement Json(string text) => JsonSerializer.Deserialize<JsonElement>(text);
    private static string Args(object value) => JsonSerializer.Serialize(value, PosteBoardLayouts.Json);
    private static LegacyBoardPreview Preview(string board, string text, bool legacy = false) => LegacyBoardLayouts.Parse(
        JsonSerializer.SerializeToElement(new Dictionary<string, string> { [legacy ? "Widgets." + board : "Dashboard." + board + ".Layout"] = text }),
        @"C:\D1\Preferences\Domenia.settings.json", Sha);
    private static string Digest(string path) => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
    private static FleetLayoutItem Item(string id, string key, bool paused = false) =>
        new(id, FleetWidgetSource.Builtin, key, "Pie", "S", "Mon titre", paused, "Mon groupe");

    [Test]
    public static async Task Actual_visual_choices_and_sections_survive_migration_and_manual_roundtrip()
    {
        const string text = "[{\"Id\":\"ram\",\"Source\":\"Builtin\",\"Key\":\"computer.memory.usage\",\"Visual\":\"Text\",\"Group\":\"Ressources\"},{\"Id\":\"services\",\"Source\":\"Builtin\",\"Key\":\"computer.services\",\"Visual\":\"Column\",\"Group\":\"Activité\",\"Paused\":true}]";
        var preview = Preview("Computer", text);
        var proposal = preview.Boards.Single(p => p.Board == "Computer");
        Check.Equal("Text", proposal.Items[0].Visual, "présentation D1 compatible conservée");
        Check.Equal("Column", proposal.Items[1].Visual, "histogramme réellement proposé");
        using var folder = new TemporaryFolder(); var path = folder.File("preferences.json");
        using (var store = new FilePreferenceStore(path, new RecordingJournal()))
        {
            Check.True(await LegacyBoardLayouts.ApplyAsync(preview, "Computer", Sha, store, TestClock.Reference, None), "import complet");
            var chosen = PosteBoardLayouts.Read(store, "Computer").Items;
            await PosteBoardLayouts.SaveAsync(store, "Computer", [chosen[1] with { Group = "Ma section", Visual = "Bar" }, chosen[0]], None);
        }
        using var fresh = new FilePreferenceStore(path, new RecordingJournal());
        var actual = PosteBoardLayouts.Read(fresh, "Computer");
        Check.Equal("services", actual.Items[0].Id, "ordre demandé");
        Check.Equal("Ma section", actual.Items[0].Group, "section demandée");
        Check.Equal("Bar", actual.Items[0].Visual, "présentation demandée");
        Check.True(actual.Items[0].Paused, "pause intacte");
        var volumes = PosteBoardLayouts.Catalog("Computer").Single(d => d.Key == "computer.disk.volumes");
        Check.False(volumes.Visuals.Contains("Pie"), "des pourcentages indépendants ne sont pas des parts d’un total");
        Check.Equal("Bar", PosteBoardLayouts.Normalize("Computer", [new("volumes", FleetWidgetSource.Builtin, volumes.Key, "Pie", "M", null, false, "")]).Single().Visual, "ancien anneau adapté à des barres");
        foreach (var board in new[] { "Computer", "Software" })
        {
            foreach (var definition in PosteBoardLayouts.Catalog(board))
            {
                Check.True(definition.Visuals.Contains(definition.Visual), "défaut autorisé pour " + definition.Key);
                foreach (var visual in definition.Visuals)
                {
                    var item = new FleetLayoutItem("test", definition.Source, definition.Key, visual, "S", null, false, "Section");
                    Check.Equal(visual, PosteBoardLayouts.Normalize(board, [item]).Single().Visual, "présentation du vrai catalogue conservée");
                }
            }
        }
    }

    [Test]
    public static async Task Probe_operation_reads_only_cache_and_rejects_a_different_guid_at_the_same_dn()
    {
        var bridge = new SimulatedBridge();
        var local = await bridge.Source.ReadLocalAsync(None);
        var computer = local.Directory.Computers.First();
        var scalar = Domenia.Core.Accueil.ProbeCatalog.All.First(p => Domenia.Core.Poste.ProbeCatalog.Find(p.Id) is null);
        foreach (var probe in new[] { scalar.Id, "hw.memorymodules" })
        {
            var response = await bridge.CallAsync("poste.layout.probe", Args(new { dn = computer.DistinguishedName, computer = computer.ObjectGuid, probe, page = 1 }));
            Check.Equal("result", response.Kind, "vraie opération locale : " + response.Error?.Message);
            Check.Equal(probe, SimulatedBridge.Json(response).GetProperty("probe").GetProperty("id").GetString(), "sonde demandée seulement");
        }
        var wrong = await bridge.CallAsync("poste.layout.probe", Args(new { dn = computer.DistinguishedName, computer = Guid.NewGuid(), probe = scalar.Id, page = 1 }));
        Check.Equal("error", wrong.Kind, "GUID remplacé refusé avant affichage");
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune écriture ni collecte implicite");
    }

    [Test]
    public static void Every_scalar_probe_uses_the_real_shared_transform_and_keeps_missing_stale_and_refused_unknown()
    {
        var scalar = Domenia.Core.Accueil.ProbeCatalog.All.Where(p => Domenia.Core.Poste.ProbeCatalog.Find(p.Id) is null).ToArray();
        Check.Equal(78, scalar.Length, "catalogue scalaire D1 complet");
        foreach (var probe in scalar)
        {
            var reading = new ProbeReading(MeasureState.Known, TestClock.Reference, ["32"], null) { DefinitionHash = ProbeDefinitionIdentity.Of(probe) };
            var page = PosteScalarProbeCards.Build(probe, reading, 1, TestClock.Reference, TimeZoneInfo.Utc);
            var expected = Domenia.Core.Accueil.ProbeCatalog.Values(probe, reading, TestClock.Reference);
            Check.Equal(expected.Length, page.Total, "même projection que D1 pour " + probe.Id);
            Check.True(page.Rows.Select(r => r[0]).SequenceEqual(expected.Select(v => v + Domenia.Core.Accueil.ProbeCatalog.Unit(probe))), "transformation et unité exactes pour " + probe.Id);
            foreach (var unknown in new ProbeReading?[] { null, reading with { State = MeasureState.Refused, Values = [] }, reading with { Error = "Refus", Values = [] } })
            {
                var missing = PosteScalarProbeCards.Build(probe, unknown, 1, TestClock.Reference, TimeZoneInfo.Utc);
                Check.Equal(0, missing.Rows.Length, "absence ou refus sans historique : aucun zéro fabriqué");
                Check.True(missing.Status.State != ProbeState.Read, "aucune réussite inventée");
            }
            var refusedWithData = PosteScalarProbeCards.Build(probe, reading with { State = MeasureState.Refused }, 1, TestClock.Reference, TimeZoneInfo.Utc);
            Check.True(refusedWithData.Rows.Select(r => r[0]).SequenceEqual(reading.Values), "refus avec valeurs conservées : historique brut sans unité");
            Check.Equal(ProbeState.Refused, refusedWithData.Status.State, "historique ne masque pas le refus");
            foreach (var hash in new string?[] { null, new string('f', 64) })
            {
                var oldDefinition = PosteScalarProbeCards.Build(probe, reading with { DefinitionHash = hash }, 1, TestClock.Reference, TimeZoneInfo.Utc);
                Check.True(oldDefinition.Rows.Select(r => r[0]).SequenceEqual(reading.Values), "ancienne définition conserve le brut");
                Check.True(oldDefinition.Status.State != ProbeState.Read, "ancienne définition n’est pas une mesure actuelle");
            }
            var failedWithData = PosteScalarProbeCards.Build(probe, reading with { Error = "Dernière tentative refusée" }, 1, TestClock.Reference, TimeZoneInfo.Utc);
            Check.True(failedWithData.Rows.Select(r => r[0]).SequenceEqual(reading.Values), "données déjà présentes conservées brutes malgré un diagnostic en erreur");
            Check.Equal("Valeur historique brute", failedWithData.Columns.Single(), "aucune transformation après erreur");
            Check.True(failedWithData.Status.State != ProbeState.Read, "la donnée conservée ne transforme pas l’erreur en succès");
            foreach (var historical in new[] { reading with { At = (DateTimeOffset?)null }, reading with { At = TestClock.Reference - TimeSpan.FromDays(31) },
                reading with { At = TestClock.Reference + TimeSpan.FromHours(1) } })
            {
                var old = PosteScalarProbeCards.Build(probe, historical, 1, TestClock.Reference, TimeZoneInfo.Utc);
                Check.True(old.Rows.Select(r => r[0]).SequenceEqual(historical.Values), "valeurs brutes conservées sans transformation ni unité");
                Check.Equal("Valeur historique brute", old.Columns.Single(), "historique explicitement désigné");
                Check.True(old.Status.State != ProbeState.Read, "historique jamais présenté comme relevé actuel");
                Check.Contains("aucune valeur actuelle", old.Provenance, "date invalide annoncée");
            }
        }
        var selectable = scalar.Select((p, i) => new FleetLayoutItem("p" + i, FleetWidgetSource.Probe, p.Id, "Kpi", "S", null, false, "")).ToArray();
        Check.Equal(64, PosteBoardLayouts.Normalize("Computer", selectable[..64]).Length, "premier groupe réellement accepté");
        Check.Equal(14, PosteBoardLayouts.Normalize("Computer", selectable[64..]).Length, "reste du catalogue réellement accepté");
    }

    [Test]
    public static async Task Detailed_probe_layout_roundtrips_all_real_ids_and_retains_local_source_proof()
    {
        var probes = Domenia.Core.Poste.ProbeCatalog.Probes.Reverse().Select((p, i) => new
        { Id = "sonde-" + i, Source = "Probe", Key = p.Id, Title = p.Name[..Math.Min(80, p.Name.Length)], Paused = i % 2 == 0 }).ToArray();
        var original = Args(probes);
        var preview = Preview("Computer", original);
        var proposed = preview.Boards.Single(p => p.Board == "Computer");
        Check.Equal("ready", proposed.State, "les 33 sondes ont un vrai consommateur local");
        Check.Equal(33, proposed.Count, "aucune sonde perdue");
        Check.True(proposed.Items.All(i => i.Source == FleetWidgetSource.Probe && i.Visual == "Table"), "adaptation au tableau brut explicitée");
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using (var store = new FilePreferenceStore(path, new RecordingJournal()))
        { Check.True(await LegacyBoardLayouts.ApplyAsync(preview, "Computer", Sha, store, TestClock.Reference, None), "import explicite local"); }
        using var fresh = new FilePreferenceStore(path, new RecordingJournal());
        var actual = PosteBoardLayouts.Read(fresh, "Computer");
        Check.True(actual.Items.SequenceEqual(proposed.Items), "ordre, titre et pause consommés après réouverture");
        Check.Equal(14, PosteBoardLayouts.Defaults("Computer").Length, "aucune sonde ajoutée aux défauts");
        Check.Equal(111, actual.Catalog.Count(d => d.Source == FleetWidgetSource.Probe), "éditeur expose les 111 sondes consommables");
        Check.True(fresh.TryGet(PosteBoardLayouts.EvidenceKey("Computer"), out var evidence), "preuve atomique");
        Check.Equal(original, evidence.GetProperty("originalLayout").GetString(), "texte D1 conservé");
    }

    [Test]
    public static void Legacy_detailed_probe_additions_keep_defaults_order_pause_and_reject_unknown_or_overflow()
    {
        var preview = Preview("Computer", "[{\"Id\":\"legacy\",\"ProbeId\":\"hw.memorymodules\",\"Paused\":true}]", legacy: true);
        var p = preview.Boards.Single(p => p.Board == "Computer");
        Check.Equal("ready", p.State, "ancienne sélection de sonde réellement consommée");
        Check.Equal(15, p.Count, "14 cartes livrées puis une sonde");
        Check.Equal("p-legacy", p.Items[^1].Id, "identité historique");
        Check.True(p.Items[^1].Paused, "pause retenue");
        var tooMany = Args(Enumerable.Range(0, 51).Select(i => new { Id = "p" + i, ProbeId = "hw.memorymodules" }));
        Check.Equal("incompatible", Preview("Computer", tooMany, true).Boards.Single(p => p.Board == "Computer").State, "65 éléments combinés refusés");
        Check.Equal("incompatible", Preview("Software", "[{\"Source\":\"Probe\",\"Key\":\"hw.memorymodules\"}]").Boards.Single(p => p.Board == "Software").State, "aucune fausse sonde dans Logiciels");
    }

    [Test]
    public static async Task Both_real_bridge_consumers_roundtrip_order_pause_titles_and_explicit_empty()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using (var preferences = new FilePreferenceStore(path, new RecordingJournal()))
        {
            var bridge = new SimulatedBridge(preferences: preferences);
            foreach (var board in new[] { "Computer", "Software" })
            {
                var initial = SimulatedBridge.Json(await bridge.CallAsync("poste.layout.get", Args(new { board })));
                Check.False(initial.GetProperty("stored").GetBoolean(), "défaut non écrit à la lecture");
                Check.True(initial.GetProperty("items").GetArrayLength() > 0, "catalogue du consommateur disponible");
                var catalog = PosteBoardLayouts.Catalog(board);
                var items = new[] { Item("second", catalog[1].Key, true), Item("first", catalog[0].Key) };
                var saved = SimulatedBridge.Json(await bridge.CallAsync("poste.layout.save", Args(new { board, items })));
                Check.Equal("second", saved.GetProperty("items")[0].GetProperty("id").GetString(), "ordre explicite conservé");
                Check.True(saved.GetProperty("items")[0].GetProperty("paused").GetBoolean(), "pause conservée");
                Check.Equal("Mon titre", saved.GetProperty("items")[1].GetProperty("title").GetString(), "titre conservé");
                Check.Equal("S", saved.GetProperty("items")[0].GetProperty("size").GetString(), "taille conservée");
            }
            Check.Equal(0L, bridge.Source.Overlay.Version, "aucune écriture du poste ou de l’annuaire");
        }
        using var again = new FilePreferenceStore(path, new RecordingJournal());
        var fresh = new SimulatedBridge(preferences: again);
        foreach (var board in new[] { "Computer", "Software" })
        {
            var reloaded = SimulatedBridge.Json(await fresh.CallAsync("poste.layout.get", Args(new { board })));
            Check.Equal("second", reloaded.GetProperty("items")[0].GetProperty("id").GetString(), "consommateur relu après nouvelle instance");
            _ = SimulatedBridge.Json(await fresh.CallAsync("poste.layout.save", Args(new { board, items = Array.Empty<FleetLayoutItem>() })));
        }
        using var empty = new FilePreferenceStore(path, new RecordingJournal());
        foreach (var board in new[] { "Computer", "Software" })
        {
            var view = PosteBoardLayouts.Read(empty, board);
            Check.True(view.Stored && view.Valid, "choix vide enregistré");
            Check.Equal(0, view.Items.Length, "aucun défaut réintroduit");
        }
    }

    [Test]
    public static async Task Migration_from_real_settings_is_consumed_and_keeps_original_and_evidence()
    {
        using var folder = new TemporaryFolder();
        var source = folder.File("Domenia.settings.json");
        const string computer = "[{\"Id\":\"cpu\",\"Source\":\"Builtin\",\"Key\":\"computer.cpu.load\",\"Paused\":true},{\"Id\":\"ram\",\"Source\":\"Builtin\",\"Key\":\"computer.memory.usage\"}]";
        const string software = "[{\"Id\":\"size\",\"Source\":\"Builtin\",\"Key\":\"software.size\",\"Paused\":true},{\"Id\":\"count\",\"Source\":\"Builtin\",\"Key\":\"software.count\"}]";
        File.WriteAllText(source, Args(new Dictionary<string, string> { ["Dashboard.Computer.Layout"] = computer, ["Dashboard.Software.Layout"] = software }));
        var digest = Digest(source);
        var preview = LegacyBoardLayoutFile.ReadCandidates([source], None);
        var path = folder.File("preferences.json");
        using (var store = new FilePreferenceStore(path, new RecordingJournal()))
        {
            foreach (var board in new[] { "Computer", "Software" })
            { Check.True(await LegacyBoardLayouts.ApplyAsync(preview, board, digest, store, TestClock.Reference, None), "import du tableau sélectionné"); }
        }
        using var fresh = new FilePreferenceStore(path, new RecordingJournal());
        var bridge = new SimulatedBridge(preferences: fresh);
        foreach (var board in new[] { "Computer", "Software" })
        {
            var view = SimulatedBridge.Json(await bridge.CallAsync("poste.layout.get", Args(new { board })));
            Check.Equal(2, view.GetProperty("items").GetArrayLength(), "les seuls éléments choisis sont consommés");
            Check.True(view.GetProperty("items")[0].GetProperty("paused").GetBoolean(), "pause importée exposée au rendu");
            Check.Equal(board == "Computer" ? "cpu" : "size", view.GetProperty("items")[0].GetProperty("id").GetString(), "ordre importé");
            Check.True(fresh.TryGet(PosteBoardLayouts.EvidenceKey(board), out var proof), "preuve persistée avec les items");
            Check.Equal(digest, proof.GetProperty("sourceSha256").GetString(), "SHA de la vraie source");
            Check.Equal(board == "Computer" ? computer : software, proof.GetProperty("originalLayout").GetString(), "texte original exact");
            await PosteBoardLayouts.SaveAsync(fresh, board, [], None);
            Check.True(fresh.TryGet(PosteBoardLayouts.EvidenceKey(board), out _), "édition manuelle garde la provenance");
        }
        Check.Equal(digest, Digest(source), "source D1 inchangée");
        Check.False(fresh.TryGet(AccueilService.LayoutPreference, out _), "import Poste/Logiciels ne touche pas Accueil");
    }

    [Test]
    public static async Task Empty_imports_stay_empty_in_both_consumers()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using (var store = new FilePreferenceStore(path, new RecordingJournal()))
        {
            foreach (var board in new[] { "Computer", "Software" })
            { Check.True(await LegacyBoardLayouts.ApplyAsync(Preview(board, "[]"), board, Sha, store, TestClock.Reference, None), "[] importé"); }
        }
        using var fresh = new FilePreferenceStore(path, new RecordingJournal());
        foreach (var board in new[] { "Computer", "Software" })
        { Check.Equal(0, PosteBoardLayouts.Read(fresh, board).Items.Length, "[] consommé sans carte implicite"); }
    }

    [Test]
    public static async Task Latest_d2_empty_choice_blocks_import_and_preserves_every_byte()
    {
        foreach (var board in new[] { "Computer", "Software" })
        {
            using var folder = new TemporaryFolder();
            var path = folder.File("preferences.json");
            using var stale = new FilePreferenceStore(path, new RecordingJournal());
            using var other = new FilePreferenceStore(path, new RecordingJournal());
            await other.SetAsync("future.keep", Json("true"), None);
            await PosteBoardLayouts.SaveAsync(other, board, [], None);
            var before = Digest(path);
            Check.False(await LegacyBoardLayouts.ApplyAsync(Preview(board, "[]"), board, Sha, stale, TestClock.Reference, None), "dernier choix disque prioritaire");
            Check.Equal(before, Digest(path), "document D2 inchangé");
            Check.False(stale.TryGet(PosteBoardLayouts.EvidenceKey(board), out _), "aucune preuve d’import inventée");
        }
    }

    [Test]
    public static async Task Corrupt_or_future_d2_choice_is_visible_and_never_replaced_by_migration()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("preferences.json");
        using var store = new FilePreferenceStore(path, new RecordingJournal());
        foreach (var board in new[] { "Computer", "Software" })
        {
            await store.SetAsync(PosteBoardLayouts.PreferenceKey(board), Json("{\"version\":99,\"items\":[]}"), None);
            var before = Digest(path);
            var view = PosteBoardLayouts.Read(store, board);
            Check.True(view.Stored, "choix incompatible présent");
            Check.False(view.Valid, "aucun remplacement silencieux par les défauts");
            Check.Equal(0, view.Items.Length, "aucun faux rendu compatible");
            Check.False(await LegacyBoardLayouts.ApplyAsync(Preview(board, "[]"), board, Sha, store, TestClock.Reference, None), "choix conservé");
            Check.Equal(before, Digest(path), "octets inchangés");
        }
    }

    [Test]
    public static void Unsupported_items_refuse_the_entire_layout_even_paused()
    {
        foreach (var invalid in new[] { "{\"Source\":\"Builtin\",\"Key\":\"computer.unrepresented\",\"Paused\":true}", "{\"Source\":\"Probe\",\"Key\":\"probe.unknown\"}" })
        {
            var proposal = Preview("Computer", "[{\"Source\":\"Builtin\",\"Key\":\"computer.health\"}," + invalid + "]").Boards.Single(p => p.Board == "Computer");
            Check.Equal("incompatible", proposal.State, "pas de migration partielle ni de widget fictif");
            Check.Equal(0, proposal.Items.Length, "aucun sous-ensemble présenté comme migré");
        }
    }

    [Test]
    public static void Explicit_empty_dashboard_is_distinct_from_legacy_empty_probe_additions()
    {
        var settings = JsonSerializer.SerializeToElement(new Dictionary<string, string>
        { ["Dashboard.Computer.Layout"] = "[]", ["Widgets.Computer"] = "[{\"ProbeId\":\"unknown\"}]" });
        var explicitEmpty = LegacyBoardLayouts.Parse(settings, @"C:\settings.json", Sha).Boards.Single(p => p.Board == "Computer");
        Check.Equal("ready", explicitEmpty.State, "[] explicite prioritaire sur Widgets");
        Check.Equal(0, explicitEmpty.Count, "aucun défaut implicite");
        var additionsOnly = Preview("Computer", "[]", legacy: true).Boards.Single(p => p.Board == "Computer");
        Check.Equal("ready", additionsOnly.State, "Widgets=[] garde les cartes livrées D1, toutes représentées");
        Check.Equal(14, additionsOnly.Items.Length, "14 cartes livrées, les 33 cartes N ne sont pas des défauts");
    }

    [Test]
    public static void Generated_ids_do_not_steal_a_later_valid_id_and_remain_stable()
    {
        const string text = "[{\"Source\":\"Builtin\",\"Key\":\"software.count\"},{\"Id\":\"d1-0\",\"Source\":\"Builtin\",\"Key\":\"software.size\"},{\"Id\":\"d1-0\",\"Source\":\"Builtin\",\"Key\":\"software.recent\"}]";
        var a = Preview("Software", text).Boards.Single(p => p.Board == "Software").Items;
        var b = Preview("Software", text).Boards.Single(p => p.Board == "Software").Items;
        Check.Equal("d1-0", a[1].Id, "identifiant historique valide réservé");
        Check.Equal(3, a.Select(i => i.Id).Distinct().Count(), "identifiants distincts");
        Check.True(a.SequenceEqual(b), "conversion stable");
    }

    [Test]
    public static async Task Invalid_save_never_replaces_the_previous_explicit_choice()
    {
        var store = new MemoryPreferenceStore();
        await PosteBoardLayouts.SaveAsync(store, "Computer", [], None);
        foreach (var items in new[]
        {
            new[] { Item("x", "computer.unknown") }, new[] { Item("x", "computer.health"), Item("x", "computer.cpu.load") },
            Enumerable.Range(0, 65).Select(n => Item("x" + n, "computer.health")).ToArray(),
            new[] { Item("x", "computer.health") with { Source = FleetWidgetSource.Query } },
        })
        {
            await Check.ThrowsAsync<InvalidDataException>(() => PosteBoardLayouts.SaveAsync(store, "Computer", items, None), "écriture invalide refusée entière");
            Check.Equal(0, PosteBoardLayouts.Read(store, "Computer").Items.Length, "[] antérieur intact");
        }
        Check.Equal(1, store.Writes, "aucune écriture des rejets");
        using var canceled = new CancellationTokenSource();
        canceled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => PosteBoardLayouts.SaveAsync(store, "Computer", [Item("x", "computer.health")], canceled.Token), "annulation avant écriture");
        Check.Equal(1, store.Writes, "annulation sans modification");
    }

    [Test]
    public static async Task Every_builtin_d1_computer_card_can_be_imported_without_expanding_the_delivered_layout()
    {
        using var folder = new TemporaryFolder();
        using var store = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal());
        Check.Equal(47, PosteBoardLayouts.Computer.Length, "catalogue D1 complet");
        Check.Equal(14, PosteBoardLayouts.Defaults("Computer").Length, "cartes D1 marquées N restent hors défauts");
        var text = Args(PosteBoardLayouts.Computer.Reverse().Select((d, n) => Item("d1-" + n, d.Key, n % 2 == 0)).ToArray());
        var preview = Preview("Computer", text);
        var proposal = preview.Boards.Single(p => p.Board == "Computer");
        Check.Equal("ready", proposal.State, "aucune clé builtin écartée");
        Check.Contains("Présentations adaptées aux cartes D2", proposal.Summary, "adaptation annoncée avant import, sans confondre carte graphique et moniteurs EDID");
        Check.True(await LegacyBoardLayouts.ApplyAsync(preview, "Computer", Sha, store, TestClock.Reference, None), "import complet");
        var view = PosteBoardLayouts.Read(store, "Computer");
        Check.Equal(47, view.Items.Length, "aucune carte perdue");
        Check.True(view.Items.Select(i => i.Key).SequenceEqual(PosteBoardLayouts.Computer.Reverse().Select(d => d.Key)), "ordre personnel exact");
        Check.True(view.Items.Where((_, n) => n % 2 == 0).All(i => i.Paused), "toutes les pauses relues");
    }

    private static InventorySnapshot EmptyInventory() => new(
        Computer: "PC1", CollectedAt: TestClock.Reference, Deep: false, DurationMs: 0, Transport: InventoryTransport.Local, Access: [],
        Os: null, System: null, Bios: null, Processors: [], MemoryModules: [], MemoryArray: null, Memory: null, Volumes: [], PhysicalDisks: [],
        BitLocker: [], Tpm: null, SecureBoot: null, Network: [], Firewall: [], Antivirus: [], Defender: null, Hotfixes: [], Updates: null,
        Software: [], Startup: [], Services: [], Devices: [], Displays: [], Batteries: [], UnsignedDrivers: [], Sessions: [], LocalAdmins: [],
        Shares: [], Printers: [], PendingReboot: null, ClockSkewSeconds: null, ClockAgainstController: false, Site: null, Proxy: null,
        Processes: [], SystemEvents: [], Tasks: [], Certificates: [], Connections: []);

    [Test]
    public static async Task Update_cards_use_typed_snapshot_values_without_claiming_wsus_is_applied_or_compliance()
    {
        var bridge = new SimulatedBridge();
        var dn = bridge.Source.CurrentDirectory.Computers.First().DistinguishedName;
        var data = SimulatedBridge.Json(await bridge.CallAsync("poste.open", Args(new { dn })));
        var computer = data.GetProperty("computer").Deserialize<PosteComputer>(PosteBoardLayouts.Json)!;
        var inventory = EmptyInventory() with
        {
            Access = [new(InventoryCategories.Updates, SourceStatus.Ok, "fixture locale", 0, 1, InventoryTransport.Local)],
            Os = new("Windows 11", "10.0", "26100", 1234, "64 bits", null, null, null, null, null, null),
            Updates = new("https://wsus.example.invalid", false, "Stratégie", null, null) { PolicyRead = true },
        };
        var board = PosteBoardBuilder.Build(computer, inventory, PosteHealthPolicy.Default, TestClock.Reference, TestClock.Paris);
        var source = board.WidgetValues.Single(v => v.Key == "computer.wsus");
        Check.Contains("non appliqué", source.Value, "adresse configurée ne prouve pas UseWUServer");
        Check.Contains("pas un contact", source.Detail, "provenance locale visible");
        var updates = board.WidgetValues.Single(v => v.Key == "computer.updates");
        Check.Equal("26100.1234", updates.Value, "build et révision du vrai snapshot");
        Check.Contains("Conformité non évaluée", updates.Detail, "aucune conformité inventée");
        var unknown = PosteBoardBuilder.Build(computer, inventory with { Updates = inventory.Updates! with { PolicyRead = false } },
            PosteHealthPolicy.Default, TestClock.Reference, TestClock.Paris);
        Check.Equal(Tone.Off, unknown.WidgetValues.Single(v => v.Key == "computer.wsus").State!.Value, "lecture de stratégie non établie reste inconnue");
    }

    [Test]
    public static async Task Unread_inventory_never_manufactures_update_or_certificate_values()
    {
        var bridge = new SimulatedBridge();
        var dn = bridge.Source.CurrentDirectory.Computers.First().DistinguishedName;
        var data = SimulatedBridge.Json(await bridge.CallAsync("poste.open", Args(new { dn })));
        var computer = data.GetProperty("computer").Deserialize<PosteComputer>(PosteBoardLayouts.Json)!;
        var board = PosteBoardBuilder.Build(computer, EmptyInventory(), PosteHealthPolicy.Default, TestClock.Reference, TestClock.Paris);
        Check.False(board.WidgetValues.Any(v => v.Key is "computer.wsus" or "computer.updates"), "absence de source conservée");
        Check.False(board.Sections.Any(s => s.Key == "certificates"), "aucun certificat lu ne devient zéro conforme");
        Check.True(board.Counts.Where(c => c.Key is "computer.admins" or "computer.drivers").All(c => c.Value is null), "compteurs non lus restent inconnus");
        Check.Equal("Non lu", board.WidgetValues.Single(v => v.Key == "computer.user").Value, "une console non lue ne devient pas une console vide");
        var emptyConsole = PosteBoardBuilder.Build(computer, EmptyInventory() with { Console = new(null, TestClock.Reference) },
            PosteHealthPolicy.Default, TestClock.Reference, TestClock.Paris);
        Check.Equal("Aucun à la console", emptyConsole.WidgetValues.Single(v => v.Key == "computer.user").Value, "null natif daté est une absence constatée");
    }
}
