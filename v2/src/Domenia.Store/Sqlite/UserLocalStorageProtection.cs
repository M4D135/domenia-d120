using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;

namespace Domenia.Store;

/// <summary>Private creation for the selected profile store. Existing ACLs are inspected, never narrowed or repaired.</summary>
internal sealed class UserLocalStorageProtection(string root)
{
    private readonly string root = System.IO.Path.GetFullPath(root);

    internal bool Contains(string path)
    {
        var relative = System.IO.Path.GetRelativePath(root, System.IO.Path.GetFullPath(path));
        return !System.IO.Path.IsPathRooted(relative) && relative != ".." && !relative.StartsWith(".." + System.IO.Path.DirectorySeparatorChar, StringComparison.Ordinal);
    }

    private static SecurityIdentifier[] Principals()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return [identity.User ?? throw new IOException("Identité Windows indisponible pour le stockage privé."),
            new(WellKnownSidType.LocalSystemSid, null), new(WellKnownSidType.BuiltinAdministratorsSid, null)];
    }

    private static DirectorySecurity DirectoryAcl()
    {
        var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
        foreach (var sid in Principals().DistinctBy(p => p.Value))
            security.AddAccessRule(new(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        return security;
    }
    private static FileSecurity FileAcl()
    {
        var security = new FileSecurity(); security.SetAccessRuleProtection(true, false);
        foreach (var sid in Principals().DistinctBy(p => p.Value)) security.AddAccessRule(new(sid, FileSystemRights.FullControl, AccessControlType.Allow));
        return security;
    }
    internal static void Verify(FileSystemSecurity security)
    {
        var allowed = Principals().Select(p => p.Value).ToHashSet(StringComparer.Ordinal);
        var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        if (security.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner || !allowed.Contains(owner.Value)
            || rules.Length == 0 || rules.Any(r => r.AccessControlType != AccessControlType.Allow || !allowed.Contains(r.IdentityReference.Value)))
            throw new IOException("Droits privés du stockage utilisateur non confirmés ; aucune écriture et aucun retrait automatique d’accès existant.");
    }

    internal void PrepareDirectory(string path, CancellationToken token)
    {
        if (!Contains(path)) return;
        CompatibleDirectoryCache.ValidateLocalPath(path);
        // A missing boundary may be below an existing general parent: create each missing directory
        // with its private descriptor, without ever changing that parent's permissions.
        var missing = new Stack<DirectoryInfo>();
        var at = new DirectoryInfo(System.IO.Path.GetDirectoryName(path)!);
        while (!at.Exists)
        {
            missing.Push(at);
            at = at.Parent ?? throw new IOException("Racine locale absente.");
        }
        if (Contains(System.IO.Path.Combine(at.FullName, "acl-check"))) Verify(at.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner));
        while (missing.TryPop(out var next))
        {
            token.ThrowIfCancellationRequested();
            CompatibleDirectoryCache.ValidateLocalPath(System.IO.Path.Combine(next.FullName, "acl-check"));
            CreatePrivate(next.FullName);
            Verify(next.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner));
        }
        for (var directory = new DirectoryInfo(System.IO.Path.GetDirectoryName(path)!); directory is not null && Contains(System.IO.Path.Combine(directory.FullName, "acl-check")); directory = directory.Parent)
            Verify(directory.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner));
    }

    internal void PrepareFile(string path, CancellationToken token)
    {
        if (!Contains(path)) return;
        PrepareDirectory(path, token); token.ThrowIfCancellationRequested();
        CompatibleDirectoryCache.ValidateLocalPath(path);
        // Validate companions before creating even an empty database; an existing orphan must not be followed by SQLite.
        foreach (var suffix in new[] { "-journal", "-wal", "-shm" })
        {
            var companion = path + suffix;
            CompatibleDirectoryCache.ValidateLocalPath(companion);
            try { _ = File.GetAttributes(companion); }
            catch (FileNotFoundException) { continue; }
            Verify(new FileInfo(companion).GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner));
        }
        try { _ = File.GetAttributes(path); }
        catch (FileNotFoundException)
        {
            using var created = new FileInfo(path).Create(FileMode.CreateNew, FileSystemRights.FullControl, FileShare.ReadWrite,
                4096, FileOptions.WriteThrough, FileAcl());
            Verify(created.GetAccessControl());
            return;
        }
        Verify(new FileInfo(path).GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner));
    }

    private static void CreatePrivate(string path)
    {
        var bytes = DirectoryAcl().GetSecurityDescriptorBinaryForm(); var pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try
        {
            var attributes = new Native.SecurityAttributes { Length = Marshal.SizeOf<Native.SecurityAttributes>(), Descriptor = pin.AddrOfPinnedObject() };
            if (!Native.CreateDirectory(path, ref attributes))
            {
                var error = Marshal.GetLastWin32Error();
                if (error != 183) throw new IOException("Création du dossier privé refusée.", new Win32Exception(error));
                // A concurrent creator won: inspect its result, never overwrite its descriptor.
                CompatibleDirectoryCache.ValidateLocalPath(System.IO.Path.Combine(path, "acl-check"));
            }
        }
        finally { pin.Free(); }
    }

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)] internal struct SecurityAttributes { internal int Length; internal IntPtr Descriptor; internal int Inherit; }
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("kernel32.dll", EntryPoint = "CreateDirectoryW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CreateDirectory(string path, ref SecurityAttributes attributes);
    }
}
