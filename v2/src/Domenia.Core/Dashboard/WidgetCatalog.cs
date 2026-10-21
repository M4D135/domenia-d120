using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Diagnostics.CodeAnalysis;

namespace Domenia.Core;

/// <summary>Default thresholds, taken from the Domenia 1 health rules (Domenia-HealthRules.Model.ps1).</summary>
public sealed record DashboardPolicy(
    TimeSpan ObservationMaxAge,
    TimeSpan StaleAfter,
    TimeSpan PasswordExpiringWindow,
    int DiskFreeAlertPercent,
    int DiskFreeWarnPercent,
    int UptimeDays,
    int StaleLogonDays,
    int MachinePasswordDays,
    int FreshDays,
    int FreshnessOkPercent,
    int FreshnessWarnPercent,
    int HistoryDays,
    int SeriesDays,
    int DeltaDays,
    int WatchlistRows,
    int TimelineRows)
{
    public static DashboardPolicy Default { get; } = new(
        ObservationMaxAge: TimeSpan.FromDays(30),
        StaleAfter: TimeSpan.FromDays(7),
        PasswordExpiringWindow: TimeSpan.FromDays(7),
        DiskFreeAlertPercent: 10,
        DiskFreeWarnPercent: 20,
        UptimeDays: 30,
        StaleLogonDays: 90,
        MachinePasswordDays: 60,
        FreshDays: 7,
        FreshnessOkPercent: 90,
        FreshnessWarnPercent: 60,
        HistoryDays: 14,
        SeriesDays: 7,
        DeltaDays: 7,
        WatchlistRows: 6,
        TimelineRows: 6);
}

public sealed record WidgetDefinition(string Id, WidgetKind Kind, string Title, WidgetScope Scope, WidgetFamily Family);

/// <summary>Closed list of the home widgets, in contract order (docs/OPERATIONS.md § 4.1).</summary>
public static class WidgetCatalog
{
    public const string WorkstationsOnline = "workstationsOnline";
    public const string ActiveAccounts = "activeAccounts";
    public const string LockedAccounts = "lockedAccounts";
    public const string PasswordsExpiring = "passwordsExpiring";
    public const string DiskAlerts = "diskAlerts";
    public const string OsDistribution = "osDistribution";
    public const string WorkstationActivity = "workstationActivity";
    public const string MeasureFreshness = "measureFreshness";
    public const string Watchlist = "watchlist";
    public const string RecentOperations = "recentOperations";

    public static ImmutableArray<WidgetDefinition> All { get; } =
    [
        new(WorkstationsOnline, WidgetKind.Kpi, "Postes en ligne", WidgetScope.WorkingOu, WidgetFamily.Presence),
        new(ActiveAccounts, WidgetKind.Kpi, "Comptes actifs", WidgetScope.Domain, WidgetFamily.Directory),
        new(LockedAccounts, WidgetKind.Kpi, "Comptes verrouillés", WidgetScope.Domain, WidgetFamily.Directory),
        new(PasswordsExpiring, WidgetKind.Kpi, "Mots de passe expirant sous 7 jours", WidgetScope.Domain, WidgetFamily.Directory),
        new(DiskAlerts, WidgetKind.Kpi, "Alertes disque", WidgetScope.WorkingOu, WidgetFamily.Inventory),
        new(OsDistribution, WidgetKind.Distribution, "Systèmes d’exploitation", WidgetScope.WorkingOu, WidgetFamily.Directory),
        new(WorkstationActivity, WidgetKind.Series, "Activité des postes · 7 jours", WidgetScope.WorkingOu, WidgetFamily.LocalComputation),
        new(MeasureFreshness, WidgetKind.Gauge, "Fraîcheur des mesures", WidgetScope.WorkingOu, WidgetFamily.Presence),
        new(Watchlist, WidgetKind.List, "Postes à surveiller", WidgetScope.WorkingOu, WidgetFamily.LocalComputation),
        new(RecentOperations, WidgetKind.Timeline, "Dernières opérations", WidgetScope.Session, WidgetFamily.LocalComputation),
    ];

    private static readonly FrozenDictionary<string, WidgetDefinition> ById = All.ToFrozenDictionary(w => w.Id, StringComparer.Ordinal);

    public static bool TryGet(string? id, [NotNullWhen(true)] out WidgetDefinition? definition)
    {
        if (id is not null && ById.TryGetValue(id, out var found))
        {
            definition = found;
            return true;
        }
        definition = null;
        return false;
    }
}
