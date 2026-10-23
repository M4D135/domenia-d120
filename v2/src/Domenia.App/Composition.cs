using System.Collections.Immutable;
using System.Reflection;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.Core;
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
internal sealed class Composition : IDisposable
{
    private readonly EngineContext context;
    private int disposed;

    private Composition(EngineContext context, OperationRegistry registry)
    {
        this.context = context;
        Registry = registry;
        Admission = AdmissionGuards.For(context.Mode);
    }

    public ModeDecision Decision => context.Decision;

    public OperationRegistry Registry { get; }

    public Func<OperationDefinition, BridgeError?> Admission { get; }

    public string WindowTitle => Decision.Mode == AppMode.Simulation ? ProductInfo.Name + ModeTexts.WindowTitleSuffix : ProductInfo.Name;

    /// <param name="capture">Capture mode: preferences in memory only, so the images never depend on (nor change) the
    /// operator's preferences.</param>
    /// <param name="e2e">E2E mode (docs/E2E.md): preferences in memory only as well, so every scenario starts from the
    /// defaults and a stopped run never leaves a widget switched off for the operator.</param>
    public static Composition Create(ModeDecision decision, bool capture, bool e2e = false)
    {
        ArgumentNullException.ThrowIfNull(decision);
        var log = AppTechnicalJournal.Instance;
        IDirectorySource source = decision.Mode == AppMode.Simulation
            ? new SimulatedDirectorySource(SimulationOptions.Default, TimeProvider.System)
            : new AdDirectorySource(decision.JoinedDomain, static () => Environment.UserDomainName + "\\" + Environment.UserName, TimeProvider.System, new WmiWorkstationProbe(TimeProvider.System, log), localStore: decision.JoinedDomain is { Length: > 0 } joined && AppPaths.UserData is { } data ? new CompatibleDirectoryCache(AppPaths.AppDirectory, data, joined, TimeProvider.System, capture || e2e) : null);
        var assemblies = OperationModules.LoadDomeniaAssemblies();
        var context = new EngineContext(decision, source, CreatePreferences(decision.Mode, capture, e2e, log), TimeProvider.System, log, ScreenReaders.Discover(source, assemblies),
            writers: WriteExecutors.Discover(source, assemblies), receipts: CreateReceipts(decision.Mode, capture || e2e, log),
            documents: CreateDocuments(decision.Mode, capture || e2e, log));
        try
        {
            var modules = OperationModules.Discover(assemblies);
            var registry = OperationModules.CreateRegistry(context, modules);
            log.Info($"Composition : {modules.Length} modules, {registry.Names.Count} opérations, lecteurs d’écran [{string.Join(", ", context.Readers.Interfaces)}], écritures [{string.Join(", ", context.Writers.Kinds)}], assemblages [{Describe(assemblies)}].");
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

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) { return; }
        if (context.Readers.Find<IOperationsReader>() is IOperationsStatisticsWriter statistics)
        {
            // Keep the context alive until the local persistence call actually ends.
            using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            try
            {
                Task.Run(() => statistics.PersistStatisticsAsync(stop.Token)).GetAwaiter().GetResult();
            }
#pragma warning disable CA1031 // Closing must preserve the diagnostic and still release engine resources.
            catch (Exception ex)
#pragma warning restore CA1031
            {
                AppTechnicalJournal.Instance.Error("Statistiques de session non sauvegardées à la fermeture ; consultez le journal des opérations.", ex);
            }
        }
        context.Dispose();
        (context.Directory as IDisposable)?.Dispose();
        (context.Preferences as IDisposable)?.Dispose();
        (context.Receipts as IDisposable)?.Dispose();
    }

    /// <summary>
    /// Durable write receipts of the mode (docs/WRITES.md § 4). Capture and E2E modes keep them in memory only: the images and
    /// the scenarios never depend on (nor add to) the operator's receipts.
    /// </summary>
    private static IReceiptStore CreateReceipts(AppMode mode, bool memoryOnly, ITechnicalJournal log)
    {
        if (memoryOnly)
        {
            log.Info("Reçus d’écriture en mémoire seulement (capture ou E2E) : ceux de l’opérateur ne sont ni lus ni modifiés.");
            return new MemoryReceiptStore();
        }
        if (AppPaths.Receipts(mode) is not string path)
        {
            log.Warning("Dossier de données introuvable : reçus d’écriture en mémoire pour cette session.");
            return new MemoryReceiptStore();
        }
        return new FileReceiptStore(path, log);
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
        return new FileDocumentStore(folder, log);
    }

    private static IPreferenceStore CreatePreferences(AppMode mode, bool capture, bool e2e, ITechnicalJournal log)
    {
        if (capture || e2e)
        {
            log.Info($"Préférences en mémoire seulement (mode {(capture ? "capture" : "E2E")}) : celles de l’opérateur ne sont ni lues ni modifiées.");
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
