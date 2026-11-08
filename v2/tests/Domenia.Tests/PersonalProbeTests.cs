using System.Collections.Immutable;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.Tests;

internal static class PersonalProbeFixtures
{
    internal static string Document(string property = "Manufacturer", string mode = "First")
    {
        var root = JsonNode.Parse("""
        {"SchemaVersion":1,"Probes":[{
          "Id":"team.hardware", "Category":"Équipe", "Name":"Fabricant de l’équipe",
          "Namespace":"root\\cimv2", "Class":"Win32_ComputerSystem", "Properties":["Manufacturer"],
          "Filter":"", "Mode":"First", "Transform":"Text", "Visual":"Bar", "Slow":true, "SkipOnDc":true,
          "Origin":"Personnalisée", "Description":"Valeur lue par la sonde de l’équipe.", "Rights":"Lecture distante autorisée.",
          "Compatibility":"Windows avec CIMWin32.", "UnknownMeaning":"Absence ou refus : inconnu.", "Limitations":"Matériel présenté à Windows seulement.",
          "SourceUrls":["https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem"],
          "Fields":[{"Name":"Manufacturer","CimType":"string","Kind":"Text","IsArray":false,"Unit":"","Description":"Nom rapporté."}],
          "Behavior":{"Reads":"CIM","Writes":false,"Code":"Aucun","Methods":[],"Target":"Postes de l’OU confirmée."},
          "Privilege":{"Level":"LectureDistanteWmi","Text":"Compte autorisé à lire cet espace de noms."},
          "Cost":{"Level":"Léger","Reason":"Classe à instance unique ; collecte explicite conservée."}
        }]}
        """)!;
        root["Probes"]![0]!["Properties"]![0] = property;
        root["Probes"]![0]!["Fields"]![0]!["Name"] = property;
        root["Probes"]![0]!["Mode"] = mode;
        return root.ToJsonString();
    }

    internal static async Task<PersonalProbeSaved> Import(AccueilService service, string document)
    {
        var current = await service.PersonalProbeCatalogAsync(CancellationToken.None);
        var preview = await service.PreviewPersonalProbesAsync(document, current.ChoiceToken, CancellationToken.None);
        return await service.ApplyPersonalProbesAsync(document, preview.ChoiceToken, preview.DocumentSha256, CancellationToken.None);
    }
}

