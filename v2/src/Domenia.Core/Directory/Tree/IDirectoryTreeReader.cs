namespace Domenia.Core;

/// <summary>
/// Read interface of the OU tree panel (working OU, docs/OPERATIONS.md § 9 and 10). Served by the simulated directory
/// now (Domenia.Simulation, Screens/SimulatedDirectoryTreeReader.cs), by Active Directory later: in directory mode these
/// reads are network reads, made only once the operator opens the panel. Checking a working OU without a gesture goes
/// through <see cref="IOrganizationalUnitIndex"/>, never through this interface.
/// </summary>
public interface IDirectoryTreeReader : IScreenReader
{
    /// <summary>Child OUs of an OU, or of the domain root when <paramref name="dn"/> is null; ou.unknown when absent.</summary>
    Task<OuChildren> ChildrenAsync(string? dn, CancellationToken cancellationToken);

    /// <summary>OUs whose name or path contains the text, accent and case insensitive, at most <paramref name="limit"/>.</summary>
    Task<OuSearchResult> SearchAsync(string text, int limit, CancellationToken cancellationToken);

    /// <summary>The domain root as a parent (DN, DNS name, path).</summary>
    Task<OuParent> RootAsync(CancellationToken cancellationToken);
}
