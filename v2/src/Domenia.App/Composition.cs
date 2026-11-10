using System.Collections.Immutable;
using System.Reflection;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.App;

/// <summary>
/// Wiring of the engine for the chosen mode (docs/PLATFORM.md). Operation modules and screen readers are found by
/// reflection on the Domenia assemblies: adding a screen never edits this file. Nothing heavy happens here: the simulated
/// world is generated on first use, off the UI thread, the preferences are read at their first use, and the directory mode
/// reads nothing until Domenia.Ad is wired.
/// </summary>
internal sealed partial class Composition : IDisposable
{
    private readonly EngineContext context;
    private int disposed;
    internal StartupDisplayOptions StartupDisplay => StartupDisplayOptions.Read(Settings.ConfigurationHostSnapshot.From(context).Report);

    private Composition(EngineContext context, OperationRegistry registry)
    {
        this.context = context;
        Registry = registry;
        Admission = AdmissionGuards.For(context.Mode);
    }

    public ModeDecision Decision => context.Decision;

    public OperationRegistry Registry { get; }
    public WriteCircuit Writes => WriteCircuit.From(context);
    public Task SuspendSensitiveWindowsAsync(CancellationToken token) => context.Readers.Find<IPosteSecretWindow>() is Poste.PosteHostServices host
        ? host.SuspendForTransitionAsync(token) : Task.CompletedTask;

    public OperationActivity Activity => OperationActivity.From(context);
    public PackageUpdateHost Updates => context.Shared(static c => new PackageUpdateHost(c));
    public DemoSessionHost Demonstration => context.Shared(static c => new DemoSessionHost(c.Mode));
    public IPosteTaskReadJournalReader? PosteTaskJournal => context.Readers.Find<IPosteTaskReadJournalReader>();

    public Func<OperationDefinition, BridgeError?> Admission { get; }

    public string WindowTitle => ProductInfo.Name + " " + ProductInfo.DisplayVersion + (Decision.Mode == AppMode.Simulation ? ModeTexts.WindowTitleSuffix : "");

