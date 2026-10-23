using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdRelationImportTests
{
    private static async Task<(DomeniaDatabase Db, SqliteDirectoryCache Cache, AdDirectorySource Source, AdBoundaryTests.RecordingAdConnection Ldap)> Open(TemporaryFolder folder, int computers = 6)
    {
        var db = new DomeniaDatabase(folder.File("imports.db"), Fixtures.Root, TestClock.Fixed()); var cache = new SqliteDirectoryCache(db);
        var alice = Fixtures.User("alice") with { UserPrincipalName = "prenom.nom@test.local" };
        await cache.SaveObjectsAsync(Fixtures.Snapshot(users: [alice, Fixtures.User("bob")], computers: Enumerable.Range(1, computers).Select(i => Fixtures.Computer("PC" + i))), null, CancellationToken.None);
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.ReadLocalAsync(CancellationToken.None); return (db, cache, source, ldap);
    }
    private static RelationImportRequest Csv(string rows) => new("file-1", RelationImportAdapter.Csv, "inventaire.csv", "UserLogin;Computer;Source;When\n" + rows);
    private static WritePlan Bind(AdRelationChangeExecutor executor, WritePlanDraft draft, AdDirectorySource source)
    {
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, source.Clock.GetUtcNow(), source.Zone); executor.Bind(draft, plan); return plan;
    }
    private static void Associate(DomeniaDatabase db, string computer, string user)
    {
        using var sql = new SqliteDatabase(db.Path, false);
        sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source,user_guid,computer_guid) VALUES(?1,?2,?1,'Saisie manuelle',?3,?4);",
            computer, user, Fixtures.User(user).ObjectGuid.ToString("D"), Fixtures.Computer(computer).ObjectGuid.ToString("D"));
    }

    [Test]
    public static async Task Native_import_resolves_complete_UPNs_and_DNS_names_locally_without_trusting_the_file_source()
    {
        using var folder = new TemporaryFolder(); var (db, _, source, ldap) = await Open(folder); using var owned = source;
        var preview = await new AdRelationsReader(source).ImportPreviewAsync(Csv("prenom.nom@test.local;PC1.test.local;Saisie manuelle;2026-10-20T12:00:00Z"), CancellationToken.None);
        Check.Equal(1, preview.Ready, "UPN dont le préfixe diffère du SAM résolu exactement"); Check.Equal("alice", preview.Rows.Single().User, "SAM canonique affiché");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aperçu sans écriture");
        using var executor = new AdRelationChangeExecutor(source); var plan = Bind(executor, await executor.PlanImportAsync(preview.Id, CancellationToken.None), source);
        await executor.ExecuteAsync(plan, CancellationToken.None); var relation = (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation;
        Check.Equal("Import CSV", relation.Source, "source imposée par l’adaptateur"); Check.Equal(RelationKind.Imported, relation.Kind, "pas une déclaration manuelle");
        Check.Equal(Fixtures.User("alice").ObjectGuid, relation.UserGuid, "identité de l’index scellée"); Check.Equal("PC1", relation.Computer, "nom Windows canonique");
        Check.Equal(preview.BatchId, relation.BatchId, "lot durable"); Check.Equal(0, ldap.Searches.Count, "aucun LDAP pendant aperçu ou import");
        await executor.ExecuteAsync(Bind(executor, await executor.PlanImportUndoAsync(preview.BatchId, CancellationToken.None), source), CancellationToken.None);
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "annulation du lot importé");
    }

    [Test]
    public static async Task Import_rejects_foreign_or_unknown_identities_and_canonicalises_aliases_before_file_conflict_detection()
    {
        using var folder = new TemporaryFolder(); var (_, _, source, _) = await Open(folder); using var owned = source;
        var preview = await new AdRelationsReader(source).ImportPreviewAsync(Csv("alice;PC1;;\nprenom.nom@test.local;PC1.test.local;;\nalice;PC2;;\nbob;PC2;;\nalice;PC3.foreign.local;;\nmissing;PC4;;\nFOREIGN\\alice;PC5;;"), CancellationToken.None);
        Check.Equal(1, preview.Ready, "un seul alias du même couple importable"); Check.Equal(1, preview.Counts.Duplicate, "alias UPN/SAM reconnus comme doublon");
        Check.Equal(2, preview.Counts.Conflict, "deux comptes sans date départageante en conflit"); Check.Equal(2, preview.Counts.Reject, "FQDN et autorité étrangers rejetés");
        Check.Equal(1, preview.Counts.Unknown, "compte absent de l’index non importé");
    }

    [Test]
    public static async Task Import_rechecks_new_associations_after_preview_and_atomically_after_confirmation()
    {
        using var folder = new TemporaryFolder(); var (db, _, source, _) = await Open(folder); using var owned = source;
        var reader = new AdRelationsReader(source); using var executor = new AdRelationChangeExecutor(source);
        var preview = await reader.ImportPreviewAsync(Csv("alice;PC1;;\nalice;PC2;;"), CancellationToken.None); Associate(db, "PC1", "bob");
        var draft = await executor.PlanImportAsync(preview.Id, CancellationToken.None); Check.Equal(1, draft.Changes.Length, "poste associé depuis l’aperçu laissé de côté");
        var plan = Bind(executor, draft, source); Check.True((await executor.CheckAsync(plan, CancellationToken.None)).Current, "second poste encore libre");
        Associate(db, "PC2", "bob");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "conflit apparu après précontrôle refusé dans la transaction");
        var rows = (await db.ReadRelationsAsync(CancellationToken.None)).Rows;
        Check.Equal(2, rows.Length, "deux déclarations préservées"); Check.True(rows.All(r => r.Relation.UserLogin == "bob"), "aucun ajout concurrent de l’import");
    }

    [Test]
    public static async Task Import_previews_expire_and_do_not_survive_identity_changes_or_session_reset()
    {
        using var folder = new TemporaryFolder(); var (_, cache, source, _) = await Open(folder); using var owned = source;
        var reader = new AdRelationsReader(source); using var executor = new AdRelationChangeExecutor(source);
        var first = await reader.ImportPreviewAsync(Csv("alice;PC1;;"), CancellationToken.None);
        ((FixedTimeProvider)source.Clock).Advance(TimeSpan.FromMinutes(16));
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanImportAsync(first.Id, CancellationToken.None), "aperçu expiré");
        var second = await reader.ImportPreviewAsync(Csv("alice;PC1;;"), CancellationToken.None); source.Reset();
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanImportAsync(second.Id, CancellationToken.None), "aperçu d’une ancienne session");
        await cache.SaveObjectsAsync(Fixtures.Snapshot(users: [Fixtures.User("bob") with { SamAccountName = "alice" }], computers: [Fixtures.Computer("PC1")]), null, CancellationToken.None);
        source.Reset(); var third = await reader.ImportPreviewAsync(Csv("alice;PC1;;"), CancellationToken.None);
        Check.Equal(1, third.Ready, "nouvel aperçu utilise explicitement le nouveau compte");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanImportAsync(first.Id, CancellationToken.None), "ancien aperçu jamais réattribué à l’homonyme");
    }

    [Test]
    public static async Task Import_limits_batches_and_never_invents_an_instant_for_a_DST_gap_or_fold()
    {
        using var folder = new TemporaryFolder(); var (_, _, source, _) = await Open(folder, 70); using var owned = source;
        var text = string.Join('\n', Enumerable.Range(1, 70).Select(i => "alice;PC" + i + ";;"));
        var preview = await new AdRelationsReader(source).ImportPreviewAsync(Csv(text), CancellationToken.None);
        Check.Equal(64, preview.Ready, "lot de 64"); Check.Equal(6, preview.Counts.Deferred, "reste annoncé");
        Check.Null(RelationRules.ParseStoredWhen("2026-03-29T02:30:00", source.Zone), "heure inexistante non déplacée artificiellement");
        Check.Null(RelationRules.ParseStoredWhen("2025-10-26T02:30:00", source.Zone), "heure ambiguë non départagée arbitrairement");
        Check.NotNull(RelationRules.ParseStoredWhen("2025-10-26T02:30:00+02:00", source.Zone), "décalage explicite garde son instant");
    }

    [Test]
    public static async Task GLPI_and_osquery_use_their_own_adapters_and_ignore_future_timestamps_when_selecting_latest_readings()
    {
        using var folder = new TemporaryFolder(); var (db, _, source, ldap) = await Open(folder); using var owned = source;
        var reader = new AdRelationsReader(source);
        var glpi = await reader.ImportPreviewAsync(new("glpi", RelationImportAdapter.Glpi, "glpi.csv", "Nom;Usager\nPC1;alice"), CancellationToken.None);
        Check.Equal(1, glpi.Ready, "export GLPI"); Check.Equal("Import GLPI", glpi.Source, "provenance GLPI");
        var past = Fixtures.Now.AddMinutes(-5).ToUnixTimeSeconds(); var future = Fixtures.Now.AddMinutes(30).ToUnixTimeSeconds();
        var json = "[{\"user\":\"alice\",\"hostname\":\"PC2\",\"time\":\"" + past + "\"},{\"user\":\"bob\",\"hostname\":\"PC2\",\"time\":\"" + future + "\"}]";
        var osquery = await reader.ImportPreviewAsync(new("osquery", RelationImportAdapter.Osquery, "releve.json", json), CancellationToken.None);
        Check.Equal(1, osquery.Ready, "un relevé daté réel"); Check.Equal("alice", osquery.Rows.Single().User, "horodatage futur non retenu pour départager");
        using var executor = new AdRelationChangeExecutor(source); await executor.ExecuteAsync(Bind(executor, await executor.PlanImportAsync(osquery.Id, CancellationToken.None), source), CancellationToken.None);
        Check.Equal("Import osquery", (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation.Source, "source osquery imposée");
        Check.Equal(0, ldap.Searches.Count, "trois adaptateurs locaux");
    }
}
