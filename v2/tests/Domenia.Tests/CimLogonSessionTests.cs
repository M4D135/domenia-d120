using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class CimLogonSessionTests
{
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(p => p.Key, p => p.Value));
    private static CimReading Logons => new("sessions", SourceStatus.Ok, "lu", 0,
        [Row(("LogonId", "42"), ("LogonType", 10), ("StartTime", "20261021162600.500000+120"))]);
    private static WmiInstance Link(string name) => Row(("Dependent", "Win32_LogonSession.LogonId=\"42\""),
        ("Antecedent", "Win32_Account.Domain=\"TEST\",Name=\"" + name + "\""));

    [Test]
    public static void CIM_references_are_parsed_as_data_and_only_for_the_confirmed_host()
    {
        var value = "\\\\PC-1\\root\\cimv2:Win32_Account.Domain=\"TEST\",Name=\"A\\\"B\"";
        var parsed = WmiLogonSessionsReader.Reference(value, "PC-1.test.local", "Win32_Account");
        Check.NotNull(parsed, "référence valide et échappement WMI");
        Check.Equal("A\"B", parsed!["Name"], "guillemet conservé dans le nom");
        foreach (var bad in new[] { value.Replace("PC-1", "PC-2", StringComparison.Ordinal), value.Replace("PC-1", "PC-1.other.local", StringComparison.Ordinal),
            "Win32_Account.Name=\"A\",Name=\"B\"", "Win32_Account.Name=\"A\",", "Win32_Account.Name=\"A\\nB\"", new string('a', 4097) })
        { Check.Null(WmiLogonSessionsReader.Reference(bad, "PC-1.test.local", "Win32_Account"), "référence étrangère ou mal formée refusée"); }
    }

    [Test]
    public static void CIM_logons_get_an_account_but_never_an_invented_WTS_session_state_or_idle_time()
    {
        var read = WmiLogonSessionsReader.Project("PC-1", Logons, new("links", SourceStatus.Ok, "lu", 0, [Link("Alice")]), Fixtures.Now);
        Check.Equal(SourceStatus.Ok, read.Status, "associations entièrement lues");
        var row = read.Sessions.Single();
        Check.Equal("Alice", row.User, "compte associé"); Check.Equal("TEST", row.Domain, "domaine distinct");
        Check.Equal("CIM:42", row.Id, "LUID non confondu avec l’identifiant du bureau");
        Check.Null(row.Idle, "aucune activité inventée");
        Check.Contains("état du bureau inconnu", row.State, "limite CIM explicite");
        Check.NotNull(row.LogonAt, "date réellement retournée");
    }

    [Test]
    public static void Ambiguous_missing_or_truncated_account_associations_remain_partial()
    {
        foreach (var links in new[] {
            new CimReading("links", SourceStatus.Ok, "lu", 0, [Link("Alice"), Link("Bob")]),
            new CimReading("links", SourceStatus.Refused, "refusé", 0, []),
            new CimReading("links", SourceStatus.Partial, "tronqué", 0, [Link("Alice")]) })
        {
            var read = WmiLogonSessionsReader.Project("PC-1", Logons, links, Fixtures.Now);
            Check.Equal(SourceStatus.Partial, read.Status, "relevé incomplet, pas absence de session");
            Check.Equal(1, read.Sessions.Length, "ouverture de session gardée");
            if (links.Status != SourceStatus.Partial) { Check.Null(read.Sessions[0].User, "identité non établie"); Check.Equal(1, read.Unread, "compte non lu explicite"); }
        }
    }

    [Test]
    public static void WTS_empty_or_partial_results_and_rejected_credentials_never_trigger_a_CIM_retry()
    {
        foreach (var status in new[] { SourceStatus.Ok, SourceStatus.Empty, SourceStatus.Partial })
        { Check.False(WmiLogonSessionsReader.NeedsFallback(new(status, [], 0, Fixtures.Now, null)), "WTS a répondu"); }
        Check.False(WmiLogonSessionsReader.NeedsFallback(new(SourceStatus.Refused, [], 0, Fixtures.Now, null) { AuthenticationRejected = true }), "secret rejeté jamais réessayé");
        Check.True(WmiLogonSessionsReader.NeedsFallback(new(SourceStatus.Unavailable, [], 0, Fixtures.Now, null)), "WTS indisponible autorise le repli borné");
        var calls = 0;
        var session = new CimSession("PC-1.test.local", TimeSpan.FromSeconds(5), TimeProvider.System)
        { ReadOverride = (_, _, _) => { calls++; return [Row(("Name", "PC-OTHER"))]; } };
        Check.Equal(SourceStatus.Error, WmiLogonSessionsReader.Read(session).Status, "identité différente refusée");
        Check.Equal(1, calls, "aucune lecture de session après un nom incohérent");
    }
}
