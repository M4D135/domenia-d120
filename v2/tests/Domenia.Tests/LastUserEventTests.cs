using System.ComponentModel;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class LastUserEventTests
{
    private static readonly RelationLogRequest Request = new("PC1.test.local", Fixtures.Now.AddDays(-30), Fixtures.Now, 40) { WorkstationInteractive = true };
    private static RelationLogRaw Raw(long id, string type, string? sid = null, string? account = null, DateTimeOffset? at = null) => new(id, 4624,
        at ?? Fixtures.Now.AddMinutes(-1), "Microsoft-Windows-Security-Auditing", "Security", "PC1.test.local",
        [account ?? "alice", "TEST", null, sid ?? Fixtures.User("alice").Sid, null, "REMOTE-CLIENT", type, null]);
    private static WindowsLastUserEventsReader Reader(IEnumerable<RelationLogRaw> rows) => new(TestClock.Fixed())
    { EventReaderOverride = new(TestClock.Fixed()) { ReadOverride = (_, _, _, _) => rows } };
    private static RemoteProbeCredential Credential() => new(@"TEST\operator", null, true);
    private static Task<WorkstationUserReading> Read(WindowsLastUserEventsReader reader, RemoteProbeCredential credential) => reader.ReadAsync(Request.Controller,
        Fixtures.Computer("PC1").WhenCreated, PosteConfiguration.Defaults with { UseSecurityLog = true }, credential, CancellationToken.None);

    [Test]
    public static void Workstation_event_query_is_closed_to_interactive_4624_and_forty_records()
    {
        var query = WindowsRelationEventsReader.Query(Request);
        Check.Contains("EventID=4624", query, "journal du poste"); Check.False(query.Contains("4768", StringComparison.Ordinal), "aucune récolte Kerberos");
        foreach (var type in new[] { "2", "10", "11" }) { Check.Contains("Data[@Name='LogonType']='" + type + "'", query, "type interactif fermé"); }
        Check.Throws<ArgumentException>(() => WindowsRelationEventsReader.Query(Request with { Maximum = 41 }), "plafond propre au poste");
        Check.Throws<ArgumentException>(() => WindowsRelationEventsReader.Query(Request with { SubjectSid = Fixtures.User("alice").Sid }), "pas de requête SID du DC confondue");
    }

    [Test]
    public static async Task Disabled_security_history_never_contacts_the_poste_or_obtains_another_credential()
    {
        var reader = new WindowsLastUserEventsReader(TestClock.Fixed())
        { EventReaderOverride = new(TestClock.Fixed()) { ReadOverride = (_, _, _, _) => throw new InvalidOperationException("Aucun journal ne doit être ouvert.") } };
        using var credential = Credential();
        var result = await reader.ReadAsync(Request.Controller, Fixtures.Computer("PC1").WhenCreated, PosteConfiguration.Defaults, credential, CancellationToken.None);
        Check.Equal(SourceStatus.Skipped, result.Access.Status, "option désactivée par défaut"); Check.Equal(0, result.Candidates.Length, "aucun candidat inventé");
    }

    [Test]
    public static async Task Security_history_filters_network_service_and_unlock_events_and_keeps_the_target_SID_and_event_date()
    {
        using var credential = Credential();
        var read = await Read(Reader([Raw(1, "3"), Raw(2, "5"), Raw(3, "7"), Raw(4, "10")]), credential);
        Check.Equal(1, read.Candidates.Length, "RDP interactif seulement"); var candidate = read.Candidates.Single();
        Check.Equal(@"TEST\alice", candidate.Account!, "domaine du compte cible"); Check.Equal(Fixtures.User("alice").Sid, candidate.Sid!, "TargetUserSid conservé");
        Check.Equal(Fixtures.Now.AddMinutes(-1), candidate.EvidenceAt!.Value, "heure de connexion et non heure de lecture");
        Check.Equal("PC1", read.ReportedName!, "source du journal, pas WorkstationName du client");
        Check.Equal(InventoryTransport.EventLog, read.Access.Transport, "protocole explicite");
    }

    [Test]
    public static async Task Newest_event_per_SID_is_kept_and_candidates_are_bounded_to_five_without_a_name_guess()
    {
        using var credential = Credential();
        var events = Enumerable.Range(1, 8).Select(i => Raw(i, "2", Fixtures.Domain.DomainSid + "-" + (1000 + i), "user" + i, Fixtures.Now.AddMinutes(-i))).ToList();
        events.Add(Raw(9, "2", Fixtures.Domain.DomainSid + "-1001", "old-name", Fixtures.Now.AddDays(-1)));
        events.Add(Raw(10, "2", "S-1-5-18", "SYSTEM"));
        var result = await Read(Reader(events), credential);
        Check.Equal(5, result.Candidates.Length, "cinq SID récents au plus"); Check.Equal(@"TEST\user1", result.Candidates[0].Account!, "événement le plus récent");
        Check.False(result.Candidates.Any(c => c.Account!.Contains("old-name", StringComparison.Ordinal)), "ancien nom non choisi");
    }

    [Test]
    public static async Task Foreign_journal_precreation_and_conflicting_records_cannot_supply_last_user_candidates()
    {
        using var credential = Credential();
        var created = Fixtures.Now.AddDays(-1);
        var reader = Reader([Raw(1, "2") with { Computer = "PC2.test.local" }, Raw(2, "2", at: created.AddMinutes(-1)),
            Raw(3, "2"), Raw(3, "2", account: "bob")]);
        var result = await reader.ReadAsync(Request.Controller, created, PosteConfiguration.Defaults with { UseSecurityLog = true }, credential, CancellationToken.None);
        Check.Equal(0, result.Candidates.Length, "aucune version arbitraire ou antérieure à la création");
        Check.Equal(SourceStatus.Partial, result.Access.Status, "rejets visibles");
    }

    [Test]
    public static async Task The_selected_journal_credential_and_late_authentication_refusal_are_preserved()
    {
        using var credential = Credential();
        IEnumerable<RelationLogRaw> Events() { yield return Raw(1, "2"); throw new Win32Exception(1326); }
        var reader = new WindowsLastUserEventsReader(TestClock.Fixed())
        { EventReaderOverride = new(TestClock.Fixed()) { ReadOverride = (request, _, account, _) =>
        {
            Check.Equal(credential.Account, account!.Account, "identité du compte machine transmise");
            Check.True(request.WorkstationInteractive, "profil limité au poste"); Check.Equal(40, request.Maximum, "quarante événements au plus");
            return Events();
        } } };
        var result = await Read(reader, credential);
        Check.True(result.Access.AuthenticationRejected, "rejet pour suspension par le lecteur AD"); Check.Equal(SourceStatus.Refused, result.Access.Status, "refus jamais transformé en succès");
        Check.Equal(1, result.Candidates.Length, "contenu antérieur reçu reste distingué du refus, le pipeline AD ne le publie pas après rejet");
    }
}
