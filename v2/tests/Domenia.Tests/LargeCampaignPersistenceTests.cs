using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using Domenia.Store;

namespace Domenia.Tests;

internal static class LargeCampaignPersistenceTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static ImmutableArray<QueryComputerIdentity> Targets(int count) => Enumerable.Range(1, count).Select(i =>
        new QueryComputerIdentity(new Guid(i, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1), $"CN=PC{i:D6}," + Fixtures.Postes,
            Fixtures.Now.AddYears(-2), Fixtures.Domain.DomainSid + "-" + (1000 + i), $"PC{i:D6}.test.local", $"PC{i:D6}$", 4096)).ToImmutableArray();
    private static HomeCampaignCheckpoint Plan(string store, ImmutableArray<QueryComputerIdentity> targets) => new(
        Guid.NewGuid().ToString("D"), store, Fixtures.Root, new(Fixtures.Postes, "Postes", true), "presence", ["presence"], [], targets,
        [], [], [], [], Fixtures.Now, Fixtures.Now, Fixtures.Now, false, false);

    [Test]
    public static async Task Hundred_thousand_frozen_identities_are_written_once_and_progress_survives_reopen_and_conflict()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("large-home.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(database);
        var targets = Targets(100_000);
        var initial = new OperationsLocalState(database.StoreId, Fixtures.Root, 1, [], [], null) { HomeCampaign = Plan(database.StoreId, targets) };
        var current = await cache.UpdateOperationsAsync(0, initial, None);
        var inspection = (await database.InspectAsync(None))!;
        Check.Equal(2, inspection.SchemaRevision, "le premier checkpoint paginé ferme l’accès des anciens lecteurs, même sans cache fleet");
        using (var backup = new SqliteDatabase(inspection.Backup!.Path, true))
        { Check.Equal("1", backup.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';") as string, "sauvegarde compatible créée avant migration du checkpoint"); }
        using (var sql = new SqliteDatabase(database.Path, false))
        {
            Check.Equal(391L, (long)sql.Scalar("SELECT count(*) FROM domenia_v2_operation_target_pages;")!, "cent mille identités en pages de 256, dernière page complète");
            Check.True((long)sql.Scalar("SELECT sum(length(CAST(payload AS BLOB))) FROM domenia_v2_operation_target_pages;")! > OperationsDocumentCodec.MaxTargetsBytes,
                "le recensement dépasse réellement l’ancien plafond brut de 16 Mio");
            sql.Execute("CREATE TABLE campaign_page_audit(writes INTEGER NOT NULL);");
            sql.Execute("INSERT INTO campaign_page_audit(writes) VALUES(0);");
            sql.Script("CREATE TRIGGER campaign_page_insert_audit AFTER INSERT ON domenia_v2_operation_target_pages BEGIN UPDATE campaign_page_audit SET writes=writes+1; END;");
        }
        var reopened = new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed());
        var reopenedCache = new SqliteDirectoryCache(reopened);
        current = await reopened.ReadOperationsAsync(None);
        var frozen = current.HomeCampaign!.Targets;
        Check.True(frozen.SequenceEqual(targets), "toutes les identités GUID/DN/SID/hôte/compte conservées à froid");
        for (var step = 1; step <= 20; step++)
        {
            var next = current with { Revision = current.Revision + 1, HomeCampaign = current.HomeCampaign! with
            { PresenceDone = [.. frozen.Take(step * 5000).Select(t => t.Guid)], Interrupted = step == 20 } };
            current = await reopenedCache.UpdateOperationsAsync(current.Revision, next, None);
            Check.True(frozen.Equals(current.HomeCampaign!.Targets), "snapshot immuable réutilisé pendant les checkpoints, sans redécoder le recensement");
        }
        using (var sql = new SqliteDatabase(database.Path, true))
        {
            Check.Equal(0L, (long)sql.Scalar("SELECT writes FROM campaign_page_audit;")!, "vingt checkpoints n’ont réécrit aucune cible");
            Check.Equal(1L, (long)sql.Scalar("SELECT count(*) FROM domenia_v2_operation_target_sets;")!, "pas d’historique de populations dupliquées en mémoire ou sur disque");
            Check.True((long)sql.Scalar("SELECT length(CAST(payload AS BLOB)) FROM domenia_v2_operations WHERE id=1;")! < 50_000,
                "journal compact : deux bitsets et références, pas cent mille GUID répétés");
        }
        var other = new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed());
        var restored = await other.ReadOperationsAsync(None);
        Check.Equal(100_000, restored.HomeCampaign!.PresenceDone.Length, "dernier bit relu à froid après interruption");
        Check.True(restored.HomeCampaign.Interrupted, "reprise offerte, jamais exécutée automatiquement");
        await Check.ThrowsAsync<InvalidDataException>(() => reopenedCache.UpdateOperationsAsync(initial.Revision, initial with { Revision = 2 }, None), "écriture concurrente périmée");
        Check.Equal(restored.Revision, (await other.ReadOperationsAsync(None)).Revision, "conflit sans écrasement de progression");
        current = await reopenedCache.UpdateOperationsAsync(current.Revision, current with { Revision = current.Revision + 1, HomeCampaign = null }, None);
        using var cleared = new SqliteDatabase(database.Path, true);
        Check.Equal(0L, (long)cleared.Scalar("SELECT count(*) FROM domenia_v2_operation_target_pages;")!, "abandon explicite nettoie les pages dans la même transaction");
    }

    [Test]
    public static async Task Legacy_embedded_checkpoint_migrates_atomically_and_published_pages_refuse_mutation()
    {
        using var folder = new TemporaryFolder(); var database = new DomeniaDatabase(folder.File("legacy-home.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(None); var cache = new SqliteDirectoryCache(database);
        var original = new OperationsLocalState(database.StoreId, Fixtures.Root, 1, [], [], null) { HomeCampaign = Plan(database.StoreId, Targets(3)) };
        var payload = OperationsDocumentCodec.Encode(original);
        using (var sql = new SqliteDatabase(database.Path, false))
        {
            sql.Execute("CREATE TABLE domenia_v2_operations(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL,payload TEXT NOT NULL,sha256 TEXT NOT NULL);");
            sql.Execute("INSERT INTO domenia_v2_operations VALUES(1,1,?1,?2);", payload, Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(payload))));
        }
        var read = await database.ReadOperationsAsync(None);
        Check.True(read.HomeCampaign!.Targets.SequenceEqual(original.HomeCampaign!.Targets), "ancien journal embarqué lu sans migration destructive");
        var saved = await cache.UpdateOperationsAsync(1, read with { Revision = 2 }, None);
        using (var sql = new SqliteDatabase(database.Path, false))
        {
            Check.Throws<SqliteStoreException>(() => sql.Execute("UPDATE domenia_v2_operation_target_pages SET payload='[]';"), "page publiée immutable");
            Check.Throws<SqliteStoreException>(() => sql.Execute("DELETE FROM domenia_v2_operation_target_pages;"), "page publiée non supprimable");
            Check.Throws<SqliteStoreException>(() => sql.Execute("DELETE FROM domenia_v2_operation_target_sets;"), "jeu encore référencé non supprimable");
            var header = (string)sql.Scalar("SELECT payload FROM domenia_v2_operations WHERE id=1;")!;
            Check.Throws<InvalidDataException>(() => OperationsDocumentCodec.Decode(header), "référence locale jamais interprétée sans magasin ni repli vers population vide");
            // Simulate an unsupported editor that removes the guard, changes a page, then restores
            // the exact guard. Matching trigger names or SQL alone cannot authorize a warm cache.
            var guard = (string)sql.Scalar("SELECT sql FROM sqlite_master WHERE type='trigger' AND name='domenia_operation_targets_page_immutable';")!;
            sql.Script("DROP TRIGGER domenia_operation_targets_page_immutable;");
            sql.Execute("UPDATE domenia_v2_operation_target_pages SET payload='[]';");
            sql.Script(guard + ";");
        }
        await Check.ThrowsAsync<InvalidDataException>(() => database.ReadOperationsAsync(None), "cache chaud revérifié après remplacement puis restauration exacte de la protection");
        await Check.ThrowsAsync<InvalidDataException>(() => new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed()).ReadOperationsAsync(None), "empreinte de page contrôlée à froid");
        Check.Equal(3, saved.HomeCampaign!.Targets.Length, "le dernier snapshot reçu reste immuable après le défaut de disque");
    }

    [Test]
    public static async Task Search_survey_uses_the_same_paged_census_and_retains_exact_completion_bits()
    {
        using var folder = new TemporaryFolder(); var database = new DomeniaDatabase(folder.File("large-search.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(database);
        var targets = Targets(100_000).Select(t => new SurveyTarget(t.Guid.ToString("D"), t.Account![..^1], t.Dn, t.Host)).ToImmutableArray();
        var completed = ImmutableArray.Create(Guid.Parse(targets[0].Id), Guid.Parse(targets[^1].Id));
        var plan = new OperationsSurveyCheckpoint(Guid.NewGuid().ToString("D"), Fixtures.Root, new(Fixtures.Postes, "Postes", true), SurveyMode.Ping,
            targets, completed, Fixtures.Now, Fixtures.Now, true, 1);
        await cache.UpdateOperationsAsync(0, new(database.StoreId, Fixtures.Root, 1, [], [], plan), None);
        var restored = await new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed()).ReadOperationsAsync(None);
        Check.True(restored.Survey!.Targets.SequenceEqual(targets), "population Recherche complète, bornée et distincte de celle de l’Accueil");
        Check.True(restored.Survey.Completed.SequenceEqual(completed), "premier et dernier bits conservés sans ajouter les postes intermédiaires");
        Check.Equal(1, restored.Survey.Failed, "un échec reste distingué d’une présence confirmée");
    }

    [Test]
    public static void Branch_selection_preserves_order_excludes_unselected_OUs_and_keeps_direct_parent_workstations_disjoint()
    {
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        ImmutableArray<ScopeSelection> branches = [new("OU=B," + Fixtures.Postes, "B", true),
            new(Fixtures.Postes, "Postes directs", false), new("OU=A\\2cB," + Fixtures.Postes, "A,B", true)];
        var b = Fixtures.Computer("B01") with { DistinguishedName = "CN=B01,OU=B," + Fixtures.Postes };
        var direct = Fixtures.Computer("DIRECT");
        var nested = Fixtures.Computer("A01") with { DistinguishedName = "CN=A01,OU=Etage,OU=A\\,B," + Fixtures.Postes };
        var excluded = Fixtures.Computer("OTHER") with { DistinguishedName = "CN=OTHER,OU=C," + Fixtures.Postes };
        var selected = HomeCampaignRules.SelectTargets(Fixtures.Snapshot(computers: [nested, excluded, direct, b]), scope, branches);
        Check.True(selected.Select(t => t.Guid).SequenceEqual([b.ObjectGuid, direct.ObjectGuid, nested.ObjectGuid]), "ordre choisi, postes directs distincts et sous-arbre avec DN échappé");
        var plan = Plan("local-store", selected) with { Branches = branches, ReadWithoutEcho = true };
        var state = new OperationsLocalState("local-store", Fixtures.Root, 1, [], [], null) { HomeCampaign = plan };
        var decoded = OperationsDocumentCodec.Decode(OperationsDocumentCodec.Encode(state)).HomeCampaign!;
        Check.True(decoded.Branches.SequenceEqual(branches), "ordre et profondeur des branches persistés, pas seulement leurs libellés");
        Check.True(decoded.ReadWithoutEcho, "admission sans écho conservée avec le plan, indépendante d’un changement ultérieur de préférences");
        Check.Throws<InvalidDataException>(() => HomeCampaignRules.Validate(plan with { Targets = selected.Add(QueryComputerIdentity.Of(excluded)) }, "local-store", Fixtures.Root), "identité ajoutée hors des branches refusée");
        Check.Throws<InvalidDataException>(() => HomeCampaignRules.ValidateBranches(scope, [scope, branches[0]]), "parent récursif et descendant se recouvrent");
        Check.Throws<InvalidDataException>(() => HomeCampaignRules.ValidateBranches(scope, [new("OU=Other," + Fixtures.Root, "Autre", true)]), "branche hors périmètre refusée");
        Check.True(HomeCampaignRules.BranchClassifier(scope, [])(excluded.DistinguishedName) == 0, "ancien plan sans branches conserve tout le périmètre");
    }

    [Test]
    public static async Task Collection_reuses_a_write_locked_verified_backup_and_rechecks_after_lease_release()
    {
        using var folder = new TemporaryFolder(); var database = new DomeniaDatabase(folder.File("backup-proof.db"), Fixtures.Root, TestClock.Fixed());
        var cache = new SqliteDirectoryCache(database);
        string firstBackup;
        using (await cache.AcquireOperationsLeaseAsync(None))
        {
            await cache.UpdateOperationsAsync(0, new(database.StoreId, Fixtures.Root, 1, [], [], null), None);
            firstBackup = (await database.InspectAsync(None))!.Backup!.Path;
            Check.Throws<IOException>(() => { using var write = new FileStream(firstBackup, FileMode.Open, FileAccess.Write, FileShare.Read); }, "la preuve réutilisée empêche réellement toute modification du fichier sous Windows");
            await cache.UpdateOperationsAsync(1, new(database.StoreId, Fixtures.Root, 2, [], [], null), None);
            Check.Equal(firstBackup, (await database.InspectAsync(None))!.Backup!.Path, "même sauvegarde vérifiée durant la collecte");
        }
        using (var write = new FileStream(firstBackup, FileMode.Open, FileAccess.Write, FileShare.Read)) { write.WriteByte(0); }
        await cache.UpdateOperationsAsync(2, new(database.StoreId, Fixtures.Root, 3, [], [], null), None);
        Check.True((await database.InspectAsync(None))!.Backup!.Path != firstBackup, "après libération la preuve est recalculée, la sauvegarde altérée n’est pas réutilisée");
        Check.True(File.Exists(firstBackup), "fichier altéré conservé, jamais remplacé silencieusement");
    }
}
