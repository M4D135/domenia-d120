using System.Collections.Immutable;
using System.Reflection;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Registration phases only: authentication and network handlers are never executed by the plan.</summary>
public enum ModuleRegistrationPhase { Foundation, Screens, Host }

/// <summary>Compiled declaration owned by the same assembly as its module; no editable external loader or scan of neighbours.</summary>
[AttributeUsage(AttributeTargets.Assembly, AllowMultiple = true)]
public sealed class OperationModulePlanAttribute(Type module, ModuleRegistrationPhase phase, string screen, Type[] dependencies, params string[] exports) : Attribute
{
    public Type Module { get; } = module;
    public ModuleRegistrationPhase Phase { get; } = phase;
    public string Screen { get; } = screen;
    public Type[] Dependencies { get; } = dependencies;
    public string[] Exports { get; } = exports;
}

public sealed record ModuleDeclaration(Type Module, ModuleRegistrationPhase Phase, string Screen,
    ImmutableArray<Type> Dependencies, ImmutableArray<string> Exports);

/// <summary>Validated immutable graph. Its existence is the precondition for constructing the production modules.</summary>
public sealed class RuntimeModulePlan
{
    public ImmutableArray<ModuleDeclaration> Ordered { get; }
    private RuntimeModulePlan(ImmutableArray<ModuleDeclaration> ordered) => Ordered = ordered;

    public static RuntimeModulePlan Read(IEnumerable<Assembly> assemblies)
    {
        ArgumentNullException.ThrowIfNull(assemblies);
        var list = assemblies.Distinct().ToArray();
        var declarations = new List<ModuleDeclaration>();
        var types = new List<Type>();
        foreach (var assembly in list)
        {
            // A partially loadable assembly is a failure, never a reduced list of apparently available functions.
            types.AddRange(assembly.GetExportedTypes().Where(IsModule));
            foreach (var item in assembly.GetCustomAttributes<OperationModulePlanAttribute>())
            {
                if (item.Module.Assembly != assembly) throw Invalid("module.origin", "Une déclaration de module provient d’un autre assemblage.");
                declarations.Add(new(item.Module, item.Phase, item.Screen, [.. item.Dependencies], [.. item.Exports]));
            }
        }
        return Validate(declarations, types);
    }

    /// <summary>Also used by tests with actual module types; does not invoke any module constructor or factory.</summary>
    public static RuntimeModulePlan Validate(IEnumerable<ModuleDeclaration> declarations, IEnumerable<Type> availableModules)
    {
        ArgumentNullException.ThrowIfNull(declarations); ArgumentNullException.ThrowIfNull(availableModules);
        var items = declarations.Take(129).ToArray();
        if (items.Length is 0 or > 128) throw Invalid("module.plan", "Plan des modules absent, vide ou hors limites.");
        var available = availableModules.ToHashSet();
        var byType = new Dictionary<Type, ModuleDeclaration>();
        var exports = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in items)
        {
            if (!IsModule(item.Module) || item.Module.GetConstructor(Type.EmptyTypes) is null || !available.Contains(item.Module)
                || !byType.TryAdd(item.Module, item)) throw Invalid("module.missing", "Module absent, répété ou constructeur public sans argument manquant.");
            if (!Enum.IsDefined(item.Phase)) throw Invalid("module.phase", "Phase de module inconnue.");
            var factory = item.Module.GetInterfaceMap(typeof(IOperationModule)).TargetMethods
                .Single(m => m.Name.EndsWith(nameof(IOperationModule.CreateOperations), StringComparison.Ordinal));
            if (factory.DeclaringType != item.Module || factory.Module.Assembly != item.Module.Assembly)
                throw Invalid("module.origin", "La fabrique d’opérations ne provient pas du type de module déclaré.");
            if (!OperationModules.IsValidScreen(item.Screen) || item.Exports.IsDefault || item.Exports.Length > 256
                || item.Dependencies.IsDefault || item.Dependencies.Length > 128 || item.Dependencies.Distinct().Count() != item.Dependencies.Length)
                throw Invalid("module.plan", "Contrat de module incomplet ou hors limites.");
            foreach (var name in item.Exports)
                if (!OperationRegistry.IsValidName(name) || !name.StartsWith(item.Screen + ".", StringComparison.Ordinal) || !exports.Add(name))
                    throw Invalid("module.export", "Export de module invalide, hors de son écran ou fourni deux fois.");
        }
        if (!available.SetEquals(byType.Keys)) throw Invalid("module.missing", "Un module public n’est pas déclaré dans le plan fermé.");
        foreach (var item in items)
            foreach (var dependency in item.Dependencies)
            {
                if (!byType.TryGetValue(dependency, out var prior)) throw Invalid("module.dependency", "Dépendance de module absente.");
                if (prior.Phase > item.Phase) throw Invalid("module.phase", "Une dépendance est déclarée dans une phase ultérieure.");
            }
        var ordered = ImmutableArray.CreateBuilder<ModuleDeclaration>(items.Length);
        var done = new HashSet<Type>();
        while (done.Count != items.Length)
        {
            var next = items.Where(i => !done.Contains(i.Module) && i.Dependencies.All(done.Contains))
                .OrderBy(i => i.Phase).ThenBy(i => i.Module.FullName, StringComparer.Ordinal).FirstOrDefault();
            if (next is null) throw Invalid("module.cycle", "Cycle dans les dépendances des modules.");
            done.Add(next.Module); ordered.Add(next);
        }
        return new(ordered.ToImmutable());
    }

    public ImmutableArray<IOperationModule> Instantiate() => [.. Ordered.Select(item =>
    {
        var instance = (IOperationModule)Activator.CreateInstance(item.Module)!;
        if (instance.Screen != item.Screen) throw Invalid("module.export", "L’écran réel du module diffère de son plan.");
        return instance;
    })];

    public OperationRegistry CreateRegistry(EngineContext context, QueueTiming? queueTiming = null)
    {
        var definitions = new List<OperationDefinition>();
        foreach (var (item, module) in Ordered.Zip(Instantiate()))
        {
            var actual = module.CreateOperations(context).Take(257).ToArray();
            if (actual.Length != item.Exports.Length || actual.Select(o => o.Name).Distinct(StringComparer.Ordinal).Count() != actual.Length
                || !actual.Select(o => o.Name).ToHashSet(StringComparer.Ordinal).SetEquals(item.Exports))
                throw Invalid("module.export", "Les opérations réelles de " + item.Module.Name + " diffèrent du plan validé.");
            if (actual.Any(o => o.Handler.Method.Module.Assembly != item.Module.Assembly))
                throw Invalid("module.origin", "Un export provient d’un autre assemblage que son module déclaré.");
            definitions.AddRange(actual);
        }
        return OperationModules.CreateRegistryFromDefinitions(context, definitions, queueTiming);
    }

    private static bool IsModule(Type type) => type.IsClass && type.IsPublic && !type.IsAbstract && !type.ContainsGenericParameters && typeof(IOperationModule).IsAssignableFrom(type);
    private static InvalidDataException Invalid(string code, string message) => new(code + " : " + message);
}
