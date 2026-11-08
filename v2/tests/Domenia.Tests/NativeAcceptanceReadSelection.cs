using System.Collections.Immutable;

namespace Domenia.Tests;

/// <summary>Explicit final native selection. It never starts a read and never qualifies a result.</summary>
internal sealed record NativeAcceptanceReadSelection(string Kind, bool CanaryRequested, ImmutableArray<string> Selected, ImmutableArray<string> NotExecuted)
{
    internal static ImmutableArray<string> Available { get; } =
    [
        "directory.scope", "audit.findTarget", "audit.searchObjects", "audit.domainGroup",
        "audit.overview", "audit.localTotals", "audit.controllers", "audit.probes", "audit.services",
        "audit.compare", "audit.passwordPolicy", "audit.nestedGroups", "audit.membership",
        "audit.delegations", "audit.tokenGroups", "audit.gpoLinks", "audit.appliedPolicies",
        "audit.machineIdentity", "audit.relations", "audit.relationHistory", "audit.identityScan",
        "audit.localNames", "operations.runs", "operations.providers", "operations.history",
        "operations.check", "poste.inventory", "poste.software", "poste.sessions", "poste.diagnostic",
    ];

    internal static ImmutableArray<string> Critical { get; } =
        ["directory.scope", "audit.machineIdentity", "operations.history", "poste.inventory"];

    internal static NativeAcceptanceReadSelection FromMode(string mode)
    {
        var critical = mode is "--critical-read-only" or "--critical-canary";
        if (!critical && mode is not ("--read-only" or "--canary"))
        { throw new InvalidDataException("Sélection native inconnue ; aucune lecture ni écriture."); }
        var selected = critical ? Critical : Available;
        Validate(selected);
        return new(critical ? "critical-only" : "complete", mode is "--canary" or "--critical-canary", selected,
            [.. Available.Where(operation => !selected.Contains(operation, StringComparer.Ordinal))]);
    }

    internal static void Validate(ImmutableArray<string> selected)
    {
        if (selected.IsDefaultOrEmpty || selected.Length > Available.Length
            || selected.Distinct(StringComparer.Ordinal).Count() != selected.Length
            || selected.Any(operation => !Available.Contains(operation, StringComparer.Ordinal)))
        { throw new InvalidDataException("Sélection native vide, répétée ou inconnue ; aucun contact."); }
    }
}
