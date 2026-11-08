namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    // File.Exists hides access failures and directories as "absent". Only actual absence may produce an empty cache.
    private bool DatabaseFileExists()
    {
        try
        {
            var attributes = File.GetAttributes(Path);
            if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                throw new IOException("La base sélectionnée n’est pas un fichier local ordinaire ; aucune donnée vide substituée.");
            return true;
        }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { return false; }
    }
}
