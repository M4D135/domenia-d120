using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Family of a collection run (Domenia 1 domenia_domain_metadata): directory objects, presence (ping) or inventory (WMI).</summary>
public enum CollectionFamily
{
    Directory,
    Presence,
    Inventory,
}

/// <summary>Recorded status of a run (Domenia 1 Get-DomeniaCollectionStatusText): réussi, partiel, en échec, arrêté.</summary>
public enum CollectionStatus
{
    Success,
    Partial,
    Error,
    Cancelled,
}

/// <summary>
/// One run of the local base as recorded (Domenia 1 ConvertFrom-DomeniaCollectionRunRecord): only what was recorded, nothing
/// guessed. <see cref="Done"/>, <see cref="Targets"/> and <see cref="Failed"/> are null when not measured.
/// </summary>
public sealed record CollectionRun(
    CollectionFamily Family,
    string ScopeDn,
    string ScopeName,
    bool Subtree,
    DateTimeOffset AttemptAt,
    CollectionStatus Status,
    int? Done,
    int? Targets,
    int? Failed,
    DateTimeOffset? SuccessAt,
    string? Reason);

/// <summary>One row of « Derniers relevés par OU » (Domenia 1 ConvertTo-DomeniaCollectionRunListRows).</summary>
public sealed record CollectionRunRow(
    string Id,
    CollectionFamily Family,
    string Type,
    string Ou,
    string OuDn,
    DateTimeOffset AttemptAt,
    CollectionStatus Status,
    string StatusLabel,
    Tone Tone,
    string Counts,
    DateTimeOffset? SuccessAt,
    string Reason);

/// <summary>
/// Phase of a running collection batch (Domenia 1 Get-DomeniaExperienceBatchRows: Préparation, Lecture AD, À confirmer, En cours,
/// Enregistrement), plus the stop asked and the end.
/// </summary>
public enum SurveyPhase
{
    Preparing,
    ReadingDirectory,
    Confirming,
    Running,
    Saving,
    Stopping,
    Done,
}

/// <summary>A collection batch in progress or just ended (scalar fields only: no target list ever leaves the reader).</summary>
public sealed record SurveyState(
    string Id,
    CollectionFamily Family,
    string Type,
    string ScopeDn,
    string ScopeName,
    int Total,
    int Done,
    int Failed,
    SurveyPhase Phase,
    string PhaseLabel,
    bool Open,
    bool StopRequested,
    DateTimeOffset StartedAt,
    DateTimeOffset? EndedAt,
    string Status,
    int PingErrors = 0,
    int InFlight = 0,
    int PendingSaves = 0,
    int Skipped = 0);

/// <summary>
/// The interrupted survey that can be resumed (Domenia 1 Get-DomeniaCampaignResumeStatus, OPE-029): offered once per session;
/// « Reprendre » reads only the remaining workstations after the usual confirmation of their count and scope.
/// </summary>
public sealed record SurveyOffer(
    bool Resumable,
    int Remaining,
    int Total,
    CollectionFamily Family,
    string Type,
    string ScopeName,
    string ScopeDn,
    DateTimeOffset? InterruptedAt,
    string Reason,
    bool Offered);

/// <summary>Result of operations.runs (OPE-027 to OPE-029).</summary>
public sealed record CollectionRunsView(
    DateTimeOffset GeneratedAt,
    bool Available,
    ImmutableArray<CollectionRunRow> Rows,
    SurveyState? Current,
    SurveyOffer? Offer,
    string CurrentText,
    string Note);

/// <summary>Status of one check of the application (Domenia 1 Add-Check: OK or ERREUR; Domenia 2 adds « à savoir » and « sans objet »).</summary>
public enum CheckStatus
{
    Ok,
    Warn,
    Error,
    Info,
}

/// <summary>One line of « Vérifier l’application » (Domenia 1 Start-SelfCheck).</summary>
public sealed record CheckRow(string Category, string Test, CheckStatus Status, double DurationMs, string Detail);

/// <summary>
/// Facts of the page itself handed to operations.check.run (closed values only, checked again by the engine): content security
/// policy strict or not, shell elements found, motion setting and version of the web engine. The engine writes the rows, so the
/// report, its summary, the journal and the dossier count the same lines.
/// </summary>
public sealed record PageChecks(bool? StrictPolicy, int? Structure, int? StructureTotal, string? Motion, string? WebView);

/// <summary>Result of operations.check.run.</summary>
public sealed record CheckReport(DateTimeOffset At, bool Full, int Ok, int Errors, int Warnings, double TotalMs, string Summary, ImmutableArray<CheckRow> Rows);

/// <summary>One common reason why an action is unavailable, with a safe route (Domenia 1 Get-DomeniaUnavailableReasonLines, OPE-003).</summary>
public sealed record BlockerLine(Tone Tone, string Text, string? RouteLabel, string? Route);

