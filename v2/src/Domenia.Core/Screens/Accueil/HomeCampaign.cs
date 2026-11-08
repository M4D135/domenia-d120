using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

/// <summary>A library reference, never the text of a query or a credential.</summary>
public sealed record HomeCampaignQuery(string Id, long Revision, string Fingerprint);

/// <summary>Frozen OU campaign. Progress identifies only facts already committed locally.</summary>
public sealed record HomeCampaignCheckpoint(string Id, string StoreId, string DomainDn, ScopeSelection Scope, string Mode,
    ImmutableArray<string> Stages, ImmutableArray<string> DoneStages, ImmutableArray<QueryComputerIdentity> Targets,
    ImmutableArray<string> Probes, ImmutableArray<HomeCampaignQuery> Queries, ImmutableArray<Guid> PresenceDone,
    ImmutableArray<Guid> InventoryDone, DateTimeOffset StartedAt, DateTimeOffset UpdatedAt, DateTimeOffset? PresenceStartedAt,
    bool Forced, bool Interrupted)
{
    /// <summary>Ordered, disjoint branches; empty preserves the historic whole-scope campaign.</summary>
    public ImmutableArray<ScopeSelection> Branches { get; init; } = [];
    public bool ReadWithoutEcho { get; init; }
    public ImmutableArray<HomeMemoryScope> MemoryPolicies { get; init; } = [];
}

public sealed record HomeCampaignStored(long Revision, HomeCampaignCheckpoint? Plan)
{
    public string? Token => Plan is null ? null : Plan.Id + ":" + Revision.ToString(System.Globalization.CultureInfo.InvariantCulture);
}

/// <summary>Local reads only. A lease is taken only after the operator confirms a newly prepared plan.</summary>
public interface IHomeCampaignRecorder : IScreenReader
{
    Task<HomeCampaignStored> ReadHomeCampaignAsync(CancellationToken cancellationToken);
    Task<IHomeCampaignLease> BeginHomeCampaignAsync(HomeCampaignCheckpoint plan, string? expectedToken, CancellationToken cancellationToken, bool replace = false);
}

/// <summary>The caller keeps admission until every physical stage and final save have ended, including cancellation.</summary>
public interface IHomeCampaignLease : IDisposable
{
    HomeCampaignCheckpoint State { get; }
    Task SaveAsync(ImmutableArray<string> doneStages, ImmutableArray<Guid> presenceDone, ImmutableArray<Guid> inventoryDone,
        DateTimeOffset? presenceStartedAt, CancellationToken cancellationToken);
    /// <summary>Replace the provisional local census only after this campaign's complete AD commit and before any workstation contact.</summary>
    Task BindDirectoryAsync(DirectoryState committed, CancellationToken cancellationToken);
    Task FinishAsync(bool complete, CancellationToken cancellationToken);
}

/// <summary>Shares the physical collection admission without replacing an interrupted durable plan.</summary>
public interface IHomeWidgetAdmission : IScreenReader
{
    Task<IDisposable> AcquireHomeWidgetAdmissionAsync(CancellationToken cancellationToken);
}

