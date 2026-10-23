using System.ComponentModel;
using System.Diagnostics.Eventing.Reader;
using System.Security;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class RelationEventReaderTests
{
    private static readonly RelationLogRequest Request = new("dc1.test.local", Fixtures.Now.AddDays(-7), Fixtures.Now, 1000);
    private static readonly string Sid = Fixtures.User("alice").Sid;
    private sealed class EventFailure(int code) : EventLogException(code);
    private static RelationLogRaw Raw(long id = 1, int eventId = 4768, string account = "alice") => new(id, eventId, Fixtures.Now.AddHours(-1),
        "Microsoft-Windows-Security-Auditing", "Security", "DC1.test.local",
        [account, "TEST", eventId == 4768 ? Sid : null, eventId == 4624 ? Sid : null, "::ffff:10.77.0.5", eventId == 4624 ? "PC1" : null, eventId == 4624 ? "3" : null, eventId == 4624 ? null : "0x0"]);
    private static WindowsRelationEventsReader Reader(IEnumerable<RelationLogRaw> rows) => new(TestClock.Fixed()) { ReadOverride = (_, _, _, _) => rows };
    private static RelationLogRaw Field(RelationLogRaw row, int index, object? value)
    { var values = row.Values.ToArray(); values[index] = value; return row with { Values = values }; }

    [Test]
    public static Task Event_query_is_closed_UTC_bounded_and_targets_only_4768_for_a_selected_SID()
    {
        var query = WindowsRelationEventsReader.Query(Request with { SubjectSid = Sid, Maximum = 100 });
        Check.Contains("EventID=4768", query, "un seul type ciblé"); Check.False(query.Contains("4769", StringComparison.Ordinal), "pas de ticket de service dans les indices ciblés");
        Check.Contains("Data[@Name='TargetSid']='" + Sid + "'", query, "SID exact"); Check.Contains("Data[@Name='Status']='0x0'", query, "succès uniquement");
        Check.Contains("2026-10-14T16:26:00.0000000Z", query, "UTC stable");
        foreach (var bad in new[] { Request with { Controller = "10.77.0.10" }, Request with { Controller = "dc1';*" }, Request with { From = Fixtures.Now.AddDays(-31) },
            Request with { Maximum = 20_001 }, Request with { SubjectSid = "S-1-5-21-1-2-3-4' or '1'='1", Maximum = 100 }, Request with { SubjectSid = Sid, Maximum = 101 } })
        { Check.Throws<ArgumentException>(() => WindowsRelationEventsReader.Query(bad), "requête hors contrat refusée"); }
        return Task.CompletedTask;
    }

    [Test]
    public static async Task Event_projection_keeps_user_and_client_clues_separate_from_the_4769_service_identity()
    {
        var service = Field(Raw(2, 4769, "alice@test.local"), 2, Fixtures.Domain.DomainSid + "-502");
        var result = await Reader([Raw(), service, Raw(3, 4624)]).ReadAsync(Request, null, CancellationToken.None);
        Check.Equal(SourceStatus.Ok, result.Status, "trois événements qualifiés"); Check.Equal(3, result.Events.Length, "types attendus");
        Check.Equal(Sid, result.Events[0].UserSid!, "SID utilisateur 4768"); Check.Equal("10.77.0.5", result.Events[0].Address!, "IPv4 mappée normalisée");
        Check.Null(result.Events[1].UserSid, "SID service jamais réattribué à l’utilisateur"); Check.Null(result.Events[1].Workstation, "service jamais transformé en poste client");
        Check.Equal("PC1", result.Events[2].Workstation!, "nom client du 4624 conservé comme indice"); Check.Equal(3, result.Events[2].LogonType!.Value, "type réseau conservé");
        Check.Equal(Fixtures.Now.AddHours(-1), result.Events[2].At, "date de l’événement et non date de lecture");
    }

    [Test]
    public static Task Event_mapping_rejects_wrong_sources_dates_arrays_and_ambiguous_addresses_without_inventing_identity()
    {
        var original = Raw();
        foreach (var bad in new[] { original with { Computer = "dc1.foreign.local" }, original with { Provider = "Other" }, original with { Channel = "System" },
            original with { At = Fixtures.Now.AddSeconds(1) }, original with { RecordId = null }, original with { Values = [] }, Field(original, 0, new[] { "alice", "bob" }),
            Field(original, 0, new string('a', 321)), Field(original, 2, "not-a-sid"), Field(Raw(eventId: 4624), 6, "99") })
        { Check.Null(WindowsRelationEventsReader.Map(bad, Request, out _), "événement incohérent écarté"); }
        foreach (var address in new[] { "::ffff:127.0.0.1", "::ffff:0.0.0.0", "::1", "255.255.255.255", "1234", "010.0.0.1", "not-an-ip" })
        { Check.Null(WindowsRelationEventsReader.Map(Field(original, 4, address), Request, out _)!.Address, "pas d’adresse ambiguë ou locale"); }
        Check.Null(WindowsRelationEventsReader.Map(Field(Raw(eventId: 4624), 3, "S-1-5-18"), Request, out var system), "compte système ignoré");
        Check.True(system, "hors population distinct d’une réponse corrompue");
        Check.Null(WindowsRelationEventsReader.Map(Field(original, 7, "0x18"), Request, out var failed), "échec historique ignoré"); Check.True(failed, "ne signale pas le refus du compte de lecture");
        Check.Null(WindowsRelationEventsReader.Map(original, Request with { SubjectSid = Fixtures.Domain.DomainSid + "-999" }, out _), "SID demandé exact");
        return Task.CompletedTask;
    }

    [Test]
    public static async Task Event_limits_and_conflicting_record_ids_never_publish_an_arbitrary_version()
    {
        var result = await Reader([Raw(), Raw(), Raw(2), Raw(2, account: "bob"), Raw(3)]).ReadAsync(Request, null, CancellationToken.None);
        Check.Equal(2, result.Events.Length, "doublon identique dédupliqué et conflit entièrement écarté");
        Check.False(result.Events.Any(e => e.RecordId == 2), "aucune des versions contradictoires retenue"); Check.Equal(3, result.Rejected, "toutes les anomalies comptées");
        var capped = await Reader(Enumerable.Range(1, 101).Select(i => Raw(i))).ReadAsync(Request with { Maximum = 100 }, null, CancellationToken.None);
        Check.Equal(100, capped.Read, "plafond d’examen"); Check.Equal(100, capped.Events.Length, "sentinelle non publiée"); Check.True(capped.Truncated, "limite annoncée");
        var failed = await Reader([Field(Raw(), 7, "0x18")]).ReadAsync(Request, null, CancellationToken.None);
        Check.False(failed.AuthenticationRejected, "échec historique différent du compte lecteur"); Check.Equal(1, failed.Ignored, "historique non réussi compté");
    }

    [Test]
    public static async Task Event_volume_is_bounded_across_UTF8_fields_before_reaching_twenty_thousand_rows()
    {
        IEnumerable<RelationLogRaw> Rows()
        {
            for (var i = 1; i <= 20_000; i++)
            {
                var row = Field(Raw(i, 4769, new string('漢', 320)), 1, new string('漢', 255));
                yield return Field(row, 5, new string('漢', 255));
            }
        }
        var read = await Reader(Rows()).ReadAsync(Request with { Maximum = 20_000 }, null, CancellationToken.None);
        Check.True(read.Truncated, "plafond octets indépendant du nombre"); Check.True(read.Events.Length is > 5000 and < 10_000, "seize Mio au plus");
        Check.Equal(SourceStatus.Partial, read.Status, "parcours partiel explicite");
    }

    [Test]
    public static async Task Native_event_refusals_preserve_finished_rows_and_distinguish_authentication_from_permissions()
    {
        foreach (var code in new[] { 1326, unchecked((int)0x8009030C), 5, 1314, 1722 })
        {
            IEnumerable<RelationLogRaw> Rows() { yield return Raw(); throw code == unchecked((int)0x8009030C) ? new EventFailure(code) : new Win32Exception(code); }
            var read = await Reader(Rows()).ReadAsync(Request, null, CancellationToken.None);
            Check.Equal(1, read.Events.Length, "lignes précédentes conservées"); Check.True(read.Truncated, "échec tardif visible");
            Check.Equal(code == 1722 ? SourceStatus.Unavailable : SourceStatus.Refused, read.Status, "refus ou indisponibilité distingués");
            Check.Equal(code is 1326 or unchecked((int)0x8009030C), read.AuthenticationRejected, "seul rejet d’identité suspend le compte");
        }
    }

    [Test]
    public static async Task Canceled_event_wait_retains_the_native_secure_copy_until_the_worker_really_finishes()
    {
        using var password = new SecureString(); foreach (var c in "Fake-Event-Only-42") { password.AppendChar(c); } password.MakeReadOnly();
        using var credential = new RemoteProbeCredential(@"TEST\reader", password.Copy(), false);
        using var stop = new CancellationTokenSource(); using var release = new ManualResetEventSlim();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        IEnumerable<RelationLogRaw> Rows(RemoteProbeCredential? owned)
        {
            Check.False(ReferenceEquals(credential.Password, owned!.Password), "copie autonome du secret");
            try { yield return Raw(); entered.TrySetResult(); release.Wait(TimeSpan.FromSeconds(5)); }
            finally { finished.TrySetResult(); }
        }
        var reader = new WindowsRelationEventsReader(TestClock.Fixed()) { ReadOverride = (_, _, owned, _) => Rows(owned) };
        var reading = reader.ReadAsync(Request, credential, stop.Token);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5)); stop.Cancel();
        try
        {
            var result = await reading;
            Check.Equal(SourceStatus.Interrupted, result.Status, "attente interrompue"); Check.Equal(1, result.Events.Length, "événement déjà reçu conservé");
            Check.True(SecureCredentialCopies.Contains(password), "secret encore détenu par appel natif en cours");
        }
        finally { release.Set(); }
        await finished.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Check.True(SpinWait.SpinUntil(() => !SecureCredentialCopies.Contains(password), TimeSpan.FromSeconds(2)), "copie libérée après fin réelle");
    }

    [Test]
    public static async Task Event_reader_never_replaces_an_incomplete_explicit_credential_with_the_Windows_session()
    {
        var reader = new WindowsRelationEventsReader(TestClock.Fixed()) { ReadOverride = (_, _, _, _) => throw new InvalidOperationException("Aucun appel attendu.") };
        using var missing = new RemoteProbeCredential(@"TEST\reader", null, false);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadAsync(Request, missing, CancellationToken.None), "secret absent");
        await Check.ThrowsAsync<ArgumentException>(() => reader.ReadAsync(Request with { To = Fixtures.Now.AddHours(1) }, null, CancellationToken.None), "fenêtre future");
    }
}
