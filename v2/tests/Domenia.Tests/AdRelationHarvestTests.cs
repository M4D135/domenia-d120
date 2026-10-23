using System.ComponentModel;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdRelationHarvestTests
{
    private static readonly DirectoryUser Alice = Fixtures.User("alice");
    private static RelationLogRaw Raw(long id, int type = 4624, string account = "alice", string? workstation = "PC1", DateTimeOffset? when = null) => new(id, type,
        when ?? Fixtures.Now.AddHours(-1), "Microsoft-Windows-Security-Auditing", "Security", "DC1.test.local",
        [account, "TEST", type == 4768 ? Alice.Sid : null, type == 4624 ? Alice.Sid : null, "10.77.0.5", workstation, type == 4624 ? "3" : null, type == 4624 ? null : "0x0"]);
    private static AdRelationsReader Reader(AdDirectorySource source, IEnumerable<RelationLogRaw> rows) => new(source)
    {
        EventReaderOverride = clock => new(clock) { ReadOverride = (_, _, _, _) => rows },
        InventoryReaderOverride = _ => throw new InvalidOperationException("La moisson ne contacte aucun poste."),
    };
    private static IReadOnlyList<AdEntry> Answer(AdSearchRequest q) => q.Scope == AdSearchScope.Base ? []
        : q.Filter.Contains("objectSid=", StringComparison.Ordinal) ? [AdRelationDirectoryTests.User(Alice)]
        : q.Filter.Contains("sAMAccountName=PC1$", StringComparison.Ordinal) ? [AdPosteNetworkTests.Entry(Fixtures.Computer("PC1"))] : [];
    private static async Task<RelationHarvest> Run(AdRelationsReader reader) => await reader.HarvestAsync((await reader.HarvestEstimateAsync(7, 5000, CancellationToken.None)).Id, CancellationToken.None);

    [Test]
    public static async Task Native_harvest_preview_is_local_does_not_invent_event_counts_and_expires_without_network()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var bytes = File.ReadAllBytes(db.Path); var reader = Reader(source, []);
        var estimate = await reader.HarvestEstimateAsync(7, 5000, CancellationToken.None);
        Check.False(estimate.EstimateKnown, "volume inconnu avant le journal"); Check.Equal(0, estimate.EstimatedEvents, "pas d’extrapolation du parc");
        Check.Equal(120, estimate.EstimatedSeconds, "budget explicite"); Check.Equal(1, estimate.Computers, "index local seulement");
        Check.Equal(0, ldap.Searches.Count, "aucune lecture réseau pour préparer"); Check.True(bytes.SequenceEqual(File.ReadAllBytes(db.Path)), "base non modifiée");
        ((FixedTimeProvider)source.Clock).Advance(TimeSpan.FromMinutes(16));
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.HarvestAsync(estimate.Id, CancellationToken.None), "aperçu expiré");
        Check.Equal(0, ldap.Searches.Count, "expiration avant contact");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.HarvestEstimateAsync(31, 5000, CancellationToken.None), "trente jours au plus");
    }

    [Test]
    public static async Task Harvest_qualifies_only_4624_client_names_and_keeps_Kerberos_addresses_as_historical_clues()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; ldap.SearchAnswer = Answer;
        var reader = Reader(source, [Raw(1), Raw(2, when: Fixtures.Now.AddHours(-2)), Raw(3, 4768), Raw(4, 4769, "alice@test.local"),
            Raw(5, 4768, "PC1$"), Raw(6, workstation: "UNKNOWN"), Raw(7, workstation: null)]);
        var result = await Run(reader); var couple = result.Couples.Single();
        Check.Equal(7, result.Events, "tous les événements examinés"); Check.Equal(1, result.MachineAccountsIgnored, "compte machine ignoré");
        Check.Equal(4, result.Unresolved, "indices sans couple conservés comme tels"); Check.Equal(2, couple.Events, "seuls deux 4624 rattachés au poste");
        Check.Equal("4624", couple.EventIds, "aucun ticket de service réattribué au client"); Check.Equal(Fixtures.Now.AddHours(-2), couple.FirstSeen, "première date réelle");
        Check.Equal(Fixtures.Now.AddHours(-1), couple.LastSeen, "dernière date réelle"); Check.Equal(2, result.Hints.Length, "adresses par compte seulement");
        Check.Equal(1, result.NewCount, "un couple en attente"); Check.True(couple.CanSave, "preuve détenue par le moteur"); Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "lecture seule avant mémorisation");
        var calls = ldap.Searches.Count; using var executor = new AdRelationChangeExecutor(source);
        Check.Equal(1, (await executor.SaveObservationsAsync(CancellationToken.None)).Saved, "mémorisation automatique possible");
        var stored = (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation;
        Check.Equal(RelationKind.History, stored.Kind, "historique et non console"); Check.Contains("ne prouve ni session actuelle", stored.Details!, "limite explicite");
        Check.Equal(calls, ldap.Searches.Count, "aucun autre LDAP pour enregistrer");
    }

    [Test]
    public static async Task A_harvest_preview_is_consumed_once_and_busy_does_not_consume_another_preview()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; ldap.SearchAnswer = Answer;
        var reader = Reader(source, []); var estimate = await reader.HarvestEstimateAsync(7, 200, CancellationToken.None);
        var results = AdRelationResults.For(source); Check.True(results.BeginProbe(source.Epoch), "verrou pris par une autre lecture");
        try { await Check.ThrowsAsync<DomeniaOperationException>(() => reader.HarvestAsync(estimate.Id, CancellationToken.None), "moisson concurrente refusée"); }
        finally { results.EndProbe(); }
        var result = await reader.HarvestAsync(estimate.Id, CancellationToken.None); Check.Equal(0, result.NewCount, "journal réellement vide");
        var contacts = ldap.Searches.Count;
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.HarvestAsync(estimate.Id, CancellationToken.None), "rejeu refusé");
        Check.Equal(contacts, ldap.Searches.Count, "aucun second envoi");
    }

    [Test]
    public static async Task Harvest_preserves_known_assignments_and_skips_future_or_ambiguous_current_identities()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; ldap.SearchAnswer = Answer;
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source,user_guid,computer_guid) VALUES('manual','alice','PC1','Saisie manuelle',?1,?2);", Alice.ObjectGuid.ToString("D"), Fixtures.Computer("PC1").ObjectGuid.ToString("D")); }
        var result = await Run(Reader(source, [Raw(1)]));
        Check.True(result.Couples.Single().Known, "couple déjà déclaré"); Check.Equal(0, result.NewCount, "aucun nouvel historique");
        Check.Equal(0, AdRelationSession.For(source).Snapshot(source.Epoch).Length, "aucune file inutile");
        Check.Equal(RelationKind.Assignment, (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation.Kind, "déclaration intacte");
        foreach (var identity in new[] { "future", "ambiguous", "wrongSid" })
        {
            ldap.SearchAnswer = q => q.Filter.Contains("objectSid=", StringComparison.Ordinal)
                ? identity == "future" ? [AdRelationDirectoryTests.User(Alice with { WhenCreated = Fixtures.Now.AddMinutes(-5) })]
                    : identity == "ambiguous" ? [AdRelationDirectoryTests.User(Alice), AdRelationDirectoryTests.User(Alice)] : [AdRelationDirectoryTests.User(Fixtures.User("bob"))]
                : Answer(q);
            result = await Run(Reader(source, [Raw(1)])); Check.Equal(0, result.Couples.Length, "identité historique non qualifiée : " + identity);
        }
    }

    [Test]
    public static async Task Harvest_keeps_finished_pairs_after_a_late_LDAP_refusal_and_never_queries_after_a_journal_rejection()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        ldap.SearchAnswer = q => q.Filter.Contains("sAMAccountName=PC2$", StringComparison.Ordinal) ? throw new DomeniaOperationException(AdErrors.Credentials, "Refus simulé") : Answer(q);
        var result = await Run(Reader(source, [Raw(1), Raw(2, workstation: "PC2", when: Fixtures.Now.AddHours(-2)), Raw(3, workstation: "PC3", when: Fixtures.Now.AddHours(-3))]));
        Check.Equal(1, result.NewCount, "premier couple fini conservé"); Check.Equal(2, result.Unresolved, "courant et reliquat comptés une fois");
        Check.True(result.Truncated && result.AuthenticationRejected, "interruption explicite"); Check.False(ldap.Searches.Any(q => q.Filter.Contains("PC3", StringComparison.Ordinal)), "pas de contact après refus");
        var before = ldap.Searches.Count;
        IEnumerable<RelationLogRaw> Rejected() { yield return Raw(10); throw new Win32Exception(1326); }
        result = await Run(Reader(source, Rejected()));
        Check.Equal(0, result.Couples.Length, "pas de résolution après rejet journal"); Check.Equal(before + 1, ldap.Searches.Count, "seul contrôle du domaine avant journal");
        Check.True(result.AuthenticationRejected, "identité rejetée signalée");
    }

    [Test]
    public static async Task Harvest_bounds_distinct_identity_reads_and_counts_the_unresolved_remainder()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var pcs = Enumerable.Range(1, 129).Select(i => Fixtures.Computer("PC" + i)).ToArray();
        ldap.SearchAnswer = q => q.Scope == AdSearchScope.Base ? [] : q.Filter.Contains("objectSid=", StringComparison.Ordinal) ? [AdRelationDirectoryTests.User(Alice)]
            : pcs.FirstOrDefault(pc => q.Filter.Contains("sAMAccountName=" + pc.SamAccountName + ")", StringComparison.Ordinal)) is { } pc ? [AdPosteNetworkTests.Entry(pc)] : [];
        var result = await Run(Reader(source, Enumerable.Range(1, 129).Select(i => Raw(i, workstation: "PC" + i))));
        Check.Equal(128, result.Couples.Length, "cent vingt-huit noms de postes résolus au plus"); Check.Equal(1, result.Unresolved, "dernier événement sans recherche supplémentaire");
        Check.Equal(130, ldap.Searches.Count, "domaine, utilisateur mis en cache, 128 postes"); Check.True(result.Truncated, "borne annoncée");
        Check.True(ldap.Searches.Where(q => q.Scope == AdSearchScope.Subtree).All(q => q.SizeLimit == 2 && q.Timeout == TimeSpan.FromSeconds(3)), "chaque identité avec sentinelle et délai");
    }

    [Test]
    public static async Task Concurrent_console_evidence_takes_precedence_over_a_pending_harvest_without_duplicating_the_pair()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; ldap.SearchAnswer = Answer;
        var harvested = await Run(Reader(source, [Raw(1)])); Check.Equal(1, harvested.NewCount, "historique initialement nouveau");
        var session = AdRelationSession.For(source); var history = session.Snapshot(source.Epoch).Single();
        Check.True(session.ObserveValidated(history with { Kind = RelationKind.Console, Source = "Console CIM/DCOM", When = Fixtures.Now }, source.Epoch).Accepted, "console concurrente reçue");
        var saved = await session.SaveAsync(source.Epoch, CancellationToken.None);
        Check.Equal(1, saved.Saved, "seule la console est ajoutée"); Check.Equal(0, saved.Remaining, "moisson acquittée comme déjà connue");
        Check.Equal(RelationKind.Console, (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation.Kind, "aucune duplication historique");
        Check.Equal(0, (await new AdRelationsReader(source).PendingAsync(CancellationToken.None)).Total, "résultat de moisson libéré");
    }
}
