using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>A direct navigation child; containers are kept distinct from organizational units.</summary>
public sealed record DirectoryBranchEntry(string Dn, string Name, string Path, string Kind, bool HasChildren, OuCounts Counts, bool System = false);

/// <summary>A complete one-level read. ReadId binds the durable read-back to this request, including an empty branch.</summary>
public sealed record DirectoryBranch(OuParent Parent, ImmutableArray<DirectoryBranchEntry> Children, DateTimeOffset ObservedAt, Guid ReadId);

public interface IDirectoryBranchReader : IScreenReader
{
    Task<DirectoryBranch> ReadBranchAsync(string? dn, CancellationToken cancellationToken);
}

/// <summary>Navigation cache, separate from object inventory and its coverage claims.</summary>
public interface IDirectoryBranchCache
{
    Task<DirectoryBranch?> ReadBranchAsync(string dn, CancellationToken cancellationToken);
    Task<DirectoryBranch> SaveBranchAsync(DirectoryBranch branch, CancellationToken cancellationToken);
}

public static class DirectoryBranchRules
{
    public const int MaxChildren = 100_000;
    public static void Validate(DirectoryBranch branch, string rootDn)
    {
        ArgumentNullException.ThrowIfNull(branch);
        if (branch.ReadId == Guid.Empty || branch.ObservedAt == default || branch.Children.IsDefault || branch.Children.Length > MaxChildren
            || (!DistinguishedName.AreEqual(branch.Parent.Dn, rootDn) && !DistinguishedName.IsWithin(branch.Parent.Dn, rootDn, true)))
        { throw new InvalidDataException("Branche d’annuaire incomplète ou hors domaine."); }
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var child in branch.Children)
        {
            if (child.Kind is not ("ou" or "container") || string.IsNullOrWhiteSpace(child.Name)
                || !DistinguishedName.IsWithin(child.Dn, branch.Parent.Dn, false)
                || !seen.Add(DistinguishedName.Format(DistinguishedName.Parse(child.Dn))))
            { throw new InvalidDataException("Enfant de branche incohérent ou dupliqué."); }
        }
    }

    public static string Path(string dn, DomainInfo domain)
    {
        var parts = DistinguishedName.Parse(dn);
        var depth = parts.Length - DistinguishedName.Parse(domain.RootDn).Length;
        return domain.DnsName + (depth == 0 ? "" : FrenchText.PathSeparator + string.Join(FrenchText.PathSeparator, parts.Take(depth).Reverse().Select(p => p.Value)));
    }
}
