using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Durable, explicit collection progress; identities never travel to the page as a replayable command.</summary>
public sealed record OperationsSurveyCheckpoint(string Id, string DomainDn, ScopeSelection Scope, SurveyMode Mode,
    ImmutableArray<SurveyTarget> Targets, ImmutableArray<Guid> Completed, DateTimeOffset StartedAt, DateTimeOffset UpdatedAt,
    bool Interrupted, int Failed);

public sealed record OperationsLocalState(string StoreId, string DomainDn, long Revision,
    ImmutableArray<OperationsCollectionRun> Runs, ImmutableArray<OperationSample> Samples, OperationsSurveyCheckpoint? Survey);

public interface IOperationsLocalStore
{
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
    public static bool Unconfirmed(SurveyOutcome outcome, SurveyMode mode) => outcome.Denied || outcome.Kind != "online" || mode != SurveyMode.Ping && outcome.Confirmed != true;

    public static void Validate(OperationsLocalState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        if (state.Revision < 0 || state.Runs.IsDefault || state.Runs.Length > 1000 || state.Samples.IsDefault || state.Samples.Length > 10000)
        { throw new InvalidDataException("Journal d’opérations hors limites."); }
        var root = DistinguishedName.Parse(state.DomainDn);
        if (root.IsEmpty || root.Any(r => !r.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)))
        { throw new InvalidDataException("Domaine du journal invalide."); }
        bool Within(string dn) => DistinguishedName.AreEqual(dn, state.DomainDn) || DistinguishedName.IsWithin(dn, state.DomainDn, true);
        foreach (var run in state.Runs)
        {
            if (!Enum.IsDefined(run.Family) || !Enum.IsDefined(run.Status) || !Within(run.ScopeDn)
                || run.Done is < 0 || run.Targets is < 0 || run.Failed is < 0 || run.Done > run.Targets || run.Failed > run.Done
                || run.ScopeName.Length > 500 || run.Reason?.Length > 2000)
            { throw new InvalidDataException("Relevé enregistré incohérent."); }
        }
        foreach (var sample in state.Samples)
        {
            if (string.IsNullOrWhiteSpace(sample.Operation) || sample.Operation.Length > 160 || !sample.Operation.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_')
                || !double.IsFinite(sample.DurationMs) || sample.DurationMs < 0 || sample.Items < 0 || sample.Bytes is < 0 || sample.RemoteAttempts < 0 || sample.Fallbacks < 0 || sample.Fallbacks > sample.RemoteAttempts)
            { throw new InvalidDataException("Mesure d’opération invalide."); }
        }
        if (state.Survey is not { } survey) { return; }
        if (!Guid.TryParse(survey.Id, out _) || !DistinguishedName.AreEqual(survey.DomainDn, state.DomainDn) || !Within(survey.Scope.Dn)
            || !Enum.IsDefined(survey.Mode)
            || survey.Targets.IsDefault || survey.Targets.Length is < 1 or > 5000 || survey.Completed.IsDefault || survey.Completed.Length > survey.Targets.Length
            || survey.Completed.Distinct().Count() != survey.Completed.Length || survey.Failed < 0 || survey.Failed > survey.Completed.Length || survey.UpdatedAt < survey.StartedAt)
        { throw new InvalidDataException("Plan de reprise invalide."); }
        var ids = new HashSet<Guid>();
        foreach (var target in survey.Targets)
        {
            if (!Guid.TryParse(target.Id, out var id) || id == Guid.Empty || !ids.Add(id) || target.Name.Length > 256
                || !DistinguishedName.IsWithin(target.Dn, survey.Scope.Dn, survey.Scope.Subtree))
            { throw new InvalidDataException("Cible du relevé hors identité ou périmètre."); }
        }
        if (survey.Completed.Any(id => !ids.Contains(id))) { throw new InvalidDataException("Progression étrangère au relevé."); }
    }
}

/// <summary>Flush measured samples before disposing the engine context; no network and no synthetic measurements.</summary>
public interface IOperationsStatisticsWriter
{
    Task PersistStatisticsAsync(CancellationToken cancellationToken);
}
