using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Kind of an engine task, from the class of its operation (Domenia 1 « Lecture », « Écriture », « Cache local »), plus the
/// collection batches of the readers (Domenia 1 OPE-017). Mirrors the operation classes of the bridge without depending on it.
/// </summary>
public enum TaskKind
{
    Local,
    LocalRead,
    NetworkRead,
    LocalWrite,
    Write,
    Batch,
}

/// <summary>
/// Exact state of a task (Domenia 1 Get-DomeniaTaskState): a task whose call is still alive is never reported as finished, and
/// a requested stop is not a confirmed cancellation.
/// </summary>
public enum TaskState
{
    Queued,
    Running,
    StopRequested,
    Cleanup,
    Completed,
}

/// <summary>Closed catalogue of the ends of a task (Domenia 1 Get-DomeniaTraceOutcomes); the rank orders them from best to worst.</summary>
public enum TaskOutcome
{
    Succeeded,
    Superseded,
    Withdrawn,
    Stopped,
    TimedOut,
    Refused,
    Failed,
    Unknown,
}

/// <summary>One entry of the outcome catalogue: label, tone, glyph (an end is read by a glyph and a word, never by a colour) and rank.</summary>
public sealed record OutcomeInfo(TaskOutcome Code, string Label, Tone Tone, string Icon, int Rank);

/// <summary>
/// One step of a task in time order (Domenia 1 OPE-019): request, wait of the write channel, steps published by the operation,
/// processing in the engine, end. <see cref="DurationMs"/> is null when the step carries no measure of its own (« non mesurée »),
/// never 0. <see cref="AtMs"/> is the offset from the start of the task.
/// </summary>
public sealed record TaskPhaseRow(
    string Phase,
    string Label,
    double AtMs,
    double? DurationMs,
    string DurationText,
    bool Measured,
    string? Detail,
    TaskOutcome? Outcome);

/// <summary>One phase of a collection batch in its stepper (Domenia 1 OPE-017): « done », « current » or « todo ».</summary>
public sealed record BatchStep(string Phase, string Label, string State);

/// <summary>
/// Progress of a collection batch (Domenia 1 Get-DomeniaExperienceBatchRows): scalar fields only, never a target list. The
/// counters are those of Domenia 1: unconfirmed reads (<see cref="Failed"/>), ping errors, reads in flight, saves waiting and
/// workstations not read for lack of capacity; <see cref="Steps"/> places the batch among its phases (Préparation, Lecture AD,
/// À confirmer, En cours, Enregistrement).
/// </summary>
public sealed record BatchProgress(
    int Done,
    int Total,
    int Failed,
    string Phase,
    string Header,
    string Counters,
    int PingErrors,
    int InFlight,
    int PendingSaves,
    int Skipped,
    ImmutableArray<BatchStep> Steps);

/// <summary>
/// One task of the session as the page reads it (Domenia 1 Get-DomeniaExperienceTaskRow and Get-DomeniaOperationTraceSummary):
/// no argument of the request, no result, no target name, no message of an error (its code only).
/// </summary>
public sealed record ActivityRow(
    string Id,
    string Reference,
    string Operation,
    string Screen,
    string Label,
    TaskKind Kind,
    string KindLabel,
    bool Foreground,
    bool Listed,
    TaskState State,
    string StateLabel,
    Tone Tone,
    string Icon,
    TaskOutcome? Outcome,
    string? OutcomeLabel,
    DateTimeOffset StartedAt,
    DateTimeOffset? EndedAt,
    double DurationMs,
    string DurationText,
    string? DominantLabel,
    double? DominantMs,
    long? Volume,
    string? VolumeText,
    bool CanStop,
    string? StopReason,
    string Detail,
    string Access,
    string? Advice,
    string Next,
    string? Category,
    string Text,
    int Dropped,
    ImmutableArray<TaskPhaseRow> Phases,
    BatchProgress? Progress);

/// <summary>Counts of the tasks and of the resources they hold (Domenia 1 Get-DomeniaTaskStateSummary and Get-DomeniaResourceSummary).</summary>
public sealed record TaskSummary(
    int Running,
    int Queued,
    int StopRequested,
    int Cleanup,
    int Active,
    int Total,
    string Text,
    int Resources,
    string ResourcesText);

