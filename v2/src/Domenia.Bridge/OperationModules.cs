using System.Collections.Immutable;
using System.Reflection;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Finds the operation modules of the Domenia assemblies and builds the closed registry of the bridge. The registry stays
/// closed: only public modules of the assemblies named « Domenia » or « Domenia.* » that the application host trusts
/// (its dependency list) are considered, and every operation still needs a valid, unique name within its screen.
/// </summary>
public static class OperationModules
{
    /// <summary>
    /// Assemblies of the application named « Domenia » or « Domenia.* », loaded from the host's trusted list (the files
    /// listed by the application's deps.json), so a stray DLL dropped next to the executable is never considered.
    /// </summary>
    public static ImmutableArray<Assembly> LoadDomeniaAssemblies()
    {
        var names = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        if (AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES") is string trusted)
        {
            foreach (var file in trusted.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            {
                var name = Path.GetFileNameWithoutExtension(file);
                if (RuntimeLibraryPlan.Contains(name))
                {
                    names.Add(name);
                }
            }
        }
        // Only the declared entry point joins the trusted list. A previously injected assembly is not a new module source.
        if (Assembly.GetEntryAssembly()?.GetName().Name is string host && RuntimeLibraryPlan.Contains(host)) names.Add(host);
        foreach (var assembly in new[] { typeof(OperationModules).Assembly, typeof(EngineContext).Assembly })
        {
            if (assembly.GetName().Name is string name && RuntimeLibraryPlan.Contains(name))
            {
                names.Add(name);
            }
        }
        var result = ImmutableArray.CreateBuilder<Assembly>(names.Count);
        foreach (var name in names)
        {
            result.Add(Assembly.Load(new AssemblyName(name)));
        }
        var loaded = result.ToImmutable();
        RuntimeLibraryPlan.ValidateLoaded(loaded, AppContext.BaseDirectory);
        return loaded;
    }

    /// <summary>
    /// Public, non-abstract classes implementing <see cref="IOperationModule"/> with a public parameterless constructor,
    /// ordered by the validated compiled plan. Explicit external fixture assemblies retain ordinary reflection discovery.
    /// </summary>
    public static ImmutableArray<IOperationModule> Discover(IEnumerable<Assembly> assemblies)
    {
        ArgumentNullException.ThrowIfNull(assemblies);
        var list = assemblies.Distinct().ToArray();
        if (list.Any(a => RuntimeLibraryPlan.Contains(a.GetName().Name))) return RuntimeModulePlan.Read(list).Instantiate();
        return
        [
            .. list
                .SelectMany(ExportedTypes)
                .Where(t => t.IsClass && !t.IsAbstract && !t.ContainsGenericParameters && typeof(IOperationModule).IsAssignableFrom(t)
                    && t.GetConstructor(Type.EmptyTypes) is not null)
                .OrderBy(t => t.FullName, StringComparer.Ordinal)
                .Select(t => (IOperationModule)Activator.CreateInstance(t)!),
        ];
    }

    /// <summary>
    /// Registry of every operation of the modules. A module whose screen name is invalid, an operation outside its
    /// screen, an invalid or duplicate name stop the start (programming errors, never a silent choice).
    /// </summary>
    public static OperationRegistry CreateRegistry(EngineContext context, IEnumerable<IOperationModule> modules, QueueTiming? queueTiming = null)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(modules);
        var definitions = new List<OperationDefinition>();
        foreach (var module in modules)
        {
            CompiledOperationContracts.RequireAssembly(module.GetType().Assembly);
            var screen = module.Screen;
            if (!IsValidScreen(screen))
            {
                throw new InvalidOperationException($"Invalid screen name in {module.GetType().FullName}: {screen}");
            }
            foreach (var definition in module.CreateOperations(context))
            {
                if (!definition.Name.StartsWith(screen + ".", StringComparison.Ordinal))
                {
                    throw new InvalidOperationException($"Operation {definition.Name} is outside the screen {screen} of {module.GetType().FullName}.");
                }
                definitions.Add(definition);
            }
        }
        return CreateRegistryFromDefinitions(context, definitions, queueTiming);
    }

    internal static OperationRegistry CreateRegistryFromDefinitions(EngineContext context, IEnumerable<OperationDefinition> definitions, QueueTiming? queueTiming)
    {
        // Tracking and admission remain identical for a planned production registry and an explicitly composed fixture.
        var tracked = definitions.Select(definition =>
        {
            // Validate the original body before wrappers move the visible delegate into Domenia.Bridge.
            CompiledOperationContracts.RequireAssembly(definition.Handler.Method.Module.Assembly);
            return BridgeReadIdentity.Bind(context,
                OperationTracking.Track(context, OperationRefusals.Journal(context, OperationReadGuards.Bind(context, SelectedObjectGuard.Bind(context, RemoteOperationGuard.Bind(context, BridgeScheduling.Declare(definition)))))));
        });
        return new OperationRegistry(tracked, context.Clock, token => BridgeScheduling.Capture(context, token),
            token => WorkstationCapabilityMemory.CaptureAsync(context, token), queueTiming ?? QueueTiming.From(context.Configuration.Report), OperationActivity.From(context));
    }

    /// <summary>Discovery and registry in one call (the application host).</summary>
    public static OperationRegistry CreateRegistry(EngineContext context, IEnumerable<Assembly> assemblies) =>
        RuntimeModulePlan.Read(assemblies).CreateRegistry(context);

    /// <summary>Screen names: one lower camel case segment (« dashboard », « directory »).</summary>
    public static bool IsValidScreen(string? screen) =>
        !string.IsNullOrEmpty(screen) && screen.Length <= 32 && char.IsAsciiLetterLower(screen[0]) && screen.All(char.IsAsciiLetterOrDigit);

    private static IEnumerable<Type> ExportedTypes(Assembly assembly) => assembly.GetExportedTypes();
}