    /// <param name="capture">Capture mode: preferences in memory only, so the images never depend on (nor change) the
    /// operator's preferences.</param>
    /// <param name="e2e">E2E mode (docs/E2E.md): preferences in memory only as well, so every scenario starts from the
    /// defaults and a stopped run never leaves a widget switched off for the operator.</param>
    public static Composition Create(ModeDecision decision, bool capture, bool e2e = false, LaunchOptions? launch = null, Action<string>? startupPhase = null)
    {
        ArgumentNullException.ThrowIfNull(decision);
        using var measurement = StartupTrace.Clock.Measure(StartupPhase.Composition);
        var log = AppTechnicalJournal.Instance;
        var clock = DemoSessionProcess.Active ? DemoSessionProcess.Clock : TimeProvider.System;
        ImmutableArray<Assembly> assemblies;
        startupPhase?.Invoke("Vérification des bibliothèques chargées…");
        using (StartupTrace.Clock.Measure(StartupPhase.LibraryIdentity)) assemblies = OperationModules.LoadDomeniaAssemblies();
        RuntimeModulePlan modulePlan;
        startupPhase?.Invoke("Vérification du plan des modules…");
        using (StartupTrace.Clock.Measure(StartupPhase.ModulePlan)) modulePlan = StartupPreflight.PrepareModules(assemblies, requireFullProduct: true);
        CompiledOperationContracts.RequireAssemblies(assemblies);
        var configuration = decision.Mode == AppMode.Simulation ? RuntimeConfiguration.Default
            : Settings.ConfigurationHostSnapshot.ReadRuntime(AppPaths.AppDirectory, log);
        startupPhase?.Invoke("Préparation de la source et de la base locale…");
        IDirectorySource source;
        using (StartupTrace.Clock.Measure(StartupPhase.LocalSource)) source = decision.Mode == AppMode.Simulation
            ? new SimulatedDirectorySource(SimulationOptions.Default with { UseReservedDomain = DemoSessionProcess.Active }, clock)
            : new AdDirectorySource(decision.JoinedDomain, static () => Environment.UserDomainName + "\\" + Environment.UserName, TimeProvider.System, new WmiWorkstationProbe(TimeProvider.System, log), connection: AdConnectionFactory.Create(new AdConnectionOptions(launch?.Server, decision.JoinedDomain)), localStore: decision.JoinedDomain is { Length: > 0 } joined && AppPaths.UserData is { } data ? new CompatibleDirectoryCache(AppPaths.AppDirectory, data, joined, TimeProvider.System, capture || e2e, configuration) : null);
        IPreferenceStore preferences;
        startupPhase?.Invoke("Lecture des préférences locales…");
        using (StartupTrace.Clock.Measure(StartupPhase.Preferences)) preferences = CreatePreferences(decision.Mode, capture, e2e, log);
        ScreenReaders readers;
        startupPhase?.Invoke("Préparation des lecteurs…");
        using (StartupTrace.Clock.Measure(StartupPhase.Readers)) readers = ScreenReaders.Discover(source, assemblies);
        var context = new EngineContext(decision, source, preferences, clock, log, readers,
            writers: WriteExecutors.Discover(source, assemblies), receipts: CreateReceipts(decision.Mode, capture || e2e || DemoSessionProcess.Active, log),
            documents: CreateDocuments(decision.Mode, capture || e2e, log), launch: launch,
            configuration: configuration);
        try
        {
            // Before screen modules restore preferences: only a genuinely absent directory profile may receive the seed automatically.
            startupPhase?.Invoke("Vérification de la configuration locale…");
            using (StartupTrace.Clock.Measure(StartupPhase.Configuration)) ConfigurationSeedHost.From(context).InitializeAsync(CancellationToken.None).GetAwaiter().GetResult();
            var activity = OperationActivity.From(context);
            activity.ConfigureSqliteTimeout(ConfigurationRules.Integer(Settings.ConfigurationHostSnapshot.From(context).Report, "LocalStore", "DatabaseBusyTimeoutMs", 2500));
            if (source is AdDirectorySource { LocalStore: CompatibleDirectoryCache localCache })
            {
                localCache.ConfigureSession(activity);
                if (preferences is IConfigurationPreferenceStore backupPreferences) localCache.ConfigureBackupPreferences(backupPreferences);
                localCache.ConfigureBackupTimeout(ConfigurationRules.Integer(Settings.ConfigurationHostSnapshot.From(context).Report, "LocalStore", "BackupTimeoutSeconds", 30));
            }
            startupPhase?.Invoke("Vérification des reçus locaux, sans reprise de commande…");
            WriteCircuit.From(context).RecoverAsync(CancellationToken.None).GetAwaiter().GetResult();
            OperationRegistry registry;
            startupPhase?.Invoke("Préparation des opérations…");
            using (StartupTrace.Clock.Measure(StartupPhase.Registry)) registry = modulePlan.CreateRegistry(context,
                Settings.ConfigurationHostSnapshot.From(context).QueueTiming);
            log.Info($"Composition : {modulePlan.Ordered.Length} modules validés, {registry.Names.Count} opérations, lecteurs d’écran [{string.Join(", ", context.Readers.Interfaces)}], écritures [{string.Join(", ", context.Writers.Kinds)}], assemblages [{Describe(assemblies)}].");
            return new Composition(context, registry);
        }
        catch
        {
            context.Dispose();
            (context.Directory as IDisposable)?.Dispose();
            (context.Preferences as IDisposable)?.Dispose();
            (context.Receipts as IDisposable)?.Dispose();
            throw;
        }
    }

    private readonly Lock shutdownGate = new();
    private HostShutdown? shutdown;
    private Task? shutdownCompletion;

    internal void SetWindowActivity(bool visible, bool active) => OperationActivity.From(context).SetWindowActivity(visible, active);

    public bool ExpertReport => Settings.ConfigurationHostSnapshot.From(context).Report.AllowExpertProfile
        && context.Preferences.TryGet(ShellInterfaceRules.InterfaceKey, out var iface)
        && iface.ValueKind == System.Text.Json.JsonValueKind.Object && iface.TryGetProperty("profile", out var profile)
        && profile.ValueKind == System.Text.Json.JsonValueKind.String && profile.GetString() == "expert";

