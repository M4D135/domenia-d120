using System.Reflection;

namespace Domenia.Core;

/// <summary>V2 pins compiled implementation closures at build time. Every loaded layer must carry the same
/// reviewed registry. PackageIntegrity additionally holds and hashes the delivered binaries. This is consistency,
/// never a claim of publisher authenticity; that requires independent Windows publisher policy.</summary>
public static class CompiledOperationContracts
{
    public const string MetadataKey = "DomeniaOperationRegistry";
    public static string Fingerprint { get; } = Read(typeof(CompiledOperationContracts).Assembly);

    public static void RequireAssembly(Assembly assembly)
    {
        ArgumentNullException.ThrowIfNull(assembly);
        if (Read(assembly) != Fingerprint)
            throw new InvalidDataException("Corps compilé d’un autre registre d’opérations ; aucune mise en file autorisée.");
    }

    public static void RequireAssemblies(IEnumerable<Assembly> assemblies)
    {
        foreach (var assembly in assemblies) RequireAssembly(assembly);
    }

    private static string Read(Assembly assembly)
    {
        var values = assembly.GetCustomAttributes<AssemblyMetadataAttribute>().Where(a => a.Key == MetadataKey).ToArray();
        if (values.Length != 1 || values[0].Value is not { Length: 64 } value || value.Any(c => !char.IsAsciiHexDigit(c))
            || value != value.ToLowerInvariant())
            throw new InvalidDataException("Registre compilé absent ou ambigu ; aucune opération admise.");
        return value;
    }
}
