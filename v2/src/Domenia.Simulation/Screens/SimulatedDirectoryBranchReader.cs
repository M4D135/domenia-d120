using Domenia.Core;

namespace Domenia.Simulation;

public sealed class SimulatedDirectoryBranchReader(SimulatedDirectorySource source) : IDirectoryBranchReader
{
    public async Task<DirectoryBranch> ReadBranchAsync(string? dn, CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("search/tree", 40, 120, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var domain = directory.Domain;
        var parent = dn ?? domain.RootDn;
        var tree = OrganizationalUnitTree.Build(directory);
        var known = directory.OrganizationalUnits.Select(o => (Dn: o.DistinguishedName, o.Name, Kind: "ou"))
            .Concat(domain.Containers.Select(c => (Dn: c, Name: DistinguishedName.Parse(c)[0].Value, Kind: "container"))).ToArray();
        if (!DistinguishedName.AreEqual(parent, domain.RootDn) && !known.Any(e => DistinguishedName.AreEqual(e.Dn, parent)))
        { throw new DomeniaOperationException(DomeniaErrors.OuUnknown, DomeniaErrors.OuUnknownMessage); }
        var children = known.Where(e => DistinguishedName.IsWithin(e.Dn, parent, false)).Select(e =>
            new DirectoryBranchEntry(e.Dn, e.Name, DirectoryBranchRules.Path(e.Dn, domain), e.Kind,
                known.Any(c => DistinguishedName.IsWithin(c.Dn, e.Dn, false)), tree.Find(e.Dn)?.Counts ?? new(null, null, null), SearchContainers.IsSystem(e.Dn, domain.RootDn)))
            .OrderBy(e => e.Kind != "ou").ThenBy(e => e.Name, StringComparer.Create(System.Globalization.CultureInfo.GetCultureInfo("fr-FR"), true)).ToArray();
        return new(new(parent, DistinguishedName.AreEqual(parent, domain.RootDn) ? domain.DnsName : DistinguishedName.Parse(parent)[0].Value,
            DirectoryBranchRules.Path(parent, domain)), [.. children], source.Clock.GetUtcNow(), Guid.NewGuid());
    }
}
