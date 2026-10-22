using System.Reflection;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

// Probe types for the discovery tests. Public ones are found, the others never are; their screen (« probe ») is used
// by no real module.

/// <summary>Found by discovery: public, non-abstract, parameterless constructor.</summary>
public sealed class ProbeModule : IOperationModule
{
    public string Screen => "probe";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
        [new OperationDefinition("probe.echo", OperationClass.Local, (_, _, _) => Task.FromResult<object?>(context.Mode.ToString()), "sonde")];
}

/// <summary>Never found: no parameterless constructor.</summary>
public sealed class ProbeModuleWithArguments(string screen) : IOperationModule
{
    public string Screen => screen;

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) => [];
}

/// <summary>Never found: abstract.</summary>
public abstract class ProbeModuleBase : IOperationModule
{
    public string Screen => "probe";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) => [];
}

/// <summary>Read interface of a probe screen.</summary>
public interface IProbeReader : IScreenReader
{
    string Name { get; }
}

/// <summary>Source type used only by the probe readers below, so they never match a real source.</summary>
public sealed class ProbeSource : IDirectorySource
{
    public DirectorySourceKind Kind => DirectorySourceKind.Simulation;

    public Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken) => throw new NotSupportedException();

    public Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken) => throw new NotSupportedException();

    public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken cancellationToken) => throw new NotSupportedException();
}

/// <summary>Probe reader for <see cref="ProbeSource"/>.</summary>
public sealed class ProbeReader(ProbeSource source) : IProbeReader
{
    public string Name => source.Kind.ToString();
}

/// <summary>Internal module and reader: never found (public types only).</summary>
internal sealed class HiddenProbeModule : IOperationModule
{
    public string Screen => "hidden";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) => [];
}

internal sealed class OutsideScreenModule : IOperationModule
{
    public string Screen => "probe";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
        [new OperationDefinition("other.echo", OperationClass.Local, (_, _, _) => Task.FromResult<object?>(null), "hors écran")];
}

internal sealed class InvalidScreenModule : IOperationModule
{
    public string Screen => "Probe.Screen";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) => [];
}

internal sealed class DuplicateModule : IOperationModule
{
    public string Screen => "probe";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
        [new OperationDefinition("probe.echo", OperationClass.Local, (_, _, _) => Task.FromResult<object?>(null), "doublon")];
}

internal static class PlatformTests
{
    private static readonly Assembly BridgeAssembly = typeof(DashboardOperations).Assembly;
    private static readonly Assembly SimulationAssembly = typeof(SimulatedDirectorySource).Assembly;

    private static readonly (string Name, OperationClass Class)[] SimulationOperations =
    [
        ("accounts.unlock.plan", OperationClass.LocalRead),
        ("dashboard.summary", OperationClass.LocalRead),
        ("dashboard.widget.refresh", OperationClass.NetworkRead),
        ("dashboard.widget.setEnabled", OperationClass.LocalWrite),
        ("directory.ou.children", OperationClass.LocalRead),
        ("directory.ou.search", OperationClass.LocalRead),
        ("session.info", OperationClass.LocalRead),
        ("session.setScope", OperationClass.LocalWrite),
        ("settings.collection", OperationClass.LocalRead),
        ("settings.collection.set", OperationClass.LocalWrite),
        ("settings.collection.window.check", OperationClass.Local),
        ("settings.connection", OperationClass.LocalRead),
        ("settings.connection.forget", OperationClass.LocalWrite),
        ("settings.connection.set", OperationClass.LocalWrite),
        ("settings.demo", OperationClass.LocalRead),
        ("settings.preferences.reset", OperationClass.LocalWrite),
        ("settings.storage", OperationClass.LocalRead),
        ("settings.storage.backup.plan", OperationClass.LocalRead),
        ("settings.storage.backup.schedule.set", OperationClass.LocalWrite),
        ("settings.storage.backupCopy.plan", OperationClass.LocalRead),
        ("settings.storage.integrity", OperationClass.LocalRead),
        ("settings.storage.legacy.plan", OperationClass.LocalRead),
        ("settings.storage.legacy.preview", OperationClass.LocalRead),
        ("settings.storage.measure", OperationClass.LocalRead),
        ("settings.storage.move.plan", OperationClass.LocalRead),
        ("settings.storage.purge.plan", OperationClass.LocalRead),
        ("settings.storage.purge.preview", OperationClass.LocalRead),
        ("settings.storage.restore.plan", OperationClass.LocalRead),
        ("settings.storage.resume.plan", OperationClass.LocalRead),
        ("settings.storage.retention.plan", OperationClass.LocalRead),
        ("settings.storage.retention.preview", OperationClass.LocalRead),
        ("settings.storage.retention.set", OperationClass.LocalWrite),
        ("settings.storage.rollback.plan", OperationClass.LocalRead),
        ("settings.storage.writerResume.plan", OperationClass.LocalRead),
        ("write.execute", OperationClass.Write),
        ("write.receipts.get", OperationClass.LocalRead),
        ("write.receipts.list", OperationClass.LocalRead),
        ("write.receipts.verify", OperationClass.NetworkRead),
    ];

