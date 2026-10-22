using System.Collections.Immutable;

namespace Domenia.Core.Accueil;

/// <summary>Button offered by a widget or a hint, run only on the operator's click (never by a rule).</summary>
public sealed record FleetAction(string Id, string Label, string Tip);

/// <summary>One part of a chart: label, count, tone, and the key of its exact set of workstations (point 2).</summary>
public sealed record FleetPart(string Label, double Value, Tone? Tone, string TargetsKey, int Targets);

/// <summary>One day of a curve drawn from the daily local snapshots; a missing day is absent, never 0.</summary>
public sealed record FleetTrendPoint(DateOnly Date, string Label, double Value);

/// <summary>
/// One widget of the fleet board (New-DomeniaBoardEntry). <see cref="Value"/> is the text shown (« 412 », « Non lu »),
/// <see cref="Number"/> the figure when there is one. <see cref="Tone"/> null: no state; Off: greyed (old or not measured).
/// </summary>
public sealed record FleetEntry(
    string Key,
    string Title,
    string Group,
    FleetDataKind Kind,
    string Value,
    double? Number,
    string? Unit,
    string Detail,
    Tone? Tone,
    string? CenterText,
    string? Subtitle,
    ImmutableArray<FleetPart> Items,
    ImmutableArray<FleetTrendPoint> Points,
    int? Targets,
    string? TargetsKey,
    FleetAction? Action,
    bool Measured);

/// <summary>One point of attention: rule, level (alert, warn, info), text, workstations concerned and their exact set.</summary>
public sealed record FleetPoint(string Id, string Rule, string Level, string Text, int Count, string? TargetsKey);

/// <summary>
/// Fleet health (Get-DomeniaFleetHealth, point 74): share of the assessed workstations without any critical point nor point to
/// watch; no reassuring score on a poorly covered perimeter, unassessed workstations counted apart and never healthy.
/// </summary>
public sealed record FleetHealth(
    int? Score,
    string Verdict,
    Tone Tone,
    string Detail,
    string? Badge,
    string PointsTitle,
    int Alerts,
    int Warnings,
    int Information,
    ImmutableArray<FleetPoint> Points,
    int Masked,
    int Total,
    int Assessed,
    int Healthy,
    int Problems,
    int Unassessed,
    string HealthyKey,
    string ProblemsKey,
    string UnknownKey);

/// <summary>The population every figure, click and export of a board refers to (point 2).</summary>
public sealed record FleetPopulation(int Machines, int Enabled, int Disabled, int Unknown, string Criteria, string StoreId);

/// <summary>Hint under an empty section, with its optional action (SP-17).</summary>
public sealed record FleetHint(string Group, string Text, FleetAction? Action);

/// <summary>
/// Figures of a daily snapshot and the fingerprints that separate perimeter, coverage and rules (point 78). A null figure was
/// not measured, never zero.
/// </summary>
public sealed record FleetFigures(
    int Machines,
    int Healthy,
    int Problems,
    int Stale,
    int StaleDays,
    int EndOfService,
    int Disabled,
    int Windows10,
    int? LowDisk,
    int Assessed,
    int Unassessed,
    int? Score,
    int PingRead,
    int WmiRead,
    string PopulationHash,
    string AssessedHash,
    string CoverageHash,
    string PolicyHash,
    int FormatVersion);

/// <summary>One reading of the fleet figures: daily snapshot, manual snapshot or the current view.</summary>
public sealed record FleetSnapshot(string Id, string Kind, string Label, DateOnly Day, DateTimeOffset ComputedAt, FleetFigures Figures);

/// <summary>Result of accueil.board (docs/ops/accueil.md § 3).</summary>
public sealed record FleetBoard(
    string Revision,
    DateTimeOffset ComputedAt,
    ScopeSelection Scope,
    string ScopeLabel,
    FleetPopulation Population,
    IReadOnlyDictionary<string, FleetEntry> Entries,
    FleetHealth Health,
    ImmutableArray<FleetHint> Hints,
    string Summary,
    FleetSnapshot Snapshot);

/// <summary>One workstation of an exact set (« Postes concernés »).</summary>
public sealed record FleetTargetRow(
    string Name,
    string Dn,
    Guid Guid,
    string Ou,
    string State,
    string? System,
    DateOnly? LastLogon,
    string Presence,
    double? DiskFree,
    int? UptimeDays,
    string? Model,
    string? User);

/// <summary>Dimensions of one workstation for the cross tables (point 79).</summary>
public sealed record FleetPivotFacts(string Site, string Version, string Model, string Ram, string Presence, string Bios, bool Ping, bool Inventory);

/// <summary>Where a rule finds its data (point 75).</summary>
public sealed record FleetEvidence(string Source, string Observed, string Value, string Rule, string Collection);

/// <summary>One line of « Comprendre le score » (Get-DomeniaHealthExplanation).</summary>
public sealed record FleetExplanationRow(
    string Id,
    string Rule,
    string Status,
    int Machines,
    string Effect,
    string Eligible,
    int? EligibleCount,
    int Exclusive,
    int Masked,
    string Consequence,
    string ObservationState,
    bool MissingData,
    FleetEvidence Evidence,
    string? TargetsKey,
    string? MaskedKey);

/// <summary>Rules applied by OU in a view.</summary>
public sealed record FleetPolicyRow(string Scope, int Machines, int Suspended, string Thresholds);

/// <summary>Result of accueil.health.explain.</summary>
public sealed record FleetExplanation(
    string Summary,
    int ActiveRules,
    int DisabledRules,
    int SuspendedRules,
    int MaskedMachines,
    int Population,
    int Unknown,
    int Assessed,
    ImmutableArray<FleetExplanationRow> Rows,
    ImmutableArray<FleetPolicyRow> Policies,
    string Scope);

/// <summary>Everything one calculation of the board produced; only <see cref="Board"/> goes to the page as is.</summary>
public sealed record FleetComputation(
    FleetBoard Board,
    ImmutableDictionary<string, ImmutableArray<Guid>> Targets,
    ImmutableDictionary<string, string> TargetLabels,
    ImmutableDictionary<Guid, FleetTargetRow> Rows,
    ImmutableDictionary<Guid, FleetPivotFacts> Dimensions,
    FleetExplanation Explanation,
    ImmutableArray<Guid> Population);

/// <summary>Inputs of one calculation of the board: no clock, culture or file is read inside.</summary>
public sealed record FleetBoardInput(
    DirectoryState State,
    ScopeSelection Scope,
    string DomainDn,
    string DomainName,
    HealthPolicyBook Book,
    AccueilFacts Facts,
    BitLockerPresence? BitLocker,
    ProbeReadings Probes,
    ImmutableArray<FleetLayoutItem> Layout,
    ImmutableArray<FleetSnapshot> History,
    DateTimeOffset Now,
    TimeZoneInfo Zone,
    int ObservationMaxAgeDays = 30);
