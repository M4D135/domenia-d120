using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace Domenia.App;

internal sealed class PackageLifecycleFiles : IDisposable
{
    internal const long MaximumBytes = 8L * 1024 * 1024 * 1024;
    private readonly Dictionary<string, SafeFileHandle> directories = new(StringComparer.OrdinalIgnoreCase);

    internal static string Root(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Length > 512 || !Path.IsPathFullyQualified(path) || path.StartsWith("\\\\", StringComparison.Ordinal)
            || path.Length < 4 || !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\')
        { throw new InvalidDataException("Dossier de livraison local absolu requis."); }
        var value = Path.TrimEndingDirectorySeparator(path);
        if (!PackageIntegrity.ValidRelativePath(value[3..].Replace('\\', '/')) || !string.Equals(value, Path.GetFullPath(value), StringComparison.OrdinalIgnoreCase))
        { throw new InvalidDataException("Dossier de livraison ambigu ou non canonique."); }
        if (new DriveInfo(Path.GetPathRoot(value)!).DriveType is not (DriveType.Fixed or DriveType.Removable))
        { throw new InvalidDataException("La livraison exige un disque local, sans partage réseau."); }
        return value;
    }

    internal void Pin(string path)
    {
        var full = Path.GetFullPath(path);
        if (directories.ContainsKey(full)) { return; }
        var parent = Path.GetDirectoryName(full);
        if (!string.IsNullOrEmpty(parent)) { Pin(parent); }
        Check(full, directory: true);
        var handle = CreateFile(full, 0x80, FileShare.Read | FileShare.Write, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid) { var error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error, "Dossier de livraison non verrouillable."); }
        try { Check(full, directory: true); directories.Add(full, handle); }
        catch { handle.Dispose(); throw; }
    }

    internal void PinTree(string root) => _ = FileNames(root);

    internal string[] FileNames(string root)
    {
        var entries = 0;
        var files = new List<string>();
        void Visit(string folder, int depth)
        {
            if (depth > 32) { throw new InvalidDataException("Arborescence de livraison trop profonde."); }
            Pin(folder);
            foreach (var path in Directory.EnumerateFileSystemEntries(folder))
            {
                if (++entries > 8192) { throw new InvalidDataException("Trop de fichiers dans la livraison."); }
                var attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("Lien ou redirection dans la livraison."); }
                if ((attributes & FileAttributes.Directory) != 0) { Visit(path, depth + 1); }
                else { files.Add(Path.GetRelativePath(root, path).Replace('\\', '/')); }
            }
        }
        Visit(root, 0); return files.ToArray();
    }

    internal static void RefuseDevelopment(string root)
    {
        foreach (var name in new[] { ".git", "src", "tests", "dev", "Domenia.sln", "Directory.Build.props" })
        { if (Exists(Path.Combine(root, name)) || Exists(Path.Combine(root, "wad", name))) { throw new InvalidDataException("Arbre de développement refusé ; aucun fichier retiré ou remplacé."); } }
    }

    internal static bool Exists(string path)
    {
        try { _ = File.GetAttributes(path); return true; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }

    internal static void Check(string path, bool directory = false)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0 || ((attributes & FileAttributes.Directory) != 0) != directory)
        { throw new InvalidDataException("Type de fichier ou redirection de livraison refusé."); }
    }

    internal static string At(string root, string relative)
    {
        if (!PackageIntegrity.ValidRelativePath(relative)) { throw new InvalidDataException("Chemin de composant invalide."); }
        return Path.Combine(root, relative.Replace('/', '\\'));
    }

    internal void MakeDirectory(string path)
    {
        var parent = Path.GetDirectoryName(path)!; Pin(parent);
        if (!Exists(path)) { Directory.CreateDirectory(path); }
        Pin(path);
    }

    internal void PrivateDirectory(string path)
    {
        Pin(Path.GetDirectoryName(path)!);
        if (!Exists(path))
        {
            var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
            foreach (var sid in Principals()) { acl.AddAccessRule(new(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow)); }
            FileSystemAclExtensions.Create(new DirectoryInfo(path), acl);
        }
        Pin(path); RequirePrivate(path);
    }

    internal static void RequirePrivate(string path)
    {
        Check(path, directory: true);
        var acl = new DirectoryInfo(path).GetAccessControl(AccessControlSections.Access);
        var expected = Principals(); var seen = new HashSet<string>(StringComparer.Ordinal);
        if (!acl.AreAccessRulesProtected) { throw new IOException("DACL de sauvegarde non privée ; aucune reprotection implicite."); }
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.IsInherited || rule.AccessControlType != AccessControlType.Allow || rule.FileSystemRights != FileSystemRights.FullControl
                || rule.InheritanceFlags != (InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit) || rule.PropagationFlags != PropagationFlags.None
                || !expected.Any(sid => sid.Equals(rule.IdentityReference)) || !seen.Add(rule.IdentityReference.Value))
            { throw new IOException("DACL de sauvegarde incompatible ; conservation sans modification."); }
        }
        if (seen.Count != expected.Length) { throw new IOException("DACL de sauvegarde incomplète."); }
    }

    private static SecurityIdentifier[] Principals()
    {
        using var identity = WindowsIdentity.GetCurrent();
        SecurityIdentifier[] values = [identity.User ?? throw new IOException("Utilisateur Windows absent."),
            new(WellKnownSidType.LocalSystemSid, null), new(WellKnownSidType.BuiltinAdministratorsSid, null)];
        return values.Distinct().ToArray();
    }

    internal static PackageComponent Measure(string root, string relative, long maximum = MaximumBytes)
    {
        var path = At(root, relative); Check(path);
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan);
        if (file.Length > maximum) { throw new InvalidDataException("Composant de livraison trop volumineux."); }
        return new(relative, file.Length, Convert.ToHexStringLower(SHA256.HashData(file)));
    }

    // Hash and delete the same opened object. A path-based hash followed by File.Delete could remove a replacement
    // written after the comparison. No write/delete sharing is granted until the disposition has been decided.
    internal static bool DeleteMatching(string root, PackageComponent expected)
    {
        var path = At(root, expected.Path); Check(path);
        using var handle = CreateFile(path, 0x80010000, FileShare.Read, IntPtr.Zero, 3, 0x00200000 | 0x08000000, IntPtr.Zero);
        if (handle.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error(), "Fichier non retirable exclusivement."); }
        Check(path);
        using var stream = new FileStream(handle, FileAccess.Read, 65536);
        if (stream.Length != expected.Length || Convert.ToHexStringLower(SHA256.HashData(stream)) != expected.Sha256) { return false; }
        var disposition = new Disposition { Delete = 1 };
        if (!SetFileInformation(handle, 4, ref disposition, 1)) { throw new Win32Exception(Marshal.GetLastWin32Error(), "Suppression du fichier vérifié refusée."); }
        return true;
    }

    internal void Copy(string from, string to, PackageComponent component, CancellationToken token)
    {
        token.ThrowIfCancellationRequested(); Check(from);
        MakeParents(Path.GetDirectoryName(to)!);
        using (var source = new FileStream(from, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan))
        using (var target = new FileStream(to, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 65536, FileOptions.WriteThrough))
        {
            if (source.Length != component.Length || source.Length > MaximumBytes) { throw new InvalidDataException("Taille de copie différente de l’aperçu."); }
            var buffer = new byte[65536]; long copied = 0; int read;
            while ((read = source.Read(buffer)) != 0)
            {
                token.ThrowIfCancellationRequested(); copied += read;
                if (copied > component.Length) { throw new InvalidDataException("Source de copie agrandie."); }
                target.Write(buffer, 0, read);
            }
            target.Flush(true); target.Position = 0;
            if (copied != component.Length || Convert.ToHexStringLower(SHA256.HashData(target)) != component.Sha256)
            { throw new InvalidDataException("Copie relue différente ; aucune activation."); }
        }
        token.ThrowIfCancellationRequested(); Check(to);
    }

    private void MakeParents(string folder)
    {
        if (directories.ContainsKey(folder)) { return; }
        var parent = Path.GetDirectoryName(folder)!; MakeParents(parent); MakeDirectory(folder);
    }

    internal static void WriteNew(string path, byte[] bytes)
    {
        using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough);
        file.Write(bytes); file.Flush(true);
    }

    public void Dispose() { foreach (var handle in directories.Values.Reverse()) { handle.Dispose(); } directories.Clear(); }

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, FileShare share, IntPtr security, uint creation, uint flags, IntPtr template);
    [StructLayout(LayoutKind.Sequential)]
    private struct Disposition { internal byte Delete; }
    [DllImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformation(SafeFileHandle file, int informationClass, ref Disposition information, uint size);
}
