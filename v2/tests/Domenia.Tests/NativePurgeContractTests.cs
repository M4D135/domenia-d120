using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativePurgeContractTests
{
    [Test]
    public static async Task Adding_a_reset_checkpoint_invalidates_the_preview_even_when_deleted_rows_stay_zero()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("stale-checkpoint.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        using (var db = new SqliteDatabase(database.Path, false))
            db.Execute("INSERT INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('directory','dc',?1,99,?2,0,'depth=Subtree;full');", Fixtures.Root, Fixtures.Now.ToString("O"));
        var before = LocalStoreRules.PurgePlan(await database.InspectLocalStoreAsync(false, false, default), ["index"], 730, Fixtures.Now, TimeZoneInfo.Utc);
        using (var db = new SqliteDatabase(database.Path, false))
            db.Execute("INSERT INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('ou:extra','dc',?1,120,?2,0,'depth=Subtree;full');", "OU=Extra," + Fixtures.Root, Fixtures.Now.ToString("O"));
        var after = LocalStoreRules.PurgePlan(await database.InspectLocalStoreAsync(false, false, default), ["index"], 730, Fixtures.Now, TimeZoneInfo.Utc);
        Check.Equal(0L, before.TotalRows, "zéro suppression avant");
        Check.Equal(0L, after.TotalRows, "zéro suppression après");
        Check.False(before.Fingerprint == after.Fingerprint, "le nombre de repères à réinitialiser appartient à l’aperçu");
        var failure = await Check.ThrowsAsync<DomeniaOperationException>(() => database.PrepareStoragePurgeAsync(["index"], 730, before.Fingerprint, default), "aucun élargissement silencieux de la purge");
        Check.Equal(StorageWritePlans.PreviewStale, failure.Code, "refaire l’aperçu demandé");
        using var verify = new SqliteDatabase(database.Path, true);
        Check.Equal(2L, (long)verify.Scalar("SELECT count(*) FROM sync_state WHERE highest_usn>0;")!, "les deux repères restent intacts");
    }

    [Test]
    public static async Task An_index_checkpoint_can_be_reset_with_zero_deleted_rows_and_a_verified_receipt()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("checkpoint.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        using (var db = new SqliteDatabase(database.Path, false))
            db.Execute("INSERT INTO sync_state(scope,server,base_dn,highest_usn,last_sync,item_count,details) VALUES('directory','dc',?1,99,?2,0,'depth=Subtree;full');", Fixtures.Root, Fixtures.Now.ToString("O"));
        var snapshot = await database.InspectLocalStoreAsync(false, false, default);
        var preview = LocalStoreRules.PurgePlan(snapshot, ["index"], 730, Fixtures.Now, TimeZoneInfo.Utc);
        Check.Equal(0L, preview.TotalRows, "aucune ligne à supprimer");
        Check.False(preview.NothingToDo, "le point de reprise existant reste une action réelle");
        Check.Equal(1L, preview.Targets.Single(t => t.Table == "sync_state").Rows, "un vrai repère à remettre à zéro");
        var draft = await database.PrepareStoragePurgeAsync(["index"], 730, preview.Fingerprint, default);
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), "test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
        await database.ApplyStoragePurgeAsync(plan, default);
        var reopened = new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed());
        Check.Equal(VerificationState.Verified, (await reopened.VerifyStoragePurgeAsync(plan, default)).State, "reçu durable valide même avec zéro suppression");
        using var verify = new SqliteDatabase(database.Path, true);
        Check.Equal(1L, (long)verify.Scalar("SELECT count(*) FROM sync_state WHERE highest_usn=0 AND last_sync IS NULL AND item_count=0 AND details IS NULL;")!, "repère conservé et réinitialisé");
    }

    [Test]
    public static async Task Native_inventory_matches_the_independent_closed_contract_and_never_fabricates_missing_counts()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("purge.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        var snapshot = await database.InspectLocalStoreAsync(false, false, default);
        var expected = LocalStoreRules.PurgeCategories.Where(c => c.Purgeable)
            .SelectMany(c => LocalStoreRules.PurgeTargets(c.Id).Select(t => (Category: c.Id, t.Table, t.Action))).ToHashSet();
        var actual = snapshot.NativePurgeTargets.Select(t => (t.Category, t.Table, t.Action)).ToHashSet();
        Check.Equal(27, actual.Count, "inventaire natif réellement produit, y compris documents partiels et mesures natives");
        Check.True(expected.SetEquals(actual), "deux listes indépendantes identiques avant toute suppression");
        Check.False(actual.Any(t => t.Table is "secret_state" or "user_machine_links" or "domenia_store_batches"), "aucune table protégée autorisée");
        var missing = Check.Throws<DomeniaOperationException>(() => LocalStoreRules.PurgePlan(snapshot with { NativePurgeTargets = [] }, ["observations"], 730, Fixtures.Now, TimeZoneInfo.Utc), "comptage absent refusé sans reporter un total sur la première table");
        Check.Equal("settings.invalidPurge", missing.Code, "refus nommé");
        var forged = snapshot with { NativePurgeTargets = snapshot.NativePurgeTargets.SetItem(0, snapshot.NativePurgeTargets[0] with { Table = "secret_state" }) };
        Check.Throws<DomeniaOperationException>(() => LocalStoreRules.PurgePlan(forged, ["observations"], 730, Fixtures.Now, TimeZoneInfo.Utc), "table ajoutée à un aperçu refusée");
        foreach (var days in new[] { 0, StoragePolicyRules.MaxRetentionDays + 1 })
        {
            Check.Throws<DomeniaOperationException>(() => LocalStoreRules.PurgePlan(snapshot, ["history"], days, Fixtures.Now, TimeZoneInfo.Utc), "âge hors bornes refusé par les règles");
            var failure = await Check.ThrowsAsync<DomeniaOperationException>(() => database.PrepareStoragePurgeAsync(["history"], days, new string('a', 64), default), "même refus avant plan natif");
            Check.Equal("settings.invalidPurge", failure.Code, "moteur direct : pas d’ArgumentException nue");
        }
    }
}