/// <summary>Result of operations.blockers: blocking facts of the session (nothing is tested) and the transports used or kept off.</summary>
public sealed record BlockerReport(DateTimeOffset At, ImmutableArray<BlockerLine> Lines, ImmutableArray<string> Transports, string Note);

/// <summary>One open task in one plain sentence for the engine state (Domenia 1 UX-32).</summary>
public sealed record EngineTaskLine(string Reference, string Text);

/// <summary>Result of operations.engine (Domenia 1 Get-DomeniaRuntimeHealthText, OPE-006).</summary>
public sealed record EngineState(
    DateTimeOffset At,
    string Product,
    string Version,
    string Runtime,
    string Os,
    bool Is64Bit,
    double? MemoryMb,
    string Mode,
    bool ReadOnly,
    string WriteState,
    Tone WriteTone,
    string Receipts,
    string Preferences,
    int Operations,
    int Tasks,
    ImmutableArray<EngineTaskLine> TaskLines,
    ImmutableArray<string> Notes);

/// <summary>Result of operations.health (Domenia 1 Get-DomeniaOperationsHealthText, OPE-005 and OPE-030 to OPE-036).</summary>
public sealed record EngineHealth(
    DateTimeOffset At,
    double? MemoryMb,
    ImmutableArray<ResponseCategory> Categories,
    ImmutableArray<SlowEvent> Slow,
    int TraceFaults,
    string LocalSave,
    Tone LocalSaveTone,
    string Sqlite,
    ImmutableArray<string> Providers,
    ImmutableArray<string> Collection,
    LatencySummary WriteWaits,
    string Note);

/// <summary>One line of the session journal (operations journal of the session, and the journal kept by the source).</summary>
public sealed record JournalLine(DateTimeOffset At, string Label, Tone Tone, string Origin);

/// <summary>Result of operations.journal (Domenia 1 OPE-014).</summary>
public sealed record JournalView(DateTimeOffset At, int Session, int Source, ImmutableArray<JournalLine> Lines, string Note);

/// <summary>Result of operations.rules: write kinds (postconditions, compensations) and life-cycle sequences.</summary>
public sealed record WriteRulesView(ImmutableArray<WriteKindRow> Kinds, ImmutableArray<LifecycleView> Lifecycles, string Note);

/// <summary>Result of operations.receipts.detail and operations.receipts.review: the receipt with what it proves and offers.</summary>
public sealed record ReceiptDetailView(ReceiptView Receipt, WriteKindRule Rule, CompensationAssessment Compensation, ReceiptActions Actions, bool ExecutorAvailable);

/// <summary>Result of operations.overview: everything the head of the screen needs, from memory and local reads only.</summary>
public sealed record OperationsOverview(
    DateTimeOffset At,
    string Mode,
    bool Simulation,
    int ReceiptsTotal,
    int ReceiptsPending,
    int ReceiptsUnreadable,
    bool ReceiptsReadable,
    bool ReceiptsPersistent,
    string ReceiptsSummary,
    PendingPill Pill,
    TaskSummary Tasks,
    int SessionTasks,
    int SessionFailures,
    double? SuccessPercent,
    LatencySummary Engine,
    ImmutableArray<string> WriteKinds,
    int HiddenAutomatic,
    string Note);

/// <summary>
/// Result of operations.center: what a panel of the shell needs from anywhere (Domenia 1 OPE-015, OPE-025, OPE-026): the pill of
/// the receipts to verify with its oldest receipt, the tasks in progress (64 at most, collection batches first), the summary and
/// the number of recent operations to review. Memory and local receipts only.
/// </summary>
public sealed record OperationsCenter(
    DateTimeOffset At,
    PendingPill Pill,
    bool ReceiptsReadable,
    string WriteState,
    Tone WriteTone,
    TaskSummary Summary,
    ImmutableArray<ActivityRow> Open,
    int Attention,
    string Note);

/// <summary>Result of operations.interface.report: samples kept and whether a stall line was written in the technical journal.</summary>
public sealed record InterfaceReportResult(int Kept, bool Logged);

/// <summary>A document written by Opérations (CSV, diagnostic, dossier) or kept in memory when the mode writes nothing.</summary>
public sealed record ExportResult(bool Saved, string? Path, string Name, string? Folder, string Sha256, long Bytes, string Message, DateTimeOffset At);

/// <summary>Result of operations.diagnostic.preview: the redacted diagnostic, its JSON text and what it contains or never contains.</summary>
public sealed record DiagnosticPreview(string Format, string Json, ImmutableArray<string> Preview, int Bytes, string Sha256, DateTimeOffset At);
