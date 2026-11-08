using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class ProbeFilterTests
{
    [Test]
    public static void Event_probe_windows_are_resolved_as_exact_utc_dmtf_before_the_native_grammar()
    {
        var now = new DateTimeOffset(2026, 10, 25, 2, 30, 0, TimeSpan.FromHours(2));
        var day = ProbeCatalog.ResolveFilter(ProbeCatalog.Find("evt.syserrors")!.Filter, now);
        var week = ProbeCatalog.ResolveFilter(ProbeCatalog.Find("evt.unexpected")!.Filter, now);
        Check.Contains("TimeGenerated>='20261024003000.000000+000'", day, "vingt-quatre heures réelles malgré le changement d'heure locale");
        Check.Contains("TimeGenerated>='20261018003000.000000+000'", week, "sept jours en UTC");
        Check.False(day.Contains('{', StringComparison.Ordinal) || week.Contains('{', StringComparison.Ordinal), "aucun jeton transmis au fournisseur");
        Check.True(CimQuery.IsReadOnlySelect("SELECT EventCode FROM Win32_NTLogEvent WHERE " + day), "grammaire native accepte la date résolue");
        Check.True(CimQuery.IsReadOnlySelect("SELECT EventCode FROM Win32_NTLogEvent WHERE " + week), "grammaire native accepte la fenêtre résolue");
    }

    [Test]
    public static void Unknown_or_torn_window_tokens_are_never_sent_as_string_literals()
    {
        foreach (var filter in new[] { "Date='{SINCE_1H}'", "Date='{SINCE_24H'", "Date='SINCE_24H}'", "Name='x'; DELETE", new string('a', 513) })
        { Check.Throws<DomeniaOperationException>(() => ProbeCatalog.ResolveFilter(filter, TestClock.Reference), "filtre inconnu ou malformé refusé avant transport"); }
        Check.Equal("", ProbeCatalog.ResolveFilter("", TestClock.Reference), "filtre absent conservé");
        Check.Equal("DriveType=3", ProbeCatalog.ResolveFilter("DriveType=3", TestClock.Reference), "filtre constant conservé");
    }
}
