using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// OU tree panel in simulation (docs/OPERATIONS.md § 9 and 10): derived from the fictitious directory only, in memory,
/// no network and no disk. The tree is built at the first call (off the UI thread) by the pure
/// <see cref="OrganizationalUnitTree"/> of Domenia.Core, from the directory as the session sees it
/// (<see cref="SimulatedDirectorySource.CurrentDirectory"/>), and built again only after a write of the simulation changed
/// the overlay; each read of the panel waits a short realistic delay (« latency/screen/tree »). It is also the local OU
/// index of the simulation (<see cref="IOrganizationalUnitIndex"/>).
/// </summary>
public sealed class SimulatedDirectoryTreeReader : IDirectoryTreeReader, IOrganizationalUnitIndex
{
    private const string LatencyKind = "tree";
    private const int MinDelayMilliseconds = 60;
    private const int MaxDelayMilliseconds = 160;

    private readonly SimulatedDirectorySource source;
    private readonly Lock gate = new();
    // Tree of the directory at one version of the overlay (writes of the session); built again when the version changes.
    private (long Version, OrganizationalUnitTree Tree)? built;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedDirectoryTreeReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public async Task<OuChildren> ChildrenAsync(string? dn, CancellationToken cancellationToken)
    {
        await WaitAsync(cancellationToken).ConfigureAwait(false);
        return Current().Children(dn) ?? throw new DomeniaOperationException(DomeniaErrors.OuUnknown, DomeniaErrors.OuUnknownMessage);
    }

    public async Task<OuSearchResult> SearchAsync(string text, int limit, CancellationToken cancellationToken)
    {
        await WaitAsync(cancellationToken).ConfigureAwait(false);
        return Current().Search(text, limit);
    }

    public Task<OuEntry?> FindLocalAsync(string dn, CancellationToken cancellationToken)
    {
        // Used to check a choice or a remembered OU: answered at once, the delay belongs to the panel reads.
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(Current().Find(dn));
    }

    public Task<OuParent> RootAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(Current().Root);
    }

    /// <summary>Tree of the directory as the session sees it; one build per version of the overlay.</summary>
    private OrganizationalUnitTree Current()
    {
        lock (gate)
        {
            var version = source.Overlay.Version;
            if (built is not { } known || known.Version != version)
            {
                known = (version, OrganizationalUnitTree.Build(source.CurrentDirectory));
                built = known;
            }
            return known.Tree;
        }
    }

    private Task WaitAsync(CancellationToken cancellationToken) =>
        source.SimulateScreenLatencyAsync(LatencyKind, MinDelayMilliseconds, MaxDelayMilliseconds, cancellationToken);
}