    private static EngineContext Context(AppMode mode = AppMode.Simulation, IDirectorySource? source = null)
    {
        var decision = mode == AppMode.Simulation
            ? SimulatedBridge.Decision
            : ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        source ??= mode == AppMode.Simulation
            ? new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed())
            : new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun");
        return new EngineContext(decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(), ScreenReaders.Discover(source, [SimulationAssembly]));
    }

    [Test]
    public static void Modules_of_the_bridge_are_found_without_any_central_list()
    {
        var modules = OperationModules.Discover([BridgeAssembly]);
        string[] names = [.. modules.Select(m => m.GetType().Name)];
        Check.True(names.SequenceEqual(["AccountUnlockOperations", "DashboardOperations", "DirectoryTreeOperations", "SessionOperations", "SettingsOperations", "WriteOperations"]), "modules trouvés : " + string.Join(", ", names));
        using var context = Context();
        var registry = OperationModules.CreateRegistry(context, modules);
        Check.Equal(SimulationOperations.Length, registry.Names.Count, "opérations déclarées");
        foreach (var (name, operationClass) in SimulationOperations)
        {
            Check.True(registry.TryGet(name, out var definition), "opération présente : " + name);
            Check.Equal(operationClass, definition!.Class, "classe de " + name);
        }
    }

    [Test]
    public static void Tree_reads_are_network_reads_in_directory_mode()
    {
        using var context = Context(AppMode.Directory);
        var registry = OperationModules.CreateRegistry(context, OperationModules.Discover([BridgeAssembly]));
        Check.True(registry.TryGet("directory.ou.children", out var children), "arbre déclaré");
        Check.Equal(OperationClass.NetworkRead, children!.Class, "lecture réseau en mode annuaire");
        Check.True(registry.TryGet("directory.ou.search", out var search), "recherche déclarée");
        Check.Equal(OperationClass.NetworkRead, search!.Class, "lecture réseau en mode annuaire");
    }

    [Test]
    public static void Only_public_concrete_modules_with_a_parameterless_constructor_are_found()
    {
        var modules = OperationModules.Discover([typeof(PlatformTests).Assembly]);
        string[] names = [.. modules.Select(m => m.GetType().Name)];
        Check.True(names.SequenceEqual(["ProbeModule"]), "seul le module public est trouvé : " + string.Join(", ", names));
    }

    [Test]
    public static void Composition_errors_stop_the_start()
    {
        using var context = Context();
        Check.Throws<InvalidOperationException>(() => OperationModules.CreateRegistry(context, [new OutsideScreenModule()]), "opération hors de son écran");
        Check.Throws<InvalidOperationException>(() => OperationModules.CreateRegistry(context, [new InvalidScreenModule()]), "nom d’écran invalide");
        Check.Throws<ArgumentException>(() => OperationModules.CreateRegistry(context, [new ProbeModule(), new DuplicateModule()]), "opération en double");
        Check.True(OperationModules.IsValidScreen("dashboard"), "écran valide");
        Check.False(OperationModules.IsValidScreen("Dashboard"), "majuscule refusée");
        Check.False(OperationModules.IsValidScreen("dash.board"), "point refusé");
        Check.False(OperationModules.IsValidScreen(""), "vide refusé");
    }

    [Test]
    public static async Task Discovered_module_runs_through_the_dispatcher()
    {
        using var context = Context();
        var registry = OperationModules.CreateRegistry(context, OperationModules.Discover([typeof(PlatformTests).Assembly]));
        var sent = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(registry, sent.Add, AdmissionGuards.For(AppMode.Simulation));
        await dispatcher.HandleAsync("""{"id":"p1","op":"probe.echo","args":{}}""", CancellationToken.None);
        Check.Equal("result", sent.Single().Kind, "réponse du module trouvé");
        Check.Equal("Simulation", (string)sent.Single().Data!, "le module a reçu le contexte");
    }

    [Test]
    public static void Domenia_assemblies_come_from_the_trusted_list_only()
    {
        var assemblies = OperationModules.LoadDomeniaAssemblies();
        string[] names = [.. assemblies.Select(a => a.GetName().Name!)];
        foreach (var expected in new[] { "Domenia.Core", "Domenia.Bridge", "Domenia.Simulation", "Domenia.Store" })
        {
            Check.True(names.Contains(expected), "assemblage chargé : " + expected);
        }
        Check.True(names.All(n => n == "Domenia" || n.StartsWith("Domenia.", StringComparison.Ordinal)), "seulement des assemblages Domenia : " + string.Join(", ", names));
    }

    [Test]
    public static void Screen_readers_follow_the_source_of_the_mode()
    {
        var simulated = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed());
        var readers = ScreenReaders.Discover(simulated, [SimulationAssembly, typeof(PlatformTests).Assembly]);
        Check.True(readers.Find<IDirectoryTreeReader>() is SimulatedDirectoryTreeReader, "arbre simulé trouvé");
        Check.True(ReferenceEquals(readers.Find<IOrganizationalUnitIndex>(), readers.Find<IDirectoryTreeReader>()), "index local des OU : la même instance");
        Check.Null(readers.Find<IProbeReader>(), "lecteur d’une autre source ignoré");

        var unavailable = new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun");
        var none = ScreenReaders.Discover(unavailable, [SimulationAssembly]);
        Check.Null(none.Find<IDirectoryTreeReader>(), "aucun arbre sans Domenia.Ad");
        Check.Null(none.Find<IOrganizationalUnitIndex>(), "aucun index local sans base");
        var refused = Check.Throws<DomeniaOperationException>(() => none.Require<IDirectoryTreeReader>(), "lecteur exigé");
        Check.Equal(DomeniaErrors.SourceUnavailable, refused.Code, "source indisponible");

        var probe = ScreenReaders.Discover(new ProbeSource(), [SimulationAssembly, typeof(PlatformTests).Assembly]);
        Check.Equal("Simulation", probe.Require<IProbeReader>().Name, "lecteur construit avec sa source");
        Check.True(probe.Interfaces.SequenceEqual(["IProbeReader"]), "interfaces servies : " + string.Join(", ", probe.Interfaces));
    }

    [Test]
    public static void Screen_reader_constructors_read_nothing()
    {
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed());
        _ = ScreenReaders.Discover(source, [SimulationAssembly]);
        // The world is a Lazy: discovering the readers must not generate it (startup stays light, on the UI thread).
        var field = typeof(SimulatedDirectorySource).GetField("world", BindingFlags.NonPublic | BindingFlags.Instance);
        var lazy = (Lazy<SimulatedWorld>)field!.GetValue(source)!;
        Check.False(lazy.IsValueCreated, "aucune génération à la découverte");
    }

    [Test]
    public static void Screen_read_interfaces_have_no_write_method()
    {
        string[] verbs = ["Write", "Set", "Delete", "Move", "Reset", "Unlock", "Enable", "Disable", "Add", "Remove", "Create", "Update"];
        var interfaces = typeof(IScreenReader).Assembly.GetExportedTypes().Where(t => t.IsInterface && typeof(IScreenReader).IsAssignableFrom(t));
        foreach (var type in interfaces)
        {
            foreach (var method in type.GetMethods())
            {
                Check.False(verbs.Any(v => method.Name.StartsWith(v, StringComparison.Ordinal)), $"méthode d’écriture : {type.Name}.{method.Name}");
            }
        }
    }

    [Test]
    public static void Engine_services_are_shared_and_disposed_with_the_context()
    {
        var context = Context();
        var first = DashboardService.From(context);
        Check.True(ReferenceEquals(first, DashboardService.From(context)), "un seul service de l’Accueil par contexte");
        Check.True(ReferenceEquals(WorkingScope.From(context), WorkingScope.From(context)), "une seule OU de travail par contexte");
        context.Dispose();
        Check.Throws<ObjectDisposedException>(() => DashboardService.From(context), "contexte fermé");
        context.Dispose();
    }

    [Test]
    public static async Task Simulation_guard_admits_local_writes_and_always_refuses_writes()
    {
        var ran = new List<string>();
        OperationDefinition Define(string name, OperationClass operationClass, bool served = false) =>
            new(name, operationClass, (_, _, _) =>
            {
                ran.Add(name);
                return Task.FromResult<object?>(null);
            }, "test", served);
        var registry = new OperationRegistry(
        [
            Define("test.local", OperationClass.Local),
            Define("test.read", OperationClass.LocalRead),
            Define("test.preference", OperationClass.LocalWrite),
            Define("test.write", OperationClass.Write, served: true),
        ]);
        var sent = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(registry, sent.Add, AdmissionGuards.For(AppMode.Simulation));
        foreach (var name in new[] { "test.local", "test.read", "test.preference", "test.write" })
        {
            await dispatcher.HandleAsync("{\"id\":\"x\",\"op\":\"" + name + "\",\"args\":{}}", CancellationToken.None);
        }
        Check.True(ran.SequenceEqual(["test.local", "test.read", "test.preference"]), "local, lecture locale et écriture locale admises : " + string.Join(", ", ran));
        Check.Equal(DomeniaErrors.SimulationReadOnly, sent[^1].Error!.Code, "écriture AD refusée, même marquée servie");
        Check.Null(AdmissionGuards.ReadOnlySimulation(new OperationDefinition("x.y", OperationClass.LocalWrite, (_, _, _) => Task.FromResult<object?>(null), "t")), "LocalWrite admise");
    }
}
