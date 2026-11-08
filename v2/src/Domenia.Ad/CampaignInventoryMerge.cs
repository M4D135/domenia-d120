using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Combines two physically completed readings of the same qualified workstation. A partial transient program
/// cannot erase fields already received directly, and retained values never acquire the newer attempt's date.</summary>
internal static class CampaignInventoryMerge
{
    internal static WorkstationInventoryRead Combine(DirectoryComputer expected, WorkstationInventoryRead direct, WorkstationInventoryRead fallback)
    {
        if (!WorkstationIdentity.Matches(expected, fallback.ReportedName, fallback.HostIdentity)) { return direct; }
        if (!WorkstationIdentity.Matches(expected, direct.ReportedName, direct.HostIdentity)) { return fallback; }
        var old = direct.Inventory; var next = fallback.Inventory; var carried = false;
        T? Value<T>(T? newer, T? older) where T : struct
        { if (newer is not null) return newer; if (older is not null) carried = true; return older; }
        string? Text(string? newer, string? older)
        { if (!string.IsNullOrWhiteSpace(newer)) return newer; if (!string.IsNullOrWhiteSpace(older)) carried = true; return older; }
        var merged = next with
        {
            SystemDiskSizeBytes = Value(next.SystemDiskSizeBytes, old.SystemDiskSizeBytes), SystemDiskFreeBytes = Value(next.SystemDiskFreeBytes, old.SystemDiskFreeBytes),
            LastBootAt = Value(next.LastBootAt, old.LastBootAt), Model = Text(next.Model, old.Model), MemoryBytes = Value(next.MemoryBytes, old.MemoryBytes),
            OsCaption = Text(next.OsCaption, old.OsCaption), Build = Text(next.Build, old.Build),
        };
        if (carried)
        {
            merged = merged with
            {
                CheckedAt = old.CheckedAt is { } oldAt && next.CheckedAt is { } newAt ? (oldAt < newAt ? oldAt : newAt) : null,
                State = old.State == MeasureState.Known || next.State == MeasureState.Known ? MeasureState.Known : MeasureState.Incomplete,
            };
        }
        var older = direct.Facts; var newer = fallback.Facts;
        var consoleNew = !string.IsNullOrWhiteSpace(newer.ConsoleUser); var biosNew = !string.IsNullOrWhiteSpace(newer.BiosVersion);
        return fallback with
        {
            Inventory = merged,
            Facts = newer with
            {
                ConsoleUser = consoleNew ? newer.ConsoleUser : older.ConsoleUser, ConsoleAt = consoleNew ? newer.ConsoleAt : older.ConsoleAt,
                BiosVersion = biosNew ? newer.BiosVersion : older.BiosVersion, BiosAt = biosNew ? newer.BiosAt : older.BiosAt,
                Memory = Domenia.Core.Accueil.MemoryUsageFact.Latest(older.Memory, newer.Memory),
            },
            AuthenticationRejected = direct.AuthenticationRejected || fallback.AuthenticationRejected,
            ReadPhysicallyCompleted = direct.ReadPhysicallyCompleted && fallback.ReadPhysicallyCompleted,
        };
    }
}
