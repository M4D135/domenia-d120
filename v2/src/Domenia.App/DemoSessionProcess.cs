using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.App;

/// <summary>Process-owned fiction only. The browser supplies no profile path, seed, identity or capability.</summary>
internal static class DemoSessionProcess
{
    public static bool Active { get; private set; }
    public static string SessionId { get; } = Guid.NewGuid().ToString("N");
    public static string Generation { get; private set; } = Guid.NewGuid().ToString("N");
    public static TimeProvider Clock { get; private set; } = new DemonstrationClock(DateTimeOffset.UtcNow, TimeZoneInfo.Local);
    private static int reset;

    /// <summary>Called before AppPaths or the technical journal is initialized; does not access the file system.</summary>
    public static bool Configure(IReadOnlyList<string> args)
    {
        if (!DemoSessionArguments.Requested(args)) return true;
        if (!DemoSessionArguments.Valid(args)) return false;
        Active = true;
        return true;
    }
    public static void RequestReset()
    {
        if (!Active) throw new InvalidOperationException("Seule la démonstration isolée peut être réinitialisée.");
        Interlocked.Exchange(ref reset, 1);
    }
    public static bool BeginRequestedReset()
    {
        if (!Active || Interlocked.Exchange(ref reset, 0) == 0) return false;
        Clock = new DemonstrationClock(DateTimeOffset.UtcNow, TimeZoneInfo.Local);
        Generation = Guid.NewGuid().ToString("N");
        return true;
    }
}
