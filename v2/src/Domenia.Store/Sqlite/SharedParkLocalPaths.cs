using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;

namespace Domenia.Store;

/// <summary>Only local, explicitly owned directories. Existing ACLs are verified, never repaired or adopted silently.</summary>
internal static class SharedParkLocalPaths
{
    internal static SharedParkPublicationFile.PathPins Open(string directory, string privateFrom, bool create, CancellationToken token)
    {
        var full = System.IO.Path.GetFullPath(directory); var boundary = System.IO.Path.GetFullPath(privateFrom);
        if (directory != full || privateFrom != boundary || !full.StartsWith(boundary + "\\", StringComparison.OrdinalIgnoreCase) && full != boundary
            || full.Split('\\').Any(c => c.Equals("dev", StringComparison.OrdinalIgnoreCase)))
        { throw new InvalidDataException("Dossier privé local canonique attendu, hors dev."); }
        CompatibleDirectoryCache.ValidateLocalPath(System.IO.Path.Combine(full, "probe.tsv"));
        var root = System.IO.Path.GetPathRoot(full)!;
        var pins = new SharedParkPublicationFile.PathPins(root, token);
        try
        {
            var at = root;
            foreach (var component in full[root.Length..].Split('\\', StringSplitOptions.RemoveEmptyEntries))
            {
                token.ThrowIfCancellationRequested(); at = System.IO.Path.Combine(at, component);
                var owned = at.Equals(boundary, StringComparison.OrdinalIgnoreCase) || at.StartsWith(boundary + "\\", StringComparison.OrdinalIgnoreCase);
                try { _ = File.GetAttributes(at); }
                catch (Exception ex) when (create && ex is FileNotFoundException or DirectoryNotFoundException)
                { CreateExclusive(at); }
                pins.Add(at);
                if (owned) { SharedParkPublicationFile.RequirePrivate(new DirectoryInfo(at).GetAccessControl(AccessControlSections.Access), FileSystemRights.FullControl, true); }
            }
            token.ThrowIfCancellationRequested(); return pins;
        }
        catch { pins.Dispose(); throw; }
    }

    internal static void CreateExclusive(string path)
    {
        using var identity = WindowsIdentity.GetCurrent();
        SecurityIdentifier[] principals = [identity.User ?? throw new IOException("Identité Windows absente."),
            new(WellKnownSidType.LocalSystemSid, null), new(WellKnownSidType.BuiltinAdministratorsSid, null)];
        var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
        foreach (var principal in principals.DistinctBy(p => p.Value))
        { security.AddAccessRule(new FileSystemAccessRule(principal, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow)); }
        var held = GCHandle.Alloc(security.GetSecurityDescriptorBinaryForm(), GCHandleType.Pinned);
        try
        {
            var attributes = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = held.AddrOfPinnedObject() };
            if (!CreateDirectory(path, ref attributes)) { throw new IOException("Dossier local privé non créé exclusivement.", new Win32Exception(Marshal.GetLastWin32Error())); }
        }
        finally { held.Free(); }
    }

    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { internal int Length; internal IntPtr Descriptor; internal int Inherit; }
    [DllImport("kernel32.dll", EntryPoint = "CreateDirectoryW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateDirectory(string path, ref SecurityAttributes attributes);
}
