using Domenia.Inventory;

namespace Domenia.Tests;

internal static class WindowsLockoutTests
{
    private const string Sid = "S-1-5-21-1-2-3-1001";
    private const string Xml = """
        <Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System>
        <Provider Name="Microsoft-Windows-Security-Auditing"/><EventID>4740</EventID><Channel>Security</Channel>
        <TimeCreated SystemTime="2026-10-20T10:00:00Z"/><Computer>DC01.test.local</Computer></System>
        <EventData><Data Name="TargetSid">S-1-5-21-1-2-3-1001</Data><Data Name="TargetDomainName">POSTE01</Data></EventData></Event>
        """;
    private static readonly DateTimeOffset To = new(2026, 10, 20, 11, 0, 0, TimeSpan.Zero);

    [Test]
    public static void Lockout_query_is_limited_to_one_SID_one_event_and_a_closed_time_window()
    {
        var query = WindowsLockoutReader.Query(Sid, To.AddHours(-2), To);
        Check.True(query.Contains("EventID=4740", StringComparison.Ordinal) && query.Contains("Data[@Name='TargetSid']='" + Sid + "'", StringComparison.Ordinal), "filtrage serveur exact");
        Check.True(query.Contains("@SystemTime >=", StringComparison.Ordinal) && query.Contains("@SystemTime <=", StringComparison.Ordinal), "fenêtre fermée");
        Check.Throws<ArgumentException>(() => WindowsLockoutReader.Query(Sid + "' or 1=1", To.AddHours(-2), To), "injection refusée");
        Check.Throws<ArgumentException>(() => WindowsLockoutReader.Query(Sid, To.AddHours(-721), To), "fenêtre excessive");
        Check.Throws<ArgumentException>(() => WindowsLockoutReader.Query(Sid, To, To), "fenêtre vide");
    }

    [Test]
    public static void Event_4740_uses_the_native_caller_field_and_keeps_the_controller_and_UTC_date()
    {
        var record = WindowsLockoutReader.Parse(Xml, Sid, To.AddHours(-2), To);
        Check.Equal("POSTE01", record.CallerComputer, "TargetDomainName porte le poste dans le schéma 4740 version 0");
        Check.Equal("DC01.test.local", record.Controller, "contrôleur d’origine");
        Check.Equal(To.AddHours(-1), record.At, "date UTC");
        record = WindowsLockoutReader.Parse(Xml.Replace("</EventData>", "<Data Name=\"CallerComputerName\">POSTE02</Data></EventData>", StringComparison.Ordinal), Sid, To.AddHours(-2), To);
        Check.Equal("POSTE02", record.CallerComputer, "champ explicite prioritaire lorsqu’il existe");
    }

    [Test]
    public static void Foreign_events_and_ambiguous_fields_are_never_reported_for_the_account()
    {
        foreach (var xml in new[] { Xml.Replace("4740", "4625", StringComparison.Ordinal), Xml.Replace(Sid, Sid + "2", StringComparison.Ordinal),
            Xml.Replace("Security</Channel>", "Application</Channel>", StringComparison.Ordinal),
            Xml.Replace("</EventData>", "<Data Name=\"TargetSid\">" + Sid + "</Data></EventData>", StringComparison.Ordinal) })
        { Check.Throws<InvalidDataException>(() => WindowsLockoutReader.Parse(xml, Sid, To.AddHours(-2), To), "événement étranger ou ambigu"); }
        Check.Throws<InvalidDataException>(() => WindowsLockoutReader.Parse(Xml, Sid, To.AddMinutes(-30), To), "événement hors fenêtre");
        Check.Throws<System.Xml.XmlException>(() => WindowsLockoutReader.Parse("<!DOCTYPE Event [<!ENTITY x SYSTEM 'file:///secret'>]>" + Xml, Sid, To.AddHours(-2), To), "DTD interdite");
    }
}
