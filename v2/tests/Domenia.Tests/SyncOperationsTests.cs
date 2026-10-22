using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>
/// Operations of « Synchronisation et base autonome » through the real bridge over the simulated source (docs/ops/synchro.md):
/// exact shapes, errors, admission, reads that keep their result, storage through write.execute only, re-read of the base.
/// </summary>
internal static class SyncOperationsTests
{
    private const string Root = "DC=example,DC=local";
    private const string Postes = "OU=Postes," + Root;
    private const string Users = "OU=Utilisateurs," + Root;
    private const string Servers = "OU=Serveurs," + Root;

    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static string Execute(JsonElement planned) => Args(new
    {
        planId = planned.GetProperty("plan").GetProperty("id").GetString(),
        token = planned.GetProperty("token").GetString(),
        typedName = (string?)null,
    });

    private static async Task<JsonElement> Ok(SimulatedBridge bridge, string op, object? args = null) =>
        SimulatedBridge.Json(await bridge.CallAsync(op, args is null ? "{}" : Args(args)));

    private static async Task<string> Error(SimulatedBridge bridge, string op, object? args = null)
    {
        var response = await bridge.CallAsync(op, args is null ? "{}" : Args(args));
        Check.Equal("error", response.Kind, op + " : refus attendu");
        return response.Error!.Code;
    }

    [Test]
    public static async Task The_overview_reads_the_base_for_the_working_OU()
    {
        var bridge = new SimulatedBridge();
        var o = await Ok(bridge, "synchro.overview");
        Check.Equal(Postes, o.GetProperty("scope").GetProperty("dn").GetString(), "OU de travail par défaut");
        Check.Equal("working", o.GetProperty("scope").GetProperty("source").GetString(), "source du périmètre");
        Check.True(o.GetProperty("simulated").GetBoolean(), "base de la simulation");
        string[] keys = [.. o.GetProperty("tiles").EnumerateArray().Select(t => t.GetProperty("key").GetString()!)];
        Check.True(keys.SequenceEqual(["accounts", "computers", "links", "updated"]), "quatre tuiles");
        Check.Equal("complete", o.GetProperty("coverage").GetProperty("status").GetString(), "Postes lue il y a 12 min");
        Check.Equal("recent", o.GetProperty("census").GetProperty("state").GetString(), "recensement récent");
        Check.True(o.GetProperty("checkpoint").GetProperty("usn").GetInt64() > 0, "repère du domaine");
        Check.True(o.GetProperty("readiness").GetProperty("ready").GetBoolean(), "lecture possible");
        Check.Equal(JsonValueKind.Null, o.GetProperty("running").ValueKind, "aucune lecture en cours (champ écrit)");
        Check.Equal(JsonValueKind.Null, o.GetProperty("pending").ValueKind, "aucune lecture en attente (champ écrit)");
        Check.True(o.GetProperty("notices").EnumerateArray().Any(n => n.GetProperty("text").GetString()!.Contains("incomplète", StringComparison.Ordinal)), "passe coupée signalée");
        Check.Contains("Postes", o.GetProperty("lead").GetString(), "phrase du héros");
        Check.False(o.ToString().Contains("password", StringComparison.OrdinalIgnoreCase), "aucun secret");
    }

    [Test]
    public static async Task The_scope_is_checked_locally_and_the_root_is_never_an_OU_update()
    {
        var bridge = new SimulatedBridge();
        var servers = await Ok(bridge, "synchro.overview", new { dn = Servers });
        Check.Equal("partial", servers.GetProperty("coverage").GetProperty("status").GetString(), "tentative coupée plus récente que le repère");
        Check.Equal("partial", servers.GetProperty("census").GetProperty("state").GetString(), "recensement incomplet");
        var domain = await Ok(bridge, "synchro.overview", new { dn = Root });
        Check.True(domain.GetProperty("scope").GetProperty("isDomain").GetBoolean(), "domaine entier");
        Check.Equal("gap", domain.GetProperty("census").GetProperty("state").GetString(), "objets manquants du recensement");
        Check.Equal("ou.unknown", await Error(bridge, "synchro.overview", new { dn = "OU=Absente," + Root }), "OU inconnue");
        Check.Equal("arguments.invalid", await Error(bridge, "synchro.overview", new { dn = "pas un DN" }), "DN mal formé");
        Check.Equal("arguments.invalid", await Error(bridge, "synchro.overview", new { autre = 1 }), "propriété non admise");
        Check.Equal(SyncErrors.ScopeRoot, await Error(bridge, "synchro.read.estimate", new { target = "ou", dn = Root }), "jamais tout le domaine par OU");
        Check.Equal("arguments.invalid", await Error(bridge, "synchro.read.estimate", new { target = "tout" }), "cible fermée");
        Check.Equal("arguments.invalid", await Error(bridge, "synchro.read.estimate", new { target = "ou", maxObjects = -1 }), "quota négatif");
        Check.Equal("arguments.invalid", await Error(bridge, "synchro.read.estimate", new { target = "ou", budgetSeconds = 5 }), "budget trop court");
    }

