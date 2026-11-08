using System.Collections.Immutable;
using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Runtime.Loader;

namespace Domenia.Bridge;

public sealed record RuntimeLibraryDeclaration(string Name, ImmutableArray<string> Dependencies)
{
    public string FileName => Name + ".dll";
}

/// <summary>Compiled product boundary. Package hashes protect the bytes; this plan also checks what the CLR really loaded.</summary>
public static class RuntimeLibraryPlan
{
    public static ImmutableArray<RuntimeLibraryDeclaration> Libraries { get; } =
    [
        new("Domenia.Core", []), new("Domenia.Bridge", ["Domenia.Core"]), new("Domenia.Store", ["Domenia.Core"]),
        new("Domenia.Engine", ["Domenia.Core"]), new("Domenia.Inventory", ["Domenia.Core"]),
        new("Domenia.Ad", ["Domenia.Core", "Domenia.Inventory"]), new("Domenia.Simulation", ["Domenia.Core"]),
        new("Domenia", ["Domenia.Core", "Domenia.Bridge", "Domenia.Store", "Domenia.Engine", "Domenia.Inventory", "Domenia.Ad", "Domenia.Simulation"]),
    ];
    public static ImmutableArray<string> RequiredFiles { get; } = [.. Libraries.Select(l => l.FileName)];
    public static bool Contains(string? name) => Libraries.Any(l => string.Equals(l.Name, name, StringComparison.Ordinal));

    public static void ValidateLoaded(IEnumerable<Assembly> assemblies, string applicationDirectory, bool requireFullProduct = false)
    {
        ArgumentNullException.ThrowIfNull(assemblies);
        Domenia.Core.Queries.QueryImplementationProvenance.Validate();
        var directory = Path.GetFullPath(applicationDirectory);
        var selected = assemblies.Distinct().ToArray();
        if (selected.Length == 0 || selected.Any(a => !Contains(a.GetName().Name)))
            throw Invalid("library.plan", "Assemblage absent ou extérieur au plan fermé.");
        var expected = selected.ToDictionary(a => a.GetName().Name!, StringComparer.Ordinal);
        if (requireFullProduct && !expected.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(Libraries.Select(l => l.Name)))
            throw Invalid("library.missing", "Le plan de bibliothèques du produit n’est pas complet.");
        var loaded = AppDomain.CurrentDomain.GetAssemblies().Where(a => Contains(a.GetName().Name)).ToArray();
        foreach (var group in loaded.GroupBy(a => a.GetName().Name, StringComparer.Ordinal))
            if (group.Count() != 1) throw Invalid("library.version", "Plusieurs versions ou contextes d’une bibliothèque Domenia sont déjà chargés.");
        var build = typeof(RuntimeLibraryPlan).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
            .SingleOrDefault(a => a.Key == "DomeniaBuildIdentity")?.Value;
        var version = typeof(RuntimeLibraryPlan).Assembly.GetName().Version;
        foreach (var assembly in selected)
        {
            var name = assembly.GetName();
            var declaration = Libraries.Single(l => l.Name == name.Name);
            var path = Path.Combine(directory, declaration.FileName);
            if (assembly.IsDynamic || AssemblyLoadContext.GetLoadContext(assembly) != AssemblyLoadContext.Default
                || string.IsNullOrEmpty(assembly.Location) || !string.Equals(Path.GetFullPath(assembly.Location), path, StringComparison.OrdinalIgnoreCase))
                throw Invalid("library.origin", "Une bibliothèque chargée ne provient pas du fichier attendu du produit.");
            var diskName = AssemblyName.GetAssemblyName(path);
            if (!string.Equals(name.FullName, diskName.FullName, StringComparison.Ordinal) || name.Version != version)
                throw Invalid("library.version", "Identité ou version de bibliothèque incohérente entre le fichier, le processus et le produit.");
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            using var pe = new PEReader(file);
            if (!pe.HasMetadata) throw Invalid("library.types", "Bibliothèque sans métadonnées .NET.");
            var metadata = pe.GetMetadataReader();
            var mvid = metadata.GetGuid(metadata.GetModuleDefinition().Mvid);
            if (mvid == Guid.Empty || mvid != assembly.ManifestModule.ModuleVersionId)
                throw Invalid("library.version", "Le module chargé diffère du module conservé sur disque.");
            var assemblyBuild = assembly.GetCustomAttributes<AssemblyMetadataAttribute>().SingleOrDefault(a => a.Key == "DomeniaBuildIdentity")?.Value;
            if (build != assemblyBuild) throw Invalid("library.version", "Les bibliothèques ne portent pas la même identité de construction.");
            // A project dependency may be shipped without producing an AssemblyRef when this build uses no type from it.
            // Every reference actually emitted must still belong to the declared dependency set and product version.
            var dependencies = assembly.GetReferencedAssemblies().Where(a => a.Name == "Domenia" || a.Name?.StartsWith("Domenia.", StringComparison.Ordinal) == true).ToArray();
            if (dependencies.Any(d => !declaration.Dependencies.Contains(d.Name!, StringComparer.Ordinal) || d.Version != version))
                throw Invalid("library.dependency", "Les références compilées d’une bibliothèque diffèrent de son plan.");
        }
    }

    private static InvalidDataException Invalid(string code, string message) => new(code + " : " + message);
}
