using System.Globalization;
using System.Management;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Inventory;

public sealed partial class CimSession
{
    // This context exists in the host only. The child reports facts and never retains a second capability cache.
    private readonly WorkstationCapabilityMemory.Context? capabilities = WorkstationCapabilityMemory.Current;
    private bool capabilityIdentity;
    private string? capabilityBuild;
    internal bool ForceCapabilities { get; set; }

    private CimReading? RememberedCapability(string category, string ns, string wql)
    {
        if (ForceCapabilities || capabilities is null || cancellationToken.IsCancellationRequested) { return null; }
        var type = WqlRules.Parse(wql).ClassName;
        // Read these again to prove the current identity and notice a Windows build change. A protocol failure can
        // still suspend them; the explicit full inventory bypasses that memory as well.
        var bootstrap = ns.Equals(@"root\cimv2", StringComparison.OrdinalIgnoreCase)
            && (type.Equals("Win32_ComputerSystem", StringComparison.OrdinalIgnoreCase) || type.Equals("Win32_OperatingSystem", StringComparison.OrdinalIgnoreCase));
        var fact = capabilities.Find(Host, Transport.ToString(), ns + "|" + type, capabilityBuild, credential?.Account, capabilityIdentity && !bootstrap);
        if (fact is null) { return null; }
        var reason = fact.Failure switch
        {
            WorkstationCapabilityFailure.ClassAbsent => "classe ou espace de noms absent lors d’une lecture précédente",
            WorkstationCapabilityFailure.ProtocolUnreachable => "protocole CIM inaccessible lors d’une lecture précédente",
            _ => "droit refusé lors d’une lecture précédente",
        };
        return new(category, SourceStatus.Skipped, "Non relu : " + reason + ". Mémoire de cette session jusqu’au "
            + fact.Until.ToUniversalTime().ToString("dd/MM HH:mm", CultureInfo.InvariantCulture) + " UTC ; un inventaire complet force la relecture.", 0, []);
    }

    private void ObserveCapability(string ns, string wql, CimReading reading)
    {
        if (capabilities is null || cancellationToken.IsCancellationRequested || nativeStopped || disposed || OutOfBudget) { return; }
        var type = WqlRules.Parse(wql).ClassName;
        var key = ns + "|" + type;
        var complete = (reading.Status is SourceStatus.Ok or SourceStatus.Empty) && !reading.AuthenticationRejected;
        if (complete)
        {
            capabilities.Success(Host, Transport.ToString(), key);
            if (ns.Equals(@"root\cimv2", StringComparison.OrdinalIgnoreCase) && reading.Status == SourceStatus.Ok && reading.Items == 1)
            {
                var row = reading.Instances[0];
                if (type.Equals("Win32_OperatingSystem", StringComparison.OrdinalIgnoreCase) && row.Text("BuildNumber") is { Length: > 0 and <= 64 } build && build.All(char.IsAsciiDigit))
                { capabilityBuild = build; }
                if (type.Equals("Win32_ComputerSystem", StringComparison.OrdinalIgnoreCase) && row.Text("Name") is { Length: > 0 and <= 255 } name)
                { capabilityIdentity = CimQuery.IsHostName(name) && string.Equals(Host.Split('.')[0], name.Split('.')[0], StringComparison.OrdinalIgnoreCase); }
                if (capabilityIdentity && capabilityBuild is not null) { capabilities.ObserveBuild(Host, Transport.ToString(), capabilityBuild); }
            }
            return;
        }
        if (reading.Items != 0 || !FactMatches(reading) || reading.CapabilityFailure == WorkstationCapabilityFailure.None) { return; }
        if (reading.CapabilityFailure == WorkstationCapabilityFailure.ClassAbsent && !capabilityIdentity) { return; }
        capabilities.Record(Host, Transport.ToString(), key, reading.CapabilityFailure, capabilityBuild, credential?.Account,
            protocolWide: !capabilityIdentity || reading.CapabilityFailure == WorkstationCapabilityFailure.ProtocolUnreachable);
    }

    private static bool FactMatches(CimReading reading) => reading.CapabilityFailure switch
    {
        WorkstationCapabilityFailure.None => true,
        WorkstationCapabilityFailure.ClassAbsent => reading.Status == SourceStatus.Unavailable && !reading.AuthenticationRejected,
        WorkstationCapabilityFailure.ProtocolUnreachable => reading.Status == SourceStatus.Unreachable && !reading.AuthenticationRejected,
        WorkstationCapabilityFailure.RightDenied => reading.Status == SourceStatus.Refused,
        _ => false,
    };

    private static WorkstationCapabilityFailure CapabilityFailure(Exception exception, SourceStatus outcome) => exception switch
    {
        ManagementException { ErrorCode: ManagementStatus.InvalidClass or ManagementStatus.InvalidNamespace } => WorkstationCapabilityFailure.ClassAbsent,
        System.Runtime.InteropServices.COMException { HResult: unchecked((int)0x80041010) or unchecked((int)0x8004100E) } => WorkstationCapabilityFailure.ClassAbsent,
        _ when outcome == SourceStatus.Unreachable => WorkstationCapabilityFailure.ProtocolUnreachable,
        _ when outcome == SourceStatus.Refused => WorkstationCapabilityFailure.RightDenied,
        _ => WorkstationCapabilityFailure.None,
    };
}
