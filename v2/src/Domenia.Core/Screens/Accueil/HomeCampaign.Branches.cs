using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

public static partial class HomeCampaignRules
{
    public const int MaxBranches = 1024;

    public static void ValidateBranches(ScopeSelection scope, ImmutableArray<ScopeSelection> branches)
    {
        if (branches.IsDefault || branches.Length > MaxBranches) { throw new InvalidDataException("Branches de campagne hors limites."); }
        var selected = new HashSet<string>(StringComparer.Ordinal);
        var subtrees = new HashSet<string>(StringComparer.Ordinal);
        var ancestors = new HashSet<string>(StringComparer.Ordinal);
        var root = DistinguishedName.Parse(scope.Dn);
        var rootKey = Key(root, 0);
        foreach (var branch in branches)
        {
            if (branch is null || string.IsNullOrWhiteSpace(branch.Dn) || branch.Dn.Length > 4096 || branch.Label is null || branch.Label.Length > 500)
            { throw new InvalidDataException("Branche de campagne invalide."); }
            var dn = DistinguishedName.Parse(branch.Dn);
            var key = Key(dn, 0); var equal = key == rootKey;
            if (!(equal && (!branch.Subtree || scope.Subtree) || scope.Subtree && DistinguishedName.IsWithin(dn, root, true)))
            { throw new InvalidDataException("Branche extérieure au périmètre de la campagne."); }
            var parents = Enumerable.Range(1, dn.Length - 1).Select(i => Key(dn, i)).ToArray();
            if (!selected.Add(key) || branch.Subtree && ancestors.Contains(key) || parents.Any(subtrees.Contains))
            { throw new InvalidDataException("Les branches de campagne se recouvrent ; choisissez des périmètres distincts."); }
            if (branch.Subtree) { subtrees.Add(key); }
            foreach (var parent in parents) { ancestors.Add(parent); }
        }
    }

    /// <summary>One parsed DN per workstation; matching is independent of the number of selected OUs.</summary>
    public static Func<string, int> BranchClassifier(ScopeSelection scope, ImmutableArray<ScopeSelection> branches)
    {
        ValidateBranches(scope, branches);
        var root = DistinguishedName.Parse(scope.Dn);
        var direct = new Dictionary<string, int>(StringComparer.Ordinal);
        var subtrees = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var i = 0; i < branches.Length; i++)
        {
            var branch = branches[i]; var key = Key(DistinguishedName.Parse(branch.Dn), 0);
            (branch.Subtree ? subtrees : direct).Add(key, i);
        }
        return dn =>
        {
            var child = DistinguishedName.Parse(dn);
            if (!DistinguishedName.IsWithin(child, root, scope.Subtree)) { return -1; }
            if (branches.IsEmpty) { return 0; }
            if (direct.TryGetValue(Key(child, 1), out var at)) { return at; }
            for (var i = 1; i < child.Length; i++) { if (subtrees.TryGetValue(Key(child, i), out at)) { return at; } }
            return -1;
        };
    }

    public static ImmutableArray<QueryComputerIdentity> SelectTargets(DirectorySnapshot directory, ScopeSelection scope, ImmutableArray<ScopeSelection> branches)
    {
        var classify = BranchClassifier(scope, branches);
        var selected = directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl))
            .Select(c => (Computer: c, Branch: classify(c.DistinguishedName))).Where(c => c.Branch >= 0);
        return branches.IsEmpty ? [.. selected.Select(c => QueryComputerIdentity.Of(c.Computer)).OrderBy(c => c.Guid)]
            : [.. selected.OrderBy(c => c.Branch).ThenBy(c => c.Computer.Name, StringComparer.OrdinalIgnoreCase)
                .ThenBy(c => c.Computer.ObjectGuid).Select(c => QueryComputerIdentity.Of(c.Computer))];
    }

    private static string Key(ImmutableArray<RelativeName> parts, int start) => string.Concat(parts.Skip(start).Select(p =>
        p.Type.Length.ToString(CultureInfo.InvariantCulture) + ":" + p.Type.ToUpperInvariant()
        + p.Value.Length.ToString(CultureInfo.InvariantCulture) + ":" + p.Value.ToUpperInvariant()));
}
