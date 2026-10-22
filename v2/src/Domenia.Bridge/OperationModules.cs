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
                if (IsDomeniaName(name))
                {
                    names.Add(name);
                }
            }
        }
        // Assemblies already loaded (and the host itself) are always part of it.
        foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            if (assembly.GetName().Name is string name && IsDomeniaName(name))
            {
                names.Add(name);
            }
        }
        var result = ImmutableArray.CreateBuilder<Assembly>(names.Count);
        foreach (var name in names)
        {
            result.Add(Assembly.Load(new AssemblyName(name)));
        }
        return result.ToImmutable();
    }

    /// <summary>
    /// Public, non-abstract classes implementing <see cref="IOperationModule"/> with a public parameterless constructor,
    /// ordered by full name (stable composition).
    /// </summary>
    public static ImmutableArray<IOperationModule> Discover(IEnumerable<Assembly> assemblies)
    {
        ArgumentNullException.ThrowIfNull(assemblies);
        return
        [
            .. assemblies.Distinct()
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
    public static OperationRegistry CreateRegistry(EngineContext context, IEnumerable<IOperationModule> modules)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(modules);
        var definitions = new List<OperationDefinition>();
        foreach (var module in modules)
        {
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
                // Every operation is followed in the activity of the session (Opérations, docs/ops/operations.md § 3): same
                // handler, same answer, same exceptions; reads become stoppable by the operator, writes never.
                definitions.Add(OperationTracking.Track(context, definition));
            }
        }
        return new OperationRegistry(definitions);
    }

    /// <summary>Discovery and registry in one call (the application host).</summary>
    public static OperationRegistry CreateRegistry(EngineContext context, IEnumerable<Assembly> assemblies) =>
        CreateRegistry(context, Discover(assemblies));

    /// <summary>Screen names: one lower camel case segment (« dashboard », « directory »).</summary>
    public static bool IsValidScreen(string? screen) =>
        !string.IsNullOrEmpty(screen) && screen.Length <= 32 && char.IsAsciiLetterLower(screen[0]) && screen.All(char.IsAsciiLetterOrDigit);

    private static bool IsDomeniaName(string name) =>
        string.Equals(name, "Domenia", StringComparison.Ordinal) || name.StartsWith("Domenia.", StringComparison.Ordinal);

    private static IEnumerable<Type> ExportedTypes(Assembly assembly)
    {
        try
        {
            return assembly.GetExportedTypes();
        }
        catch (ReflectionTypeLoadException ex)
        {
            return ex.Types.OfType<Type>().Where(t => t.IsPublic);
        }
    }
}
