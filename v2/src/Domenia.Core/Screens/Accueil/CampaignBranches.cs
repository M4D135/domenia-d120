using System.Collections.Immutable;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

public sealed record RefreshBranch(ScopeSelection Scope, int Targets, int PresenceDone = 0, int InventoryDone = 0);

/// <summary>Disjoint work objectives beneath the approved OU. Parsed DN ancestry, never textual suffix matching.</summary>
public static class CampaignBranches
{
    public const int DisplayLimit = 128;
    public static ImmutableArray<ScopeSelection> Validate(ScopeSelection scope, ImmutableArray<ScopeSelection> branches)
    {
        if (branches.IsDefaultOrEmpty) { return []; }
        if (branches.Length > DisplayLimit) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Branches de collecte trop nombreuses."); }
        try { HomeCampaignRules.ValidateBranches(scope, branches); }
        catch (Exception error) when (error is InvalidDataException or FormatException)
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Branches de collecte hors périmètre ou recouvrantes."); }
        return branches;
    }

    public static bool Contains(ImmutableArray<ScopeSelection> branches, string dn) => branches.IsDefaultOrEmpty || branches.Any(b => ScopeRules.Contains(b, dn));

    public static IEnumerable<DirectoryComputer> Order(IEnumerable<DirectoryComputer> computers) => computers
        .GroupBy(c => DistinguishedName.Parent(c.DistinguishedName) ?? "", StringComparer.OrdinalIgnoreCase)
        .OrderBy(g => string.Join("\0", DistinguishedName.Parse(g.Key).Reverse().Select(r => r.Type + "=" + r.Value)), StringComparer.OrdinalIgnoreCase)
        .SelectMany(g => g);

    public static ImmutableArray<RefreshBranch> Summarize(ScopeSelection scope, IEnumerable<QueryComputerIdentity> targets,
        IReadOnlySet<Guid>? presence = null, IReadOnlySet<Guid>? inventory = null)
    {
        var parents = new Dictionary<string, ScopeSelection>(StringComparer.OrdinalIgnoreCase);
        var groups = new Dictionary<string, RefreshBranch>(StringComparer.OrdinalIgnoreCase);
        foreach (var target in targets)
        {
            var parent = DistinguishedName.Parent(target.Dn);
            if (parent is null || !ScopeRules.Contains(scope, target.Dn)) { continue; }
            if (!parents.TryGetValue(parent, out var branch))
            {
                var dn = parent;
                while (!DistinguishedName.AreEqual(dn, scope.Dn) && DistinguishedName.Parent(dn) is { } ancestor
                    && !DistinguishedName.AreEqual(ancestor, scope.Dn)) { dn = ancestor; }
                var direct = DistinguishedName.AreEqual(dn, scope.Dn);
                branch = new(dn, direct ? scope.Label + " · postes directs" : DistinguishedName.Parse(dn)[0].Value, !direct);
                parents[parent] = branch;
            }
            var key = DistinguishedName.Format(DistinguishedName.Parse(branch.Dn));
            var row = groups.GetValueOrDefault(key) ?? new RefreshBranch(branch, 0);
            groups[key] = row with { Targets = row.Targets + 1, PresenceDone = row.PresenceDone + (presence?.Contains(target.Guid) == true ? 1 : 0),
                InventoryDone = row.InventoryDone + (inventory?.Contains(target.Guid) == true ? 1 : 0) };
        }
        return [.. groups.Values.OrderBy(b => b.Scope.Dn, StringComparer.OrdinalIgnoreCase)];
    }
}
