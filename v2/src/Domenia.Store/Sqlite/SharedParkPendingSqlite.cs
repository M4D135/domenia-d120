using System.Security.AccessControl;
using System.Security.Principal;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// A new local store is prepared on the final volume, in a private create-only directory. Neither cancellation nor publication
/// ambiguity deletes it. Its committed receipt can be inspected manually if installing the final name fails; nothing replays it.
/// The existing cooperative storage fence serializes admission for this target. It cannot reserve an absent name against D1 or
/// arbitrary writers, so installation always uses Move(overwrite:false) and verifies the moved identity and bytes.
/// </summary>
internal sealed class SharedParkPendingSqlite : IDisposable
{
    internal static string RootFor(string target) => target + ".sharedpark-pending";
    private readonly string target;
    private readonly SharedParkPublicationFile.PathPins pins;
    private IDisposable? fence;
    private SharedParkPublicationFile.BoundFile? installed;
    internal string Path { get; private set; } = "";
    private const long Reserve = 512L * 1024 * 1024;

    internal SharedParkPendingSqlite(string target, string planId, CancellationToken token)
    {
        this.target = target;
        if (!WritePlans.IsPlanId(planId) || target.Split('\\').Any(c => c.Equals("dev", StringComparison.OrdinalIgnoreCase)))
        { throw new InvalidDataException("Identité ou destination de préparation SQLite non qualifiée."); }
        CompatibleDirectoryCache.ValidateLocalPath(target);
        var root = RootFor(target); var batch = System.IO.Path.Combine(root, planId);
        Path = System.IO.Path.Combine(batch, "prepared.db");
        if (Path.Length > 1024) { throw new InvalidDataException("Chemin de la base préparée supérieur à 1 024 caractères."); }
        var parent = System.IO.Path.GetDirectoryName(target)!;
        pins = OpenParent(parent, token);
        try
        {
            RequireAbsent(token);
            if (File.Exists(StorageWriteFence.Marker(target))) { throw new InvalidDataException("Ancien stockage protégé ; aucune initialisation du partage."); }
            fence = StorageWriteFence.Exclusive(target, token); RequireAbsent(token);
            using (var roots = SharedParkLocalPaths.Open(root, root, true, token)) { pins.Add(root); }
            Admit(root, token);
            SharedParkLocalPaths.CreateExclusive(batch); pins.Add(batch);
            using var file = FileSystemAclExtensions.Create(new FileInfo(Path), FileMode.CreateNew, FileSystemRights.FullControl,
                FileShare.None, 4096, FileOptions.WriteThrough, PrivateSecurity());
            SharedParkPublicationFile.RequirePrivate(file.GetAccessControl(), FileSystemRights.FullControl, false);
            file.Flush(flushToDisk: true); token.ThrowIfCancellationRequested();
        }
        catch { Dispose(); throw; }
    }

    internal void RequireAbsent(CancellationToken token)
    {
        foreach (var suffix in new[] { "", "-wal", "-shm", "-journal" })
        {
            token.ThrowIfCancellationRequested();
            try { _ = File.GetAttributes(target + suffix); }
            catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { continue; }
            throw new InvalidDataException("La base initialement absente ou un de ses fichiers SQLite est apparu ; aucune substitution.");
        }
    }