/// <summary>
/// Result of operations.activity: tasks in progress (operations and collection batches), the last 64 tasks of the session
/// (most recent first, each with its « listed » flag: operator requests, and automatic ones that ended badly) and the summary.
/// </summary>
public sealed record ActivitySnapshot(
    DateTimeOffset GeneratedAt,
    TaskSummary Summary,
    ImmutableArray<ActivityRow> Open,
    ImmutableArray<ActivityRow> Recent,
    int Kept,
    int Listed,
    int Faults,
    string Note);

/// <summary>Median, 95th percentile (stated from 20 measures) and maximum of a series (Domenia 1 Get-DomeniaLatencySummary).</summary>
public sealed record LatencySummary(int Count, double? P50, double? P95, double? Max, bool P95Stated, int MinimumForP95);

/// <summary>Response times of one category (Domenia 1 OPE-031) with a histogram of 8 bins for the page.</summary>
public sealed record ResponseCategory(
    string Id,
    string Label,
    LatencySummary Summary,
    string Text,
    ImmutableArray<int> Histogram,
    ImmutableArray<string> HistogramLabels);

/// <summary>One slowness explained by its operation, its phases and its volume (Domenia 1 Get-DomeniaSlownessVerdict, OPE-034).</summary>
public sealed record SlowEvent(DateTimeOffset At, string Operation, string Reference, string Phase, double DurationMs, double TotalMs, string Text);

/// <summary>A paused or recovering source (Domenia 1 provider state): provider, target, kind of state and until when.</summary>
public enum ProviderStateKind
{
    Blocked,
    Paused,
    Recovering,
}

/// <param name="Provider">Directory, Cim, Wts, Network, Storage or Local.</param>
/// <param name="Target">A workstation name, « group:&lt;site&gt; » for a whole site, or null for every target of the provider.</param>
public sealed record ProviderState(string Provider, string? Target, ProviderStateKind Kind, DateTimeOffset? Until, int RecoveryLimit);

/// <summary>
/// Per operation statistics (Domenia 1 OPE-002, Register-DomeniaOperationSample): samples of the session and, when the source keeps
/// them, of earlier sessions. <see cref="Bytes"/> is the estimated volume received (null when not measured, never 0 invented);
/// <see cref="RemoteAttempts"/> counts the requests that left for the directory or a workstation (Domenia 2 never retries: one per
/// remote request, none in simulation); <see cref="Fallbacks"/> counts the fallback transports used (none exist in Domenia 2).
/// </summary>
public sealed record OperationSample(
    string Operation,
    DateTimeOffset At,
    double DurationMs,
    long Items,
    bool Succeeded,
    bool Session,
    long? Bytes = null,
    int RemoteAttempts = 0,
    int Fallbacks = 0);

/// <summary>One row of the statistics grid.</summary>
public sealed record OperationStatsRow(
    string Operation,
    string Label,
    string Screen,
    TaskKind Kind,
    string KindLabel,
    int Samples,
    int SessionSamples,
    double? AverageMs,
    double? MedianMs,
    double? P95Ms,
    double? PerItemMs,
    double? AverageItems,
    double? SuccessPercent,
    DateTimeOffset? LastRun,
    double? AverageBytes,
    double? BytesPerSecond,
    int RemoteAttempts,
    double? FallbackPercent);

/// <summary>
/// One piece of work of the interface measured by the page (Domenia 1 Register-DomeniaUiWork): a closed code
/// (<see cref="ActivityRules.InterfaceWorkLabel"/>) and its duration, never a text of the page.
/// </summary>
public sealed record InterfaceSample(string Work, double Ms);

/// <summary>
/// A beat of the interface late by 400 ms or more (Domenia 1 Register-DomeniaDispatcherLateness), as the page reports it: the
/// lateness, the tracked work that overlapped it (closed code and duration) or none, and the long tasks the browser saw (counted,
/// never taken for a cause).
/// </summary>
public sealed record StallReport(double LateMs, string? Work, double? WorkMs, double? LongTaskMs);

/// <summary>Result of operations.stats.</summary>
public sealed record OperationStats(
    DateTimeOffset GeneratedAt,
    int Samples,
    int Operations,
    bool History,
    string Summary,
    string Note,
    ImmutableArray<OperationStatsRow> Rows);
