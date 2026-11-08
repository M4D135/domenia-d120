using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Domenia.Core;

/// <summary>Durable, explicit collection progress; identities never travel to the page as a replayable command.</summary>
public sealed record OperationsSurveyCheckpoint(string Id, string DomainDn, ScopeSelection Scope, SurveyMode Mode,
    ImmutableArray<SurveyTarget> Targets, ImmutableArray<Guid> Completed, DateTimeOffset StartedAt, DateTimeOffset UpdatedAt,
    bool Interrupted, int Failed);

public sealed record OperationsLocalState(string StoreId, string DomainDn, long Revision,
    ImmutableArray<OperationsCollectionRun> Runs, ImmutableArray<OperationSample> Samples, OperationsSurveyCheckpoint? Survey)
{
    public Accueil.HomeCampaignCheckpoint? HomeCampaign { get; init; }
}

public interface IOperationsLocalStore
{
    /// <summary>Confirms that this exact local store currently retains its exclusive collection lease.</summary>
    Task<bool> HasOperationsLeaseAsync(CancellationToken cancellationToken) => Task.FromResult(false);
    Task<OperationsLocalState> ReadOperationsAsync(CancellationToken cancellationToken);
    Task<IDisposable> AcquireOperationsLeaseAsync(CancellationToken cancellationToken);
    Task<OperationsLocalState> UpdateOperationsAsync(long expectedRevision, OperationsLocalState next, CancellationToken cancellationToken);
}

/// <summary>Observer of operator-approved surveys. A failed durable start must prevent network work.</summary>
public interface IOperationsCollectionRecorder
{
    Task BeginCollectionAsync(string id, ScopeSelection scope, SurveyMode mode, ImmutableArray<SurveyTarget> targets, CancellationToken cancellationToken);
    Task ProgressCollectionAsync(string id, ImmutableArray<Guid> completed, int failed, CancellationToken cancellationToken);
    Task FinishCollectionAsync(string id, bool interrupted, CancellationToken cancellationToken);
}

public interface IOperationsConfirmedResume
{
    Task<SurveyState> ResumeSurveyAsync(int remaining, string token, CancellationToken cancellationToken);
}

public static class OperationsPersistence
{
    public const int MaxTargets = 100_000;
    private sealed record TargetIndex(ScopeSelection Scope, HashSet<Guid> Ids);
    private static readonly ConditionalWeakTable<SurveyTarget[], TargetIndex> TargetIndexes = new();
    public static bool Unconfirmed(SurveyOutcome outcome, SurveyMode mode) => outcome.Denied
        || (mode == SurveyMode.Ping ? outcome.Kind != "online" : outcome.Confirmed != true);