    internal void Install(CancellationToken token)
    {
        RequireAbsent(token);
        using var before = SharedParkPublicationFile.BoundFile.Open(Path, SharedParkBackupFiles.MaxSqliteBytes, token, allowDelete: true);
        SharedParkPublicationFile.RequirePrivate(before.Stream.GetAccessControl(), FileSystemRights.FullControl, false);
        // No live SQLite handle or WAL is allowed across the rename. This store was created in rollback-journal mode.
        foreach (var suffix in new[] { "-wal", "-shm", "-journal" })
        { if (File.Exists(Path + suffix)) { throw new InvalidDataException("Fichier SQLite annexe encore présent ; base préparée conservée."); } }
        token.ThrowIfCancellationRequested(); File.Move(Path, target, overwrite: false);
        installed = SharedParkPublicationFile.BoundFile.Open(target, SharedParkBackupFiles.MaxSqliteBytes, token, allowDelete: false);
        if (installed.Identity != before.Identity || installed.Length != before.Length || installed.Sha256 != before.Sha256)
        { throw new InvalidDataException("Base installée différente du fichier préparé ; état incertain."); }
        SharedParkPublicationFile.RequirePrivate(installed.Stream.GetAccessControl(), FileSystemRights.FullControl, false);
    }

    private static SharedParkPublicationFile.PathPins OpenParent(string parent, CancellationToken token)
    {
        var root = System.IO.Path.GetPathRoot(parent)!;
        var pins = new SharedParkPublicationFile.PathPins(root, token);
        try
        {
            var at = root;
            foreach (var segment in parent[root.Length..].Split('\\', StringSplitOptions.RemoveEmptyEntries))
            {
                token.ThrowIfCancellationRequested(); at = System.IO.Path.Combine(at, segment);
                try { _ = File.GetAttributes(at); }
                catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { SharedParkLocalPaths.CreateExclusive(at); }
                pins.Add(at);
            }
            return pins;
        }
        catch { pins.Dispose(); throw; }
    }

    private static void Admit(string root, CancellationToken token)
    {
        var count = 0; long bytes = 0;
        foreach (var directory in Directory.EnumerateFileSystemEntries(root))
        {
            token.ThrowIfCancellationRequested();
            if (++count >= SharedParkBackupFiles.MaxBatches || !WritePlans.IsPlanId(System.IO.Path.GetFileName(directory)))
            { throw new IOException("Quota de 32 bases préparées ou entrée inattendue ; preuves conservées sans nettoyage."); }
            using var held = new SharedParkPublicationFile.PathPins(directory, token);
            SharedParkPublicationFile.RequirePrivate(new DirectoryInfo(directory).GetAccessControl(), FileSystemRights.FullControl, true);
            var files = 0;
            foreach (var file in Directory.EnumerateFileSystemEntries(directory))
            {
                if (++files > 5 || System.IO.Path.GetFileName(file) is not ("prepared.db" or "prepared.db-journal" or "prepared.db-wal" or "prepared.db-shm" or "prepared.db.domenia-write.lock"))
                { throw new InvalidDataException("Entrée inattendue dans une preuve SQLite préparée."); }
                using var read = SharedParkPublicationFile.BoundFile.Open(file, SharedParkBackupFiles.MaxSqliteBytes, token, false);
                bytes = checked(bytes + read.Length);
                if (bytes > SharedParkBackupFiles.MaxRetainedBytes - Reserve) { throw new IOException("Quota de 1 Gio de bases préparées atteint."); }
            }
        }
        if (new DriveInfo(System.IO.Path.GetPathRoot(root)!).AvailableFreeSpace < Reserve + SharedParkBackupFiles.MaxSqliteBytes)
        { throw new IOException("Espace insuffisant pour la base préparée et sa marge privée."); }
    }

    private static FileSecurity PrivateSecurity()
    {
        using var user = WindowsIdentity.GetCurrent();
        SecurityIdentifier[] principals = [user.User ?? throw new IOException("Identité Windows absente."),
            new(WellKnownSidType.LocalSystemSid, null), new(WellKnownSidType.BuiltinAdministratorsSid, null)];
        var security = new FileSecurity(); security.SetAccessRuleProtection(true, false);
        foreach (var sid in principals.DistinctBy(s => s.Value)) { security.AddAccessRule(new(sid, FileSystemRights.FullControl, AccessControlType.Allow)); }
        return security;
    }

    public void Dispose() { installed?.Dispose(); fence?.Dispose(); fence = null; pins.Dispose(); }
}
