using System.Collections.Immutable;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;
using Domenia.Simulation;
using Domenia.Store;
using Reading = Domenia.Core.Queries.ProbeReading;

namespace Domenia.Tests;

internal static class QueryPersonalProbeTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    internal static QueryRecipe Recipe(FrozenProbe probe) => QueryRecipe.Empty() with
    {
        Name = "Fabricants déclarés", Clauses = [new("probe:" + probe.Key, QueryOperator.Contains, QueryValue.FromText("B"))],
        PersonalProbes = [QueryProbeDeclaration.From(probe)],
    };
    internal static Reading ReadingOf(FrozenProbe probe, params string[] values) => new(probe.Key, Fixtures.Now, null, false, false,
        values.Length, true, [.. values.Select((v, i) => new ProbeInstance(i.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ImmutableDictionary<string, object?>.Empty.Add(probe.Definition.Properties[0], v), []))])
    { PersonalDeclaration = QueryProbeDeclaration.From(probe) };

    private static QueryDataset Dataset(DirectorySnapshot directory, ImmutableDictionary<Guid, ImmutableArray<Reading>>? probes = null) =>
        new(directory, new(null, []), probes ?? ImmutableDictionary<Guid, ImmutableArray<Reading>>.Empty,
            ImmutableDictionary<Guid, ConsoleReading>.Empty, ImmutableDictionary<Guid, char>.Empty,
            ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>>.Empty, 1, "Données de fixture", true);

    private static async Task<JsonElement> Call(SimulatedBridge bridge, string operation, object? args = null) =>
        SimulatedBridge.Json(await bridge.CallAsync(operation, JsonSerializer.Serialize(args ?? new { }, BridgeJson.Options)));

    [Test]
    public static async Task Personal_query_widget_placement_uses_a_preloaded_profile_inside_the_real_atomic_preference_store()
    {
        using var folder = new TemporaryFolder();
        using var preferences = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal());
        var bridge = new SimulatedBridge(preferences: preferences);
        var probe = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        await PersonalProbeFixtures.Import(AccueilService.From(bridge.Context), PersonalProbeFixtures.Document());
        await Domenia.Core.Poste.PosteBoardLayouts.SaveAsync(preferences, "Computer", [], None);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var response = await bridge.CallAsync("requetes.widget.save", JsonSerializer.Serialize(new
        { recipe = Recipe(probe), board = "computer", visual = "text", title = "Fabricant personnel", expectedRevision = 0 }, BridgeJson.Options), deadline.Token)
            .WaitAsync(TimeSpan.FromSeconds(10));
        var saved = SimulatedBridge.Json(response);
        Check.True(saved.GetProperty("placement").GetProperty("applied").GetBoolean(), "la lecture du profil ne réentre pas dans writeGate depuis le callback atomique");
        using var reopened = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal());
        var item = Domenia.Core.Poste.PosteBoardLayouts.Read(reopened, "Computer").Items.Single();
        Check.Equal(saved.GetProperty("id").GetString(), item.QueryBinding!.RecipeId, "carte réellement relue sur disque");
        Check.Equal(probe.Key, ProfileProbeCatalog.Read(reopened).Entries.Single().Key, "profil personnel conservé avec la disposition");
    }

    [Test]
    public static async Task One_collection_request_sends_only_each_targets_missing_probe_without_restarting_the_total_budget()
    {
        var bridge = new SimulatedBridge(); var reader = bridge.Context.Readers.Require<IQueryWorkshopReader>();
        var data = await reader.DatasetAsync(None);
        var a = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        var b = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document("Model")).Single();
        var targets = data.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && (c.UserAccountControl & AdValues.ServerTrustAccount) == 0
            && !bridge.Source.World.Presence.NeverAnswer.Contains(c.ObjectGuid) && !bridge.Source.World.Presence.ErrorProbes.Contains(c.ObjectGuid)).Take(2).ToArray();
        var masks = ImmutableDictionary<Guid, QueryMeasureMask>.Empty
            .Add(targets[0].ObjectGuid, new(false, false, false, [a.Key], []))
            .Add(targets[1].ObjectGuid, new(false, false, false, [b.Key], []));
        var request = new QueryMeasureRequest([.. targets.Select(c => c.ObjectGuid)], false, false, false, [a.Key, b.Key])
        { PersonalProbes = [a, b], TargetMeasures = masks };
        request.ValidateTargetMeasures();
        Check.Equal(a.Key, request.ForComputer(targets[0].ObjectGuid).Probes.Single(), "première cible : seulement la source manquante A");
        Check.Equal(b.Key, request.ForComputer(targets[1].ObjectGuid).PersonalProbes.Single().Key, "seconde cible : seulement la définition manquante B");
        await reader.MeasureAsync(request, None);
        var after = await reader.DatasetAsync(None);
        Check.True(after.Probes[targets[0].ObjectGuid].Any(p => p.ProbeId == a.Key), "tentative A reçue ou explicitement inconnue");
        Check.False(after.Probes[targets[0].ObjectGuid].Any(p => p.ProbeId == b.Key), "aucune lecture B sur A");
        Check.True(after.Probes[targets[1].ObjectGuid].Any(p => p.ProbeId == b.Key), "tentative B reçue ou explicitement inconnue");
        Check.False(after.Probes[targets[1].ObjectGuid].Any(p => p.ProbeId == a.Key), "aucune lecture A sur B");
        Check.Throws<QueryDefinitionException>(() => (request with { TargetMeasures = masks.Remove(targets[1].ObjectGuid) }).ValidateTargetMeasures(), "aucune cible oubliée par le masque");
        Check.Throws<QueryDefinitionException>(() => (request with { TargetMeasures = masks.SetItem(targets[0].ObjectGuid, new(false, false, false, [], []))
            .SetItem(targets[1].ObjectGuid, new(false, false, false, [a.Key, b.Key], [])) }).ValidateTargetMeasures(), "union valide mais cible vide refusée : jamais Answered sans contact");
    }

    [Test]
    public static void Personal_collection_preserves_declared_numbers_booleans_and_unknown_instead_of_text_coercion()
    {
        var document = JsonNode.Parse(PersonalProbeFixtures.Document("TotalPhysicalMemory", "All"))!;
        var definition = document["Probes"]![0]!;
        definition["Transform"] = "Number";
        definition["Fields"]![0]!["CimType"] = "uint64";
        definition["Fields"]![0]!["Kind"] = "Number";
        definition["Properties"]!.AsArray().Add("HypervisorPresent");
        definition["Fields"]!.AsArray().Add(JsonNode.Parse("""{"Name":"HypervisorPresent","CimType":"boolean","Kind":"Boolean","IsArray":false,"Unit":"","Description":"État déclaré."}"""));
        var probe = PersonalProbeCatalog.Import(document.ToJsonString()).Single();
        var query = QueryEngine.Compile(Recipe(probe) with { Clauses = [], Expression = QueryNode.Collection("probe:" + probe.Key, CollectionQuantifier.All,
            QueryNode.Group(QueryNodeKind.All, [QueryNode.Leaf(new("instance:" + probe.Key + ":TotalPhysicalMemory", QueryOperator.Greater, QueryValue.FromNumber(1000))),
                QueryNode.Leaf(new("instance:" + probe.Key + ":HypervisorPresent", QueryOperator.Equal, QueryValue.FromBoolean(true)))])) });
        Check.Equal(QueryFieldKind.Number, query.FindField("instance:" + probe.Key + ":TotalPhysicalMemory")!.Kind, "type numérique déclaré");
        Check.Equal(QueryFieldKind.Boolean, query.FindField("instance:" + probe.Key + ":HypervisorPresent")!.Kind, "type booléen déclaré");
        var pc = Fixtures.Computer("PC1");
        var instance = new ProbeInstance("one", ImmutableDictionary<string, object?>.Empty.Add("TotalPhysicalMemory", 4096m).Add("HypervisorPresent", true), []);
        var reading = new Reading(probe.Key, Fixtures.Now, null, false, false, 1, true, [instance]) { PersonalDeclaration = QueryProbeDeclaration.From(probe) };
        QueryReadingRules.Validate(new(pc.ObjectGuid, pc.DistinguishedName, pc.WhenCreated, [reading], []), Fixtures.Now);
        var dataset = Dataset(Fixtures.Snapshot(computers: [pc]), ImmutableDictionary<Guid, ImmutableArray<Reading>>.Empty.Add(pc.ObjectGuid, [reading]));
        var record = QueryRecordBuilder.Computer(dataset, pc.ObjectGuid, Fixtures.Now)!;
        Check.Equal(MatchState.Match, query.Evaluate(record, new(null, Fixtures.Now)), "valeurs CLR typées conservées jusqu’au verdict");
        reading = reading with { Instances = [instance with { Values = instance.Values.SetItem("HypervisorPresent", null) }] };
        var missing = QueryRecordBuilder.Computer(dataset with { Probes = dataset.Probes.SetItem(pc.ObjectGuid, [reading]) }, pc.ObjectGuid, Fixtures.Now)!;
        Check.Equal(MatchState.Unknown, query.Evaluate(missing, new(null, Fixtures.Now)), "booléen absent reste inconnu");
    }

    [Test]
    public static async Task Actual_bridge_connects_profile_catalog_editor_collection_library_widget_and_exports_to_the_same_version()
    {
        var bridge = new SimulatedBridge();
        var document = PersonalProbeFixtures.Document(mode: "All"); var frozen = PersonalProbeCatalog.Import(document).Single();
        var catalog = await Call(bridge, "accueil.probes.personal");
        var import = await Call(bridge, "accueil.probes.preview", new { document, expectedChoiceToken = catalog.GetProperty("choiceToken").GetString() });
        await Call(bridge, "accueil.probes.apply", new { document, expectedChoiceToken = import.GetProperty("choiceToken").GetString(), expectedDocumentSha256 = import.GetProperty("documentSha256").GetString() });
        var workshop = await Call(bridge, "requetes.catalog", new { target = "computer" });
        Check.True(workshop.GetProperty("fields").EnumerateArray().Any(f => f.GetProperty("id").GetString() == "probe:" + frozen.Key), "même clé complète exposée au compositeur existant");
        Check.True(workshop.GetProperty("instanceFields").EnumerateArray().Any(f => f.GetProperty("id").GetString() == "instance:" + frozen.Key + ":Manufacturer"), "propriété typée disponible dans l’arbre de collections");
        var ou = await RequetesOperationsTests.WorkstationsOuAsync(bridge);
        await Call(bridge, "requetes.scope.set", new { dn = ou, subtree = true });
        var reader = bridge.Context.Readers.Require<IQueryWorkshopReader>(); var before = await reader.DatasetAsync(None);
        var scope = new ScopeSelection(ou, "Postes", true);
        var computers = before.Directory.Computers.Where(c => ScopeRules.Contains(scope, c.DistinguishedName) && !AdValues.IsDisabled(c.UserAccountControl)
            && (c.UserAccountControl & AdValues.ServerTrustAccount) == 0 && !bridge.Source.World.Presence.NeverAnswer.Contains(c.ObjectGuid)
            && !bridge.Source.World.Presence.ErrorProbes.Contains(c.ObjectGuid)).Take(24).ToArray();
        var expected = bridge.Source.ScreenStream("requetes").Fork("measure/1");
        Check.True(computers.Length > 0 && computers.Select(_ => expected.Chance(88)).Any(answer => answer), "fixture de la prochaine manche contient un répondant déterministe");
        var draft = Recipe(frozen) with { PersonalProbes = [], Clauses = [new("probe:" + frozen.Key, QueryOperator.IsPresent, QueryValue.None)],
            ObjectIds = [.. computers.Select(c => c.ObjectGuid.ToString("D"))] };
        var validation = await Call(bridge, "requetes.validate", new { recipe = draft });
        Check.True(validation.GetProperty("valid").GetBoolean(), "brouillon créé par la liste de champs hydraté et validé");
        var normalized = QueryRecipeJson.Read(validation.GetProperty("recipe"));
        Check.Equal(frozen.Key, normalized.PersonalProbes.Single().Key, "déclaration figée injectée par le moteur");
        var saved = await Call(bridge, "requetes.widget.save", new { recipe = draft, board = "fleet", visual = "kpi", title = "Fabricants reçus", expectedRevision = 0 });
        var savedRecipe = QueryRecipeJson.Read(saved.GetProperty("recipe")); var id = saved.GetProperty("id").GetString()!;
        Check.True(saved.GetProperty("remote").GetBoolean(), "personnalisée classée parmi les mesures à collecter");
        Check.False((await reader.DatasetAsync(None)).Probes.Values.SelectMany(p => p).Any(p => p.ProbeId == frozen.Key), "import, validation et enregistrement sans collecte");
        var plan = await Call(bridge, "requetes.collect.plan", new { recipe = savedRecipe, cacheMinutes = 0 });
        Check.Equal(frozen.Key, plan.GetProperty("plan").GetProperty("personalProbes")[0].GetProperty("key").GetString(), "plan expose la définition exacte qu’il conserve");
        var changed = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document("Model", "All")).Single();
        await PersonalProbeFixtures.Import(AccueilService.From(bridge.Context), PersonalProbeFixtures.Document("Model", "All"));
        var read = await Call(bridge, "requetes.collect.run", new { ticket = plan.GetProperty("ticket").GetString() });
        Check.True(read.GetProperty("result").GetProperty("answered").GetInt32() > 0, "collecte simulée par le vrai lecteur d’atelier");
        var after = await reader.DatasetAsync(None);
        Check.True(after.Probes.Values.SelectMany(p => p).Any(p => p.ProbeId == frozen.Key && p.Error is null), "résultats de la version préparée persistés");
        Check.False(after.Probes.Values.SelectMany(p => p).Any(p => p.ProbeId == changed.Key), "ajout concurrent sans substitution de définition");
        var preview = await Call(bridge, "requetes.preview", new { recipe = savedRecipe, verdict = "all", limit = 250 });
        Check.True(preview.GetProperty("counts").GetProperty("matched").GetInt32() > 0, "données typées retrouvées par l’aperçu réel");
        Check.True(preview.GetProperty("columns").EnumerateArray().Any(c => c.GetProperty("id").GetString() == "probe:" + frozen.Key), "colonne affichable par l’UI existante");
        var export = await Call(bridge, "requetes.preview.export", new { evaluationId = preview.GetProperty("id").GetString(), verdict = "all", format = "json" });
        var contents = await Call(bridge, "requetes.export.content", new { token = export.GetProperty("token").GetString() });
        Check.Contains("probe:" + frozen.Key, contents.GetProperty("content").GetString(), "export des vraies valeurs, clé complète conservée");
        var unconfirmed = await bridge.CallAsync("requetes.library.save", JsonSerializer.Serialize(new { recipe = Recipe(changed) with { Id = id }, expectedRevision = 1 }, BridgeJson.Options));
        Check.Equal("query.impactRequired", unconfirmed.Error!.Code, "changement de définition lié exige la revue d’impact");
        var revision = await Call(bridge, "requetes.library.save", new { recipe = Recipe(changed) with { Id = id }, expectedRevision = 1, mode = "copy" });
        Check.True(revision.GetProperty("id").GetString() != id, "copie explicite de la nouvelle projection sans réattribuer le widget existant");
        var widget = await Call(bridge, "requetes.widget.evaluate", new { id = saved.GetProperty("widget").GetProperty("id").GetString() });
        Check.Equal(1L, widget.GetProperty("boundRevision").GetInt64(), "widget toujours lié à la révision initiale");
        Check.True(widget.GetProperty("counts").GetProperty("matched").GetInt32() > 0, "ancienne révision conserve sa projection et ses valeurs");
        var next = await Call(bridge, "requetes.collect.plan", new { recipe = savedRecipe, cacheMinutes = 0 });
        var version = (await reader.DatasetAsync(None)).Version;
        await bridge.Preferences.SetAsync(PersonalProbeCatalog.PreferenceKey, JsonSerializer.SerializeToElement<object?>(null), None);
        var refused = await bridge.CallAsync("requetes.collect.run", JsonSerializer.Serialize(new { ticket = next.GetProperty("ticket").GetString() }));
        Check.Equal("probes.changed", refused.Error!.Code, "déclaration embarquée n’autorise pas une collecte sans profil");
        Check.Equal(version, (await reader.DatasetAsync(None)).Version, "aucune mesure après refus");
        var retained = await Call(bridge, "requetes.library.get", new { id });
        Check.Contains("Utilisation indisponible", retained.GetProperty("collection").GetString(), "absence de profil expliquée dans la bibliothèque sans perdre la recette");
    }

    [Test]
    public static async Task Actual_bridge_refuses_a_collection_ticket_after_account_or_scope_changes_before_any_measure()
    {
        var bridge = new SimulatedBridge(); var probe = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        await PersonalProbeFixtures.Import(AccueilService.From(bridge.Context), PersonalProbeFixtures.Document());
        var ou = await RequetesOperationsTests.WorkstationsOuAsync(bridge);
        await Call(bridge, "requetes.scope.set", new { dn = ou, subtree = true });
        var reader = bridge.Context.Readers.Require<IQueryWorkshopReader>(); var local = await reader.DatasetAsync(None);
        var pc = local.Directory.Computers.First(c => ScopeRules.Contains(new(ou, "Postes", true), c.DistinguishedName) && !AdValues.IsDisabled(c.UserAccountControl));
        var recipe = Recipe(probe) with { ObjectIds = [pc.ObjectGuid.ToString("D")] };
        var plan = await Call(bridge, "requetes.collect.plan", new { recipe, cacheMinutes = 0 });
        MachineAccountService.From(bridge.Context).UseRemote(@"TEST\another", null);
        var refused = await bridge.CallAsync("requetes.collect.run", JsonSerializer.Serialize(new { ticket = plan.GetProperty("ticket").GetString() }));
        Check.Equal("query.collectRefused", refused.Error!.Code, "génération du compte figée avant confirmation");
        plan = await Call(bridge, "requetes.collect.plan", new { recipe, cacheMinutes = 0 });
        await Call(bridge, "requetes.scope.set", new { dn = ou, subtree = false });
        refused = await bridge.CallAsync("requetes.collect.run", JsonSerializer.Serialize(new { ticket = plan.GetProperty("ticket").GetString() }));
        Check.Equal("query.collectRefused", refused.Error!.Code, "sous-arbre changé : ancien plan refusé");
        Check.Equal(local.Version, (await reader.DatasetAsync(None)).Version, "aucun lecteur de mesures engagé");
    }

    [Test]
    public static void Recipe_four_roundtrips_the_exact_declaration_and_evaluates_typed_instances_without_exists_shortcuts()
    {
        var frozen = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document(mode: "All")).Single();
        var recipe = Recipe(frozen) with { Expression = QueryNode.Collection("probe:" + frozen.Key, CollectionQuantifier.Any,
            QueryNode.Leaf(new("instance:" + frozen.Key + ":Manufacturer", QueryOperator.Equal, QueryValue.FromText("B")))) };
        var query = QueryEngine.Compile(recipe);
        var written = QueryRecipeJson.Write(query.Normalized);
        Check.Contains("Domenia.Query/4", written, "format minimal dédié aux déclarations personnelles");
        Check.Equal(query.Fingerprint, QueryEngine.Compile(QueryRecipeJson.Read(written)).Fingerprint, "empreinte stable après lecture canonique");
        Check.Equal(QueryFieldKind.Text, query.FindField("instance:" + frozen.Key + ":Manufacturer")!.Kind, "type de la propriété conservé");
        Check.Equal(frozen.Key, query.Probes.Definitions.Single().Key, "clé complète de 71 caractères");
        var pc = Fixtures.Computer("PC1");
        var data = Dataset(Fixtures.Snapshot(computers: [pc]), ImmutableDictionary<Guid, ImmutableArray<Reading>>.Empty.Add(pc.ObjectGuid, [ReadingOf(frozen, "A", "B")]));
        var record = QueryRecordBuilder.Computer(data, pc.ObjectGuid, Fixtures.Now)!;
        Check.Equal(MatchState.Match, query.Evaluate(record, new(null, Fixtures.Now)), "la deuxième instance réelle est interrogée");
        Check.True(record.Collections[frozen.Key].Complete, "collection complète datée, sans conversion en simple exists");
        Check.Contains("B", record.Value("probe:" + frozen.Key) as string, "valeurs All conservées");
        Check.True(query.Explain(record, new(null, Fixtures.Now)).Any(r => r.Condition.Contains("Fabricant", StringComparison.Ordinal)), "explication avec le vrai catalogue personnel");
        Check.Null(QueryProbeCatalog.Find(frozen.Key), "aucun catalogue global modifié");
        var ordinary = QueryRecipe.Empty() with { Id = "ordinary", Name = "Ordinaire" };
        Check.Equal(QueryRecipe.FormatV1, ordinary.MinimalFormat(), "format historique minimal inchangé");
        Check.False(QueryRecipeJson.Write(ordinary).Contains("PersonalProbes", StringComparison.Ordinal), "aucun champ ajouté aux écritures ordinaires");
        var different = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document("Model", "All")).Single();
        Check.Throws<QueryDefinitionException>(() => QueryEngine.Compile(recipe with
        { PersonalProbes = [new(frozen.Key, PersonalProbeCatalog.Export(different))] }), "déclaration valide mais empreinte différente refusée");
        Check.Throws<QueryDefinitionException>(() => QueryEngine.Compile(recipe with { PersonalProbes = [] }), "déclaration absente refusée par le compilateur pur");
    }

    [Test]
    public static async Task Profile_admission_and_library_import_preserve_revisions_without_importing_a_probe_or_collecting()
    {
        var frozen = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document(mode: "All")).Single();
        var preferences = new MemoryPreferenceStore();
        var draft = Recipe(frozen) with { PersonalProbes = [] };
        await Check.ThrowsAsync<DomeniaOperationException>(() => QueryPersonalProbes.BindAsync(draft, preferences, None), "profil vide refusé");
        await preferences.SetAsync(PersonalProbeCatalog.PreferenceKey, PersonalProbeCatalog.Merge(PersonalProbeCatalog.Read(null), [frozen]), None);
        var bound = await QueryPersonalProbes.BindAsync(draft, preferences, None);
        var query = QueryEngine.Compile(bound);
        using var folder = new TemporaryFolder();
        var cache = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", TestClock.Fixed(), isolated: true);
        using var library = new QueryLibrary(cache, new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
        var saved = await library.SaveAsync(Fixtures.Root, bound, null, null, 0, "update", null, None);
        var changed = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document("Model", "All")).Single();
        await preferences.SetAsync(PersonalProbeCatalog.PreferenceKey, PersonalProbeCatalog.Merge(ProfileProbeCatalog.Read(preferences), [changed]), None);
        await QueryPersonalProbes.ConfirmAsync(query, preferences, None);
        var revision = await library.SaveAsync(Fixtures.Root, Recipe(changed) with { Id = saved.Record.Id }, null, null, 1, "update", null, None);
        Check.Equal(frozen.Key, QueryLibrary.RevisionRecipe(revision.Record, 1)!.PersonalProbes.Single().Key, "historique lié à l’ancienne projection");
        using var reopened = new QueryLibrary(new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", TestClock.Fixed(), isolated: true),
            new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
        Check.Equal(changed.Key, (await reopened.ReadAsync(Fixtures.Root, None)).Records.Single().Recipe.PersonalProbes.Single().Key, "déclaration relue par SQLite");
        var restored = await reopened.RevertAsync(Fixtures.Root, saved.Record.Id, 1, 2, "update", None);
        Check.Equal(frozen.Key, restored.Record.Recipe.PersonalProbes.Single().Key, "restauration conserve la provenance originale");
        var pack = await reopened.ExportPackAsync(Fixtures.Root, Fixtures.Root, "Équipe", 1, null, "Déclarant", None);
        using var imported = new QueryLibrary(new MemoryQueryLibraryStore(), new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
        var preview = await imported.ExaminePackAsync(Fixtures.Root, Fixtures.Root, pack.Json, None);
        Check.Equal(1, preview.Items.Length, "une recette qualifiée dans l’aperçu");
        Check.Equal("ignore", preview.Items.Single().DefaultAction, "l’aperçu n’accorde aucun consentement d’import implicite");
        var ignored = await imported.ApplyImportAsync(Fixtures.Root, preview.ExaminationId, preview.Items.ToDictionary(i => i.Id, i => i.DefaultAction), None);
        Check.Equal(0, ignored.Created, "le choix par défaut ne crée aucune recette");
        Check.Equal(1, ignored.Ignored, "la recette reste explicitement ignorée");
        Check.Equal(0, (await imported.ReadAsync(Fixtures.Root, None)).Records.Count, "aucune recette enregistrée sans choix de création");
        preview = await imported.ExaminePackAsync(Fixtures.Root, Fixtures.Root, pack.Json, None);
        Check.True(preview.Items.Single().AllowedActions.Contains("create"), "création proposée après lecture de l’aperçu");
        var applied = await imported.ApplyImportAsync(Fixtures.Root, preview.ExaminationId, preview.Items.ToDictionary(i => i.Id, _ => "create"), None);
        Check.Equal(1, applied.Created, "choix explicite de création appliqué");
        var received = (await imported.ReadAsync(Fixtures.Root, None)).Records.Single();
        Check.Equal(frozen.Key, received.Recipe.PersonalProbes.Single().Key, "pack garde la clé originale");
        Check.Equal(PersonalProbeCatalog.Export(frozen), received.Recipe.PersonalProbes.Single().Document, "déclaration originale conservée intégralement");
        var emptyProfile = new MemoryPreferenceStore();
        await Check.ThrowsAsync<DomeniaOperationException>(() => QueryPersonalProbes.ConfirmAsync(QueryEngine.Compile(received.Recipe), emptyProfile, None), "l’import de recette ne donne pas autorité de collecte");
        Check.False(emptyProfile.TryGet(PersonalProbeCatalog.PreferenceKey, out _), "aucune sonde importée implicitement");
    }

    [Test]
    public static async Task Cached_typed_readings_keep_their_declaration_after_SQLite_reopen_and_reject_alias_reassignment()
    {
        var frozen = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document(mode: "All")).Single(); var pc = Fixtures.Computer("PC1");
        using var folder = new TemporaryFolder();
        var cache = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", TestClock.Fixed(), isolated: true);
        await cache.PrepareAsync(None); await cache.SaveObjectsAsync(Fixtures.Snapshot(computers: [pc]), "DC1.test.local", None);
        var reading = new QueryComputerReadings(pc.ObjectGuid, pc.DistinguishedName, pc.WhenCreated, [ReadingOf(frozen, "A", "B")], []);
        await cache.SaveQueryResultsAsync(reading, None);
        var reopened = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", TestClock.Fixed(), isolated: true);
        var actual = (await reopened.ReadQueryResultsAsync(None)).Computers.Single().Probes.Single();
        Check.Equal(frozen.Key, actual.PersonalDeclaration!.Key, "provenance relue");
        Check.Equal("B", actual.Instances[1].Values["Manufacturer"] as string, "seconde valeur typée conservée");
        Check.Throws<InvalidDataException>(() => QueryReadingRules.Validate(reading with { Probes = [actual with { PersonalDeclaration = null }] }, Fixtures.Now), "clé custom sans provenance refusée");
        var changed = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document("Model", "All")).Single();
        Check.Throws<InvalidDataException>(() => QueryReadingRules.Validate(reading with
        { Probes = [actual with { PersonalDeclaration = new(frozen.Key, PersonalProbeCatalog.Export(changed)) }] }, Fixtures.Now), "cache jamais réinterprété sous un nouvel alias");
    }

    [Test]
    public static void Query_collection_and_frozen_refresh_retain_exact_definitions_and_exclude_controllers_from_fresh_counts()
    {
        var frozen = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document(mode: "All")).Single();
        var pc = Fixtures.Computer("PC1"); var dc = Fixtures.Computer("DC1") with { UserAccountControl = AdValues.ServerTrustAccount };
        var data = Dataset(Fixtures.Snapshot(computers: [pc, dc])); var query = QueryEngine.Compile(Recipe(frozen));
        var plan = QueryAnalysis.CollectPlan(query, QueryRecordBuilder.Build(data, QueryTarget.Computer, null, Fixtures.Now), new(null, Fixtures.Now), Fixtures.Now);
        Check.Equal(1, plan.Targets.Length, "seul le membre est une cible"); Check.Equal(0L, plan.Reused, "DC exclu jamais annoncé à jour");
        Check.Equal(1L, plan.ExcludedDomainControllers, "exclusion explicite dans le plan");
        Check.Equal(frozen.Key, plan.PersonalProbes.Single().Key, "plan figé complet");
        var identities = new[] { pc, dc }.ToImmutableDictionary(c => c.ObjectGuid, QueryComputerIdentity.Of);
        var requests = QueryRefreshRules.Requests(new(query.Normalized.Id, 1, query.Fingerprint, query.Normalized), data,
            new(Fixtures.Postes, "Postes", true), identities, identities.Keys.ToHashSet(), Fixtures.Now, true);
        Check.Equal(frozen.Key, requests.Single().PersonalProbes.Single().Key, "requête du widget reprend la définition figée");
        Check.True(QueryPersonalProbes.ForRequest(requests.Single()).Find(frozen.Key) is not null, "admission réelle sait résoudre la clé");
        Check.Throws<QueryDefinitionException>(() => QueryPersonalProbes.ForRequest(requests.Single() with { PersonalProbes = [] }), "reprise privée de sa déclaration refusée");
        Check.Throws<QueryDefinitionException>(() => QueryPersonalProbes.Confirm(query, []), "évaluation du widget refuse un profil incomplet");
    }

    [Test]
    public static async Task Simulation_projects_the_same_catalog_instances_and_never_reuses_a_different_version()
    {
        var bridge = new SimulatedBridge();
        var frozen = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document(mode: "All")).Single();
        var changed = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document("Model", "All")).Single();
        var reader = bridge.Context.Readers.Require<IQueryWorkshopReader>();
        var before = await reader.DatasetAsync(None); var session = await bridge.Source.GetSessionAsync(None);
        var candidates = before.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && (c.UserAccountControl & AdValues.ServerTrustAccount) == 0
            && !bridge.Source.World.Presence.NeverAnswer.Contains(c.ObjectGuid) && !bridge.Source.World.Presence.ErrorProbes.Contains(c.ObjectGuid)).Take(24).ToArray();
        var expectedStream = bridge.Source.ScreenStream("requetes").Fork("measure/1");
        Check.True(candidates.Select(_ => expectedStream.Chance(88)).Any(answer => answer), "la prochaine manche inclut explicitement un répondant déterministe");
        var request = new QueryMeasureRequest([.. candidates.Select(c => c.ObjectGuid)], false, false, false, [frozen.Key])
        { PersonalProbes = [frozen], ExpectedEpoch = session.Epoch, ExpectedIdentities = candidates.ToImmutableDictionary(c => c.ObjectGuid, QueryComputerIdentity.Of) };
        await reader.MeasureAsync(request, None);
        var after = await reader.DatasetAsync(None);
        var successful = after.Probes.SelectMany(p => p.Value.Select(r => (Id: p.Key, Reading: r))).Where(r => r.Reading.ProbeId == frozen.Key && r.Reading.Error is null).ToArray();
        Check.True(successful.Length > 0, "projection simulée disponible dans une population de répondants");
        foreach (var item in successful)
        {
            var select = await bridge.Context.Readers.Require<IQueryWmiReader>().SelectAsync(item.Id, frozen.Definition.Namespace,
                WqlRules.Parse("SELECT Manufacturer FROM Win32_ComputerSystem"), 500, None);
            var expected = select.Rows.Select(row => row.Values.GetValueOrDefault("Manufacturer")).ToArray();
            Check.True(item.Reading.Instances.Select(i => i.Values["Manufacturer"] as string).SequenceEqual(expected), "valeurs du catalogue simulé existant, aucune valeur générique inventée");
            Check.Equal(frozen.Key, item.Reading.PersonalDeclaration!.Key, "cache de simulation qualifié");
        }
        Check.False(after.Probes.Values.SelectMany(p => p).Any(p => p.ProbeId == changed.Key), "nouvelle version jamais remplie avec les mesures de l’ancienne");
        var target = candidates[0];
        var mixed = request with { Computers = [target.ObjectGuid], Probes = [.. QueryProbeCatalog.All.Select(p => p.Id), frozen.Key],
            ExpectedIdentities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(target.ObjectGuid, QueryComputerIdentity.Of(target) with { Host = "other.test.local" }) };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.MeasureAsync(mixed, None), "catalogue mixte accepté jusqu’à la garde de cible, sans mauvaise borne embarquée");
    }
}
