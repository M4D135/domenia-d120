using System.Reflection;

namespace Domenia.App;

/// <summary>The real --check-only terminal path, shared with the Windows tests. No profile or application timers.</summary>
internal static class StartupCheckCommand
{
    internal static int Run(PackageIntegrity package, IEnumerable<Assembly> assemblies, Action<string> output)
    {
        try
        {
            if (!package.Packaged) throw new InvalidDataException("Paquet non vérifié.");
            var loaded = assemblies.ToArray();
            package.VerifyCompiledRelease(loaded);
            var check = StartupPreflight.CheckModules(loaded);
            output($"Paquet : {package.FilesChecked} fichiers vérifiés (plafond {PackageIntegrity.MaximumFiles}). Modules chargés : {check.Modules}, {check.Assemblies} assemblages, {check.Milliseconds} ms. Aucun accès AD, aucune fenêtre ou minuterie applicative.");
            return 0;
        }
#pragma warning disable CA1031 // A failed local diagnostic reports failure and never enters the interactive startup path.
        catch (Exception failure) { output("Contrôle local non validé : " + failure.GetType().Name + ". Aucun accès AD."); return 1; }
#pragma warning restore CA1031
    }
}
