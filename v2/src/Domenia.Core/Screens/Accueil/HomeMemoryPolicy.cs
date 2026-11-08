using System.Collections.Immutable;

namespace Domenia.Core.Accueil;

/// <summary>Frozen collection dependency, by OU. False entries retain explicit child-OU exceptions.</summary>
public sealed record HomeMemoryScope(string Dn, bool Required);

public static class HomeMemoryPolicy
{
    public static ImmutableArray<HomeMemoryScope> Freeze(HealthPolicyBook book, ScopeSelection scope, DateTimeOffset now)
    {
        var scopes = new[] { scope.Dn }.Concat(book.Scopes.Select(s => s.ScopeDn).Where(dn =>
            !DistinguishedName.AreEqual(dn, scope.Dn) && ScopeRules.Contains(scope, dn))).Distinct(StringComparer.OrdinalIgnoreCase);
        var rules = scopes.Select(dn =>
        {
            var policy = HealthRules.Resolve(book, dn).Policy;
            return new HomeMemoryScope(dn, policy.CustomRules.Any(r => r.Measure == "MemoryUsed" && HealthRules.IsEnabled(policy, r.Id, now)));
        }).ToImmutableArray();
        return rules.Any(r => r.Required) ? rules : [];
    }

    public static void Validate(ImmutableArray<HomeMemoryScope> rules, ScopeSelection scope)
    {
        if (rules.IsDefault || rules.Length > HealthRules.MaxScopes + 1 || rules.Any(r => r is null || string.IsNullOrWhiteSpace(r.Dn)
            || r.Dn.Length > 4096 || !(DistinguishedName.AreEqual(r.Dn, scope.Dn) || DistinguishedName.IsWithin(r.Dn, scope.Dn, true)))
            || rules.Select(r => DistinguishedName.Format(DistinguishedName.Parse(r.Dn)).ToUpperInvariant()).Distinct().Count() != rules.Length)
            throw new InvalidDataException("Politique mémoire du plan Accueil invalide.");
    }

    public static Func<string, bool> Resolver(ImmutableArray<HomeMemoryScope> rules)
    {
        if (rules.IsDefaultOrEmpty) return static _ => false;
        // Escaped spellings can make an ancestor longer than its child; specificity is DN depth.
        var ordered = rules.OrderByDescending(r => DistinguishedName.Parse(r.Dn).Length).ToArray();
        var parents = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        return dn =>
        {
            var parent = DistinguishedName.Parent(dn);
            if (parent is null) return false;
            if (!parents.TryGetValue(parent, out var required))
            {
                required = ordered.FirstOrDefault(r => DistinguishedName.AreEqual(parent, r.Dn)
                    || DistinguishedName.IsWithin(parent, r.Dn, true))?.Required == true;
                parents[parent] = required;
            }
            return required;
        };
    }

    public static bool Answered(MemoryUsageFact? memory, DateTimeOffset since, DateTimeOffset now) => memory is { IsValid: true }
        && memory.At >= since && memory.At <= now + RefreshRules.FutureTolerance;
}
