using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Runtime.InteropServices;
using System.Runtime.Loader;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>The V2 route is compiled LDAP/ADSI, not an imported RSAT PowerShell module. Validate its actual libraries
/// before opening a connection. This proves loading coherence, not publisher trust (checked by the package boundary).</summary>
internal static class AdTransportPrerequisites
{
    private static readonly Lazy<bool> Ready = new(() =>
    {
        Validate(OperatingSystem.IsWindows(), RuntimeInformation.ProcessArchitecture == Architecture.X64,
            [typeof(System.DirectoryServices.Protocols.LdapConnection).Assembly, typeof(System.DirectoryServices.DirectoryEntry).Assembly],
            Path.GetDirectoryName(typeof(AdConnection).Assembly.Location), RuntimeDesktopDirectory());
        return true;
    });

    internal static void Require()
    {
        // Resolving the assembly arguments can itself fail before Validate receives them.
        try { _ = Ready.Value; }
        catch (Exception error) when (error is IOException or BadImageFormatException or TypeLoadException)
        { throw Unavailable(); }
    }

    private static DomeniaOperationException Unavailable() => new(AdErrors.Unavailable,
        "Transport AD V2 indisponible : Windows x64 et les bibliothèques LDAP/ADSI exactes du pack sont requis. Réparez le pack ; aucun import RSAT ni contact annuaire tenté.");

    /// <summary>Microsoft.WindowsDesktop.App beside the NETCore.App that runs this process (the private runtime of the pack in
    /// production). It ships the same LDAP/ADSI assemblies and the host prefers it when its file version is not lower.</summary>
    internal static string? RuntimeDesktopDirectory()
    {
        var core = Path.GetDirectoryName(typeof(object).Assembly.Location);
        var shared = core is null ? null : Path.GetDirectoryName(core);
        return string.IsNullOrEmpty(shared) || !string.Equals(Path.GetFileName(shared), "Microsoft.NETCore.App", StringComparison.OrdinalIgnoreCase) ? null
            : Path.Combine(Path.GetDirectoryName(shared)!, "Microsoft.WindowsDesktop.App", Path.GetFileName(core)!);
    }

    internal static void Validate(bool windows, bool x64, IReadOnlyList<Assembly> libraries, string? directory, string? runtimeDirectory)
    {
        try
        {
            if (!windows || !x64 || libraries.Count != 2 || string.IsNullOrWhiteSpace(directory)) throw new InvalidDataException();
            // The managed pack lives beside Domenia.Ad (wad in production), not necessarily beside the launcher.
            var expected = typeof(AdConnection).Assembly.GetReferencedAssemblies()
                .Where(a => a.Name is "System.DirectoryServices" or "System.DirectoryServices.Protocols")
                .ToDictionary(a => a.Name!, StringComparer.Ordinal);
            if (expected.Count != 2 || libraries.Select(a => a.GetName().Name).Distinct(StringComparer.Ordinal).Count() != 2) throw new InvalidDataException();
            foreach (var library in libraries)
            {
                var name = library.GetName();
                if (!expected.TryGetValue(name.Name!, out var reference) || name.FullName != reference.FullName
                    || library.IsDynamic || AssemblyLoadContext.GetLoadContext(library) != AssemblyLoadContext.Default
                    || string.IsNullOrWhiteSpace(library.Location)
                    || !IsBeside(library.Location, directory, name.Name!) && (runtimeDirectory is null || !IsBeside(library.Location, runtimeDirectory, name.Name!)))
                    throw new InvalidDataException();
                using var input = new FileStream(library.Location, FileMode.Open, FileAccess.Read, FileShare.Read);
                using var pe = new PEReader(input);
                if (!pe.HasMetadata) throw new InvalidDataException();
                var metadata = pe.GetMetadataReader();
                if (metadata.GetGuid(metadata.GetModuleDefinition().Mvid) != library.ManifestModule.ModuleVersionId) throw new InvalidDataException();
            }
        }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or BadImageFormatException or ArgumentException
            or InvalidOperationException or TypeLoadException)
        { throw Unavailable(); }
    }

    private static bool IsBeside(string location, string directory, string name) =>
        string.Equals(Path.GetFullPath(location), Path.GetFullPath(Path.Combine(directory, name + ".dll")), StringComparison.OrdinalIgnoreCase);
}
