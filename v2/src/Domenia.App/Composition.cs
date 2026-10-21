using System.Collections.Immutable;
using System.Reflection;
using Domenia.Bridge;
using Domenia.Core;
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
    public static Composition Create(ModeDecision decision, bool capture)
    {
        ArgumentNullException.ThrowIfNull(decision);
        var log = AppTechnicalJournal.Instance;
        IDirectorySource source = decision.Mode == AppMode.Simulation
            ? new SimulatedDirectorySource(SimulationOptions.Default, TimeProvider.System)
            : new UnavailableDirectorySource(decision.JoinedDomain, static () => Environment.UserDomainName + "\\" + Environment.UserName);
        var assemblies = OperationModules.LoadDomeniaAssemblies();
        var context = new EngineContext(decision, source, CreatePreferences(decision.Mode, capture, log), TimeProvider.System, log, ScreenReaders.Discover(source, assemblies));
        try
        {
            var modules = OperationModules.Discover(assemblies);
            var registry = OperationModules.CreateRegistry(context, modules);
            log.Info($"Composition : {modules.Length} modules, {registry.Names.Count} opérations, lecteurs d’écran [{string.Join(", ", context.Readers.Interfaces)}], assemblages [{Describe(assemblies)}].");
            return new Composition(context, registry);
        }
        catch
        {
            context.Dispose();
            (context.Preferences as IDisposable)?.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        context.Dispose();
        (context.Preferences as IDisposable)?.Dispose();
    }

    private static IPreferenceStore CreatePreferences(AppMode mode, bool capture, ITechnicalJournal log)
    {
        if (capture)
        {
            log.Info("Préférences en mémoire seulement (mode capture) : celles de l’opérateur ne sont ni lues ni modifiées.");
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