    [Test]
    public static async Task The_local_index_is_paged_after_a_sort_of_the_whole_population()
    {
        var bridge = new SimulatedBridge();
        var all = await Ok(bridge, "synchro.index.search", new { text = "" });
        var total = all.GetProperty("total").GetInt32();
        Check.True(total > 400, "tout le périmètre Postes");
        Check.Equal(200, all.GetProperty("rows").GetArrayLength(), "page de 200");
        Check.True(all.GetProperty("hasMore").GetBoolean(), "pages suivantes");
        var page2 = await Ok(bridge, "synchro.index.search", new { text = "", sort = "name", descending = true, offset = 200, limit = 100 });
        Check.Equal(3, page2.GetProperty("page").GetInt32(), "page 3 de 100");
        var names = page2.GetProperty("rows").EnumerateArray().Select(r => FrenchText.Fold(r.GetProperty("name").GetString()!)).ToList();
        Check.True(names.SequenceEqual(names.OrderByDescending(n => n, StringComparer.Ordinal)), "tri décroissant sur la population");
        var term = await Ok(bridge, "synchro.index.search", new { text = "PC-BDX-0003$" });
        Check.Equal(100, term.GetProperty("rows")[0].GetProperty("score").GetInt32(), "correspondance exacte en tête");
        Check.Equal("arguments.invalid", await Error(bridge, "synchro.index.search", new { text = new string('a', 101) }), "terme trop long");
        Check.Equal("arguments.invalid", await Error(bridge, "synchro.index.search", new { text = "", sort = "dn" }), "tri non admis");
        Check.Equal("arguments.invalid", await Error(bridge, "synchro.index.search", new { text = "", limit = 501 }), "500 au plus");
        var export = await Ok(bridge, "synchro.index.export", new { text = "pc-lyo" });
        Check.False(export.GetProperty("written").GetBoolean(), "mémoire seulement dans les tests : rien n’est écrit");
        Check.True(export.GetProperty("rows").GetInt32() > 0, "lignes exportées");
    }

