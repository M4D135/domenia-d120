using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdRelationOrphanTests
{
    private static void Insert(DomeniaDatabase db, string key, string user = "alice", string computer = "PC1", string source = "Console CIM/DCOM", bool identified = true)
    {
        using var sql = new SqliteDatabase(db.Path, false);
        sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source,user_guid,computer_guid) VALUES(?1,?2,?3,?4,?5,?6);", key, user, computer, source,
            identified ? Fixtures.User(user).ObjectGuid.ToString("D") : null, identified ? Fixtures.Computer(computer).ObjectGuid.ToString("D") : null);
    }
    private static WritePlan Bind(AdRelationChangeExecutor executor, WritePlanDraft draft, AdDirectorySource source)
    {
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, source.Clock.GetUtcNow(), source.Zone); executor.Bind(draft, plan); return plan;
    }

    [Test]
    public static async Task Orphan_check_uses_GUID_batches_protects_declarations_and_never_preselects_a_local_removal()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        Insert(db, "observed"); Insert(db, "declared", user: "bob", source: RelationRules.ManualSource); Insert(db, "imported", user: "missing", source: "Import CSV");
        ldap.SearchAnswer = _ => [];
        var check = await new AdRelationsReader(source).OrphansAsync(CancellationToken.None);
        Check.Equal(1, check.Checked, "seule l’observation est contrôlée"); Check.Equal(2, check.Protected, "déclaration et import protégés");
        Check.Equal(1, check.Rows.Length, "association non retrouvée à examiner"); Check.False(check.Rows[0].Selected, "choix laissé à l’opérateur");
        Check.Contains("suppression non prouvée", check.Rows[0].Reason, "absence de réponse qualifiée");
        Check.Equal(2, ldap.Searches.Count, "un paquet par type"); Check.True(ldap.Searches.All(q => q.Filter.Contains("objectGUID=", StringComparison.Ordinal) && q.SizeLimit == 129), "GUID exacts et borne par paquet");
        Check.Equal(3L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucun retrait automatique");
    }

    [Test]
    public static async Task Cleanup_rechecks_directory_absence_after_confirmation_and_keeps_every_row_if_an_object_returns()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Insert(db, "observed");
        ldap.SearchAnswer = _ => []; var check = await new AdRelationsReader(source).OrphansAsync(CancellationToken.None);
        using var executor = new AdRelationChangeExecutor(source); var draft = await executor.PlanOrphanCleanupAsync(check.Id, [check.Rows[0].Key], CancellationToken.None);
        var plan = Bind(executor, draft, source); Check.True((await executor.CheckAsync(plan, CancellationToken.None)).Current, "toujours non retrouvée");
        ldap.SearchAnswer = q => q.Filter.Contains(AdDirectoryMapper.UserFilter, StringComparison.Ordinal)
            ? [AdRelationDirectoryTests.User(Fixtures.User("alice"))] : [AdPosteNetworkTests.Entry(Fixtures.Computer("PC1"))];
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "identités revenues après précontrôle");
        Check.Equal(1L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "association conservée");
        ldap.SearchAnswer = _ => [];
        var fresh = Bind(executor, await executor.PlanOrphanCleanupAsync(check.Id, [check.Rows[0].Key], CancellationToken.None), source);
        await executor.ExecuteAsync(fresh, CancellationToken.None);
        Check.Equal(VerificationState.Verified, (await executor.VerifyAsync(fresh, CancellationToken.None)).State, "retrait local relu");
        Check.Equal(1, RelationRules.Restorable((await db.ReadRelationJournalAsync(CancellationToken.None)).Entries).Length, "retrait restaurable");
    }

    [Test]
    public static async Task Ambiguous_or_truncated_LDAP_answers_do_not_turn_other_missing_rows_into_orphans()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        Insert(db, "observed"); Insert(db, "another", user: "bob", computer: "PC2");
        var alice = AdRelationDirectoryTests.User(Fixtures.User("alice"));
        ldap.SearchAnswer = q => q.Filter.Contains(AdDirectoryMapper.UserFilter, StringComparison.Ordinal) ? [alice, alice] : [];
        var ambiguous = await new AdRelationsReader(source).OrphansAsync(CancellationToken.None);
        Check.Equal(0, ambiguous.Rows.Length, "ambiguïté du paquet ne prouve pas l’absence de bob"); Check.Contains("non concluante", ambiguous.Summary, "incertitude visible");
        ldap.SearchAnswer = _ => Enumerable.Repeat(alice, 129).ToArray();
        Check.Equal(0, (await new AdRelationsReader(source).OrphansAsync(CancellationToken.None)).Rows.Length, "limite atteinte non interprétée comme réponse complète");
    }

    [Test]
    public static async Task Refused_reads_stop_the_orphan_check_and_legacy_foreign_names_are_not_reinterpreted()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        Insert(db, "foreign", user: @"FOREIGN\alice", computer: "PC1.foreign.local", identified: false);
        ldap.SearchAnswer = _ => [];
        Check.Equal(0, (await new AdRelationsReader(source).OrphansAsync(CancellationToken.None)).Rows.Length, "noms étrangers non recherchés en tant que noms locaux");
        Check.Equal(0, ldap.Searches.Count, "aucun objet pour les deux identités invalides"); Insert(db, "native");
        ldap.SearchAnswer = _ => throw new DomeniaOperationException(AdErrors.AccessDenied, "Lecture refusée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => new AdRelationsReader(source).OrphansAsync(CancellationToken.None), "refus non converti en absence");
        Check.Equal(1, ldap.Searches.Count, "aucun autre paquet après refus");
    }

    [Test]
    public static async Task Orphan_results_are_bounded_and_only_checked_unchanged_unprotected_rows_can_be_planned()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        for (var i = 1; i <= 520; i++) { Insert(db, "PC" + i, computer: "PC" + i); }
        ldap.SearchAnswer = _ => []; var check = await new AdRelationsReader(source).OrphansAsync(CancellationToken.None);
        Check.Equal(512, check.Rows.Length, "résultats retenus bornés"); Check.Contains("partiel", check.Summary, "reste annoncé");
        using var executor = new AdRelationChangeExecutor(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanOrphanCleanupAsync(check.Id, check.Rows.Take(65).Select(r => r.Key).ToArray(), CancellationToken.None), "64 par plan");
        var chosen = check.Rows[0];
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE user_machine_links SET source='Saisie manuelle' WHERE computer_key=?1;", chosen.Computer); }
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanOrphanCleanupAsync(check.Id, [chosen.Key, "invented"], CancellationToken.None), "ligne changée/protégée ou inventée non retirée");
        Check.Equal(520L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "tous les originaux restent présents");
    }
}
