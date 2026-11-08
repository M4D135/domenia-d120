using System.Collections.Immutable;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.Loader;
using Domenia.App;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class RuntimePlanTests
{
    private static ModuleDeclaration Probe => new(typeof(ProbeModule), ModuleRegistrationPhase.Screens, "probe", [], ["probe.echo"]);
    private static ModuleDeclaration Session => new(typeof(SessionOperations), ModuleRegistrationPhase.Foundation, "session", [], ["session.get"]);

    [Test]
    public static void Closed_graph_rejects_empty_unknown_missing_late_cyclic_and_duplicate_exports_before_any_constructor()
    {
        var constructed = ProbeModule.ConstructorCalls; var created = ProbeModule.FactoryCalls;
        Reject([], [], "module.plan");
        Reject([Probe with { Phase = (ModuleRegistrationPhase)99 }], [typeof(ProbeModule)], "module.phase");
        Reject([Probe], [], "module.missing");
        Reject([Probe], [typeof(ProbeModule), typeof(SessionOperations)], "module.missing");
        Reject([Probe with { Dependencies = [typeof(SessionOperations)] }], [typeof(ProbeModule)], "module.dependency");
        Reject([Probe with { Phase = ModuleRegistrationPhase.Foundation, Dependencies = [typeof(SessionOperations)] }, Session with { Phase = ModuleRegistrationPhase.Host }],
            [typeof(ProbeModule), typeof(SessionOperations)], "module.phase");
        Reject([Probe with { Dependencies = [typeof(SessionOperations)] }, Session with { Phase = ModuleRegistrationPhase.Screens, Dependencies = [typeof(ProbeModule)] }],
            [typeof(ProbeModule), typeof(SessionOperations)], "module.cycle");
        Reject([Probe with { Exports = ["probe.echo", "probe.echo"] }], [typeof(ProbeModule)], "module.export");
        Reject([Probe with { Exports = ["outside.echo"] }], [typeof(ProbeModule)], "module.export");
        Reject([Probe with { Module = typeof(ProbeModuleWithArguments) }], [typeof(ProbeModuleWithArguments)], "module.missing");
        Check.Equal(constructed, ProbeModule.ConstructorCalls, "aucun constructeur déclenché pour examiner un plan invalide");
        Check.Equal(created, ProbeModule.FactoryCalls, "aucune fabrique, service ou opération lancé");
    }

    [Test]
    public static void Validated_plan_orders_dependencies_and_compares_real_factory_exports_before_registry_publication()
    {
        var plan = RuntimeModulePlan.Validate([Probe with { Dependencies = [typeof(SessionOperations)] }, Session], [typeof(ProbeModule), typeof(SessionOperations)]);
        Check.Equal(typeof(SessionOperations), plan.Ordered[0].Module, "dépendance en premier malgré ordre d’entrée inverse");
        var declaration = RuntimeModulePlan.Validate([Probe], [typeof(ProbeModule)]);
        using var context = Context();
        var registry = declaration.CreateRegistry(context);
        Check.True(registry.Names.SequenceEqual(["probe.echo"]), "export réel de la vraie fabrique enregistré");
        var invalid = RuntimeModulePlan.Validate([Probe with { Exports = ["probe.missing"] }], [typeof(ProbeModule)]);
        Check.Contains("module.export", Check.Throws<InvalidDataException>(() => invalid.CreateRegistry(context), "omission réelle refusée").Message,
            "code stable, aucun registre partiel rendu");
    }

    [Test]
    public static void Product_module_graph_and_real_exports_are_complete_in_both_application_modes()
    {
        var assembly = typeof(OperationModules).Assembly;
        var plan = RuntimeModulePlan.Read([assembly]);
        Check.Equal(31, plan.Ordered.Length, "tous les modules du pont présents dans le plan compilé");
        var types = plan.Ordered.Select(d => d.Module).ToArray();
        foreach (var item in plan.Ordered)
            foreach (var dependency in item.Dependencies)
                Check.True(Array.IndexOf(types, dependency) < Array.IndexOf(types, item.Module), "dépendance effectivement antérieure");
        var declared = plan.Ordered.SelectMany(d => d.Exports).ToHashSet(StringComparer.Ordinal);
        var search = plan.Ordered.Single(d => d.Module == typeof(SearchOperations));
        Check.True(search.Exports.ToHashSet(StringComparer.Ordinal).SetEquals(SearchOperationsTests.Operations.Select(o => o.Name)),
            "le plan inclut aussi les opérations des recettes ajoutées par la fabrique partielle Rechercher");
        foreach (var mode in new[] { AppMode.Simulation, AppMode.Directory })
        {
            using var context = Context(mode);
            var registry = plan.CreateRegistry(context);
            Check.True(declared.SetEquals(registry.Names), "exports réels exacts dans le mode " + mode);
            Check.True(registry.TryGet("write.execute", out _), "circuit d’écriture conservé sans exécution");
        }
        var preflight = StartupPreflight.PrepareModules([assembly]);
        Check.Equal(31, preflight.Ordered.Length, "précontrôle partagé par composition normale et diagnostic");
    }

    [Test]
    public static void Library_plan_matches_real_loaded_files_and_rejects_an_external_origin()
    {
        var libraries = OperationModules.LoadDomeniaAssemblies();
        RuntimeLibraryPlan.ValidateLoaded(libraries, AppContext.BaseDirectory);
        Check.Equal(8, RuntimeLibraryPlan.RequiredFiles.Length, "huit bibliothèques produit requises, hôte compris");
        Check.True(RuntimeLibraryPlan.RequiredFiles.Contains("Domenia.dll"), "hôte déclaré dans le plan de paquet");
        Check.False(libraries.Any(a => a == typeof(RuntimePlanTests).Assembly), "l’exécutable de test chargé n’est jamais un module produit");
        using var folder = new TemporaryFolder();
        File.Copy(typeof(EngineContext).Assembly.Location, folder.File("Domenia.Core.dll"));
        var error = Check.Throws<InvalidDataException>(() => RuntimeLibraryPlan.ValidateLoaded([typeof(EngineContext).Assembly], folder.Path), "origine réelle différente malgré copie identique");
        Check.Contains("library.origin", error.Message, "le même nom et la même version ne suffisent pas");
        Check.Throws<InvalidDataException>(() => RuntimeLibraryPlan.ValidateLoaded([typeof(RuntimePlanTests).Assembly], AppContext.BaseDirectory), "bibliothèque hors plan refusée");
    }

    [Test]
    public static Task Already_loaded_duplicate_product_library_is_rejected_in_a_fresh_process() => RunProcessAsync();

    internal const string FixtureArgument = "--runtime-plan-fixture";
    internal static Task<int> RunFixtureAsync(string[] args)
    {
        if (args.Length != 1 || args[0] != FixtureArgument) return Task.FromResult(2);
        try
        {
            var actual = typeof(EngineContext).Assembly;
            RuntimeLibraryPlan.ValidateLoaded([actual], AppContext.BaseDirectory);
            using var folder = new TemporaryFolder(); var copy = folder.File("Domenia.Core.dll"); File.Copy(actual.Location, copy);
            var loader = new AssemblyLoadContext("untrusted-copy", isCollectible: true);
            try
            {
                var duplicate = loader.LoadFromAssemblyPath(copy);
                Check.False(ReferenceEquals(actual, duplicate), "second assemblage réellement chargé");
                Check.Equal(actual.ManifestModule.ModuleVersionId, duplicate.ManifestModule.ModuleVersionId, "mêmes octets et version : le contexte supplémentaire reste interdit");
                var error = Check.Throws<InvalidDataException>(() => RuntimeLibraryPlan.ValidateLoaded([actual], AppContext.BaseDirectory), "doublon déjà chargé refusé");
                Check.Contains("library.version", error.Message, "refus explicite avant tout module métier");
            }
            finally { loader.Unload(); }
            Console.WriteLine("runtime-plan:ok"); return Task.FromResult(0);
        }
        catch (Exception error) { Console.Error.WriteLine(error.GetType().Name + ": " + error.Message); return Task.FromResult(1); }
    }

    private static async Task RunProcessAsync()
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Exécutable de test absent.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            WorkingDirectory = AppContext.BaseDirectory, RedirectStandardOutput = true, RedirectStandardError = true };
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(typeof(RuntimePlanTests).Assembly.Location);
        start.ArgumentList.Add(FixtureArgument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Processus de qualification absent.");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var output = process.StandardOutput.ReadToEndAsync(timeout.Token); var errors = process.StandardError.ReadToEndAsync(timeout.Token);
        try
        {
            await process.WaitForExitAsync(timeout.Token);
            Check.Equal(0, process.ExitCode, "chargement isolé : " + await output + await errors);
            Check.Equal("runtime-plan:ok", (await output).Trim(), "scénario réellement exécuté");
        }
        finally
        {
            if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); }
        }
    }

    private static void Reject(ImmutableArray<ModuleDeclaration> declarations, ImmutableArray<Type> available, string code) =>
        Check.Contains(code, Check.Throws<InvalidDataException>(() => RuntimeModulePlan.Validate(declarations, available), "plan refusé").Message, "cause précise");
    private static EngineContext Context(AppMode mode = AppMode.Simulation)
    {
        var decision = ModeResolver.Resolve(mode == AppMode.Simulation ? ["--simulation"] : [], null, () => new(DomainJoinState.Joined, "example.invalid"));
        IDirectorySource source = mode == AppMode.Simulation
            ? new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed())
            : new UnavailableDirectorySource("example.invalid", () => "EXAMPLE\\reader");
        return new(decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(),
            ScreenReaders.Discover(source, [typeof(SimulatedDirectorySource).Assembly]));
    }
}