public static partial class HomeCampaignRules
{
    private sealed record TargetIndex(ScopeSelection Scope, ImmutableArray<ScopeSelection> Branches, HashSet<Guid> Ids);
    private static readonly ConditionalWeakTable<QueryComputerIdentity[], TargetIndex> TargetIndexes = new();
    public static ImmutableArray<string> StageOrder { get; } = ["backup", "directory", "commit", "presence", "inventory", "queries"];
    public static void Validate(HomeCampaignCheckpoint plan, string storeId, string domainDn)
    {
        if (plan is null || plan.StoreId != storeId || !Guid.TryParse(plan.Id, out var id) || id == Guid.Empty
            || string.IsNullOrWhiteSpace(plan.DomainDn) || !DistinguishedName.AreEqual(plan.DomainDn, domainDn)
            || plan.Scope is null || string.IsNullOrWhiteSpace(plan.Scope.Dn) || plan.Scope.Dn.Length > 4096
            || !DistinguishedName.IsWithin(plan.Scope.Dn, domainDn, true) || plan.Scope.Label is null || plan.Scope.Label.Length > 500
            || plan.Mode is not ("directory" or "presence" or "inventory" or "all")
            || plan.Stages.IsDefaultOrEmpty || plan.Stages.Length > StageOrder.Length || plan.Stages.Distinct().Count() != plan.Stages.Length
            || plan.Stages.Any(s => !StageOrder.Contains(s)) || !plan.Stages.SequenceEqual(plan.Stages.OrderBy(s => StageOrder.IndexOf(s)))
            || plan.DoneStages.IsDefault || plan.DoneStages.Distinct().Count() != plan.DoneStages.Length || plan.DoneStages.Except(plan.Stages).Any()
            || plan.Targets.IsDefault || plan.Targets.Length > OperationsPersistence.MaxTargets
            || plan.Probes.IsDefault || plan.Probes.Length > 128 || plan.Probes.Distinct().Count() != plan.Probes.Length || plan.Probes.Any(p => ProbeCatalog.Find(p) is null && !PersonalProbeCatalog.IsKey(p))
            || plan.Queries.IsDefault || plan.Queries.Length > 64 || plan.Queries.Select(q => (q?.Id, q?.Revision, q?.Fingerprint)).Distinct().Count() != plan.Queries.Length
            || plan.StartedAt == default || plan.UpdatedAt < plan.StartedAt || plan.PresenceStartedAt < plan.StartedAt || plan.PresenceStartedAt > plan.UpdatedAt)
        { throw new InvalidDataException("Plan durable de l’Accueil invalide ou hors limites."); }
        if (plan.Stages.Contains("queries") != !plan.Queries.IsEmpty || !plan.Stages.Contains("inventory") && !plan.Probes.IsEmpty)
        { throw new InvalidDataException("Sondes ou références étrangères aux étapes du plan."); }
        // Immutable target records are checked once per frozen census, not once per progress bitset.
        ValidateBranches(plan.Scope, plan.Branches);
        HomeMemoryPolicy.Validate(plan.MemoryPolicies, plan.Scope);
        if (!plan.Stages.Contains("inventory") && !plan.MemoryPolicies.IsEmpty) throw new InvalidDataException("Dépendance mémoire sans étape inventaire.");
        var array = ImmutableCollectionsMarshal.AsArray(plan.Targets)!;
        var indexed = TargetIndexes.GetValue(array, _ => IndexTargets(plan.Scope, plan.Branches, plan.Targets));
        var targets = ScopeRules.SameScope(indexed.Scope, plan.Scope) && indexed.Branches.SequenceEqual(plan.Branches)
            ? indexed.Ids : IndexTargets(plan.Scope, plan.Branches, plan.Targets).Ids;
        foreach (var query in plan.Queries)
        {
            if (query is null || query.Id is not { Length: > 0 and <= 128 } || !query.Id.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.')
                || query.Revision < 1 || query.Fingerprint is not { Length: 64 } || !query.Fingerprint.All(char.IsAsciiHexDigit))
            { throw new InvalidDataException("Référence de requête du plan Accueil invalide."); }
        }
        void Bits(ImmutableArray<Guid> ids)
        { if (ids.IsDefault || ids.Length > targets.Count || ids.Distinct().Count() != ids.Length || ids.Any(id => !targets.Contains(id))) { throw new InvalidDataException("Progression étrangère aux cibles du plan Accueil."); } }
        Bits(plan.PresenceDone); Bits(plan.InventoryDone);
        if ((!plan.Stages.Contains("presence") && !plan.PresenceDone.IsEmpty) || (!plan.PresenceDone.IsEmpty && plan.PresenceStartedAt is null) || (!plan.Stages.Contains("inventory") && !plan.InventoryDone.IsEmpty))
        { throw new InvalidDataException("Progression sans étape qualifiée."); }
    }

    private static TargetIndex IndexTargets(ScopeSelection scope, ImmutableArray<ScopeSelection> branches, ImmutableArray<QueryComputerIdentity> values)
    {
        var ids = new HashSet<Guid>(values.Length);
        var classify = BranchClassifier(scope, branches);
        foreach (var target in values)
        {
            if (target is null || target.Guid == Guid.Empty || !ids.Add(target.Guid) || string.IsNullOrWhiteSpace(target.Dn) || target.Dn.Length > 4096
                || classify(target.Dn) < 0 || target.Host?.Length > 253 || target.Account?.Length > 256 || target.Sid?.Length > 256
                || AdValues.IsDisabled(target.UserAccountControl)) { throw new InvalidDataException("Identité du plan Accueil invalide ou hors périmètre."); }
        }
        return new(scope, branches, ids);
    }
}