    public static void Validate(OperationsLocalState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        if (string.IsNullOrWhiteSpace(state.StoreId) || state.StoreId.Length > 128 || string.IsNullOrWhiteSpace(state.DomainDn) || state.DomainDn.Length > 4096
            || state.Revision < 0 || state.Runs.IsDefault || state.Runs.Length > 1000 || state.Samples.IsDefault || state.Samples.Length > 10000)
        { throw new InvalidDataException("Journal d’opérations hors limites."); }
        var root = DistinguishedName.Parse(state.DomainDn);
        if (root.IsEmpty || root.Any(r => !r.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)))
        { throw new InvalidDataException("Domaine du journal invalide."); }
        bool Within(string dn) => DistinguishedName.AreEqual(dn, state.DomainDn) || DistinguishedName.IsWithin(dn, state.DomainDn, true);
        foreach (var run in state.Runs)
        {
            if (run is null || string.IsNullOrWhiteSpace(run.ScopeDn) || run.ScopeName is null || !Enum.IsDefined(run.Family) || !Enum.IsDefined(run.Status) || !Within(run.ScopeDn)
                || run.Done is < 0 || run.Targets is < 0 || run.Failed is < 0 || run.Done > run.Targets || run.Failed > run.Done
                || run.ScopeName.Length > 500 || run.Reason?.Length > 2000)
            { throw new InvalidDataException("Relevé enregistré incohérent."); }
        }
        foreach (var sample in state.Samples)
        {
            if (sample is null || string.IsNullOrWhiteSpace(sample.Operation) || sample.Operation.Length > 160 || !sample.Operation.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_')
                || !double.IsFinite(sample.DurationMs) || sample.DurationMs < 0 || sample.Items < 0 || sample.Bytes is < 0 || sample.RemoteAttempts < 0 || sample.Fallbacks < 0 || sample.Fallbacks > sample.RemoteAttempts)
            { throw new InvalidDataException("Mesure d’opération invalide."); }
            if (sample.Sync is { } sync && (sample.Operation != "synchro.read.run" || !sample.Succeeded
                || sync.Mode is not (SyncReadMode.Full or SyncReadMode.Ou) || sync.Items is < 1 or > 300_000
                || sync.DurationMs is < 1 or > 7_200_000 || sync.ScopeDn is not { Length: > 0 and <= 4096 }
                || !Within(sync.ScopeDn) || sync.Controller is not { Length: > 0 and <= 253 } || sync.Controller.Any(char.IsControl)))
            { throw new InvalidDataException("Mesure de synchronisation hors périmètre ou invalide."); }
        }
        if (state.HomeCampaign is { } home)
        {
            if (state.Survey is not null) { throw new InvalidDataException("Deux plans durables simultanés sont interdits."); }
            Accueil.HomeCampaignRules.Validate(home, state.StoreId, state.DomainDn);
        }
        if (state.Survey is not { } survey) { return; }
        if (!Guid.TryParse(survey.Id, out var planId) || planId == Guid.Empty || survey.Scope is null || string.IsNullOrWhiteSpace(survey.DomainDn)
            || string.IsNullOrWhiteSpace(survey.Scope.Dn) || survey.Scope.Dn.Length > 4096 || survey.Scope.Label is null || survey.Scope.Label.Length > 500
            || survey.StartedAt == default || survey.UpdatedAt == default || !DistinguishedName.AreEqual(survey.DomainDn, state.DomainDn) || !Within(survey.Scope.Dn)
            || !Enum.IsDefined(survey.Mode)
            || survey.Targets.IsDefault || survey.Targets.Length is < 1 or > MaxTargets || survey.Completed.IsDefault || survey.Completed.Length > survey.Targets.Length
            || survey.Completed.Distinct().Count() != survey.Completed.Length || survey.Failed < 0 || survey.Failed > survey.Completed.Length || survey.UpdatedAt < survey.StartedAt)
        { throw new InvalidDataException("Plan de reprise invalide."); }
        var array = ImmutableCollectionsMarshal.AsArray(survey.Targets)!;
        var indexed = TargetIndexes.GetValue(array, _ => IndexTargets(survey.Scope, survey.Targets));
        var ids = ScopeRules.SameScope(indexed.Scope, survey.Scope) ? indexed.Ids : IndexTargets(survey.Scope, survey.Targets).Ids;
        if (survey.Completed.Any(id => !ids.Contains(id))) { throw new InvalidDataException("Progression étrangère au relevé."); }
    }

    private static TargetIndex IndexTargets(ScopeSelection scope, ImmutableArray<SurveyTarget> values)
    {
        var ids = new HashSet<Guid>(values.Length);
        foreach (var target in values)
        {
            if (target is null || string.IsNullOrWhiteSpace(target.Name) || string.IsNullOrWhiteSpace(target.Dn) || target.Dn.Length > 4096
                || target.Address?.Length > 253 || !Guid.TryParse(target.Id, out var id) || id == Guid.Empty || !ids.Add(id) || target.Name.Length > 256
                || !DistinguishedName.IsWithin(target.Dn, scope.Dn, scope.Subtree))
            { throw new InvalidDataException("Cible du relevé hors identité ou périmètre."); }
        }
        return new(scope, ids);
    }
}

/// <summary>Flush measured samples before disposing the engine context; no network and no synthetic measurements.</summary>
public interface IOperationsStatisticsWriter
{
    Task PersistStatisticsAsync(CancellationToken cancellationToken);
}
