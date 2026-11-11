using System.Management;
using System.Runtime.InteropServices;
using System.Xml;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries.Wmi;
using Microsoft.CSharp.RuntimeBinder;

namespace Domenia.Inventory;

/// <summary>
/// Cold-path preparation of a reading process, run once during its startup, before the handshake and before any request
/// budget runs. Bench of 11/11/2026 (workstation without a WinRM listener): the first source of a fresh reading process took
/// 9.5 s in DCOM against 0.15 s for the same queries read directly, and in WinRM that one-time cost plus a 4.2 s refusal
/// (0x80338012) passed the first request's deadline, so every source ended « Interrompu ». Loading and compiling the read
/// path here moves that cost into the startup bound (<see cref="CimBudgets.WorkerStartup"/>). Nothing leaves the process:
/// no session, connection, name resolution or query is made.
/// </summary>
internal static class NativeReadWarmup
{
    private const string Namespace = @"root\cimv2";
    private const string Sample = "SELECT Caption FROM Win32_OperatingSystem";

    internal static void Run(InventoryTransport transport)
    {
        NativeReadProtocol.Prime();
        _ = CimQuery.IsReadOnlySelect(Sample, Namespace);
        _ = WqlRules.Parse(Sample);
        try
        {
            if (transport == InventoryTransport.WinRm) { WsmanReadChannel.Prime(); }
            else
            {
                // Object construction only: Connect and Get, which contact the workstation, are not called.
                _ = new ManagementScope(@"\\.\" + Namespace, new ConnectionOptions { Impersonation = ImpersonationLevel.Impersonate, Authentication = AuthenticationLevel.PacketPrivacy });
                _ = new ObjectQuery(Sample);
                _ = new System.Management.EnumerationOptions { ReturnImmediately = true, Rewindable = false, BlockSize = 1 };
            }
        }
        // Preparation is an optimisation, never a gate: a component that fails here fails again on the first real request,
        // which reports it with its own status and code.
        catch (Exception ex) when (ex is COMException or ArgumentException or InvalidCastException or RuntimeBinderException
            or XmlException or ManagementException or UnauthorizedAccessException) { }
    }
}
