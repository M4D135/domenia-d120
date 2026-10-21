namespace Domenia.Core;

/// <summary>
/// Local index of the OUs: checks a working OU (chosen in the panel, or remembered in the preferences) without any directory
/// read. Served from memory in simulation (Domenia.Simulation, Screens/SimulatedDirectoryTreeReader.cs) and by the local
/// base in directory mode. It must never touch the network: session.info and dashboard.summary (LocalRead) go through it
/// when the page loads, without any operator gesture (docs/OPERATIONS.md § 11).
/// </summary>
public interface IOrganizationalUnitIndex : IScreenReader
{
    /// <summary>The OU with this DN (escaping and case ignored) as known locally, or null when it is not known.</summary>
    Task<OuEntry?> FindLocalAsync(string dn, CancellationToken cancellationToken);
}
