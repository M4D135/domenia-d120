using System.Collections.Immutable;
using System.Runtime.InteropServices;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdSearchConsoleTests
{
    private static WmiWorkstationReader Inventory(Func<object?> account) => new(TestClock.Fixed())
    {
        SessionFactory = (host, budget, token) => new(host, budget, TestClock.Fixed(), cancellationToken: token)
        { ReadOverride = (_, query, _) =>
        {
            Check.Equal("SELECT Name, UserName FROM Win32_ComputerSystem", query, "console seule demandée");
            return [new(new Dictionary<string, object?> { ["Name"] = "PC1", ["UserName"] = account() })];
        } },
    };
    private static AdSearchReader Reader(AdDirectorySource source, Func<object?> account) => new(source)
    {
        EchoOverride = (_, _) => Task.FromResult(new PresenceMeasure(MeasureState.Known, true, Fixtures.Now, Fixtures.Now)),
        ConsoleReaderOverride = _ => Inventory(account),
    };
    private static void Directory(AdBoundaryTests.RecordingAdConnection ldap)
    {
        ldap.SearchAnswer = q => q.BaseDn == Fixtures.Computer("PC1").DistinguishedName ? [AdPosteNetworkTests.Entry(Fixtures.Computer("PC1"))]
            : [AdRelationDirectoryTests.User(Fixtures.User("alice"))];
    }
    private static async Task OldConsole(AdDirectorySource source)
    {
        var old = new MachineFacts(@"TEST\ancien", Fixtures.Now.AddDays(-1), null, null, MeasureState.Known, Fixtures.Now.AddDays(-1), null);
        await source.SaveFleetAsync(FleetCachePatch.Empty with { Machines = ImmutableDictionary<Guid, MachineFacts>.Empty.Add(Fixtures.Computer("PC1").ObjectGuid, old) }, source.Epoch, CancellationToken.None);
    }
    private static Task<SurveyOutcome> Probe(AdSearchReader reader, SurveyMode mode = SurveyMode.Console) =>
        reader.ProbeAsync(Fixtures.Computer("PC1").ObjectGuid, mode, 1, TimeSpan.Zero, CancellationToken.None);

    [Test]
    public static async Task Search_console_shares_qualified_relations_passages_and_native_read_time_without_a_second_CIM_call()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap); var calls = 0;
        var result = await Probe(Reader(source, () => { calls++; return @"TEST\alice"; }));
        Check.Equal(1, calls, "un seul appel CIM"); Check.False(result.Denied, "compte accepté");
        Check.Equal(@"TEST\alice", source.FleetDetails.Facts.Machines[Fixtures.Computer("PC1").ObjectGuid].ConsoleUser!, "console factuelle partagée");
        Check.Equal(Fixtures.Now, source.FleetDetails.Facts.Machines[Fixtures.Computer("PC1").ObjectGuid].ConsoleAt!.Value, "date native après validation finale");
        var relation = (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation;
        Check.Equal(Fixtures.User("alice").ObjectGuid, relation.UserGuid!.Value, "GUID utilisateur résolu exactement"); Check.Equal(RelationKind.Console, relation.Kind, "console actuelle");
        Check.Equal("CONFIRME", (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single().Status, "passage du même geste");
        Check.Equal(0, (await new AdRelationsReader(source).PendingAsync(CancellationToken.None)).Total, "observation acquittée après stockage");
        Check.Equal(3, ldap.Searches.Count, "poste avant/après et compte exact");
    }

    [Test]
    public static async Task A_verified_empty_console_replaces_the_old_console_without_creating_an_association()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap); await OldConsole(source);
        await Probe(Reader(source, () => null));
        var fact = source.FleetDetails.Facts.Machines[Fixtures.Computer("PC1").ObjectGuid];
        Check.Null(fact.ConsoleUser, "console vide réellement lue"); Check.Equal(Fixtures.Now, fact.ConsoleAt!.Value, "nouvelle lecture datée");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucun lien vide fabriqué");
        Check.Equal("LU", (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single().Status, "passage vide complet");
    }

    [Test]
    public static async Task Foreign_console_text_remains_an_observation_and_does_not_create_a_domain_relation()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap);
        await Probe(Reader(source, () => @"OTHER\alice"), SurveyMode.Unaddressed);
        Check.Equal(@"OTHER\alice", source.FleetDetails.Facts.Machines[Fixtures.Computer("PC1").ObjectGuid].ConsoleUser!, "texte observé sans substitution");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucune association par homonymie");
        Check.Equal("ERREUR", (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single().Status, "compte non qualifié conservé à relire");
        Check.Equal(2, ldap.Searches.Count, "aucune recherche d’un compte du mauvais domaine");
    }

    [Test]
    public static async Task Unreadable_and_refused_console_reads_preserve_the_previous_fact_and_never_publish_empty_console()
    {
        foreach (var refused in new[] { false, true })
        {
            using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap); await OldConsole(source);
            var result = await Probe(Reader(source, () => refused ? throw new COMException("Rejet simulé", unchecked((int)0x8007052E)) : 42));
            var fact = source.FleetDetails.Facts.Machines[Fixtures.Computer("PC1").ObjectGuid];
            Check.Equal(@"TEST\ancien", fact.ConsoleUser!, "ancienne observation conservée"); Check.Equal(Fixtures.Now.AddDays(-1), fact.ConsoleAt!.Value, "ancienne date non rafraîchie");
            Check.Equal(refused, result.Denied, "refus distinct d’une valeur illisible"); Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucun compte fabriqué");
        }
    }

    [Test]
    public static async Task A_parent_recreated_during_search_console_preserves_echo_but_publishes_no_console_or_relation()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var pc = Fixtures.Computer("PC1"); var parents = 0;
        ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(++parents == 1 ? pc : pc with { ObjectGuid = Guid.NewGuid() })]
            : [AdRelationDirectoryTests.User(Fixtures.User("alice"))];
        await Check.ThrowsAsync<DomeniaOperationException>(() => Probe(Reader(source, () => @"TEST\alice")), "parent recréé rejeté");
        Check.True(source.CurrentObservations.Workstations.Single().Presence.Answered == true, "ping fini conservé");
        Check.False(source.FleetDetails.Facts.Machines.ContainsKey(pc.ObjectGuid), "aucun fait attaché à l’ancien GUID");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucun lien publié");
        Check.Equal(0L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "aucun passage final non validé");
    }

    [Test]
    public static async Task Search_expected_GUID_is_checked_before_network_even_if_the_DN_now_names_another_local_object()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => throw new InvalidOperationException("Aucun CIM attendu.") };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ComputerSessionAsync(Fixtures.Computer("PC1").DistinguishedName, Guid.NewGuid(), CancellationToken.None), "GUID de la ligne affichée non substitué");
        Check.Equal(0, ldap.Searches.Count, "aucun LDAP après échec local");
    }

    [Test]
    public static async Task Late_AD_refusal_after_a_native_empty_read_cannot_clear_the_previous_console()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; await OldConsole(source); var parents = 0;
        ldap.SearchAnswer = _ => ++parents == 1 ? [AdPosteNetworkTests.Entry(Fixtures.Computer("PC1"))]
            : throw new DomeniaOperationException(AdErrors.AccessDenied, "Refus de validation simulé");
        var result = await Probe(Reader(source, () => null));
        Check.True(result.Denied, "validation refusée visible");
        Check.Equal(@"TEST\ancien", source.FleetDetails.Facts.Machines[Fixtures.Computer("PC1").ObjectGuid].ConsoleUser!, "absence non validée ne remplace pas l’historique");
    }
}
