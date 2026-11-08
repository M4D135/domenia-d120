using System.DirectoryServices.Protocols;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class DirectoryAvailabilityTests
{
    [Test]
    public static void Only_native_completion_changes_availability_and_recovery_preserves_the_disruption_revision()
    {
        using var connection = new AdConnection(new(null, "test.local"));
        Check.Equal(DirectoryAvailabilityState.Unknown, connection.Availability.State, "construction paresseuse, pas de sonde");
        using var read = connection.ForRead();
        read.ObserveReadCompletion(new LdapException(85), default);
        Check.Equal(DirectoryAvailabilityState.Slow, connection.Availability.State, "délai confirmé par le lecteur natif partagé");
        var interrupted = connection.Availability;
        read.ObserveReadCompletion(new LdapException(49), default);
        read.ObserveReadCompletion(new OperationCanceledException(), default);
        read.ObserveReadCompletion(new LdapException(81), new CancellationToken(true));
        Check.Equal(interrupted, connection.Availability, "authentification, annulation et abandon sans preuve réseau");
        using var otherController = connection.ForServer("dc2.test.local");
        otherController.ObserveReadCompletion(new LdapException(81), default);
        Check.Equal(interrupted, connection.Availability, "un autre contrôleur ne décrit pas celui de la session");
        read.ObserveReadCompletion(new LdapException(81), default);
        var offline = connection.Availability;
        Check.Equal(DirectoryAvailabilityState.Offline, offline.State, "service injoignable réellement constaté");
        Check.True(offline.Revision > interrupted.Revision, "barrière conservée après chaque perturbation");
        read.ObserveReadCompletion(null, default);
        Check.Equal(DirectoryAvailabilityState.Online, connection.Availability.State, "reprise seulement après réponse native");
        Check.Equal(offline.Revision, connection.Availability.Revision, "rétablissement ne ressuscite pas les fiches anciennes");
        Check.Equal(offline.LastDisruptionAt, connection.Availability.LastDisruptionAt, "date de perturbation conservée");
    }

    [Test]
    public static async Task Actual_source_and_session_projection_invalidate_visits_but_keep_the_SQLite_fiche_after_recovery()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed(); var user = Fixtures.User("alice");
        var store = new SqliteDirectoryCache(new DomeniaDatabase(folder.File("availability.db"), Fixtures.Root, clock));
        await store.SaveObjectsAsync(Fixtures.Snapshot(users: [user]), null, default);
        var entry = AdFicheObjects.Project(AdRelationDirectoryTests.User(user));
        await store.SaveFicheAsync(new(entry, Fixtures.Now), default);
        using var connection = new AdConnection(new(null, "test.local"));
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: new AdBoundaryTests.RecordingAdConnection(), localStore: store);
        source.AdoptConnection(connection, Fixtures.Domain, new(new(@"TEST\operator", "operator", "Opérateur", "CN=operator," + Fixtures.People),
            Fixtures.Domain.DomainSid + "-1001", new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), source.Epoch, false);
        await source.ReadLocalAsync(default);
        using var board = new DashboardService(source, new OperationJournal(), clock);
        var session = new FicheSession(clock); var owner = session.BindOwner(await source.GetSessionAsync(default));
        Check.True(session.Publish(new(entry, Fixtures.Now, "dc", 0), owner), "visite initiale qualifiée");
        connection.ObserveReadCompletion(new LdapException(81), default);
        var failed = await board.GetSessionInfoAsync(default);
        Check.Equal(DirectoryAvailabilityState.Offline, failed.DirectoryAvailability.State, "état réel transmis à session.info");
        Check.Contains("cache conservé", failed.Connection.Label, "libellé sans perte de cache");
        session.BindOwner(await source.GetSessionAsync(default));
        Check.Null(session.LastRead(entry.Dn), "visite invalidée malgré compte et époque inchangés");
        Check.False(session.Publish(new(entry, Fixtures.Now, "dc", 0), owner), "résultat tardif pré-panne refusé");
        Check.NotNull(await new AdFicheReader(source).PreviewAsync(entry.Dn, default), "fiche SQLite encore consultable sans LDAP");
        connection.ObserveReadCompletion(null, default);
        session.BindOwner(await source.GetSessionAsync(default));
        Check.Null(session.LastRead(entry.Dn), "retour en ligne ne requalifie aucune visite ancienne");
        Check.Equal(Fixtures.Now, (await store.ReadFicheAsync(entry.Dn, default))!.ReadAt, "date et données durables inchangées");
        Check.Equal(DirectoryAvailabilityState.Online, (await board.GetSessionInfoAsync(default)).DirectoryAvailability.State, "reprise affichable");
    }
}
