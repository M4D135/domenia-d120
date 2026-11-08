namespace Domenia.Simulation;

/// <summary>One explicit opening instant for a demo; an injectable advancing clock preserves expiry rules and reproducibility.</summary>
public sealed class DemonstrationClock : TimeProvider
{
    private readonly DateTimeOffset openedAt, origin;
    private readonly TimeProvider elapsed;
    private readonly TimeZoneInfo zone;
    public DemonstrationClock(DateTimeOffset openedAt, TimeZoneInfo zone, TimeProvider? elapsed = null)
    {
        this.openedAt = openedAt.ToUniversalTime();
        this.zone = zone;
        this.elapsed = elapsed ?? System;
        origin = this.elapsed.GetUtcNow();
    }
    public override DateTimeOffset GetUtcNow() => openedAt + (elapsed.GetUtcNow() - origin);
    public override TimeZoneInfo LocalTimeZone => zone;
}
