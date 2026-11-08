namespace Domenia.Core;

/// <summary>Observed complete read, not a command, a quota or a promise of completion.</summary>
public sealed record SyncCalibration(SyncReadMode Mode, string ScopeDn, bool Subtree, string Controller, int Items, int DurationMs);

public static class SyncCalibrationRules
{
    public static SyncCalibration? Observe(SyncReadResult read) => read.Complete && read.Cut is null && read.Read > 0 && read.DurationMs > 0
        && read.Mode is SyncReadMode.Full or SyncReadMode.Ou
        ? new(read.Mode, read.Scope.Dn, read.Scope.Subtree, read.Controller, read.Read, read.DurationMs) : null;

    public static (int Milliseconds, string Text) Estimate(IEnumerable<OperationSample> history, SyncReadMode mode,
        SyncScope scope, string? controller, int expected, DateTimeOffset now)
    {
        const string unknown = "Durée non estimée sans lecture complète comparable ; aucune lecture réseau pour cette estimation.";
        if (expected <= 0 || string.IsNullOrWhiteSpace(controller) || mode is not (SyncReadMode.Full or SyncReadMode.Ou)) return (0, unknown);
        var samples = history.Where(s => s is { Succeeded: true, Operation: "synchro.read.run", Sync: { } }
            && s.At <= now && s.At >= now.AddDays(-7)
            && s.Sync.Mode == mode && s.Sync.Subtree == scope.Subtree && s.Sync.Items is > 0 and <= 300_000
            && s.Sync.DurationMs is > 0 and <= 7_200_000 && s.Sync.ScopeDn is { Length: > 0 and <= 4096 }
            && DistinguishedName.AreEqual(s.Sync.ScopeDn, scope.Dn)
            && string.Equals(s.Sync.Controller, controller, StringComparison.OrdinalIgnoreCase))
            .DistinctBy(s => (s.At, s.Sync)).OrderByDescending(s => s.At).Take(5).ToArray();
        if (samples.Length == 0) return (0, unknown);
        var rates = samples.Select(s => (double)s.Sync!.DurationMs / s.Sync.Items).Order().ToArray();
        var median = rates.Length % 2 == 0 ? (rates[rates.Length / 2 - 1] + rates[rates.Length / 2]) / 2 : rates[rates.Length / 2];
        var ms = (int)Math.Clamp(Math.Ceiling(median * Math.Min(expected, 300_000)), 1, 7_200_000);
        return (ms, "Environ " + SyncText.Duration(ms) + " d’après " + FrenchText.Count(samples.Length, "lecture complète", "lectures complètes")
            + " des sept derniers jours sur ce périmètre et ce contrôleur. Le réseau et les droits peuvent changer ; ce n’est pas une garantie ni le délai maximal.");
    }
}