    public void BeginHostClose(IEnumerable<Task> pending, Func<Task> cancel, Action releaseCaller)
    {
        lock (shutdownGate)
        {
            if (shutdownCompletion is not null) return;
            HostIncidentReport.Closing();
            shutdown = new(HostShutdown.DrainBudget);
            var handlers = pending.ToArray();
            var lifetime = shutdown;
            shutdownCompletion = HostShutdown.FinishAsync(
                () => Task.WhenAll(Task.Run(cancel), Task.Run(() => context.Existing<Domenia.Core.Accueil.AccueilService>()?.StopForHost()),
                    Task.Run(BeginAccessClose),
                    Task.Run(() => context.Readers.Find<IOperationsReader>() is AdOperationsReader native ? native.StopForHostAsync() : Task.CompletedTask)),
                handlers, PhysicalWorkBudget.WaitForIdleAsync,
                async () =>
                {
                    if (context.Readers.Find<IOperationsReader>() is not IOperationsStatisticsWriter statistics) return;
                    var remaining = lifetime.Remaining;
                    if (remaining <= TimeSpan.Zero)
                    {
                        TechnicalLog.Warning("Fermeture : statistiques finales non ajoutées après le délai ; les relevés et mesures déjà enregistrés restent conservés.");
                        return;
                    }
                    using var stop = new CancellationTokenSource(remaining);
                    await statistics.PersistStatisticsAsync(stop.Token).ConfigureAwait(false);
                },
                () =>
                {
                    Release(context);
                    Release(context.Directory as IDisposable);
                    Release(context.Preferences as IDisposable);
                    Release(context.Receipts as IDisposable);
                    releaseCaller();
                }, ShutdownFailure);
        }
    }

    private static void Release(IDisposable? value)
    {
        try { value?.Dispose(); }
        catch (Exception error) { ShutdownFailure(error); }
    }

    private static void ShutdownFailure(Exception error)
    {
#pragma warning disable CA1031 // A broken log must not skip the remaining resource releases.
        try { TechnicalLog.Error("Fermeture : une finalisation n’est pas confirmée ; les derniers reçus durables restent la référence.", error); }
        catch (Exception) { System.Diagnostics.Trace.WriteLine("Domenia : diagnostic de fermeture indisponible."); }
#pragma warning restore CA1031
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        BeginHostClose([], () => Task.CompletedTask, () => { });
        if (!shutdown!.Wait(shutdownCompletion!, ShutdownFailure))
        {
            var native = PhysicalWorkBudget.Snapshot().Outstanding;
            TechnicalLog.Warning("Fermeture : délai commun de 3 s atteint ; des travaux ou enregistrements restent en cours (" + native
                + " appels physiques). Leur arrêt n’est pas confirmé et leurs ressources restent détenues jusqu’à leur fin réelle. "
                + "Les mesures validées sont conservées ; reprise du relevé dans Opérations, campagne dans Accueil, après confirmation.");
        }
    }

    /// <summary>
    /// Durable receipts in directory mode, including isolated E2E journals. Only simulation may keep them in memory.
    /// </summary>
    private static IReceiptStore CreateReceipts(AppMode mode, bool memoryOnly, ITechnicalJournal log)
    {
        return ReceiptStorePolicy.Create(mode, memoryOnly, AppPaths.UserData, log);
    }

    /// <summary>
    /// Documents of the operator (docs/PLATFORM.md § 3.3): Exports or Exports-simulation under the user data folder. Capture and
    /// E2E modes write nothing: their images and scenarios never add a file to the operator's folder.
    /// </summary>
    private static IDocumentStore CreateDocuments(AppMode mode, bool memoryOnly, ITechnicalJournal log)
    {
        if (memoryOnly)
        {
            log.Info("Documents en mémoire seulement (capture ou E2E) : rien n’est écrit dans le dossier des exports.");
            return new MemoryDocumentStore();
        }
        if (AppPaths.Exports(mode) is not string folder)
        {
            log.Warning("Dossier de données introuvable : documents en mémoire pour cette session.");
            return new MemoryDocumentStore();
        }
        var store = new FileDocumentStore(folder, log);
        return DemoSessionProcess.Active ? new DemonstrationDocumentStore(store) : store;
    }

    private static IPreferenceStore CreatePreferences(AppMode mode, bool capture, bool e2e, ITechnicalJournal log)
    {
        if (capture || e2e || DemoSessionProcess.Active)
        {
            log.Info($"Préférences en mémoire seulement (mode {(capture ? "capture" : e2e ? "E2E" : "démonstration")}) : celles de l’opérateur ne sont ni lues ni modifiées.");
            return new MemoryPreferenceStore();
        }
        if (AppPaths.Preferences(mode) is not string path)
        {
            log.Warning("Dossier de données introuvable : préférences en mémoire pour cette session.");
            return new MemoryPreferenceStore();
        }
        return new FilePreferenceStore(path, log);
    }

    private static string Describe(ImmutableArray<Assembly> assemblies) =>
        string.Join(", ", assemblies.Select(a => a.GetName().Name));
}
