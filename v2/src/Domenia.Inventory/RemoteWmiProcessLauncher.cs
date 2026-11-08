using System.Diagnostics;
using System.Globalization;
using System.Management;
using Domenia.Core;

namespace Domenia.Inventory;

internal sealed record RemoteProcessIdentity(uint Pid, string CreationDate, string CommandLine);
internal interface IRemoteProcessWire : IDisposable
{
    string Connect(CancellationToken token);
    uint Create(string command);
    RemoteProcessIdentity? Read(uint pid);
}

/// <summary>Dedicated, consented Win32_Process.Create primitive; never exposed by the SELECT-only CIM channel.</summary>
internal sealed class RemoteWmiProcessLauncher : IRemoteScriptLauncher
{
    private readonly IRemoteProcessWire wire;
    private uint? pid;
    private RemoteProcessIdentity? identity;
    private bool attempted, finished;
    private string? expectedCommand;

    internal RemoteWmiProcessLauncher(string host, RemoteProbeCredential? credential) : this(new NativeProcessWire(host, credential)) { }
    internal RemoteWmiProcessLauncher(IRemoteProcessWire wire) => this.wire = wire;
    public string Preflight(CancellationToken token) => wire.Connect(token);
    public void Start(string command, CancellationToken token)
    {
        if (attempted) { throw new InvalidOperationException("Création WMI déjà tentée."); }
        token.ThrowIfCancellationRequested(); expectedCommand = command; attempted = true;
        pid = wire.Create(command);
        if (pid == 0) { throw new InvalidDataException("PID de création WMI absent."); }
        Observe();
    }

    private void Observe()
    {
        if (finished || pid is not { } processId) { return; }
        var current = wire.Read(processId);
        if (current is null) { finished = true; return; }
        if (current.Pid != processId || string.IsNullOrWhiteSpace(current.CreationDate))
        { throw new InvalidDataException("Identité de processus WMI incomplète ; aucun arrêt par PID."); }
        if (identity is not null)
        {
            // A recycled PID proves the original ended, but never authorizes touching its successor.
            if (current.CreationDate != identity.CreationDate) { finished = true; return; }
            if (current.CommandLine != identity.CommandLine) { throw new InvalidDataException("Processus WMI modifié ; aucun arrêt par PID."); }
            return;
        }
        if (current.CommandLine != expectedCommand) { throw new InvalidDataException("Propriétaire du PID WMI non confirmé ; aucun arrêt par PID."); }
        identity = current;
    }
    public bool Finished { get { Observe(); return finished; } }
    public bool CloseOwned()
    {
        if (!attempted) { return true; }
        if (pid is null) { return false; } // Lost Create response, not evidence of a failed creation.
        var watch = Stopwatch.StartNew();
        do { Observe(); if (finished) { return true; } Thread.Sleep(100); } while (watch.Elapsed < TimeSpan.FromSeconds(3));
        return false; // No Terminate method: querying a PID then terminating it cannot fence PID reuse atomically.
    }
    public void Dispose() => wire.Dispose();

    private sealed class NativeProcessWire(string host, RemoteProbeCredential? credential) : IRemoteProcessWire
    {
        private ManagementScope? scope;
        private readonly ConnectionOptions options = new()
        {
            Impersonation = ImpersonationLevel.Impersonate, Authentication = AuthenticationLevel.PacketPrivacy,
            EnablePrivileges = false, Timeout = TimeSpan.FromSeconds(5),
        };
        public string Connect(CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (credential is { Session: false }) { options.Username = credential.Account; options.SecurePassword = credential.Password; }
            scope = new(@"\\" + host + @"\root\cimv2", options); scope.Connect(); token.ThrowIfCancellationRequested();
            using var search = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT WindowsDirectory FROM Win32_OperatingSystem"), Enumeration());
            using var rows = search.Get(); string? folder = null; var count = 0;
            foreach (ManagementBaseObject row in rows) { using (row) { token.ThrowIfCancellationRequested(); folder = row["WindowsDirectory"] as string; count++; } }
            if (count != 1 || folder is null) { throw new InvalidDataException("Répertoire Windows distant absent ou ambigu."); }
            return RemoteScriptPlan.WindowsFolder(folder);
        }
        public uint Create(string command)
        {
            using var type = new ManagementClass(scope!, new ManagementPath("Win32_Process"), null);
            using var input = type.GetMethodParameters("Create"); input["CommandLine"] = command;
            using var result = type.InvokeMethod("Create", input, new InvokeMethodOptions { Timeout = TimeSpan.FromSeconds(10) });
            var code = CreationCode(result["ReturnValue"]);
            if (code is 2 or 3) { throw new UnauthorizedAccessException("Création WMI refusée par le poste."); }
            if (code != 0 || result["ProcessId"] is null) { throw new IOException("Création WMI non confirmée (code " + code.ToString(CultureInfo.InvariantCulture) + ")."); }
            return Convert.ToUInt32(result["ProcessId"], CultureInfo.InvariantCulture);
        }
        public RemoteProcessIdentity? Read(uint pid)
        {
            using var search = new ManagementObjectSearcher(scope!, new ObjectQuery("SELECT ProcessId,CreationDate,CommandLine FROM Win32_Process WHERE ProcessId=" + pid.ToString(CultureInfo.InvariantCulture)), Enumeration());
            using var rows = search.Get(); RemoteProcessIdentity? result = null;
            foreach (ManagementBaseObject row in rows)
            {
                using (row)
                {
                    if (result is not null) { throw new InvalidDataException("PID WMI ambigu."); }
                    result = new(Convert.ToUInt32(row["ProcessId"], CultureInfo.InvariantCulture), row["CreationDate"] as string ?? "", row["CommandLine"] as string ?? "");
                }
            }
            return result;
        }
        private static System.Management.EnumerationOptions Enumeration() => new() { Timeout = TimeSpan.FromSeconds(3), ReturnImmediately = true, Rewindable = false, BlockSize = 1 };
        public void Dispose() { if (scope is not null) { scope.Options.SecurePassword = null; } options.SecurePassword = null; scope = null; }
    }

    internal static uint CreationCode(object? value) => value is uint code ? code
        : throw new InvalidDataException("Code de création WMI absent ou non uint32 ; issue inconnue.");
}
