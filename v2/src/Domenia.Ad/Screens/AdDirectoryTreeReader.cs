using Domenia.Core;

namespace Domenia.Ad;

/// <summary>
/// OU tree panel in directory mode (docs/OPERATIONS.md § 9 and 10): the pure <see cref="OrganizationalUnitTree"/> of
/// Domenia.Core, built from the last directory picture of the session (<see cref="AdDirectorySource.CurrentDirectory"/>), or,
/// before the first read of the directory, from the OUs alone, read once when the operator opens the panel (one paged LDAP
/// search of the organizational units of the domain). It is also the OU index of the session (<see cref="IOrganizationalUnitIndex"/>):
/// a remembered OU is checked against the tree already built, else by one base read of that OU.
/// </summary>
public sealed class AdDirectoryTreeReader : IDirectoryTreeReader, IOrganizationalUnitIndex, IDisposable
{
    private readonly AdDirectorySource source;
    private readonly SemaphoreSlim building = new(1, 1);
    private readonly Lock gate = new();
    private (DirectorySnapshot Basis, OrganizationalUnitTree Tree)? built;

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

    public async Task<OuEntry?> FindLocalAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        OrganizationalUnitTree? known;
        lock (gate)
        {
            known = built?.Tree;
        }
        if (known is not null)
        {
            return known.Find(dn);
        }
        // No tree yet: one base read of that OU (its existence and its name), never the whole tree without a gesture.
        var entry = await source.Connection.ReadAsync(dn, AdDirectoryMapper.OuAttributes, cancellationToken).ConfigureAwait(false);
        if (entry is null || AdDirectoryMapper.Ou(entry) is not DirectoryOu ou)
        {
            return null;
        }
        var domain = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
        return OrganizationalUnitTree.Build(new DirectorySnapshot(domain, source.Clock.GetUtcNow(), false, [ou], [], [], [])).Find(dn);
    }

    public void Dispose() => building.Dispose();

    /// <summary>The tree of the last directory picture; rebuilt when a newer picture was read.</summary>
    private async Task<OrganizationalUnitTree> TreeAsync(CancellationToken cancellationToken)
    {
        var current = source.CurrentDirectory;
        lock (gate)
        {
            if (built is { } known && (current is null || ReferenceEquals(known.Basis, current) || current.OrganizationalUnits.IsDefaultOrEmpty))
            {
                return known.Tree;
            }
        }
        await building.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            current = source.CurrentDirectory;
            DirectorySnapshot basis;
            if (current is { OrganizationalUnits.IsDefaultOrEmpty: false })
            {
                basis = current;
            }
            else
            {
                var domain = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
                var entries = await source.Connection.SearchAsync(new AdSearchRequest(domain.RootDn, "(objectClass=organizationalUnit)", AdSearchScope.Subtree, AdDirectoryMapper.OuAttributes) { SizeLimit = AdDirectorySource.MaxObjectsPerKind }, cancellationToken).ConfigureAwait(false);
                var ous = entries.Select(AdDirectoryMapper.Ou).OfType<DirectoryOu>().ToArray();
                basis = new DirectorySnapshot(domain, source.Clock.GetUtcNow(), entries.Count < AdDirectorySource.MaxObjectsPerKind, [.. ous], [], [], []);
            }
            var tree = OrganizationalUnitTree.Build(basis);
            lock (gate)
            {
                built = (basis, tree);
            }
            return tree;
        }
        finally
        {
            building.Release();
        }
    }
}
