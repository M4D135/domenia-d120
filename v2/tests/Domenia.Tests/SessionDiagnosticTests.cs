using Domenia.Core;

namespace Domenia.Tests;

internal static class SessionDiagnosticTests
{
    [Test]
    public static async Task Notification_incidents_accept_only_a_digest_and_publish_the_same_code_to_support()
    {
        var bridge = new SimulatedBridge();
        var args = System.Text.Json.JsonSerializer.Serialize(new { route = "accueil", fingerprint = new string('a', 64) });
        var first = SimulatedBridge.Json(await bridge.CallAsync("shell.incident", args)).GetProperty("code").GetString();
        var second = SimulatedBridge.Json(await bridge.CallAsync("shell.incident", args)).GetProperty("code").GetString();
        Check.Equal(first, second, "même empreinte et source corrélées");
        Check.True(bridge.Log.Lines.Any(l => l.Contains(first!, StringComparison.Ordinal)), "même code au journal sans texte de page");
        var code = SessionIncidents.CodeIn(bridge.Log.Lines.First(l => l.Contains(first!, StringComparison.Ordinal)));
        Check.Equal(first, code, "format complet reconnu");
        var handled = SimulatedBridge.Json(await bridge.CallAsync("shell.diagnostics.handled"));
        Check.True(handled.GetArrayLength() <= SwallowedDiagnostics.Capacity, "accès mémoire seul et borné");
    }

    [Test]
    public static void Incidents_share_a_code_in_ui_journal_and_support_and_group_identical_errors()
    {
        var clock = TestClock.Fixed(); var log = new RecordingJournal(); var journal = new OperationJournal();
        var incidents = new SessionIncidents(log, journal, clock);
        var first = incidents.Report("poste.read", new IOException("Accès refusé ; password=hidden-test-value"));
        var again = incidents.Report("poste.read", new IOException("Accès refusé ; password=hidden-test-value"));
        Check.Equal(first, again, "même type/message/source dans la minute");
        Check.Equal(1, log.Lines.Count, "pas de rafale de traces");
        Check.True(log.Lines[0].Contains(first, StringComparison.Ordinal), "code du message UI dans le journal technique");
        Check.False(log.Lines[0].Contains("hidden-test-value", StringComparison.Ordinal), "secret reconnu masqué");
        var row = journal.Snapshot().Single();
        var support = SupportIncidents.Create(new("key", row.At, row.Tone, "Session", row.Label, "session"), "old-guid");
        Check.Equal(first, support.Id, "même identifiant support");
        Check.True(support.Codes.Contains(first, StringComparison.Ordinal), "code visible avec les pistes de diagnostic");
        Check.Equal(2, incidents.Snapshot().Single().Count, "occurrences comptées");
        var otherSource = incidents.Report("search.read", new IOException("Accès refusé ; password=hidden-test-value"));
        var otherMessage = incidents.Report("poste.read", new IOException("Autre erreur"));
        var otherType = incidents.Report("poste.read", new InvalidOperationException("Autre erreur"));
        Check.Equal(4, new[] { first, otherSource, otherMessage, otherType }.Distinct().Count(), "incidents différents sans code commun");
        clock.Advance(TimeSpan.FromMinutes(1));
        Check.Equal(first, incidents.Report("poste.read", new IOException("Accès refusé ; password=hidden-test-value")), "même corrélation après la minute");
        Check.True(log.Lines.Last().Contains("3 occurrence", StringComparison.Ordinal), "synthèse cumulative après temporisation");
    }

    [Test]
    public static void Diagnostic_rings_are_bounded_and_safe_for_parallel_rule_workers()
    {
        var ring = new SwallowedDiagnostics(); var at = TestClock.Reference;
        Parallel.For(0, 1000, i => ring.Record("regle", "query.value", "FormatException", "token=hidden-value", at.AddSeconds(i)));
        var snapshot = ring.Snapshot();
        Check.Equal(SwallowedDiagnostics.Capacity, snapshot.Length, "anneau borné sous concurrence");
        Check.True(snapshot.All(e => e.Category == "regle" && e.Operation == "query.value" && e.Type == "FormatException"), "provenance des règles conservée");
        Check.True(snapshot.All(e => !e.Message.Contains("hidden-value", StringComparison.Ordinal)), "messages masqués avant mémorisation");
        ring.Record("secret avec espace", "invalide!", "type trop libre", new string('x', 8193), at);
        Check.Equal("inconnu", ring.Snapshot()[0].Category, "identifiants fermés");
        Check.Equal("Message hors limites ; contenu non conservé.", ring.Snapshot()[0].Message, "pas de message tronqué trompeur");
        Check.Equal(SwallowedDiagnostics.Capacity, snapshot.Length, "instantané précédent indépendant");
        var incidents = new SessionIncidents(SilentTechnicalJournal.Instance, new OperationJournal(), TestClock.Fixed());
        for (var i = 0; i < 500; i++) incidents.Report("test.operation", new IOException(i.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        Check.Equal(SessionIncidents.Capacity, incidents.Snapshot().Length, "registre d’incidents borné lui aussi");
        var huge = incidents.Report("test.operation", new IOException(new string('x', 200_000)));
        var another = incidents.Report("test.operation", new IOException(new string('x', 200_000) + "y"));
        Check.False(huge == another, "messages trop longs distincts ne partagent pas une signature tronquée");
        Check.True(incidents.Snapshot().Where(e => e.Code == huge || e.Code == another).All(e => e.Message == "Message hors limites ; contenu non conservé."), "aucune rétention du message démesuré");
    }
}
