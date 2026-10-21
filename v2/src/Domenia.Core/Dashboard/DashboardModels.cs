using System.Collections.Immutable;

namespace Domenia.Core;

public enum WidgetKind
{
    Kpi,
    Distribution,
    Series,
    Gauge,
    List,
    Timeline,
}

/// <summary>Tone usable as is in the page's data-tone attribute.</summary>
public enum Tone
{
    Ok,
    Warn,
    Alert,
    Info,
    Off,
}

public enum WidgetScope
{
    Domain,
    WorkingOu,
    Session,
}

public enum WidgetFamily
{
    Directory,
    Presence,
    Inventory,
    LocalComputation,
}

/// <summary>Watch-list rules, in their display order (docs/OPERATIONS.md § 4.7).</summary>
public enum WatchRule
{
    LowDisk,
    NeverLoggedOn,
    Stale,
    MachinePasswordOld,
    DiskTight,
    Uptime,
}

/// <summary>One widget of the home page. <see cref="Data"/> is null if and only if the widget is disabled or never measured.</summary>
public sealed record DashboardWidget(
    string Id,
    WidgetKind Kind,
    string Title,
    string ScopeLabel,
    bool Enabled,
    Tone Tone,
    DateTimeOffset? MeasuredAt,
    bool Stale,
    string Detail,
    object? Data);

public sealed record DashboardSummary(
    DateTimeOffset GeneratedAt,
    ScopeSelection Scope,
    StoreStatus Store,
    IReadOnlyDictionary<string, DashboardWidget> Widgets);

public sealed record HistoryPoint(DateOnly Date, int Value);

public sealed record KpiDelta(int Value, string Period, string Label, Tone Tone);

public sealed record BreakdownItem(string Key, string Label, int Value, Tone Tone);

public sealed record KpiData(
    int Value,
    int? Total,
    string Unit,
    KpiDelta? Delta,
    ImmutableArray<HistoryPoint> History,
    ImmutableArray<BreakdownItem> Breakdown);

public sealed record DistributionSegment(string Key, string Label, int Value, double Percent, ImmutableArray<string> Members);

public sealed record DistributionLead(string Label, double Percent);

/// <summary>Ring chart data; <see cref="Lead"/> is null only when the scope holds no enabled computer.</summary>
public sealed record DistributionData(int Total, string Unit, string CenterText, ImmutableArray<DistributionSegment> Segments, DistributionLead? Lead);

public sealed record SeriesPoint(DateOnly Date, string Label, int? Value, bool Partial);

public sealed record SeriesData(string Unit, int Max, ImmutableArray<SeriesPoint> Points);

public sealed record GaugeData(double Percent, int Fresh, int Total, int FreshDays, ImmutableArray<BreakdownItem> Breakdown);

public sealed record WatchlistRow(
    string Name,
    string Dn,
    string ObjectGuid,
    WatchRule RuleId,
    string Reason,
    Tone Severity,
    int OtherReasons,
    DateTimeOffset? LastSeenAt);

public sealed record WatchlistData(int Total, int Shown, ImmutableArray<WatchlistRow> Rows);

public sealed record TimelineRow(string Label, DateTimeOffset At, Tone Tone);

public sealed record TimelineData(int Total, ImmutableArray<TimelineRow> Rows);

/// <summary>
/// Everything the pure calculation needs: no clock, time zone or culture is read inside. <see cref="RootDn"/> (domain root
/// of the session) lets a working scope on the whole domain be labelled « Domaine … »; null falls back to the snapshot.
/// </summary>
public sealed record DashboardInput(
    DirectoryState State,
    ScopeSelection Scope,
    DashboardPolicy Policy,
    IReadOnlySet<string> DisabledWidgets,
    ImmutableArray<JournalEntry> Journal,
    DateTimeOffset Now,
    TimeZoneInfo TimeZone,
    DirectorySourceKind SourceKind,
    string? RootDn = null);
