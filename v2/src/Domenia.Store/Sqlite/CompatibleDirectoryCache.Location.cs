using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ILocalStorageLocation
{
    public async Task<LocalStorageLocation> LocationAsync(CancellationToken cancellationToken)
    {
        var database = await DatabaseAsync(cancellationToken).ConfigureAwait(false);
        return await Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            ValidateLocalPath(database.Path);
            var mode = ReadSwitchState() is not null ? "Emplacement choisi" : selectedMode;
            var place = Within(database.Path, System.IO.Path.Combine(appFolder, "data")) ? "dossier portable"
                : Within(database.Path, userFolder) ? "profil utilisateur" : "disque local choisi";
            // A read check is read-only: never create a file just to display this page, nor promise write access.
            return InspectLocation(database.Path, mode + " · " + place);
        }, cancellationToken).ConfigureAwait(false);
    }

    internal static LocalStorageLocation InspectLocation(string path, string mode)
    {
        try
        {
            _ = File.GetAttributes(path);
            using var read = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return new(path, mode, "Lecture disponible", "L’écriture est vérifiée lors de chaque enregistrement.");
        }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { return new(path, mode, "À créer", null); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { return new(path, mode, "Non lisible", "Accès refusé ou fichier occupé ; emplacement conservé, aucun repli."); }
    }

    private static bool Within(string path, string folder)
    {
        var relative = System.IO.Path.GetRelativePath(System.IO.Path.GetFullPath(folder), path);
        return !System.IO.Path.IsPathRooted(relative) && relative != ".." && !relative.StartsWith(".." + System.IO.Path.DirectorySeparatorChar, StringComparison.Ordinal);
    }
}

public sealed partial class SqliteDirectoryCache : ILocalStorageLocation
{
    public Task<LocalStorageLocation> LocationAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        cancellationToken.ThrowIfCancellationRequested();
        CompatibleDirectoryCache.ValidateLocalPath(Database.Path);
        return CompatibleDirectoryCache.InspectLocation(Database.Path, "Emplacement local choisi");
    }, cancellationToken);
}
