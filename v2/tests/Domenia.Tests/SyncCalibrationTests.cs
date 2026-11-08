using Domenia.Core;
namespace Domenia.Tests;
internal static class SyncCalibrationTests
{
    [Test]
    public static void Calibration_uses_recent_complete_same_scope_same_controller_and_no_invented_old_measurements()
    {
        var now = DateTimeOffset.Parse("2026-11-01T12:00:00Z", System.Globalization.CultureInfo.InvariantCulture);
        var scope = new SyncScope("OU=Postes,DC=example,DC=local", "Postes", "Postes", true, false, "test");
        OperationSample Sample(int duration, int minutes) => new("synchro.read.run", now.AddMinutes(-minutes), duration, 100, true, false)
        { Sync = new(SyncReadMode.Ou, scope.Dn, scope.Subtree, "dc.example.local", 100, duration) };
        var first = Sample(1000, 1); var second = Sample(3000, 2);
        var result = SyncCalibrationRules.Estimate([first, first, second], SyncReadMode.Ou, scope, "DC.example.local", 200, now);
        Check.Equal(4000, result.Milliseconds, "médiane réelle, doublon session/disque exclu");
        Check.Contains("2 lectures complètes", result.Text, "provenance affichée");
        foreach (var invalid in new[] { first with { Sync = null }, first with { Succeeded = false }, first with { At = now.AddMinutes(1) },
            first with { At = now.AddDays(-8) }, first with { Sync = first.Sync! with { Controller = "other.example.local" } },
            first with { Sync = first.Sync! with { ScopeDn = "OU=Autre,DC=example,DC=local" } }, first with { Sync = first.Sync! with { DurationMs = 0 } } })
            Check.Equal(0, SyncCalibrationRules.Estimate([invalid], SyncReadMode.Ou, scope, "dc.example.local", 200, now).Milliseconds, "échantillon non comparable exclu");
        Check.Equal(0, SyncCalibrationRules.Estimate([first], SyncReadMode.Incremental, scope, "dc.example.local", 200, now).Milliseconds, "volume du delta inconnu");
        Check.Equal(0, SyncCalibrationRules.Estimate([first], SyncReadMode.Ou, scope, null, 200, now).Milliseconds, "contrôleur inconnu");
    }
}
