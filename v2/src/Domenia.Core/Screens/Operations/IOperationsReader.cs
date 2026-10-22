using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// What the Opérations screen reads from the source of the mode (docs/ops/operations.md): collection runs of the local base and
/// the interrupted survey (Domenia 1 OPE-027 to OPE-029), paused sources (OPE-036), statistics of earlier sessions (OPE-002) and
/// the directory checks of « Vérifier l’application » (OPE-007). Served by Domenia.Simulation today, by Domenia.Ad and the local
/// base later; without a reader (directory mode, wave 3) the screen says what is not available yet. Never a directory write: the
/// survey commands only start, stop or forget a collection of the workstations (reads) and its local plan.
/// </summary>
public interface IOperationsReader : IScreenReader
{
    /// <summary>Last run of each family and scope (newest first), the batch in progress and the interrupted survey.</summary>
    Task<CollectionRunsView> RunsAsync(CancellationToken cancellationToken);

    /// <summary>The batch in progress, from memory, without delay (polled by operations.activity).</summary>
    SurveyState? CurrentSurvey();

    /// <summary>
    /// Resumes the interrupted survey after the operator confirmed its <paramref name="remaining"/> workstations; refused when the
    /// offer changed meanwhile (operations.surveyChanged) or another batch runs (operations.surveyBusy).
    /// </summary>
    Task<SurveyState> ResumeSurveyAsync(int remaining, CancellationToken cancellationToken);

    /// <summary>Asks the batch in progress to stop: measures already received stay, nothing is replayed. Null when none runs.</summary>
    SurveyState? StopSurvey();

    /// <summary>« Abandonner »: forgets the interrupted survey; the measures already read stay in the local base.</summary>
    Task<SurveyOffer?> ForgetSurveyAsync(CancellationToken cancellationToken);

    /// <summary>« Plus tard »: the offer is not proposed again in this session (it stays in Relevés).</summary>
    SurveyOffer? PostponeSurvey();

    /// <summary>Sources paused or in progressive recovery (healthy ones are not listed).</summary>
    Task<ImmutableArray<ProviderState>> ProviderStatesAsync(CancellationToken cancellationToken);

    /// <summary>Measured samples of earlier sessions (local base), oldest first.</summary>
    Task<ImmutableArray<OperationSample>> HistoryAsync(CancellationToken cancellationToken);

    /// <summary>Directory checks of « Vérifier l’application » (session, base read, searches, tree, rights; repeated searches in full).</summary>
    Task<ImmutableArray<CheckRow>> CheckDirectoryAsync(bool full, CancellationToken cancellationToken);

    /// <summary>One sentence on the collection profile and window of this source.</summary>
    string CollectionProfile { get; }
}
