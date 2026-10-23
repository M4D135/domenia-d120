using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class WorkstationEventsTests
{
    private static EventQuery Query(string id = "Startup", int count = 10) => PosteEvents.Query(PosteEvents.Preset(id)!, 24, count, Fixtures.Now);
    private static object Event(int id = 6005, string provider = "EventLog", string log = "System", string? date = null, string message = "Service démarré") =>
        new { Id = id, Provider = provider, Log = log, Level = 4, At = date ?? Fixtures.Now.AddHours(-1).ToString("o"), Machine = "PC1.test.local", Message = message };
    private static string Payload(object[] rows, object[]? access = null, string computer = "PC1") => JsonSerializer.Serialize(new
    {
        Format = "Domenia.EventsRead/1", Computer = computer,
        Access = access ?? [new { Log = "System", Code = 0, Partial = false }], Rows = rows,
    });

    [Test]
    public static void Event_projection_checks_host_window_provider_and_log_before_claiming_absence()
    {
        var query = Query();
        Check.Equal(SourceStatus.Ok, CimSession.ParseEvents(Payload([Event()]), "PC1.test.local", query).Status, "événement exact retenu");
        Check.Equal(SourceStatus.Ok, CimSession.ParseEvents(Payload([Event(message: "")]), "PC1", query).Status, "message vide admis, métadonnées conservées");
        foreach (var invalid in new[] { Event(provider: "Other"), Event(date: Fixtures.Now.AddHours(-25).ToString("o")), Event(date: "2026-10-21T15:00:00") })
        {
            var result = CimSession.ParseEvents(Payload([invalid]), "PC1.test.local", query);
            Check.Equal(SourceStatus.Partial, result.Status, "événement illisible ou hors sélection rend le bilan incomplet");
            Check.Equal(0, result.Items, "pas d’attribution erronée");
        }
        Check.Throws<JsonException>(() => CimSession.ParseEvents(Payload([Event()], computer: "OTHER"), "PC1.test.local", query), "réponse d’un autre poste refusée");
        Check.Throws<JsonException>(() => CimSession.ParseEvents(Payload([Event(log: "Security")]), "PC1.test.local", query), "journal étranger refusé");
    }

    [Test]
    public static void Event_cap_uses_newest_received_rows_and_keeps_incomplete_journals_visible()
    {
        var one = Query(count: 1);
        var result = CimSession.ParseEvents(Payload([Event(date: Fixtures.Now.AddHours(-2).ToString("o")), Event()]), "PC1", one);
        Check.Equal(SourceStatus.Partial, result.Status, "sentinelle signale la troncature"); Check.Equal(1, result.Items, "volume borné");
        Check.Equal(Fixtures.Now.AddHours(-1), CimSession.UtcDate(result.Instances[0].Text("At"))!.Value, "plus récent parmi les événements reçus");
        var policy = Query("Policy");
        var logs = new object[] { new { Log = "System", Code = 0, Partial = false }, new { Log = "Microsoft-Windows-GroupPolicy/Operational", Code = unchecked((int)0x80070005), Partial = false } };
        var refused = CimSession.ParseEvents(Payload([], logs), "PC1", policy);
        Check.Equal(SourceStatus.Partial, refused.Status, "journal refusé distinct de l’autre journal vide");
        var view = PosteEvents.Interpret("PC1", policy, refused.Status, [], true, "reader", TestClock.Paris);
        Check.False(view.NoEventsConfirmed, "aucune conclusion d’absence sur les deux journaux");
        Check.Throws<JsonException>(() => CimSession.ParseEvents(Payload([], [logs[0], logs[0]]), "PC1", policy), "journal dupliqué ne remplace pas le journal manquant");
    }

    [Test]
    public static void Event_shell_cleanup_uncertainty_never_changes_access_refused_into_a_read()
    {
        var clock = TestClock.Fixed();
        using var session = new CimSession("PC1.test.local", TimeSpan.FromSeconds(30), clock, transport: InventoryTransport.WinRm)
        {
            EventsShellOverride = (_, _) => new(SourceStatus.Ok, Payload([], [new { Log = "System", Code = unchecked((int)0x80070005), Partial = false }]), false, false),
        };
        var result = session.ReadEvents(Query());
        Check.Equal(SourceStatus.Refused, result.Status, "refus conservé"); Check.False(result.Answered, "aucune donnée exploitable");
        Check.True(result.Detail.Contains("Fermeture", StringComparison.Ordinal), "fermeture incertaine expliquée");
    }

    [Test]
    public static void Event_scripts_accept_only_known_presets_and_bounded_numbers_dates()
    {
        var query = Query("Policy");
        var script = WsmanReadChannel.EventScript(query);
        Check.True(script.Contains("Microsoft-Windows-GroupPolicy/Operational", StringComparison.Ordinal), "journal opérationnel inclus");
        Check.True(script.Contains("-MaxEvents $cap", StringComparison.Ordinal), "plafond à la source");
        Check.True(script.Contains("ProviderName=$providers", StringComparison.Ordinal), "fournisseurs filtrés à la source");
        Check.Throws<ArgumentException>(() => WsmanReadChannel.EventScript(query with { PresetId = "x';Remove-Item C:\\*;#" }), "aucun texte libre admis");
        Check.Throws<ArgumentException>(() => WsmanReadChannel.EventScript(query with { MaxEvents = 201 }), "volume refusé avant contact");
        Check.Throws<ArgumentException>(() => WsmanReadChannel.EventScript(query with { Start = query.Start.AddDays(-1) }), "période incohérente refusée");
    }

    [Test]
    public static void Classic_event_read_keeps_operational_log_unavailable_and_disabling_CIM_contacts_nothing()
    {
        var calls = 0;
        using var classic = new CimSession("PC1", TimeSpan.FromSeconds(30), TestClock.Fixed())
        {
            ReadOverride = (_, text, _) => { calls++; Check.True(text.Contains("ComputerName", StringComparison.Ordinal), "émetteur demandé explicitement"); return []; },
        };
        var result = classic.ReadEvents(Query("Policy"));
        Check.Equal(1, calls, "seul System passe par le fournisseur classique"); Check.Equal(SourceStatus.Partial, result.Status, "journal opérationnel non lu distinct d’un journal vide");
        using var disabled = new CimSession("PC1.test.local", TimeSpan.FromSeconds(30), TestClock.Fixed(), transport: InventoryTransport.WinRm)
        { ReadsEnabled = false, EventsShellOverride = (_, _) => throw new InvalidOperationException("Contact interdit") };
        Check.Equal(SourceStatus.Skipped, disabled.ReadEvents(Query()).Status, "désactivation respectée avant création de shell");
    }
}
