using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Explicit Rechercher branch reads. OU pickers retain their separate OU-only contract.</summary>
public sealed class AdDirectoryBranchReader(AdDirectorySource source) : IDirectoryBranchReader, IDirectoryBranchIndex
{
    private static readonly string[] Attributes = ["distinguishedName", "name", "objectClass"];

    public async Task<DirectoryBranchEntry?> FindLocalAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        if (session.Domain?.RootDn is not { } root || !DistinguishedName.IsWithin(dn, root, true)
            || DistinguishedName.Parent(dn) is not { } parent || source.LocalStore is not IDirectoryBranchCache cache)
        { return null; }
        CheckEpoch(session.Epoch);
        var branch = await cache.ReadBranchAsync(parent, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        DirectoryBranchEntry? found = null;
        if (branch is not null)
        {
            DirectoryBranchRules.Validate(branch, root);
            if (!DistinguishedName.AreEqual(branch.Parent.Dn, parent))
            { throw new InvalidDataException("Le cache a retourné une autre branche que celle demandée."); }
            // Navigation is recorded separately from the object inventory. Its exact children are valid search bases,
            // including nested containers, without manufacturing OU objects or loading the domain-wide OU picker.
            found = branch.Children.FirstOrDefault(child => DistinguishedName.AreEqual(child.Dn, dn));
        }
        cancellationToken.ThrowIfCancellationRequested();
        var current = source.PeekSession();
        if (current is null || current.Epoch != session.Epoch || current.Domain?.RootDn is not { } currentRoot
            || !DistinguishedName.AreEqual(currentRoot, root))
        { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la lecture locale de branche : résultat écarté."); }
        return found;
    }

    public async Task<DirectoryBranch> ReadBranchAsync(string? dn, CancellationToken cancellationToken)
    {
        _ = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var (domain, epoch, connection) = source.CaptureTreeRead();
        var parent = dn ?? domain.RootDn;
        if (!DistinguishedName.AreEqual(parent, domain.RootDn) && !DistinguishedName.IsWithin(parent, domain.RootDn, true))
        { throw new DomeniaOperationException(DomeniaErrors.OuUnknown, "Branche située hors du domaine connecté."); }
        if (source.LocalStore is not IDirectoryBranchCache cache)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Stockage durable des branches indisponible : lecture annulée."); }
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(60));
        var entries = await connection.SearchAsync(new AdSearchRequest(parent,
            "(|(objectClass=organizationalUnit)(objectClass=container)(objectClass=builtinDomain))", AdSearchScope.OneLevel, Attributes)
        { PageSize = 250, SizeLimit = DirectoryBranchRules.MaxChildren + 1, Timeout = TimeSpan.FromSeconds(15), Budget = TimeSpan.FromSeconds(60) }, deadline.Token).ConfigureAwait(false);
        CheckEpoch(epoch);
        if (entries.Count > DirectoryBranchRules.MaxChildren)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Branche supérieure à 100 000 enfants : aucune publication partielle."); }
        var children = entries.Select(e =>
        {
            var classes = e.Strings("objectClass");
            var kind = classes.Contains("organizationalUnit", StringComparer.OrdinalIgnoreCase) ? "ou"
                : classes.Any(c => c.Equals("container", StringComparison.OrdinalIgnoreCase) || c.Equals("builtinDomain", StringComparison.OrdinalIgnoreCase)) ? "container" : "invalid";
            var name = e.String("name") ?? DistinguishedName.Parse(e.DistinguishedName)[0].Value;
            // Children are unknown until their branch is opened; never issue one LDAP count per child.
            return new DirectoryBranchEntry(e.DistinguishedName, name, DirectoryBranchRules.Path(e.DistinguishedName, domain), kind, true,
                new(null, null, null), SearchContainers.IsSystem(e.DistinguishedName, domain.RootDn));
        }).OrderBy(e => e.Kind != "ou").ThenBy(e => e.Name, StringComparer.OrdinalIgnoreCase).ThenBy(e => e.Dn, StringComparer.Ordinal).ToArray();
        var root = DistinguishedName.AreEqual(parent, domain.RootDn);
        var branch = new DirectoryBranch(new(parent, root ? domain.DnsName : DistinguishedName.Parse(parent)[0].Value, DirectoryBranchRules.Path(parent, domain)),
            [.. children], source.Clock.GetUtcNow(), Guid.NewGuid());
        DirectoryBranchRules.Validate(branch, domain.RootDn);
        CheckEpoch(epoch);
        var saved = await cache.SaveBranchAsync(branch, deadline.Token).ConfigureAwait(false);
        CheckEpoch(epoch);
        if (saved.ReadId != branch.ReadId) { throw new InvalidDataException("La branche relue ne correspond pas à cette lecture."); }
        return saved;
    }

    private void CheckEpoch(long epoch)
    {
        if (source.Epoch != epoch) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la lecture de branche : publication annulée."); }
    }
}
