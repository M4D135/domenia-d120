namespace Domenia.Core.Poste;

/// <summary>Non-secret, GUID-bound observations. At is when these attributes were read, never the date of a UI refresh.</summary>
public sealed record SecretPresenceRead(DateTimeOffset At, FactState State, int? Keys, DateTimeOffset? Newest);
public sealed record LapsMetadataRead(DateTimeOffset At, LapsKind Kind, long? Expiration, FactState State);
public sealed record WorkstationSecretMetadata(SecretPresenceRead? BitLocker, SecretPresenceRead? LastPositive, LapsMetadataRead? Laps);

public static class PosteSecretCache
{
    public static WorkstationSecretMetadata Merge(WorkstationSecretMetadata? previous, WorkstationSecretMetadata next)
    {
        var attempt = previous?.BitLocker;
        if (next.BitLocker is { } read && (attempt is null || read.At >= attempt.At)) { attempt = read; }
        var positive = new[] { next.LastPositive, next.BitLocker, previous?.LastPositive, previous?.BitLocker }
            .OfType<SecretPresenceRead>().Where(r => r.Keys > 0 && r.State is FactState.Observed or FactState.Estimated).OrderByDescending(r => r.At).FirstOrDefault();
        var laps = previous?.Laps;
        if (next.Laps is { } metadata && (laps is null || metadata.At >= laps.At)) { laps = metadata; }
        return new(attempt, positive, laps);
    }

    public static void Validate(WorkstationSecretMetadata value, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(value);
        static void Invalid() => throw new InvalidDataException("Métadonnées de secret incohérentes ; aucune écriture.");
        void Date(DateTimeOffset at) { if (at == DateTimeOffset.MinValue || at > now.AddMinutes(2)) { Invalid(); } }
        if (value.BitLocker is null && value.Laps is null) { Invalid(); }
        foreach (var read in new[] { value.BitLocker, value.LastPositive }.OfType<SecretPresenceRead>())
        {
            Date(read.At);
            if (read.Newest == DateTimeOffset.MinValue || read.Newest > read.At || read.Keys is < 0 or > 100_000 || read.Keys == 0 && read.Newest is not null) { Invalid(); }
            if (read.State == FactState.Observed && read.Keys is null || read.State == FactState.Estimated && read.Keys is not > 0
                || read.State is FactState.Refused or FactState.Unknown or FactState.Unavailable && (read.Keys is not null || read.Newest is not null)
                || read.State is not (FactState.Observed or FactState.Estimated or FactState.Refused or FactState.Unknown or FactState.Unavailable)) { Invalid(); }
        }
        if (value.LastPositive is { } positive && (positive.Keys is not > 0 || positive.State is not (FactState.Observed or FactState.Estimated)
            || value.BitLocker is null || positive.At > value.BitLocker.At)) { Invalid(); }
        if (value.Laps is { } laps)
        {
            Date(laps.At);
            if (!Enum.IsDefined(laps.Kind) || laps.State is not (FactState.Observed or FactState.Refused or FactState.Unknown or FactState.Unavailable)
                || laps.Expiration is < 0 || laps.Expiration is > 0 && AdValues.FromFileTime(laps.Expiration) is null
                || laps.State != FactState.Observed && laps.Expiration is not null || laps.Kind == LapsKind.None && laps.Expiration is not null) { Invalid(); }
        }
    }

    public static WorkstationSecretMetadata? Applicable(WorkstationSecretMetadata? value, DateTimeOffset created, DateTimeOffset now)
    {
        if (value is null || created == DateTimeOffset.MinValue) { return null; }
        try { Validate(value, now); } catch (InvalidDataException) { return null; }
        var attempt = value.BitLocker is { } b && b.At >= created ? b : null;
        var positive = value.LastPositive is { } p && p.At >= created ? p : null;
        var laps = value.Laps is { } l && l.At >= created ? l : null;
        return attempt is null && laps is null ? null : new(attempt, positive, laps);
    }
}
