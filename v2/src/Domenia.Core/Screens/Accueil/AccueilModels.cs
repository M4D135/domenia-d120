using System.Collections.Immutable;

namespace Domenia.Core.Accueil;

// ---------------------------------------------------------------- refresh of the OU (ACC-001 to ACC-008)

/// <summary>One stage of an OU refresh, in its fixed order.</summary>
public sealed record RefreshStage(string Id, string Label, string Detail);

/// <summary>
/// Plan of an explicit OU refresh, frozen at the click (Domenia 1, Invoke-DomeniaOuRefresh): mode, OU, workstations, stages, the
/// probe plan of the active widgets, and the estimate. Valid five minutes, used once; never replayed.
/// </summary>
public sealed record RefreshPlan(
    string Id,
    string Mode,
    string Title,
    string Summary,
    ScopeSelection Scope,
    int Targets,
    ImmutableArray<RefreshStage> Stages,
    ImmutableArray<string> Probes,
    ImmutableArray<string> ProbeNames,
    int EstimateSeconds,
    string EstimateText,
    ImmutableArray<string> Warnings,
    string Confirm,
    DateTimeOffset CreatedAt,
    DateTimeOffset ExpiresAt);

/// <summary>Progress of one stage, pushed to the page by the event « accueil.refresh.run:progress ».</summary>
public sealed record RefreshProgress(string RunId, string Stage, string State, string Label, string Detail, int Index, int Count, int Percent);

/// <summary>A stage of a finished or running refresh.</summary>
public sealed record RefreshStageResult(string Id, string Label, string State, string Detail, DateTimeOffset? StartedAt, DateTimeOffset? FinishedAt);

/// <summary>Report of one OU refresh: status, stages, collection runs recorded.</summary>
public sealed record RefreshReport(
    string Id,
    string Mode,
    string Status,
    string Label,
    ScopeSelection Scope,
    DateTimeOffset StartedAt,
    DateTimeOffset? FinishedAt,
    ImmutableArray<RefreshStageResult> Stages,
    ImmutableArray<CollectionRunRow> Runs,
    bool Stopping);

/// <summary>Result of accueil.refresh.state.</summary>
public sealed record RefreshState(bool Running, RefreshReport? Current, RefreshReport? Last);

/// <summary>Result of accueil.refresh.stop.</summary>
public sealed record RefreshStopResult(bool Stopping, string Label);

// ---------------------------------------------------------------- first steps (ACC-015 to ACC-018)

/// <summary>One step of the first run guide (Get-DomeniaFirstRunPlan, point 148).</summary>
public sealed record FirstStep(string Id, int Number, string Label, string Text, bool Done, bool Enabled, bool Current, string ActionLabel);

/// <summary>Result of accueil.firstSteps.</summary>
public sealed record FirstStepsInfo(
    ImmutableArray<FirstStep> Steps,
    string? Next,
    bool Done,
    string Deferred,
    bool Dismissed,
    bool HelpSeen,
    bool ReadInterrupted,
    bool Offline,
    int Completed,
    int Total);

// ---------------------------------------------------------------- scope, favourites, last view

/// <summary>A favourite working OU of the domain (ACC-011 improvement: named favourites switched in one click).</summary>
public sealed record ScopeFavorite(string Id, string Name, string Dn, bool Subtree, string Path, bool Exists);

public sealed record ScopeFavorites(ImmutableArray<ScopeFavorite> Items, int Max);

/// <summary>Last overview computed for the same base and OU (R40, cache first): counts and a dated line, never a name.</summary>
public sealed record LastViewNotice(bool Available, string Text, DateTimeOffset? ComputedAt, int Machines, int Problems, string? ScopeLabel);

// ---------------------------------------------------------------- health editor

/// <summary>Result of accueil.health.policy: the policy of one scope, its origins and the editor choices.</summary>
public sealed record HealthPolicyView(
    string? ScopeDn,
    string ScopeLabel,
    bool Local,
    HealthPolicy Policy,
    ImmutableArray<HealthOriginRow> Origins,
    ImmutableArray<HealthEditorScope> Scopes,
    ImmutableArray<HealthRuleView> Rules,
    ImmutableArray<HealthThresholdDefinition> Thresholds,
    ImmutableArray<int> SuspensionHours,
    int MaxCustomRules,
    bool QueryAlertsAvailable);

/// <summary>One check in the editor: state now, where its setting comes from, and its active suspension.</summary>
public sealed record HealthRuleView(string Id, string Name, bool Fleet, string State, string Origin, HealthSuspension? Suspension);

public sealed record HealthExceptions(ImmutableArray<HealthExceptionRow> Rows);

// ---------------------------------------------------------------- analysis

/// <summary>One reading offered by the comparison (daily, manual or current view).</summary>
public sealed record SnapshotItem(string Id, string Kind, string Label, DateOnly Day, DateTimeOffset ComputedAt);

public sealed record SnapshotList(ImmutableArray<SnapshotItem> Items, ImmutableArray<FleetPivotTable> Tables);

// ---------------------------------------------------------------- exact sets

/// <summary>Result of accueil.targets: the exact workstations of one figure, from the calculation that produced it.</summary>
public sealed record TargetList(string Key, string Label, int Total, bool Truncated, ImmutableArray<FleetTargetRow> Rows, string Revision);

// ---------------------------------------------------------------- catalogs

public sealed record FleetWidgetView(string Key, string Title, string Group, FleetDataKind Kind, string Visual, ImmutableArray<string> Visuals, string Size, string Description, bool Default);

public sealed record ProbeView(string Id, string Name, string Category, string Mode, string Transform, ImmutableArray<string> Visuals, string Visual, bool Slow, bool SkipOnDc, string Origin, string Summary);

public sealed record WidgetGroupView(string Name, ImmutableArray<FleetWidgetView> Widgets);

public sealed record ProbeCategoryView(string Name, ImmutableArray<ProbeView> Probes);

/// <summary>Result of accueil.widgets.catalog.</summary>
public sealed record WidgetCatalogView(
    ImmutableArray<WidgetGroupView> Groups,
    IReadOnlyDictionary<string, string> VisualNames,
    IReadOnlyDictionary<string, string> SizeNames,
    ImmutableArray<FleetPreset> Presets,
    ImmutableArray<ProbeCategoryView> Probes,
    int ProbeCount,
    bool QueriesAvailable,
    string QueriesText);

/// <summary>Result of accueil.layout.* : the layout and whether it differs from the delivered one.</summary>
public sealed record FleetLayoutView(ImmutableArray<FleetLayoutItem> Items, bool Customized, int Max);

// ---------------------------------------------------------------- session tools

/// <summary>One check of « Vérifier l’application ».</summary>
public sealed record SelfCheckItem(string Id, string Label, Tone Tone, string Detail);

public sealed record SelfCheckResult(DateTimeOffset CheckedAt, int Ok, int Warnings, int Failures, string Summary, ImmutableArray<SelfCheckItem> Checks);

public sealed record CacheClearItem(string Label, int Count);

public sealed record CacheClearResult(ImmutableArray<CacheClearItem> Cleared, string Text);

public sealed record JournalView(int Total, ImmutableArray<JournalEntry> Rows);

public sealed record CollectionRunList(int Total, ImmutableArray<CollectionRunRow> Rows);

/// <summary>Result of accueil.bitlocker.read: counts of the OU, never a key.</summary>
public sealed record BitLockerSummary(string ScopeLabel, int Read, int WithKey, int WithoutKey, DateTimeOffset At, bool Truncated, bool ClassPresent, string Text);
