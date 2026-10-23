using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdPosteSessionsTests
{
    private static WindowsSessionsRead Full(DateTimeOffset at) => new(SourceStatus.Ok,
        [new("1", "Console", "alice", "TEST", "Active", "Console", at.AddHours(-1), null, null)], 0, at, "WTS lu.");
    private static ConsentState NoConsent => new(new(false, null, 0, "", null), new(false, null, 0, "", null));

    [Test]
    public static async Task Native_sessions_survive_a_cold_reopen_and_a_later_refusal_keeps_the_last_complete_list()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var first = true; var pc = Fixtures.Computer("PC1");
        var reader = new AdPosteReader(source) { SessionsOverride = (_, _, _) => Task.FromResult(first ? Full(source.Clock.GetUtcNow())
            : new WindowsSessionsRead(SourceStatus.Refused, [], 0, source.Clock.GetUtcNow(), "Accès refusé.") { AuthenticationRejected = true }) };
        var live = await reader.SessionsAsync(pc.DistinguishedName, CancellationToken.None);
        Check.False(live.Cached, "résultat du geste"); Check.Equal(2, ldap.Searches.Count, "même parent avant et après WTS");
        Check.Equal(3, ldap.Calls, "un seul RootDSE pour ce geste"); Check.Equal(@"TEST\alice", live.Rows.Single().AccountReference!, "domaine conservé");
        first = false; ((FixedTimeProvider)source.Clock).Advance(TimeSpan.FromMinutes(1));
        var refusal = await reader.SessionsAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal(FactState.Refused, refusal.ReadState, "dernier refus affiché"); Check.Equal(0, refusal.Rows.Length, "aucune ligne du succès placée dans le refus");
        Check.Equal(1, refusal.LastComplete!.UserSessions, "ancienne liste séparée"); Check.True(refusal.LastComplete.Cached, "historique explicite");
        var cold = new DomeniaDatabase(db.Path, Fixtures.Root, source.Clock);
        var saved = (await cold.ReadFleetAsync(CancellationToken.None)).WorkstationSessions[pc.ObjectGuid];
        Check.Equal(SourceStatus.Refused, saved.Latest.Status, "refus durable"); Check.Equal(Fixtures.Now, saved.LastComplete!.At, "date antérieure intacte");
        var calls = ldap.Calls;
        var opened = await reader.OpenAsync(pc.DistinguishedName, PosteHealthPolicy.Default, NoConsent, CancellationToken.None);
        Check.Equal(calls, ldap.Calls, "ouverture locale sans contact LDAP ou WTS"); Check.True(opened.CachedSessions!.Cached, "cache signalé");
        Check.Equal(1, opened.CachedSessions.LastComplete!.UserSessions, "historique visible dès l’ouverture");
    }

    [Test]
    public static async Task A_recreated_or_retargeted_computer_during_WTS_never_receives_the_session_list()
    {
        foreach (var defect in new[] { "guid", "sid", "creation", "dns", "sam" })
        {
            using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
            var pc = Fixtures.Computer("PC1"); var calls = 0;
            var changed = pc with { ObjectGuid = defect == "guid" ? Guid.NewGuid() : pc.ObjectGuid,
                Sid = defect == "sid" ? Fixtures.Domain.DomainSid + "-9876" : pc.Sid, WhenCreated = defect == "creation" ? pc.WhenCreated.AddDays(1) : pc.WhenCreated,
                DnsHostName = defect is "dns" or "sam" ? "PC2.test.local" : pc.DnsHostName, SamAccountName = defect is "dns" or "sam" ? "PC2$" : pc.SamAccountName };
            ldap.SearchAnswer = _ => [AdPosteNetworkTests.Entry(++calls == 1 ? pc : changed)];
            var reader = new AdPosteReader(source) { SessionsOverride = (_, _, _) => Task.FromResult(Full(Fixtures.Now)) };
            await Check.ThrowsAsync<DomeniaOperationException>(() => reader.SessionsAsync(pc.DistinguishedName, CancellationToken.None), "identité finale différente : " + defect);
            Check.Equal(0, (await db.ReadFleetAsync(CancellationToken.None)).WorkstationSessions.Count, "aucune attribution après modification");
        }
    }

    [Test]
    public static async Task A_final_LDAP_refusal_discards_the_unqualified_WTS_payload()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var pc = Fixtures.Computer("PC1"); var calls = 0;
        ldap.SearchAnswer = _ => ++calls == 1 ? [AdPosteNetworkTests.Entry(pc)] : throw new DomeniaOperationException(AdErrors.AccessDenied, "Refus simulé.");
        var reader = new AdPosteReader(source) { SessionsOverride = (_, _, _) => Task.FromResult(Full(Fixtures.Now)) };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.SessionsAsync(pc.DistinguishedName, CancellationToken.None), "pas de publication sans identité finale");
        Check.Equal(0, (await db.ReadFleetAsync(CancellationToken.None)).WorkstationSessions.Count, "aucune liste stockée");
    }

    [Test]
    public static async Task Local_and_foreign_session_accounts_never_navigate_to_an_AD_homonym()
    {
        using var folder = new TemporaryFolder(); var (_, source, _) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var reader = new AdPosteReader(source);
        var rows = new[] { new LocalSession("1", "", "alice", "PC1", "Active", "Console", null, null, null),
            new LocalSession("2", "", "alice", "OTHER", "Active", "RDP", null, null, null),
            new LocalSession("3", "", "alice", null, "Active", "RDP", null, null, null),
            new LocalSession("4", "", "TEST\\alice", null, "Active", "RDP", null, null, null) };
        var view = PosteSessions.View("PC1", SourceStatus.Ok, rows, Fixtures.Now, "Opérateur", TestClock.Paris);
        Check.Null(await reader.FindAccountAsync(view.Rows[0].AccountReference!, CancellationToken.None), "compte local distinct");
        Check.Null(await reader.FindAccountAsync(view.Rows[1].AccountReference!, CancellationToken.None), "domaine étranger distinct");
        Check.Null(view.Rows[2].AccountReference, "compte sans domaine non navigable");
        Check.Equal(Fixtures.User("alice").ObjectGuid, (await reader.FindAccountAsync(view.Rows[3].AccountReference!, CancellationToken.None))!.Guid!.Value, "compte du domaine connu");
    }

    [Test]
    public static void Native_unread_count_without_a_row_cannot_be_reported_as_zero_or_reduce_the_known_user_count()
    {
        var full = Full(Fixtures.Now);
        var result = PosteSessions.View("PC1", SourceStatus.Partial, full.Sessions, full.At, "Opérateur", TestClock.Paris, 3);
        Check.Equal(1, result.UserSessions, "compte effectivement affiché"); Check.Equal(3, result.UnreadSessions, "éléments absents de la liste signalés");
        Check.True(result.Partial, "total non complet");
        var empty = PosteSessions.View("PC1", SourceStatus.Ok, [], Fixtures.Now, "Opérateur", TestClock.Paris, 1);
        Check.True(empty.Partial, "incomplétude explicite"); Check.True(empty.EmptyText.Contains("partielle", StringComparison.Ordinal), "pas de fausse absence");
    }
}
