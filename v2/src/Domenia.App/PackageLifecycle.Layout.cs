using System.Reflection;

namespace Domenia.App;

/// <summary>Two explicit portable layouts. Component paths always remain relative to the EXE root.</summary>
internal static class PackageLayout
{
    internal const string Payload = "wad";
    internal static string ApplicationRoot
    {
        get
        {
            return ResolveApplicationRoot(AppContext.BaseDirectory, typeof(PackageLayout).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
                .Any(value => value.Key == "DomeniaWadLayout" && value.Value == "true"));
        }
    }

    // One candidate only: compiled host base. CWD, DOMENIA_ROOT/MEGAD_ROOT and legacy HKCU do not redirect executable code.
    internal static string ResolveApplicationRoot(string applicationDirectory, bool wad)
    {
        if (!Path.IsPathFullyQualified(applicationDirectory)) throw new InvalidDataException("Racine du pack non absolue.");
        var directory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(applicationDirectory));
        if (!wad) return directory;
        if (!Path.GetFileName(directory).Equals(Payload, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Dossier wad absent : réextrayez le pack complet.");
        return Path.GetDirectoryName(directory) ?? throw new InvalidDataException("Racine du pack absente.");
    }

    internal static bool IsWad(string root)
    {
        var flat = System.IO.File.Exists(Path.Combine(root, PackageIntegrity.ManifestName));
        var nested = System.IO.File.Exists(Path.Combine(root, Payload, PackageIntegrity.ManifestName));
        if (flat && nested) throw new InvalidDataException("Deux dispositions de paquet mélangées ; extrayez le pack dans un nouveau dossier.");
        return nested || !flat && (System.IO.File.Exists(Path.Combine(root, Payload, ".lifecycle.lock"))
            || System.IO.File.Exists(Path.Combine(root, Payload, ".update.pending")));
    }

    internal static string Relative(string root, string name) => IsWad(root) ? Payload + "/" + name : name;
    internal static string At(string root, string name) => Path.Combine(root, Relative(root, name).Replace('/', Path.DirectorySeparatorChar));
    internal static string Relative(bool wad, string name) => wad ? Payload + "/" + name : name;
    internal static bool IsState(string name) => name is ".lifecycle.lock" or "package-manifest.json" or ".update.pending"
        or "wad/.lifecycle.lock" or "wad/package-manifest.json" or "wad/.update.pending";

    internal static void RequireSameLayout(string source, string target)
    {
        if ((System.IO.File.Exists(At(target, PackageIntegrity.ManifestName))
            || System.IO.File.Exists(At(target, ".lifecycle.lock"))) && IsWad(source) != IsWad(target))
            throw new InvalidDataException("Cette version utilise une autre disposition de dossier. Extrayez le nouveau pack dans un dossier distinct ; conservez l’ancien pack pour sa reprise ou sa restauration.");
    }
}
