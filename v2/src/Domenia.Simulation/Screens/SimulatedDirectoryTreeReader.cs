using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// OU tree panel in simulation (docs/OPERATIONS.md § 9 and 10): derived from the fictitious directory only, in memory,
/// no network and no disk. The tree is built once, at the first call (off the UI thread), by the pure
/// <see cref="OrganizationalUnitTree"/> of Domenia.Core; each read of the panel waits a short realistic delay
/// (« latency/screen/tree »). It is also the local OU index of the simulation (<see cref="IOrganizationalUnitIndex"/>).
/// </summary>
public sealed class SimulatedDirectoryTreeReader : IDirectoryTreeReader, IOrganizationalUnitIndex
{
    private const string LatencyKind = "tree";
    private const int MinDelayMilliseconds = 60;
    private const int MaxDelayMilliseconds = 160;

    private readonly SimulatedDirectorySource source;
    private readonly Lazy<OrganizationalUnitTree> tree;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedDirectoryTreeReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
        // The directory never changes during a session: one tree for the whole session.
        tree = new Lazy<OrganizationalUnitTree>(() => OrganizationalUnitTree.Build(source.World.Directory), LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public async Task<OuChildren> ChildrenAsync(string? dn, CancellationToken cancellationToken)
    {
        await WaitAsync(cancellationToken).ConfigureAwait(false);
        return tree.Value.Children(dn) ?? throw new DomeniaOperationException(DomeniaErrors.OuUnknown, DomeniaErrors.OuUnknownMessage);
    }

    public async Task<OuSearchResult> SearchAsync(string text, int limit, CancellationToken cancellationToken)
    {
        await WaitAsync(cancellationToken).ConfigureAwait(false);
        return tree.Value.Search(text, limit);
    }

    public Task<OuEntry?> FindLocalAsync(string dn, CancellationToken cancellationToken)
    {
        // Used to check a choice or a remembered OU: answered at once, the delay belongs to the panel reads.
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(tree.Value.Find(dn));
    }

    public Task<OuParent> RootAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(tree.Value.Root);
    }

    private Task WaitAsync(CancellationToken cancellationToken) =>
        source.SimulateScreenLatencyAsync(LatencyKind, MinDelayMilliseconds, MaxDelayMilliseconds, cancellationToken);
}
