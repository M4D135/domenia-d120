using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>State of one measurement (Domenia 1 vocabulary, Domenia-Collection.Model.ps1).</summary>
public enum MeasureState
{
    Known,
    Absent,
    NotRead,
    Refused,
    Expired,
    Incomplete,
    Error,
}

/// <summary>
/// Last presence reading (ping) of a workstation. A reading exists only when <see cref="State"/> is Known with a date and an
/// answer; a missing answer is never a verdict. <see cref="LastOnlineAt"/> is the last time the workstation answered.
/// </summary>
public sealed record PresenceMeasure(MeasureState State, bool? Answered, DateTimeOffset? CheckedAt, DateTimeOffset? LastOnlineAt)
{
    public static PresenceMeasure Unread { get; } = new(MeasureState.NotRead, null, null, null);

    public bool HasReading => State == MeasureState.Known && CheckedAt is not null && Answered is not null;
}

/// <summary>Last inventory reading (WMI). A disk size of 0 or unreadable is « no reading », never a full disk.</summary>
public sealed record InventoryMeasure(
    MeasureState State,
    DateTimeOffset? CheckedAt,
    long? SystemDiskSizeBytes,
    long? SystemDiskFreeBytes,
    DateTimeOffset? LastBootAt,
    string? Model,
    long? MemoryBytes,
    string? OsCaption,
    string? Build)
{
    public static InventoryMeasure Unread { get; } = new(MeasureState.NotRead, null, null, null, null, null, null, null, null);

    public bool HasReading => State == MeasureState.Known && CheckedAt is not null;
}

public sealed record WorkstationObservation(Guid ComputerGuid, PresenceMeasure Presence, InventoryMeasure Inventory);

/// <summary>Local observations of the workstations (presence and inventory), keyed by computer GUID.</summary>
public sealed record FleetObservations(DateTimeOffset? TakenAt, ImmutableArray<WorkstationObservation> Workstations)
{
    public static FleetObservations Empty { get; } = new(null, []);
}

/// <summary>Daily snapshot of the home figures. A null figure is missing, never zero.</summary>
public sealed record DailyFigures(
    DateOnly Day,
    int? WorkstationsOnline,
    int? WorkstationsSeen,
    int? ActiveAccounts,
    int? LockedAccounts,
    int? PasswordsExpiring,
    int? DiskAlerts);

/// <summary>Local calendar days in a given time zone, robust to daylight saving transitions.</summary>
public static class LocalDays
{
    public static DateOnly DateOf(DateTimeOffset instant, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        return DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(instant, timeZone).DateTime);
    }

    /// <summary>UTC instant of the first valid local minute of <paramref name="day"/>.</summary>
    public static DateTimeOffset StartOf(DateOnly day, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        var local = day.ToDateTime(TimeOnly.MinValue, DateTimeKind.Unspecified);
        while (timeZone.IsInvalidTime(local))
        {
            local = local.AddMinutes(1);
        }
        var offset = timeZone.IsAmbiguousTime(local) ? timeZone.GetAmbiguousTimeOffsets(local).Max() : timeZone.GetUtcOffset(local);
        return new DateTimeOffset(local, offset).ToUniversalTime();
    }
}
