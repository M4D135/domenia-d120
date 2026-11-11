using System.Text;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.Tests;

internal static class RuntimeConfigurationTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    internal static RuntimeConfiguration Config(string json) => RuntimeConfiguration.Read(Encoding.UTF8.GetBytes(json), "test");

    [Test]
    public static async Task The_composed_readers_and_report_use_one_bounded_immutable_configuration()
    {
        var configuration = Config("""{"UI":{"AllowExpertProfile":0},"Features":{"ColumnProfiles":false,"LocalAssistant":true,"Scheduler":false,"SecretSingleCopy":false},"Security":{"GeneratedPasswordLength":999,"AutoClearSecretClipboardSeconds":2,"SingleWriteChannel":false},"Remote":{"PortTimeoutMs":99999},"Index":{"FullRebuildDays":999,"BudgetMs":4321},"LocalStore":{"DatabaseBackupCount":4}}""");
        Check.False(configuration.Shell.ExpertAllowed, "restriction numérique D1 conservée dans la composition");
        Check.False(configuration.Shell.ColumnProfiles, "profil de colonnes désactivé réellement");
        Check.True(configuration.Shell.LocalAssistant, "aide locale explicitement activée");
        Check.True(configuration.Flag("Features", "Scheduler", false) && configuration.Flag("Features", "SecretSingleCopy", false)
            && configuration.Flag("Security", "SingleWriteChannel", false), "protections obligatoires non neutralisées par un vieux réglage");
        var source = new SimulatedDirectorySource(SimulationOptions.Default, TestClock.Fixed());
        using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(),
            ScreenReaders.Discover(source, [typeof(FicheSettingsFileReader).Assembly]), configuration: configuration);
        var fiche = await context.Readers.Require<IFicheSettingsReader>().ReadAsync(None);
        var poste = await context.Readers.Require<IPosteSettingsReader>().CurrentAsync(None);
        Check.Equal(configuration.Integer("Security", "GeneratedPasswordLength", 0), fiche.GeneratedPasswordLength, "rapport et vrai lecteur Fiche identiques");
        Check.Equal(64, fiche.GeneratedPasswordLength, "longueur bornée");
        Check.Equal(5, fiche.AutoClearSecretClipboardSeconds, "effacement borné");
        Check.Equal(configuration.Integer("Remote", "PortTimeoutMs", 0), poste.PortTimeoutMs, "rapport et vrai lecteur Poste identiques");
        Check.Equal(5000, poste.PortTimeoutMs, "borne native effective");
        Check.Equal(90, configuration.Sync.FullRebuildDays, "borne réelle index");
        Check.Equal(30000, configuration.Sync.BudgetMs, "minimum effectif exposé et consommé");
        Check.Equal(4, StoragePolicyRules.ForContext(context, out _).BackupKeep, "défaut administrateur des sauvegardes");
        await context.Preferences.SetAsync(StoragePolicyRules.PreferenceKey, JsonSerializer.SerializeToElement(new { presenceDays = 10 }), None);
        Check.Equal(4, StoragePolicyRules.ForContext(context, out _).BackupKeep, "préférence ancienne sans nombre de copies conserve le défaut administrateur");
        await context.Preferences.SetAsync(StoragePolicyRules.PreferenceKey, JsonSerializer.SerializeToElement(new { backupKeep = 9 }), None);
        Check.Equal(9, StoragePolicyRules.ForContext(context, out _).BackupKeep, "préférence opérateur explicite prioritaire");
    }

    [Test]
    public static async Task Deferred_storage_uses_the_startup_snapshot_and_never_silently_selects_a_base_from_invalid_settings()
    {
        using var folder = new TemporaryFolder(); var app = folder.File("app"); var profile = folder.File("profile");
        Directory.CreateDirectory(app);
        var config = Config("""{"LocalStore":{"Mode":"UserLocal","DatabaseFile":"chosen.db"}}""");
        var cache = new CompatibleDirectoryCache(app, profile, "example.local", TestClock.Fixed(), configuration: config);
        File.WriteAllText(Path.Combine(app, "Domenia.config.json"), """{"LocalStore":{"Mode":"Portable","DatabaseFile":"later.db"}}""");
        var database = await cache.DatabaseAsync(None);
        Check.True(database.Path.StartsWith(Path.Combine(profile, "Data") + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase), "mode du démarrage, pas la modification ultérieure");
        Check.Equal("chosen.db", Path.GetFileName(database.Path), "nom du même instantané que le rapport");
        Check.False(File.Exists(database.Path), "résolution sans création ni écriture");
        foreach (var invalid in new[] { "{", """{"LocalStore":{"Mode":"Unknown"}}""", """{"LocalStore":{"DatabaseFile":"../else.db"}}""" })
        {
            var refused = new CompatibleDirectoryCache(app, profile, "example.local", TestClock.Fixed(), configuration: Config(invalid));
            await Check.ThrowsAsync<InvalidDataException>(() => refused.DatabaseAsync(None), "aucun repli vers une base différente");
        }
    }

    [Test]
    public static void Invalid_documents_keep_safe_consistent_defaults_and_dependent_capacities_are_displayed_exactly()
    {
        var bad = Config("""{"Security":{"GeneratedPasswordLength":32},"security":{}}""");
        Check.Equal("invalid", bad.Report.FileState, "ambiguïté globale refusée");
        Check.Equal(16, FicheSecurityPolicy.From(bad.Fiche, AppMode.Directory).GeneratedPasswordLength, "pas de lecture partielle divergente");
        var bounded = Config("""{"Async":{"MaxThreads":2,"MaxQueued":900,"MaxOutstandingWorkers":100,"ReservedForeground":7,"WriteSoftTimeoutSeconds":500,"WriteHardTimeoutSeconds":30}}""");
        var timing = QueueTiming.From(bounded.Report);
        Check.Equal(2, timing.MaxThreads, "capacité demandée"); Check.Equal(32, timing.MaxQueued, "file bornée");
        Check.Equal(12, timing.MaxOutstanding, "plafond physique non relevable");
        Check.Equal(1, timing.ReservedForeground, "ne réserve pas toutes les places");
        Check.Equal(1, bounded.Integer("Async", "ReservedForeground", -1), "même valeur dans le rapport");
        Check.Equal(30, bounded.Integer("Async", "WriteSoftTimeoutSeconds", -1), "alerte douce jamais après la prolongée");
        Check.Equal(0, bounded.Integer("Security", "ReadOnlyReturnMinutes", -1), "pas de mode écriture persistant");
        Check.Equal(100, bounded.Integer("UserMachineLink", "MinimumConfidence", -1), "preuve obligatoire, aucun score heuristique autorisant une identité");
        var index = Config("""{"Index":{"MaxObjects":10000000,"BudgetMs":240000}}""");
        Check.Equal(300000, index.Integer("Index", "MaxObjects", -1), "rapport borné au plafond de collecte réel");
        Check.Equal(300000L, index.Sync.MaxObjects, "même plafond transmis au lecteur");
        Check.Equal(1200000, index.Sync.BudgetMs, "ancien budget converti comme dans le moteur");
        Check.Equal(index.Sync.BudgetMs, index.Integer("Index", "BudgetMs", -1), "rapport fidèle au budget effectif");
    }

    [Test]
    public static async Task Search_switches_and_default_limit_reach_the_real_operation_and_native_ldap_query()
    {
        var configuration = Config("""{"Features":{"SearchSyntax":false,"SearchRanking":false},"Browser":{"DefaultLimit":7,"SearchPageSize":37,"SearchServerTimeLimitSeconds":19},"Async":{"SearchTimeoutSeconds":44}}""");
        var bridge = new SimulatedBridge(configuration: configuration);
        var policy = SimulatedBridge.Json(await bridge.CallAsync("search.policy"));
        Check.False(policy.GetProperty("syntax").GetBoolean(), "analyse syntaxique désactivée");
        Check.False(policy.GetProperty("ranking").GetBoolean(), "classement optionnel désactivé");
        var result = SimulatedBridge.Json(await bridge.CallAsync("search.run", """{"text":"utilisateur: martin"}"""));
        Check.Equal(7, result.GetProperty("limit").GetInt32(), "limite réelle par défaut du pont");
        Check.Equal("default", result.GetProperty("plan").GetProperty("kind").GetString(), "préfixe non interprété comme syntaxe avancée");
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        var clock = TestClock.Fixed();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", clock, connection: ldap);
        using var context = new EngineContext(ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "test.local")),
            source, new MemoryPreferenceStore(), clock, new RecordingJournal(), configuration: configuration);
        _ = await new AdSearchReader(source).FindAsync(new(SearchListKind.Search, SearchText.Plan("poste*", SearchTypeFilter.Computers, SearchMatchMode.Prefix),
            SearchTypeFilter.Computers, Fixtures.Postes, true, null, null, new HashSet<string>(), 10), None);
        Check.True(ldap.Searches.Any(q => q.SortAttribute == "name"), "vrai lecteur passé par le transport scripté");
        Check.True(ldap.Searches.Where(q => q.SortAttribute == "name").All(q => q.PageSize == 37 && q.Timeout == TimeSpan.FromSeconds(19)
            && q.Budget == TimeSpan.FromSeconds(900)), "pages et délai serveur configurés ; progression totale conservée");
    }

    [Test]
    public static async Task Configured_capacity_queue_and_idle_policy_reach_actual_admission_without_releasing_active_work()
    {
        var configuration = Config("""{"Async":{"MaxThreads":1,"MaxQueued":0},"Features":{"IdlePolicy":true}}""");
        var bridge = new SimulatedBridge(configuration: configuration);
        var activity = OperationActivity.From(bridge.Context);
        using var admission = new BridgeAdmission(bridge.Clock, _ => Task.FromResult(new BridgeSessionStamp("settings", "site")), QueueTiming.From(configuration.Report), activity);
        var read = new OperationDefinition("test.read", OperationClass.NetworkRead, (_, _, _) => Task.FromResult<object?>(null), "Lecture")
        { Scheduling = new(OperationPriority.Explicit, OperationProvider.Directory, []) };
        var empty = JsonSerializer.SerializeToElement(new { });
        using var held = await admission.EnterAsync("one", read, empty, None, () => { });
        var refused = await Check.ThrowsAsync<BridgeOperationException>(() => admission.EnterAsync("two", read, empty, None, () => { }), "deuxième lecture refusée sans file");
        Check.Equal("operation.queueFull", refused.Code, "borne configurée appliquée"); Check.Equal(1, admission.Load.Network, "lecture active toujours occupée");
        held.Dispose(); activity.SetWindowActivity(false, false);
        var background = read with { Scheduling = new(OperationPriority.Background, OperationProvider.Directory, []) };
        _ = await Check.ThrowsAsync<BridgeOperationException>(() => admission.EnterAsync("background", background, empty, None, () => { }), "fond inactif sans file");
        using var foreground = await admission.EnterAsync("explicit", read, empty, None, () => { });
        Check.Equal(1, admission.Load.Network, "geste explicite autorisé même fenêtre inactive");
        var off = new SimulatedBridge(configuration: Config("""{"Features":{"IdlePolicy":false}}"""));
        OperationActivity.From(off.Context).SetWindowActivity(false, false);
        Check.True(OperationActivity.From(off.Context).BackgroundAllowed, "désactivation réelle de la politique, sans modifier les autres quotas");
    }

    [Test]
    public static async Task Configured_read_deadline_requests_cancellation_but_keeps_admission_until_the_real_return()
    {
        var clock = new RuntimeSecurityPolicyTests.Clock();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var responses = new System.Collections.Concurrent.ConcurrentQueue<BridgeResponse>();
        var definition = new OperationDefinition("fiche.read", OperationClass.NetworkRead, async (_, _, token) =>
        {
            using var observe = token.Register(() => cancelled.TrySetResult());
            entered.TrySetResult(); await release.Task;
            token.ThrowIfCancellationRequested(); return null;
        }, "Lecture de test") { Scheduling = new(OperationPriority.Explicit, OperationProvider.Directory, []) };
        var registry = new OperationRegistry([definition], clock, _ => Task.FromResult(new BridgeSessionStamp("account", "source")),
            queueTiming: QueueTiming.From(Config("""{"Async":{"ObjectTimeoutSeconds":5}}""").Report));
        using var dispatcher = new BridgeDispatcher(registry, responses.Enqueue);
        var request = dispatcher.HandleAsync("""{"id":"deadline","op":"fiche.read","args":{}}""", None);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5)); clock.Advance(TimeSpan.FromSeconds(5));
            await cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check.False(request.IsCompleted, "l’annulation demandée ne prétend pas que le fournisseur est sorti");
            Check.Equal(1, dispatcher.AdmissionLoad.Network, "place toujours occupée pendant nettoyage réel");
            Check.False(responses.Any(r => r.Kind is "result" or "error"), "aucune issue finale prématurée");
        }
        finally { release.TrySetResult(); }
        await request.WaitAsync(TimeSpan.FromSeconds(5));
        Check.Equal("network.timeout", responses.Single(r => r.Error is not null).Error!.Code, "délai distinct d’un refus du compte");
        Check.Equal(0, dispatcher.AdmissionLoad.Network, "place libérée seulement après retour réel");
    }

    [Test]
    public static async Task Self_bounded_workstation_read_is_not_cut_by_the_remote_delay_before_its_own_budget()
    {
        // Bench of 11/11/2026: the 45 s remote delay stopped a 55 s quick inventory at its drivers and discarded its partial result.
        var clock = new RuntimeSecurityPolicyTests.Clock();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var responses = new System.Collections.Concurrent.ConcurrentQueue<BridgeResponse>();
        var definition = new OperationDefinition("poste.inventory", OperationClass.NetworkRead, async (_, _, token) =>
        {
            using var observe = token.Register(() => cancelled.TrySetResult());
            entered.TrySetResult(); await release.Task;
            token.ThrowIfCancellationRequested(); return null;
        }, "Inventaire de test") { Scheduling = new(OperationPriority.Explicit, OperationProvider.Directory, []), OwnBudget = TimeSpan.FromSeconds(55) };
        var registry = new OperationRegistry([definition], clock, _ => Task.FromResult(new BridgeSessionStamp("account", "source")),
            queueTiming: QueueTiming.From(Config("""{"Async":{"RemoteTimeoutSeconds":45}}""").Report));
        using var dispatcher = new BridgeDispatcher(registry, responses.Enqueue);
        var request = dispatcher.HandleAsync("""{"id":"inventory","op":"poste.inventory","args":{}}""", None);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            clock.Advance(TimeSpan.FromSeconds(45));
            Check.False(cancelled.Task.IsCompleted, "le délai distant configuré ne coupe pas une lecture bornée par son propre budget");
            clock.Advance(TimeSpan.FromSeconds(55) + BridgeDispatcher.OwnBudgetMargin - TimeSpan.FromSeconds(45) - TimeSpan.FromSeconds(1));
            Check.False(cancelled.Task.IsCompleted, "le lecteur garde son budget et le temps de consigner son résultat partiel");
            clock.Advance(TimeSpan.FromSeconds(1));
            await cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally { release.TrySetResult(); }
        await request.WaitAsync(TimeSpan.FromSeconds(5));
        Check.Equal("network.timeout", responses.Single(r => r.Error is not null).Error!.Code, "filet de sécurité conservé au-delà du budget propre");
    }

    [Test]
    public static void Workstation_reads_declare_at_least_the_budget_their_reader_applies()
    {
        var bridge = new SimulatedBridge();
        var operations = new PosteOperations().CreateOperations(bridge.Context).ToDictionary(o => o.Name, StringComparer.Ordinal);
        TimeSpan Own(string name) => operations[name].OwnBudget ?? TimeSpan.Zero;
        Check.True(Own("poste.inventory") >= Domenia.Inventory.CimBudgets.FullInventory, "inventaire complet : 150 s");
        Check.True(Own("poste.software") >= Domenia.Inventory.CimBudgets.SoftwareWithProfiles, "logiciels avec profils : 200 s");
        Check.True(Own("poste.services") >= Domenia.Inventory.CimBudgets.Services, "services : 90 s");
        Check.True(Own("poste.diagnostic") >= Domenia.Inventory.WmiWorkstationReader.Budget(Domenia.Inventory.WorkstationReading.Diagnostic), "diagnostic : 45 s");
        Check.True(Own("poste.probes.collect") >= Domenia.Inventory.CimBudgets.ProbesFor(int.MaxValue), "toutes les sondes : 300 s");
        var remote = QueueTiming.Default.RemoteSeconds;
        foreach (var (name, budget) in new[] { ("poste.processes", Domenia.Inventory.CimBudgets.Processes), ("poste.events", Domenia.Inventory.CimBudgets.Events),
            ("poste.quickDiag", Domenia.Inventory.CimBudgets.QuickDiagnostic), ("poste.lastUser.detect", Domenia.Inventory.CimBudgets.LastUser) })
        {
            Check.True(operations[name].OwnBudget is not null || budget + Domenia.Inventory.CimBudgets.GiveUpMargin < TimeSpan.FromSeconds(remote),
                name + " tient dans le délai distant par défaut");
        }
    }

    [Test]
    public static void Read_trace_switch_only_adds_bounded_provider_details_and_never_removes_the_final_summary()
    {
        foreach (var enabled in new[] { false, true })
        {
            var log = new RecordingJournal(); var clock = TestClock.Fixed();
            var source = new SimulatedDirectorySource(SimulationOptions.Default, clock);
            using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock, log,
                configuration: Config(enabled ? """{"Features":{"ReadTrace":true}}""" : """{"Features":{"ReadTrace":false}}"""));
            var activity = OperationActivity.From(context);
            using (var request = activity.BeginRequest("search.run") ?? throw new TestFailureException("Trace indisponible"))
            {
                using (request.BeginJob(RequestJobKind.Directory)) { }
                request.Outcome(TaskOutcome.Succeeded);
            }
            Check.Equal(enabled ? 1 : 0, log.Lines.Count(x => x.Contains("début fournisseur", StringComparison.Ordinal)), "détail optionnel réellement contrôlé");
            Check.Equal(1, log.Lines.Count(x => x.StartsWith("TRACE Requête [", StringComparison.Ordinal)), "synthèse finale toujours unique");
        }
    }

    [Test]
    public static async Task Cache_durations_and_capacity_bound_actual_fiche_visits_without_erasing_the_source()
    {
        var bridge = new SimulatedBridge(configuration: Config("""{"Cache":{"ObjectTtlSeconds":1,"MaxEntries":10}}"""));
        var session = FicheSession.From(bridge.Context);
        var reader = bridge.Context.Readers.Require<IFicheReader>();
        var users = bridge.Source.CurrentDirectory.Users.Take(11).ToArray();
        foreach (var user in users) session.KeepRead(await reader.ReadAsync(user.DistinguishedName, None));
        Check.Equal(10, session.RetainedObjects, "borne opérante sur toutes les familles de visite");
        Check.Null(session.LastRead(users[0].DistinguishedName), "plus ancienne visite évincée");
        Check.NotNull(session.LastRead(users[^1].DistinguishedName), "dernière visite disponible");
        bridge.Clock.Advance(TimeSpan.FromSeconds(1));
        Check.Null(session.LastRead(users[^1].DistinguishedName), "durée effective consommée par FicheSession");
        Check.NotNull(await reader.PreviewAsync(users[^1].DistinguishedName, None), "projection source conservée malgré expiration de l’accélération");
        var disabled = new SimulatedBridge(configuration: Config("""{"Cache":{"ObjectTtlSeconds":0}}"""));
        var read = await disabled.Context.Readers.Require<IFicheReader>().ReadAsync(disabled.Source.CurrentDirectory.Users[0].DistinguishedName, None);
        FicheSession.From(disabled.Context).KeepRead(read);
        Check.Null(FicheSession.From(disabled.Context).LastRead(read.Entry.Dn), "TTL zéro désactive réellement la réutilisation");
    }
}
