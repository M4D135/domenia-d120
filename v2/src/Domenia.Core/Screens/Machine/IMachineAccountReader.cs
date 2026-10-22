using System.Collections.Immutable;
using System.Security;

namespace Domenia.Core;

/// <summary>
/// One access trial, as the engine sends it to the reader: the workstation, the source and name of the account, and its password
/// as a SecureString (null for the Windows session, and always null in simulation). Never serialized, never logged.
/// </summary>
public sealed record MachineProbeRequest(string Computer, MachineAccountSource Source, string Account, SecureString? Password);

/// <summary>
/// Read interface of the workstation account screen (docs/ops/schema.md, « Comptes machine »). Served by the simulated
/// directory now (Domenia.Simulation/Screens/Machine), by the local base and one light CIM read later (vague 3,
/// Domenia.Inventory). Read only by construction: a trial reads the system of one workstation, it never changes anything.
/// </summary>
public interface IMachineAccountReader : IScreenReader
{
    /// <summary>A workstation of the directory by name, DNS name or name with the domain (local base, never the network).</summary>
    Task<MachineWorkstation?> FindWorkstationAsync(string computer, CancellationToken cancellationToken);

    /// <summary>Workstations whose name starts with or contains the text, at most <paramref name="limit"/> (local base).</summary>
    Task<ImmutableArray<MachineWorkstation>> SearchWorkstationsAsync(string text, int limit, CancellationToken cancellationToken);

    /// <summary>
    /// One light read of one workstation with the account given (Domenia 1 FO-19: Win32_OperatingSystem.Caption over CIM/DCOM,
    /// 6 s per method, no fallback, no sweep). Network read in directory mode, after the operator’s click only.
    /// </summary>
    Task<MachineTrialObservation> ProbeAccessAsync(MachineProbeRequest request, CancellationToken cancellationToken);
}
