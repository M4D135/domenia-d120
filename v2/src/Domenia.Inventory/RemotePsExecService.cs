using System.ComponentModel;
using System.Runtime.InteropServices;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>Read-only SCM/ADMIN$ qualification. Never creates, stops or deletes a service or its binary.</summary>
internal sealed class RemotePsExecService(RemoteTaskReadPlan plan) : IDisposable
{
    private IntPtr manager;
    internal string WindowsFolder { get; private set; } = "";
    internal bool Observed { get; private set; }
    private string Binary => @"\\" + plan.Host + @"\ADMIN$\" + RemotePsExecPlan.ServiceFile(plan);

    internal void Connect(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var status = NetShareGetInfo(@"\\" + plan.Host, "ADMIN$", 2, out var buffer);
        try
        {
            if (status != 0) { throw new Win32Exception(status); }
            WindowsFolder = Marshal.PtrToStringUni(Marshal.PtrToStructure<ShareInfo>(buffer).Path) ?? throw new IOException("Chemin ADMIN$ non lisible.");
            _ = RemotePsExecPlan.Arguments(plan, WindowsFolder);
        }
        finally { if (buffer != IntPtr.Zero) { NetApiBufferFree(buffer); } }
        token.ThrowIfCancellationRequested(); manager = OpenSCManagerW(@"\\" + plan.Host, null, 1);
        if (manager == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
    }

    internal void Preflight(CancellationToken token)
    {
        Connect(token); var service = Open();
        try { if (service != IntPtr.Zero || Attributes(Binary) is not null) { throw new IOException("Service ou binaire PsExec déjà présent ; aucune adoption ni suppression."); } }
        finally { if (service != IntPtr.Zero) { CloseServiceHandle(service); } }
    }

    internal void Observe()
    {
        var service = Open(); if (service == IntPtr.Zero) { return; }
        try
        {
            if (QueryServiceConfigW(service, IntPtr.Zero, 0, out var size) || Marshal.GetLastWin32Error() != 122 || size is < 1 or > 65_536)
            { throw new IOException("Configuration du service PsExec hors limites."); }
            var buffer = Marshal.AllocHGlobal((int)size);
            try
            {
                if (!QueryServiceConfigW(service, buffer, size, out _)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                var config = Marshal.PtrToStructure<ServiceConfig>(buffer);
                var binary = Marshal.PtrToStringUni(config.BinaryPath) ?? ""; var account = Marshal.PtrToStringUni(config.Account) ?? "";
                if (!Matches(plan, WindowsFolder, binary, account, config.Type, config.Start)) { throw new IOException("Service PsExec différent du plan ; aucun nettoyage arbitraire."); }
                var attributes = Attributes(Binary);
                // The launcher's own teardown can unlink the binary after a previously qualified observation.
                if (attributes is null && Observed) { return; }
                if (attributes is null || (attributes.Value & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                { throw new IOException("Binaire du service distant absent ou indirect."); }
                Observed = true;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        finally { CloseServiceHandle(service); }
    }

    internal static bool Matches(RemoteTaskReadPlan plan, string windows, string binary, string account, uint type, uint start)
    {
        if (binary.Length >= 2 && binary[0] == '"' && binary[^1] == '"') { binary = binary[1..^1]; }
        return type == 0x10 && start == 3 && (account.Equals("LocalSystem", StringComparison.OrdinalIgnoreCase) || account.Equals(@"NT AUTHORITY\SYSTEM", StringComparison.OrdinalIgnoreCase))
            && binary.Equals(windows + "\\" + RemotePsExecPlan.ServiceFile(plan), StringComparison.OrdinalIgnoreCase);
    }

    internal bool ArtifactsAbsent()
    {
        var service = Open();
        try { return service == IntPtr.Zero && Attributes(Binary) is null; }
        finally { if (service != IntPtr.Zero) { CloseServiceHandle(service); } }
    }
    private IntPtr Open()
    {
        if (manager == IntPtr.Zero) { throw new InvalidOperationException("SCM non qualifié."); }
        var value = OpenServiceW(manager, RemotePsExecPlan.ServiceName(plan), 1);
        if (value == IntPtr.Zero && Marshal.GetLastWin32Error() != 1060) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        return value;
    }
    private static FileAttributes? Attributes(string path)
    { try { return File.GetAttributes(path); } catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { return null; } }
    public void Dispose() { if (manager != IntPtr.Zero) { CloseServiceHandle(manager); manager = IntPtr.Zero; } }

    [StructLayout(LayoutKind.Sequential)]
    private struct ShareInfo { internal IntPtr Name; internal uint Type; internal IntPtr Remark; internal uint Permissions, MaxUses, Uses; internal IntPtr Path, Password; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceConfig { internal uint Type, Start, Error; internal IntPtr BinaryPath, Group; internal uint Tag; internal IntPtr Dependencies, Account, Name; }
    [DllImport("netapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern int NetShareGetInfo(string server, string name, int level, out IntPtr buffer);
    [DllImport("netapi32.dll", ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern int NetApiBufferFree(IntPtr buffer);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern IntPtr OpenSCManagerW(string server, string? database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern IntPtr OpenServiceW(IntPtr manager, string name, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceConfigW(IntPtr service, IntPtr config, uint length, out uint needed);
    [DllImport("advapi32.dll", ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(IntPtr handle);
}