    [Test]
    public static async Task A_read_is_kept_until_its_plan_runs_once_and_the_base_is_read_again()
    {
        var bridge = new SimulatedBridge();
        var before = await Ok(bridge, "synchro.overview", new { dn = Users });
        var estimate = await Ok(bridge, "synchro.read.estimate", new { target = "ou", dn = Users });
        Check.Equal("ou", estimate.GetProperty("mode").GetString(), "lecture d’OU");
        Check.True(estimate.GetProperty("ready").GetBoolean(), "prête");
        var read = await Ok(bridge, "synchro.read.run", new { estimateId = estimate.GetProperty("id").GetString() });
        Check.True(read.GetProperty("complete").GetBoolean(), "lecture complète");
        var reconcile = read.GetProperty("reconcile");
        Check.True(reconcile.GetProperty("added").GetInt32() >= SimulatedSyncSeed.CensusGapsFound, "objets manquants de la base ajoutés");
        Check.Equal(SimulatedSyncSeed.PendingGhosts, reconcile.GetProperty("unseen").GetInt32(), "objets supprimés depuis : non revus");
        Check.True(reconcile.GetProperty("updated").GetInt32() > 0, "versions plus anciennes mises à jour");
        string[] phases = [.. bridge.Events.Where(e => e.Operation == "synchro.read.run:progress").Select(e => ((SyncProgress)e.Data!).Phase.ToString())];
        Check.True(phases.Contains("Reading") && phases[^1] == "Done", "progression poussée jusqu’à la fin");
        Check.Equal("error", (await bridge.CallAsync("synchro.read.run", Args(new { estimateId = estimate.GetProperty("id").GetString() }))).Kind, "une estimation ne sert qu’une fois");
        var same = await Ok(bridge, "synchro.overview", new { dn = Users });
        Check.Equal(before.GetProperty("generation").GetInt64(), same.GetProperty("generation").GetInt64(), "la lecture n’écrit rien");
        Check.Equal(read.GetProperty("batchId").GetString(), same.GetProperty("pending").GetProperty("batchId").GetString(), "lecture en attente d’enregistrement");
        var planned = await Ok(bridge, "synchro.store.plan", new { batchId = read.GetProperty("batchId").GetString() });
        var plan = planned.GetProperty("plan");
        Check.Equal(SyncStoreChange.Kind, plan.GetProperty("kind").GetString(), "type d’écriture");
        Check.Equal("database", plan.GetProperty("target").GetProperty("kind").GetString(), "cible : la base locale");
        Check.Equal(SyncStoreChange.BatchAttribute, plan.GetProperty("changes")[0].GetProperty("attribute").GetString(), "lot en tête");
        Check.False(plan.GetProperty("confirmation").GetProperty("typedNameRequired").GetBoolean(), "confirmation simple");
        var receipt = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(planned)));
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "écrit");
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "relu dans la base");
        Check.Equal("error", (await bridge.CallAsync("write.execute", Execute(planned))).Kind, "jamais rejoué");
        var after = await Ok(bridge, "synchro.overview", new { dn = Users });
        Check.True(after.GetProperty("generation").GetInt64() > before.GetProperty("generation").GetInt64(), "génération suivante");
        Check.Equal(JsonValueKind.Null, after.GetProperty("pending").ValueKind, "plus rien en attente");
        Check.Equal(read.GetProperty("batchId").GetString(), after.GetProperty("receipts")[0].GetProperty("batchId").GetString(), "reçu de stockage");
        Check.True(after.GetProperty("coverage").GetProperty("at").GetString()!.Length > 0, "couverture datée");
        var controls = await Ok(bridge, "synchro.controls");
        Check.True(controls.GetProperty("absences").GetProperty("rows").EnumerateArray().Count(r => r.GetProperty("status").GetString() == "notSeen" && r.GetProperty("scopeDn").GetString() == Users) == SimulatedSyncSeed.PendingGhosts,
            "objets non revus notés comme tels, jamais supprimés");
        Check.Equal(0, controls.GetProperty("gaps").GetProperty("rows").EnumerateArray().Count(g => g.GetProperty("dn").GetString()!.EndsWith(Users, StringComparison.OrdinalIgnoreCase)
            && !g.GetProperty("dn").GetString()!.Contains("Lille", StringComparison.Ordinal)), "les identités lues ne manquent plus");
        Check.True(bridge.Context.Journal.Snapshot().Any(e => e.Label.Contains("Lecture de l’annuaire", StringComparison.Ordinal)), "journal des opérations");
    }

    [Test]
    public static async Task A_plan_whose_read_was_replaced_sends_nothing()
    {
        var bridge = new SimulatedBridge();
        var first = await Ok(bridge, "synchro.read.estimate", new { target = "ou", dn = Users });
        var read = await Ok(bridge, "synchro.read.run", new { estimateId = first.GetProperty("id").GetString() });
        var planned = await Ok(bridge, "synchro.store.plan", new { batchId = read.GetProperty("batchId").GetString() });
        var second = await Ok(bridge, "synchro.read.estimate", new { target = "ou", dn = Postes });
        Check.True(second.GetProperty("warnings").EnumerateArray().Any(w => w.GetString()!.Contains("sera remplacée", StringComparison.Ordinal)), "remplacement annoncé");
        await Ok(bridge, "synchro.read.run", new { estimateId = second.GetProperty("id").GetString() });
        var refused = await bridge.CallAsync("write.execute", Execute(planned));
        Check.Equal("error", refused.Kind, "refusé");
        Check.Equal(WriteErrors.Stale, refused.Error!.Code, "préconditions changées : rien n’est écrit");
        Check.Equal(SyncErrors.BatchUnknown, await Error(bridge, "synchro.store.plan", new { batchId = read.GetProperty("batchId").GetString() }), "lot remplacé");
        Check.Equal("arguments.invalid", await Error(bridge, "synchro.store.plan", new { batchId = "court" }), "identifiant invalide");
        Check.Equal(SyncErrors.EstimateUnknown, await Error(bridge, "synchro.read.run", new { estimateId = new string('0', 32) }), "estimation inconnue");
    }

    [Test]
    public static async Task The_changes_of_the_domain_move_the_checkpoint_only_with_their_data()
    {
        var bridge = new SimulatedBridge();
        var before = await Ok(bridge, "synchro.overview", new { dn = Root });
        var estimate = await Ok(bridge, "synchro.read.estimate", new { target = "domain" });
        Check.Equal("incremental", estimate.GetProperty("mode").GetString(), "repère utilisable : incrémentiel");
        Check.True(estimate.GetProperty("expectedObjects").GetInt32() > 0, "objets modifiés depuis le repère");
        var read = await Ok(bridge, "synchro.read.run", new { estimateId = estimate.GetProperty("id").GetString() });
        Check.True(read.GetProperty("checkpointAdvances").GetBoolean(), "le repère avancera");
        Check.Equal(0, read.GetProperty("reconcile").GetProperty("unseen").GetInt32(), "une lecture différentielle ne déduit aucune absence");
        Check.True(read.GetProperty("notes").EnumerateArray().Any(n => n.GetString()!.Contains("jamais une suppression", StringComparison.Ordinal)), "absence ≠ suppression");
        var planned = await Ok(bridge, "synchro.store.plan", new { batchId = read.GetProperty("batchId").GetString() });
        Check.True(planned.GetProperty("plan").GetProperty("changes").EnumerateArray().Any(c => c.GetProperty("attribute").GetString() == "checkpoint"), "changement du repère dans le plan");
        SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(planned)));
        var after = await Ok(bridge, "synchro.overview", new { dn = Root });
        Check.Equal(read.GetProperty("highestUsn").GetInt64(), after.GetProperty("checkpoint").GetProperty("usn").GetInt64(), "repère avancé à l’USN lu");
        Check.True(after.GetProperty("checkpoint").GetProperty("usn").GetInt64() > before.GetProperty("checkpoint").GetProperty("usn").GetInt64(), "repère plus récent");
    }

    [Test]
    public static async Task A_stopped_read_stays_partial_and_never_moves_the_coverage()
    {
        var bridge = new SimulatedBridge(SimulationLatency.Realistic);
        var estimate = await Ok(bridge, "synchro.read.estimate", new { target = "ou", dn = Users });
        var running = bridge.CallAsync("synchro.read.run", Args(new { estimateId = estimate.GetProperty("id").GetString() }));
        string? runId = null;
        for (var i = 0; i < 200 && runId is null; i++)
        {
            await Task.Delay(25);
            runId = bridge.Events.Where(e => e.Operation == "synchro.read.run:progress").Select(e => ((SyncProgress)e.Data!).RunId).FirstOrDefault();
        }
        Check.NotNull(runId, "progression reçue");
        var stop = await Ok(bridge, "synchro.read.stop", new { runId });
        Check.True(stop.GetProperty("stopping").GetBoolean(), "arrêt demandé");
        var read = SimulatedBridge.Json(await running);
        Check.False(read.GetProperty("complete").GetBoolean(), "lecture partielle");
        Check.Equal("arret", read.GetProperty("cut").GetProperty("reason").GetString(), "motif de la coupure");
        Check.Equal(0, read.GetProperty("reconcile").GetProperty("unseen").GetInt32(), "aucune absence déduite");
        var again = await Ok(bridge, "synchro.read.stop", new { runId });
        Check.False(again.GetProperty("stopping").GetBoolean(), "plus de lecture en cours");
    }

    [Test]
    public static async Task Verifications_and_census_gaps_are_read_by_guid_then_stored()
    {
        var bridge = new SimulatedBridge();
        var check = await Ok(bridge, "synchro.absences.check");
        var statuses = check.GetProperty("rows").EnumerateArray().Select(r => r.GetProperty("status").GetString()).ToList();
        Check.True(statuses.Contains("deleted") && statuses.Contains("moved") && statuses.Contains("visible") && statuses.Contains("notFound"), "suppression prouvée, déplacement, retour, introuvable");
        Check.Equal("read", check.GetProperty("deletedProbe").GetString(), "objets supprimés lisibles");
        var planned = await Ok(bridge, "synchro.store.plan", new { batchId = check.GetProperty("batchId").GetString() });
        SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(planned)));
        var controls = await Ok(bridge, "synchro.controls");
        Check.Equal(0, controls.GetProperty("absences").GetProperty("pending").GetInt32(), "plus rien à vérifier");
        Check.Equal(SyncErrors.NothingToCheck, await Error(bridge, "synchro.absences.check"), "liste vérifiée");
        var desktop = controls.GetProperty("absences").GetProperty("rows").EnumerateArray().First(r => r.GetProperty("status").GetString() == "moved" && r.GetProperty("name").GetString()!.StartsWith("DESKTOP-", StringComparison.Ordinal));
        var found = await Ok(bridge, "synchro.index.search", new { text = desktop.GetProperty("name").GetString(), dn = Root });
        Check.Equal(1, found.GetProperty("total").GetInt32(), "objet retrouvé remis dans la base sous le même GUID");
        var gaps = await Ok(bridge, "synchro.gaps.read");
        Check.Equal(SimulatedSyncSeed.CensusGapsFound, gaps.GetProperty("added").GetInt32(), "identités retrouvées");
        Check.Equal(1, gaps.GetProperty("gone").GetInt32(), "identité disparue depuis : retirée sans conclusion");
        var plannedGaps = await Ok(bridge, "synchro.store.plan", new { batchId = gaps.GetProperty("batchId").GetString() });
        SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(plannedGaps)));
        var after = await Ok(bridge, "synchro.controls");
        Check.Equal(0, after.GetProperty("gaps").GetProperty("total").GetInt32(), "plus aucune identité manquante");
    }

    [Test]
    public static async Task Snapshots_are_captured_compared_and_deleted_in_the_base_only()
    {
        var bridge = new SimulatedBridge();
        var controls = await Ok(bridge, "synchro.controls");
        var rows = controls.GetProperty("snapshots").GetProperty("rows").EnumerateArray().ToList();
        Check.Equal(3, rows.Count, "relevés de la simulation");
        var postes = rows.Where(r => r.GetProperty("scopeDn").GetString() == Postes).OrderBy(r => r.GetProperty("capturedAt").GetString(), StringComparer.Ordinal).ToList();
        var report = await Ok(bridge, "synchro.snapshot.compare", new { before = postes[0].GetProperty("id").GetString(), after = postes[1].GetProperty("id").GetString() });
        Check.True(report.GetProperty("comparable").GetBoolean(), "même périmètre");
        var counts = report.GetProperty("counts");
        Check.True(counts.GetProperty("changed").GetInt32() >= 20, "migration Windows 10 → 11 visible");
        Check.True(counts.GetProperty("disappeared").GetInt32() > 0 && counts.GetProperty("moved").GetInt32() > 0, "disparitions et déplacements");
        var mixed = await Ok(bridge, "synchro.snapshot.compare", new { before = postes[0].GetProperty("id").GetString(), after = rows.First(r => r.GetProperty("scopeDn").GetString() == Root).GetProperty("id").GetString() });
        Check.False(mixed.GetProperty("comparable").GetBoolean(), "périmètres différents : refusé");
        Check.Equal(SyncErrors.SnapshotUnknown, await Error(bridge, "synchro.snapshot.compare", new { before = new string('1', 32), after = new string('2', 32) }), "relevé inconnu");
        var planned = await Ok(bridge, "synchro.snapshot.plan", new { label = "Avant migration" });
        Check.Equal("Relevés de l’annuaire", planned.GetProperty("plan").GetProperty("target").GetProperty("kindLabel").GetString(), "cible");
        SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(planned)));
        var after = await Ok(bridge, "synchro.controls");
        var taken = after.GetProperty("snapshots").GetProperty("rows").EnumerateArray().First(r => r.GetProperty("label").GetString() == "Avant migration");
        Check.True(taken.GetProperty("objectCount").GetInt32() > 400, "copie du périmètre");
        Check.Equal("complete", taken.GetProperty("coverageState").GetString(), "preuve de couverture");
        var delete = await Ok(bridge, "synchro.snapshot.delete.plan", new { id = taken.GetProperty("id").GetString() });
        Check.True(delete.GetProperty("plan").GetProperty("risks").EnumerateArray().Any(r => r.GetProperty("tone").GetString() == "alert"), "suppression définitive signalée");
        SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(delete)));
        Check.Equal(3, (await Ok(bridge, "synchro.controls")).GetProperty("snapshots").GetProperty("count").GetInt32(), "relevé supprimé");
        Check.Equal("arguments.invalid", await Error(bridge, "synchro.snapshot.plan", new { label = new string('x', 121) }), "nom trop long");
        var export = await Ok(bridge, "synchro.snapshot.export", new { before = postes[0].GetProperty("id").GetString(), after = postes[1].GetProperty("id").GetString() });
        Check.False(export.GetProperty("written").GetBoolean(), "tests : mémoire seulement");
    }

    [Test]
    public static async Task The_park_survey_merges_the_shared_file_and_can_be_forgotten()
    {
        var bridge = new SimulatedBridge();
        var park = await Ok(bridge, "synchro.park.state");
        var coverage = park.GetProperty("coverage");
        Check.True(coverage.GetProperty("surveyed").GetInt32() > 0, "postes relevés");
        Check.True(park.GetProperty("shared").GetProperty("configured").GetBoolean(), "partage configuré en simulation");
        var shared = await Ok(bridge, "synchro.park.shared.read");
        Check.True(shared.GetProperty("added").GetInt32() > 0 && shared.GetProperty("updated").GetInt32() > 0, "ajouts et relevés plus récents des autres consoles");
        var planned = await Ok(bridge, "synchro.store.plan", new { batchId = shared.GetProperty("batchId").GetString() });
        SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(planned)));
        var merged = await Ok(bridge, "synchro.park.state");
        Check.Equal(shared.GetProperty("total").GetInt32(), merged.GetProperty("rows").GetArrayLength(), "relevé fusionné");
        var reset = await Ok(bridge, "synchro.park.reset.plan");
        Check.True(reset.GetProperty("plan").GetProperty("reversibility").GetProperty("reversible").GetBoolean(), "point de retour : sauvegarde vérifiée");
        var receipt = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(reset)));
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "relevé relu : vide");
        Check.Equal(0, (await Ok(bridge, "synchro.park.state")).GetProperty("rows").GetArrayLength(), "état de balayage effacé");
        Check.Equal(SyncErrors.ParkEmpty, await Error(bridge, "synchro.park.reset.plan"), "rien à oublier");
    }

    [Test]
    public static async Task Directory_mode_has_no_reader_yet()
    {
        var decision = ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        var source = new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun");
        using var context = new EngineContext(decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(), ScreenReaders.Discover(source, [typeof(SimulatedDirectorySource).Assembly]));
        var registry = OperationModules.CreateRegistry(context, OperationModules.Discover([typeof(SyncOperations).Assembly]));
        var dispatcher = new BridgeDispatcher(registry, _ => { }, AdmissionGuards.ReadOnlyDirectory);
        Check.True(registry.TryGet("synchro.read.run", out var run) && run!.Class == OperationClass.NetworkRead, "lecture réseau en mode annuaire");
        Check.True(run!.ServedInSimulation, "servie par l’annuaire fictif");
        Check.True(registry.Names.Where(n => n.StartsWith("synchro.", StringComparison.Ordinal)).All(n => registry.TryGet(n, out var d) && d!.Class != OperationClass.Write), "aucune écriture directe : seulement des plans");
        _ = dispatcher;
    }
}
