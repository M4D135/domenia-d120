using System.Collections.Immutable;
using System.Text;
using System.Text.Json;

namespace Domenia.Core.Poste;

/// <summary>One bounded read, kept separately from the last complete list; a refusal never means zero sessions.</summary>
public sealed record WorkstationSessionRead(DateTimeOffset At, SourceStatus Status, ImmutableArray<LocalSession> Rows, int Unread, string Reader, string? Detail)
{
    public bool AuthenticationRejected { get; init; }
    public bool Complete => Status is SourceStatus.Ok or SourceStatus.Empty && Unread == 0;
}
public sealed record WorkstationSessionMemory(string Computer, WorkstationSessionRead Latest, WorkstationSessionRead? LastComplete);
public sealed record LegacySessionCacheRead(WorkstationSessionMemory? Memory, string? Notice);

/// <summary>Read the original D1 Sessions/WTS detail for one GUID; no migration, refresh or write.</summary>
public interface ILegacySessionCache
{
    Task<LegacySessionCacheRead> ReadLegacySessionsAsync(DirectoryComputer computer, CancellationToken cancellationToken);
}

public static class PosteSessionCache
{
    public const int MaxSessions = 512;
    public const int MaxBytes = 2 * 1024 * 1024;

    public static WorkstationSessionMemory Merge(WorkstationSessionMemory? previous, WorkstationSessionMemory next)
    {
        // Equal timestamps with differing payloads cannot establish which read is newer.
        if (previous is not null && next.Latest.At <= previous.Latest.At) { return previous; }
        var complete = new[] { previous?.LastComplete, previous?.Latest, next.LastComplete, next.Latest }
            .OfType<WorkstationSessionRead>().Where(r => r.Complete).OrderByDescending(r => r.At).FirstOrDefault();
        return next with { LastComplete = complete };
    }

    public static void Validate(WorkstationSessionMemory value, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(value);
        static bool Text(string? value, int max, bool required = false) => value is null ? !required : value.Length <= max
            && (!required || value.Length > 0) && !value.Any(char.IsControl);
        static void Invalid() => throw new InvalidDataException("Sessions Windows hors du contrat local ; aucune écriture.");
        if (!Text(value.Computer, 255, true) || value.Latest is null) { Invalid(); }
        foreach (var read in new[] { value.Latest, value.LastComplete }.OfType<WorkstationSessionRead>())
        {
            if (read.At == DateTimeOffset.MinValue || read.At > now.AddMinutes(2) || !Enum.IsDefined(read.Status)
                || read.Rows.IsDefault || read.Rows.Length > MaxSessions || read.Unread is < 0 or > MaxSessions
                || !Text(read.Reader, 320, true) || !Text(read.Detail, 2048)
                || read.Status == SourceStatus.Empty && (read.Rows.Length != 0 || read.Unread != 0)
                || read.Status == SourceStatus.Ok && read.Unread != 0
                || read.AuthenticationRejected && read.Status is SourceStatus.Ok or SourceStatus.Empty
                || read.Rows.Any(r => r is null) || read.Rows.Select(r => r.Id).Distinct(StringComparer.Ordinal).Count() != read.Rows.Length)
            { Invalid(); }
            foreach (var row in read.Rows)
            {
                if (!Text(row.Id, 64, true) || !Text(row.Station, 512) || !Text(row.User, 320) || !Text(row.Domain, 255)
                    || !Text(row.State, 64, true) || !Text(row.Protocol, 32, true) || !Text(row.ClientName, 255)
                    || row.LogonAt == DateTimeOffset.MinValue || row.LogonAt > read.At || row.Idle < TimeSpan.Zero || row.Idle > TimeSpan.FromDays(3660))
                { Invalid(); }
            }
        }
        if (value.LastComplete is { } completed && (!completed.Complete || completed.At > value.Latest!.At)) { Invalid(); }
        if (Encoding.UTF8.GetByteCount(JsonSerializer.Serialize(value)) > MaxBytes) { Invalid(); }
    }

    public static WorkstationSessionMemory? Applicable(WorkstationSessionMemory? value, DateTimeOffset created, DateTimeOffset now)
    {
        if (value is null || created == DateTimeOffset.MinValue) { return null; }
        try { Validate(value, now); } catch (InvalidDataException) { return null; }
        if (value.Latest.At < created) { return null; }
        return value.LastComplete is { } complete && complete.At < created ? value with { LastComplete = null } : value;
    }
}