internal static class PersonalProbeTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static void Canonical_versions_preserve_alias_edits_and_export_roundtrips_without_a_global_catalog()
    {
        var original = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        var changed = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document("Model")).Single();
        var current = PersonalProbeCatalog.Read(PersonalProbeCatalog.Merge(PersonalProbeCatalog.Read(null), [original, changed]));
        Check.Equal(71, original.Key.Length, "clé intégrale de 71 caractères");
        Check.True(original.Key != changed.Key, "même alias, projection différente : autre version");
        Check.Equal(original.Definition.Id, changed.Definition.Id, "alias conservé, jamais utilisé pour réaffecter les valeurs");
        Check.Equal(2, current.Entries.Length, "ancienne définition conservée même sans widget");
        Check.Equal(original.Key, PersonalProbeCatalog.Import(PersonalProbeCatalog.Export(original)).Single().Key, "export canonique réimportable");
        Check.Equal(original.Key, PersonalProbeCatalog.Import("\n " + PersonalProbeFixtures.Document() + "\n").Single().Key, "espaces de transport hors de l’identité sémantique");
        Check.Null(ProbeCatalog.Find(original.Key), "aucun ajout au catalogue global");
        Check.Null(PersonalProbeCatalog.Read(null).Find(original.Key), "autre profil vide");
        var malformed = JsonNode.Parse(PersonalProbeCatalog.Merge(PersonalProbeCatalog.Read(null), [original]).GetRawText())!;
        malformed["entries"]![0]!["definition"] = JsonNode.Parse(PersonalProbeCatalog.Export(changed))!["Probes"]![0]!.DeepClone();
        Check.Throws<DomeniaOperationException>(() => PersonalProbeCatalog.Read(JsonSerializer.SerializeToElement(malformed)), "altération sous l’ancienne clé refusée");
    }

    [Test]
    public static async Task Actual_bridge_preview_is_read_only_and_apply_checks_text_catalog_and_readback()
    {
        var preferences = new MemoryPreferenceStore(); var bridge = new SimulatedBridge(preferences: preferences);
        var current = SimulatedBridge.Json(await bridge.CallAsync("accueil.probes.personal"));
        var document = PersonalProbeFixtures.Document();
        var preview = SimulatedBridge.Json(await bridge.CallAsync("accueil.probes.preview", JsonSerializer.Serialize(new
        { document, expectedChoiceToken = current.GetProperty("choiceToken").GetString() })));
        Check.False(preferences.TryGet(PersonalProbeCatalog.PreferenceKey, out _), "aperçu sans écriture");
        Check.True((await bridge.Context.Readers.Require<IAccueilReader>().StoredProbesAsync(None)).ByProbe.IsEmpty, "aperçu sans collecte");
        var choice = preview.GetProperty("choiceToken").GetString(); var hash = preview.GetProperty("documentSha256").GetString();
        var changed = await bridge.CallAsync("accueil.probes.apply", JsonSerializer.Serialize(new { document = document + " ", expectedChoiceToken = choice, expectedDocumentSha256 = hash }));
        Check.Equal("probes.changed", changed.Error!.Code, "texte modifié depuis l’aperçu refusé");
        var saved = SimulatedBridge.Json(await bridge.CallAsync("accueil.probes.apply", JsonSerializer.Serialize(new { document, expectedChoiceToken = choice, expectedDocumentSha256 = hash })));
        Check.True(saved.GetProperty("receipt").GetProperty("readBack").GetBoolean(), "succès relu");
        Check.False(saved.GetProperty("receipt").GetProperty("persistent").GetBoolean(), "mémoire simulée jamais annoncée durable");
        var replay = await bridge.CallAsync("accueil.probes.apply", JsonSerializer.Serialize(new { document, expectedChoiceToken = choice, expectedDocumentSha256 = hash }));
        Check.Equal("probes.changed", replay.Error!.Code, "ancienne version de catalogue refusée");
        Check.True((await bridge.Context.Readers.Require<IAccueilReader>().StoredProbesAsync(None)).ByProbe.IsEmpty, "import sans collecte");
        var reopened = new SimulatedBridge(preferences: preferences);
        Check.Equal(1, (await AccueilService.From(reopened.Context).PersonalProbeCatalogAsync(None)).Entries.Length, "catalogue du profil relu par une autre instance");
        Check.Equal(0, (await AccueilService.From(new SimulatedBridge().Context).PersonalProbeCatalogAsync(None)).Entries.Length, "profil distinct inchangé");
    }

    [Test]
    public static async Task Invalid_or_unretained_metadata_refuses_the_entire_import_and_self_check_reports_corruption()
    {
        var bridge = new SimulatedBridge(); var home = AccueilService.From(bridge.Context);
        var document = PersonalProbeFixtures.Document(); var current = await home.PersonalProbeCatalogAsync(None);
        foreach (var modify in new Action<JsonNode>[]
        {
            root => root["Probes"]![0]!["Behavior"]!["Writes"] = true,
            root => root["Probes"]![0]!["Origin"] = "Catalogue détaillé",
            root => root["Probes"]![0]!["Class"] = "Win32_Product",
            root => root["Probes"]![0]!["Class"] = "Win32_NotDelivered",
            root => root["Qualification"] = "Ne pas perdre cette qualification.",
            root => root["Probes"]![0]!["DocumentationReviewedUtc"] = "2026-10-25",
        })
        {
            var root = JsonNode.Parse(document)!; modify(root);
            await Check.ThrowsAsync<DomeniaOperationException>(() => home.PreviewPersonalProbesAsync(root.ToJsonString(), current.ChoiceToken, None), "document entier refusé");
        }
        Check.False(bridge.Preferences.TryGet(PersonalProbeCatalog.PreferenceKey, out _), "aucun sous-ensemble enregistré");
        await bridge.Preferences.SetAsync(PersonalProbeCatalog.PreferenceKey, JsonSerializer.SerializeToElement(new { format = "incorrect", entries = Array.Empty<object>() }), None);
        var check = await home.SelfCheckAsync(None);
        Check.True(check.Checks.Any(c => c.Id == "personalProbes" && c.Tone == Tone.Alert), "profil invalide jamais annoncé vert");
        Check.True(bridge.Preferences.TryGet(PersonalProbeCatalog.PreferenceKey, out var kept) && kept.GetProperty("format").GetString() == "incorrect", "original conservé");
    }

    [Test]
    public static async Task Widget_uses_the_imported_version_and_a_second_edit_does_not_rebind_or_reuse_its_values()
    {
        var bridge = new SimulatedBridge(); var home = AccueilService.From(bridge.Context);
        var session = await bridge.Source.GetSessionAsync(None);
        var local = await bridge.Source.ReadLocalAsync(None);
        var nextPresence = PresenceRounds.Apply(bridge.Source.World.Presence, local.Observations, bridge.Source.PresenceRound + 1, bridge.Clock.GetUtcNow());
        var responders = nextPresence.Workstations.Where(o => o.Presence.HasReading && o.Presence.Answered == true).Select(o => o.ComputerGuid).ToHashSet();
        var ou = local.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && (c.UserAccountControl & AdValues.ServerTrustAccount) == 0)
            .GroupBy(c => DistinguishedName.Parent(c.DistinguishedName)!).OrderBy(g => g.Count())
            .First(g => g.OrderBy(c => c.ObjectGuid).Take(32).Any(c => responders.Contains(c.ObjectGuid))).Key;
        await WorkingScope.From(bridge.Context).SetAsync(session, ou, false, None);
        var saved = await PersonalProbeFixtures.Import(home, PersonalProbeFixtures.Document());
        var key = saved.Catalog.Entries.Single().Key;
        var catalog = await home.CatalogAsync(None);
        Check.True(catalog.Probes.SelectMany(g => g.Probes).Any(p => p.Id == key), "même clé exposée dans le tiroir existant");
        var layout = await home.SaveLayoutAsync([new("", FleetWidgetSource.Probe, key, "Bar", "M", null, false, "Équipe")], None);
        Check.True(layout.Items.Single().Id.Length <= 64, "id de carte borné malgré la clé de 71 caractères");
        var plan = await home.PlanWidgetCollectionAsync(layout.Items.Single().Id, "add", None);
        Check.True(plan.ConfirmationRequired, "personnalisée : confirmation même pour Ajouter");
        await Check.ThrowsAsync<DomeniaOperationException>(() => home.RunWidgetCollectionAsync(plan.Id, false, None), "pas de collecte implicite");
        plan = await home.PlanWidgetCollectionAsync(layout.Items.Single().Id, "add", None);
        await home.RunWidgetCollectionAsync(plan.Id, true, None);
        var board = await home.BoardAsync(None); home.AcknowledgeWidgetDraw(plan.Id);
        var entry = board.Entries["probe:" + key];
        Check.True(entry.Measured && entry.Targets > 0, "valeurs de la vraie projection simulée calculées par le tableau");
        var part = entry.Items.First();
        Check.Equal(part.Targets, home.Targets(board.Revision, part.TargetsKey).Total, "poste exact du chiffre");
        var revised = await PersonalProbeFixtures.Import(home, PersonalProbeFixtures.Document("Model"));
        Check.Equal(2, revised.Catalog.Entries.Length, "révision précédente conservée");
        Check.Equal(key, home.Layout().Items.Single().Key, "widget toujours lié à l’ancienne définition");
        var second = revised.Catalog.Entries.Single(p => p.Key != key);
        var stored = await bridge.Context.Readers.Require<IAccueilReader>().StoredProbesAsync(None);
        Check.True(stored.ByProbe.ContainsKey(key), "valeurs conservées sous la clé réellement exécutée");
        Check.False(stored.ByProbe.ContainsKey(second.Key), "aucune mesure ancienne attribuée à la nouvelle définition");
    }

    [Test]
    public static async Task Missing_profile_definition_blocks_layout_import_widget_collection_and_durable_resume_without_dropping_existing_cards()
    {
        var bridge = new SimulatedBridge(); var home = AccueilService.From(bridge.Context);
        var entry = (await PersonalProbeFixtures.Import(home, PersonalProbeFixtures.Document())).Catalog.Entries.Single();
        await home.SaveLayoutAsync([new("personal", FleetWidgetSource.Probe, entry.Key, "Bar", "M", null, false, "Équipe")], None);
        await bridge.Preferences.SetAsync(PersonalProbeCatalog.PreferenceKey, JsonSerializer.SerializeToElement<object?>(null), None);
        Check.Equal(entry.Key, home.Layout().Items.Single().Key, "ancien widget manquant conservé pour diagnostic");
        Check.Equal("probes.changed", (await Check.ThrowsAsync<DomeniaOperationException>(() => home.SaveLayoutAsync(home.Layout().Items, None), "import incomplet refusé")).Code, "définition exacte requise");
        Check.Equal("probes.changed", (await Check.ThrowsAsync<DomeniaOperationException>(() => home.PlanWidgetCollectionAsync("personal", "refresh", None), "aucune collecte sans définition")).Code, "pas de recherche par alias");
        var source = new HomePipelineSource(); source.Saved = source.Checkpoint() with { Probes = [entry.Key] };
        using var context = source.Context();
        Check.Equal("probes.changed", (await Check.ThrowsAsync<DomeniaOperationException>(() => AccueilService.From(context).PlanRefreshAsync("resume", None), "reprise dans un autre profil refusée")).Code, "ancienne définition nécessaire à la reprise");
        Check.Equal(0, source.PresenceCalls + source.InventoryCalls, "aucun poste contacté");
        Check.Equal(entry.Key, source.Saved!.Probes.Single(), "checkpoint laissé intact");
    }

    [Test]
    public static async Task Excluded_controllers_do_not_become_fresh_or_trigger_a_missing_probe_read()
    {
        var source = new HomePipelineSource();
        source.Current = source.Current with { Directory = source.Current.Directory with
        { Computers = [Fixtures.Computer("DC1") with { UserAccountControl = AdValues.ServerTrustAccount }] } };
        using var context = source.Context(); var home = AccueilService.From(context);
        var key = (await PersonalProbeFixtures.Import(home, PersonalProbeFixtures.Document())).Catalog.Entries.Single().Key;
        await home.SaveLayoutAsync([new("personal", FleetWidgetSource.Probe, key, "Bar", "M", null, false, "Équipe")], None);
        var plan = await home.PlanWidgetCollectionAsync("personal", "add", None);
        Check.Equal(0, plan.Targets, "aucun contrôleur admis pour cette sonde");
        Check.Equal(0, plan.Fresh, "exclusion ne signifie pas mesure à jour");
        Check.Contains("1 contrôleurs exclus", plan.Detail, "exclusion expliquée");
        source.Record(source.Current.Directory.Computers.Select(c => c.ObjectGuid), true);
        var refresh = await home.PlanRefreshAsync("inventory", None);
        Check.Equal(1, refresh.Reused, "inventaire récent du contrôleur conservé, sonde inapplicable ignorée");
    }

    [Test]
    public static void Normalized_widget_ids_remain_unique_even_against_an_existing_fallback_id()
    {
        var key = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single().Key;
        var collision = "p-" + key[..48] + "-2";
        var clean = AccueilService.Clean([
            new(collision, FleetWidgetSource.Probe, key, "Bar", "M", null, false, "Équipe"),
            new("", FleetWidgetSource.Probe, key, "Bar", "M", null, false, "Équipe")]);
        Check.Equal(2, clean.Select(i => i.Id).Distinct().Count(), "collision résolue avant tout plan de widget");
        Check.True(clean.All(i => i.Id.Length <= 64 && i.Key == key), "identifiants bornés, référence immuable intégrale");
    }

    [Test]
    public static async Task SQLite_reopens_custom_values_under_the_exact_immutable_key()
    {
        using var folder = new TemporaryFolder(); var computer = Fixtures.Computer("PC1");
        var probe = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        var db = new DomeniaDatabase(folder.File("personal-probes.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(None);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [computer]), new(Fixtures.Postes, "Postes", true), "dc1.test.local", None);
        var measured = new ProbeReadings(ImmutableDictionary<string, ImmutableDictionary<Guid, ProbeReading>>.Empty.Add(probe.Key,
            ImmutableDictionary<Guid, ProbeReading>.Empty.Add(computer.ObjectGuid, new(MeasureState.Known, Fixtures.Now, ["Fabricant"], null))));
        await db.SaveFleetAsync(FleetCachePatch.Empty with { Probes = measured }, None);
        var stored = await new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed()).ReadFleetAsync(None);
        Check.Equal("Fabricant", stored.Probes.ByProbe[probe.Key][computer.ObjectGuid].Values.Single(), "réouverture réelle du cache local");
        Check.False(stored.Probes.ByProbe.ContainsKey(probe.Definition.Id), "aucun index par alias mutable");
        var invalid = new ProbeReadings(ImmutableDictionary<string, ImmutableDictionary<Guid, ProbeReading>>.Empty.Add("custom.short", measured.ByProbe[probe.Key]));
        await Check.ThrowsAsync<InvalidDataException>(() => db.SaveFleetAsync(FleetCachePatch.Empty with { Probes = invalid }, None), "clé incorrecte refusée");
    }
}
