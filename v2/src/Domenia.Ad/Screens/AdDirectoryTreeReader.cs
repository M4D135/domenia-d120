using Domenia.Core;

namespace Domenia.Ad;

/// <summary>
/// OU tree panel in directory mode (docs/OPERATIONS.md § 9 and 10): the pure <see cref="OrganizationalUnitTree"/> of
/// Domenia.Core, built from the OUs alone when the operator opens the panel (one bounded, paged LDAP search).
/// The local index never contacts LDAP, and an OU-scoped object snapshot never replaces this navigation tree.
/// </summary>
public sealed class AdDirectoryTreeReader : IDirectoryTreeReader, IOrganizationalUnitIndex, IDisposable
{
    private readonly AdDirectorySource source;
    private readonly SemaphoreSlim building = new(1, 1);
    private readonly Lock gate = new();
    private (long Epoch, OrganizationalUnitTree Tree)? built;

    /// <summary>Found by ScreenReaders.Discover for the directory source; reads nothing.</summary>
    public AdDirectoryTreeReader(AdDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public async Task<OuChildren> ChildrenAsync(string? dn, CancellationToken cancellationToken)
    {
        var tree = await TreeAsync(cancellationToken).ConfigureAwait(false);
        return tree.Children(dn) ?? throw new DomeniaOperationException(DomeniaErrors.OuUnknown, DomeniaErrors.OuUnknownMessage);
    }

    public async Task<OuSearchResult> SearchAsync(string text, int limit, CancellationToken cancellationToken)
    {
        var tree = await TreeAsync(cancellationToken).ConfigureAwait(false);
        return tree.Search(text, limit);
    }

    public async Task<OuParent> RootAsync(CancellationToken cancellationToken)
    {
        var tree = await TreeAsync(cancellationToken).ConfigureAwait(false);
        return tree.Root;
    }

    public Task<OuEntry?> FindLocalAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        cancellationToken.ThrowIfCancellationRequested();
        OrganizationalUnitTree? known;
        lock (gate)
        {
            known = built is { } cached && cached.Epoch == source.Epoch ? cached.Tree : null;
        }
        // A restored preference must never cause an LDAP read. Opening the picker explicitly populates this index.
        return Task.FromResult(known?.Find(dn));
    }

    public void Dispose() => building.Dispose();

    /// <summary>The OU navigation tree of this session, loaded only by an explicit picker operation.</summary>
    private async Task<OrganizationalUnitTree> TreeAsync(CancellationToken cancellationToken)
    {
        lock (gate)
        {
            if (built is { } known && known.Epoch == source.Epoch)
            {
                return known.Tree;
            }
        }
        await building.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var domain = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
            var epoch = source.Epoch;
            lock (gate)
            {
                if (built is { } known && known.Epoch == epoch)
                {
                    return known.Tree;
                }
            }
            var entries = await source.Connection.SearchAsync(new AdSearchRequest(domain.RootDn, "(objectClass=organizationalUnit)", AdSearchScope.Subtree, AdDirectoryMapper.OuAttributes) { SizeLimit = AdDirectorySource.MaxObjectsPerKind + 1 }, cancellationToken).ConfigureAwait(false);
            var ous = entries.Take(AdDirectorySource.MaxObjectsPerKind).Select(AdDirectoryMapper.Ou).OfType<DirectoryOu>().ToArray();
            var basis = new DirectorySnapshot(domain, source.Clock.GetUtcNow(), entries.Count <= AdDirectorySource.MaxObjectsPerKind && ous.Length == entries.Count, [.. ous], [], [], []);
            var tree = OrganizationalUnitTree.Build(basis);
            lock (gate)
            {
                built = (epoch, tree);
            }
            return tree;
        }
        finally
        {
            building.Release();
        }
    }
}
