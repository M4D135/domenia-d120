using System.Security.Cryptography;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Ldap;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static partial class NativeStorageSwitchTests
{
    [Test]
    public static async Task Separate_D1_database_is_upgraded_only_on_its_copy_and_all_original_bytes_remain_unchanged()
    {
        foreach (var bound in new[] { false, true })
        {
            using var setup = new Setup(); await setup.Initialize();
            var source = Path.Combine(setup.App, "Historique.db"); CreateD1(source, bound);
            var original = Hash(source); var active = Hash(setup.Database.Path);
            var beforeFiles = Directory.GetFiles(setup.App).Order().ToArray();
            var plan = Seal(await setup.Cache.PrepareStorageRestoreAsync(source, false, None));
            Check.True(plan.Changes.Single(c => c.Attribute == "switch.proof").AfterValue!.Contains("\"legacy\":true"), "provenance D1 explicite dans la preuve fermée");
            Check.True(beforeFiles.SequenceEqual(Directory.GetFiles(setup.App).Order()), "préparation ne migre ni ne sauvegarde l’original");
            Check.Equal(original, Hash(source), "source intacte après aperçu");
            await setup.Cache.ApplyStorageSwitchAsync(plan, None);
            var target = await setup.Cache.DatabaseAsync(None);
            Check.True(target.Path != source && target.Path != setup.Database.Path, "nouveau fichier de la session");
            Check.Equal(original, Hash(source), "aucun octet D1 réécrit après reprise");
            Check.Equal(active, Hash(setup.Database.Path), "ancienne base active préservée");
            using (var copy = new SqliteDatabase(target.Path, true))
            {
                Check.Equal("Historique à conserver", copy.Scalar("SELECT description FROM ad_objects WHERE name='PC1';") as string, "donnée historique exacte");
                Check.Equal(target.StoreId, copy.Scalar("SELECT store_id FROM domenia_store_state WHERE id=1;") as string, "identité du nouveau chemin");
                Check.Equal(bound ? 43L : 1L, (long)copy.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;")!, "révision de la source identifiée ou première conversion explicitement qualifiée");
                Check.Equal(1L, (long)copy.Scalar("SELECT count(*) FROM sqlite_master WHERE name='domenia_v2_objects';")!, "schéma V2 prêt avant sélection");
            }
            Check.Equal(VerificationState.Verified, (await setup.Cache.VerifyStorageSwitchAsync(plan, None)).State, "preuve et copie relues");
            Check.Equal(target.Path, (await setup.Reopen().DatabaseAsync(None)).Path, "base sélectionnée après relecture froide");
        }
    }

    [Test]
    public static async Task Interrupted_D1_copy_requires_explicit_resume_and_refuses_source_changes_before_any_switch()
    {
        using var setup = new Setup(); await setup.Initialize();
        var source = Path.Combine(setup.App, "Historique.db"); CreateD1(source, false); var original = Hash(source);
        var stale = Seal(await setup.Cache.PrepareStorageRestoreAsync(source, false, None));
        using (var edit = new SqliteDatabase(source, false)) edit.Execute("UPDATE ad_objects SET description='Modifié';");
        Check.False((await setup.Cache.CheckStorageSwitchAsync(stale, None)).Current, "nouveau contenu ne vaut pas l’aperçu confirmé");
        await ExpectFailure(() => setup.Cache.ApplyStorageSwitchAsync(stale, None), "source changée refusée avant sélection");
        Check.Equal(setup.Database.Path, (await setup.Reopen().DatabaseAsync(None)).Path, "ancienne base toujours active");
        var plan = Seal(await setup.Cache.PrepareStorageRestoreAsync(source, false, None));
        setup.Cache.SwitchCheckpoint = step => { if (step == "copied") throw new IOException("Arrêt après conversion de copie D1."); };
        await ExpectFailure(() => setup.Cache.ApplyStorageSwitchAsync(plan, None), "conversion arrêtée avant publication");
        var changed = Hash(source); Check.True(original != changed, "fixture réellement modifiée avant nouveau plan");
        var reopened = setup.Reopen();
        Check.True((await reopened.InspectLocalStoreAsync(false, false, None)).Maintenance.Locked, "reprise explicite nécessaire");
        var resume = Seal(await reopened.PrepareStorageResumeAsync(None));
        await reopened.ApplyStorageSwitchAsync(resume, None);
        Check.Equal(changed, Hash(source), "source non modifiée par reprise");
        Check.Equal(VerificationState.Verified, (await reopened.VerifyStorageSwitchAsync(resume, None)).State, "nouveau reçu de reprise vérifié");
    }

    [Test]
    public static async Task Separate_D1_refuses_unknown_domain_future_schema_and_busy_file_without_modifying_it()
    {
        foreach (var issue in new[] { "domain", "schema", "damagedV2", "busy", "guid", "guidFormat", "guidCase", "state", "dn" })
        {
            using var setup = new Setup(); await setup.Initialize(); var source = Path.Combine(setup.App, "Refus.db"); CreateD1(source, false);
            using (var edit = new SqliteDatabase(source, false))
            {
                if (issue == "domain") edit.Execute("DELETE FROM sync_state;");
                if (issue == "schema") edit.Execute("UPDATE schema_info SET value='12' WHERE key='schema_version';");
                if (issue == "damagedV2") edit.Execute("CREATE TABLE domenia_v2_objects(object_guid TEXT);");
                if (issue == "guid") edit.Execute("UPDATE ad_objects SET object_guid=NULL;");
                if (issue == "guidFormat") edit.Execute("UPDATE ad_objects SET object_guid=?1;", Fixtures.IdOf("PC1").ToString("N"));
                if (issue == "guidCase") edit.Execute("UPDATE ad_objects SET object_guid=?1;", "ABCDEF01-0000-0000-0000-000000000001");
                if (issue == "state") edit.Execute("UPDATE ad_objects SET state='Inconnu';");
                if (issue == "dn") edit.Execute("UPDATE ad_objects SET distinguished_name='CN=PC1,DC=other,DC=local';");
            }
            var before = Hash(source);
            if (issue == "busy")
            {
                var plan = Seal(await setup.Cache.PrepareStorageRestoreAsync(source, false, None));
                using var busy = new FileStream(source, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
                await ExpectFailure(() => setup.Cache.ApplyStorageSwitchAsync(plan, None), "source encore ouverte en écriture refusée");
            }
            else await ExpectFailure(() => setup.Cache.PrepareStorageRestoreAsync(source, false, None), "qualification fermée " + issue);
            Check.Equal(before, Hash(source), "fichier refusé intact : " + issue);
            Check.Equal(setup.Database.Path, (await setup.Reopen().DatabaseAsync(None)).Path, "sélection originale : " + issue);
        }
    }

    [Test]
    public static async Task Same_account_offline_switch_transports_new_epoch_and_store_identity_to_the_real_session_info()
    {
        using var setup = new Setup(); await setup.Initialize();
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new Domenia.Ad.AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: setup.Cache);
        using var dashboard = new DashboardService(source, new OperationJournal(), TestClock.Fixed());
        var before = await dashboard.GetSessionInfoAsync(None);
        Check.Equal(ConnectionState.Disconnected, before.Connection.State, "reprise possible sans connexion AD");
        Check.Equal(setup.Database.StoreId, before.StoreId, "identité de la vraie base locale transmise");
        var executor = new Domenia.Ad.AdStorageMoveExecutor(source);
        var draft = await executor.PlanMoveAsync(setup.Destination, None); var plan = Seal(draft); executor.Bind(draft, plan);
        await executor.ExecuteAsync(plan, None);
        var after = await dashboard.GetSessionInfoAsync(None);
        Check.Equal(before.Account.Login, after.Account.Login, "même compte");
        Check.Equal(before.Domain?.DnsName, after.Domain?.DnsName, "même domaine");
        Check.True(after.Epoch > before.Epoch, "nouvelle génération réellement transmise");
        Check.Equal((await setup.Cache.DatabaseAsync(None)).StoreId, after.StoreId, "identité de la nouvelle base relue");
        Check.True(after.StoreId != before.StoreId, "un marqueur ne dépend pas seulement du compte");
        Check.Equal(0, ldap.Searches.Count, "aucune requête AD pour qualifier ce changement local");
    }

    [Test]
    public static async Task D1_restore_executor_reloads_real_objects_and_partial_AD_refresh_preserves_other_history_without_invented_facts()
    {
        using var setup = new Setup(); await setup.Initialize();
        var original = Path.Combine(setup.App, "Historique.db"); CreateD1(original, true);
        var pc2 = Fixtures.Computer("PC2"); var user = Fixtures.User("LEGACY");
        using (var db = new SqliteDatabase(original, false))
        {
            db.Execute("INSERT INTO ad_objects(object_key,object_guid,object_type,name,state,distinguished_name,description) VALUES(?1,?1,'Machine','PC2','Actif',?2,'Sans date conservée');", pc2.ObjectGuid.ToString("D"), pc2.DistinguishedName);
            db.Execute("INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,state,distinguished_name) VALUES(?1,?1,'Utilisateur','LEGACY','legacy','Actif',?2);", user.ObjectGuid.ToString("D"), user.DistinguishedName);
        }
        var originalHash = Hash(original);
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new Domenia.Ad.AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: setup.Cache);
        using var dashboard = new DashboardService(source, new OperationJournal(), TestClock.Fixed());
        var before = await dashboard.GetSessionInfoAsync(None);
        var executor = new Domenia.Ad.AdStorageRestoreExecutor(source);
        var draft = await executor.PlanRestoreFileAsync(original, None); var plan = Seal(draft); executor.Bind(draft, plan);
        Check.Equal(WriteResult.Applied, (await executor.ExecuteAsync(plan, None)).Result, "vraie restauration par l’exécuteur de session");
        Check.Equal(VerificationState.Verified, (await executor.VerifyAsync(plan, None)).State, "copie durable vérifiée");
        var local = (await source.ReadLocalAsync(None)).Directory;
        var pc1 = local.Computers.Single(c => c.Name == "PC1");
        Check.Equal("Historique à conserver", pc1.Description, "objet D1 immédiatement disponible dans la source réelle");
        Check.Equal(2, local.Computers.Length, "tous les GUID historiques lisibles"); Check.Equal(1, local.Users.Length, "utilisateur historique relu");
        Check.False(local.Complete, "jamais annoncé comme recensement complet");
        Check.True(pc1.LegacyIndexOnly && pc1.Sid == "" && pc1.DnsHostName is null, "aucune identité de sécurité ni adresse inventée");
        Check.Equal(Fixtures.Now.AddDays(-10), local.ObjectReadAt![pc1.ObjectGuid], "date D1 conservée");
        Check.Equal(DateTimeOffset.MinValue, local.ObjectReadAt![pc2.ObjectGuid], "date inconnue reste inconnue");
        var dataset = HomeQueryDraftTests.Dataset(pc1) with { Directory = local };
        var pcRecord = QueryRecordBuilder.Computer(dataset, pc1.ObjectGuid, Fixtures.Now)!;
        Check.True(pcRecord.Active == true && pcRecord.Value("createdDays") is null && pcRecord.Value("laps") is null, "état conservé sans âge ou LAPS inventé");
        Check.Equal(LdapPresence.NotRead, pcRecord.Entry.Get(LdapSchema.Find("userAccountControl")!, out _), "bit actif historique ne vaut pas UAC complet");
        var account = QueryRecordBuilder.Build(dataset, QueryTarget.User, null, Fixtures.Now).Single();
        Check.True(account.Value("passwordNeverExpires") is null && account.Value("privileged") is null && account.Value("lockState") is null, "pas de verdict compte dérivé de champs absents");
        var fiche = Domenia.Ad.AdFicheProjection.Entry(pc1);
        Check.False(fiche.Attributes.ContainsKey("userAccountControl") || fiche.Attributes.ContainsKey("objectSid"), "la fiche ne présente pas de faux attributs");
        var after = await dashboard.GetSessionInfoAsync(None);
        Check.True(after.Epoch > before.Epoch && after.StoreId != before.StoreId, "session réelle invalidée");
        Check.Equal((await setup.Cache.DatabaseAsync(None)).StoreId, after.StoreId, "nouvelle base active annoncée");
        Check.Equal(3, after.Cache.Objects, "compteurs locaux disponibles hors ligne");
        await setup.Cache.SaveObjectsAsync(Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]), null, None);
        var mixed = (await setup.Reopen().ReadKnownAsync(None))!;
        Check.Equal(2, mixed.Computers.Length, "une nouvelle lecture partielle ne masque pas l’autre poste D1");
        Check.False(mixed.Computers.Single(c => c.Name == "PC1").LegacyIndexOnly, "le vrai relevé remplace son propre GUID");
        Check.True(mixed.Computers.Single(c => c.Name == "PC2").LegacyIndexOnly, "autre GUID reste historique");
        Check.Equal(1, mixed.Users.Length, "utilisateur historique conservé à froid");
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        var census = Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]) with { Coverage = scope, OrganizationalUnits = [] };
        await setup.Cache.SaveAsync(census, scope, null, None);
        var scoped = (await setup.Cache.ReadAsync(None))!;
        Check.Equal(0, scoped.Users.Length, "lecture du périmètre ne fait pas entrer l’utilisateur d’une autre OU");
        Check.False(scoped.Complete, "l’union conservée reste une connaissance partielle, même après une collecte complète");
        Check.Equal(1, (await setup.Cache.ReadKnownAsync(None))!.Users.Length, "allKnown conserve l’autre OU");
        var target = ObjectWrites.Target(Domenia.Ad.AdFicheProjection.Entry(pc2));
        await setup.Cache.ApplyDeletionAsync(target, Fixtures.Now, None);
        await setup.Cache.SaveAsync(census, scope, null, None);
        Check.False((await setup.Reopen().ReadKnownAsync(None))!.Computers.Any(c => c.ObjectGuid == pc2.ObjectGuid), "suppression confirmée jamais ressuscitée par l’index D1 après lecture complète");
        Check.Equal(originalHash, Hash(original), "aucun changement du fichier D1");
        Check.Equal(0, ldap.Searches.Count, "aucune requête annuaire réelle");
    }

    private static void CreateD1(string path, bool bound)
    {
        using var resource = typeof(DomeniaDatabase).Assembly.GetManifestResourceStream("Domenia.Store.Sqlite.schema-11.sql") ?? throw new TestFailureException("Schéma embarqué absent.");
        using var text = new StreamReader(resource); using var db = new SqliteDatabase(path, false); db.Script(text.ReadToEnd());
        db.Execute("INSERT INTO sync_state(scope,base_dn) VALUES('directory',?1);", Fixtures.Root);
        db.Execute("INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,state,distinguished_name,description,synced_at) VALUES(?1,?1,'Machine','PC1','PC1$','Actif',?2,'Historique à conserver',?3);", Fixtures.IdOf("PC1").ToString("D"), "CN=PC1," + Fixtures.Postes, Fixtures.Now.AddDays(-10).ToString("O"));
        if (bound) db.Execute("INSERT INTO domenia_store_state(id,store_id,domain_dn,revision) VALUES(1,?1,?2,42);", new string('a', 64), Fixtures.Root);
    }
    private static string Hash(string path) => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
}
