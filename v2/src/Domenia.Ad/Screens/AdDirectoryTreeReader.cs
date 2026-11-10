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

    public async Task<OuEntry?> FindLocalAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        cancellationToken.ThrowIfCancellationRequested();
        OrganizationalUnitTree? known;
        lock (gate)
        {
            known = built is { } cached && cached.Epoch == source.Epoch ? cached.Tree : null;
        }
        // A fresh picker result is authoritative, including an OU absent from that result.
        if (known is not null) { return known.Find(dn); }
        // Cold start or credential replacement: use persisted OUs without contacting LDAP or warming the picker.
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        if (session.Domain?.RootDn is not { } root) { return null; }
        var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        if (source.Epoch != session.Epoch || !DistinguishedName.AreEqual(local.Directory.Domain.RootDn, root)) { return null; }
        var tree = OrganizationalUnitTree.Build(local.Directory with { Users = [], Computers = [], Groups = [] }, objectsRead: false);
        cancellationToken.ThrowIfCancellationRequested();
        return source.Epoch == session.Epoch ? tree.Find(dn) : null;
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
            _ = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
            var (domain, epoch, connection) = source.CaptureTreeRead();
            lock (gate)
            {
                if (built is { } known && known.Epoch == epoch)
                {
                    return known.Tree;
                }
            }
            var entries = await connection.SearchAsync(new AdSearchRequest(domain.RootDn, "(objectClass=organizationalUnit)", AdSearchScope.Subtree, AdDirectoryMapper.OuAttributes) { PageSize = 250, SizeLimit = AdDirectorySource.MaxObjectsPerKind + 1 }, cancellationToken).ConfigureAwait(false);
            var ous = entries.Take(AdDirectorySource.MaxObjectsPerKind).Select(AdDirectoryMapper.Ou).OfType<DirectoryOu>().ToArray();
            var basis = new DirectorySnapshot(domain, source.Clock.GetUtcNow(), entries.Count <= AdDirectorySource.MaxObjectsPerKind && ous.Length == entries.Count, [.. ous], [], [], []);
            var stored = await source.RememberObjectsAsync(basis with { Complete = false }, epoch, cancellationToken).ConfigureAwait(false);
            // Only this read's OUs form the fresh navigation tree; retained older branches stay in local history.
            var readback = DirectoryReadback.Select(basis, stored);
            var tree = OrganizationalUnitTree.Build(readback, objectsRead: false);
            lock (gate)
            {
                if (source.Epoch != epoch) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la lecture de l’arbre : publication annulée."); }
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
