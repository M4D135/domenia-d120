using System.Security.Cryptography;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class SqliteSweepWriteTests
{
    private static RelationSweepUpdate Update(string computer = "PC1", string status = "CONFIRME", DateTimeOffset? at = null) => new(Fixtures.Computer(computer).ObjectGuid,
        Fixtures.Computer(computer).DistinguishedName, computer, at ?? Fixtures.Now, status, status == "CONFIRME" ? @"TEST\alice" : null);
    private static RelationSweepWrite Request(DomeniaDatabase db, params RelationSweepUpdate[] values) => new(db.StoreId, WritePlans.NewId(), 0, [.. values]);
    private static async Task<DomeniaDatabase> Open(TemporaryFolder folder)
    { var db = new DomeniaDatabase(folder.File("sweeps.db"), Fixtures.Root, TestClock.Fixed()); await db.InitializeAsync(CancellationToken.None); return db; }
    private static Task<RelationSweepWriteResult> Apply(DomeniaDatabase db, RelationSweepWrite request) => db.ApplyRelationSweepsAsync(request, CancellationToken.None);

    [Test]
    public static async Task Native_sweep_inserts_preserve_legacy_name_rows_extensions_and_a_verified_pre_migration_backup()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder);
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Execute("ALTER TABLE park_state ADD COLUMN extension TEXT DEFAULT 'défaut';");
            sql.Execute("INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts,extension) VALUES('PC1','PC1','2026-10-20T10:00:00Z','SESSION','ancien',7,'original');");
        }
        var old = (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single();
        var saved = await Apply(db, Request(db, Update())); Check.Equal(1, saved.Updated, "nouveau passage GUID");
        var read = await db.ReadRelationSweepsAsync(CancellationToken.None);
        Check.Equal(2, read.Rows.Length, "ancien nom et nouvelle identité séparés");
        var legacy = read.Rows.Single(r => r.StorageKey == "PC1"); Check.Null(legacy.ComputerGuid, "ancien nom non réidentifié"); Check.Equal(7, legacy.Attempts, "compteur D1 intact");
        Check.Equal(old.PreservedFingerprint, legacy.PreservedFingerprint, "extension et clé préservées malgré migration additive");
        var native = read.Rows.Single(r => r.ComputerGuid is not null); Check.True(native.StorageKey.StartsWith("PC1|", StringComparison.Ordinal), "clé secondaire native");
        Check.Equal(Fixtures.Now, native.At!.Value, "date du passage"); Check.Equal(1, native.Attempts, "première tentative");
        var backup = (await db.InspectAsync(CancellationToken.None))!.Backup!;
        Check.Equal(backup.Sha256, Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(backup.Path))), "empreinte vérifiée");
        using var original = new SqliteDatabase(backup.Path, true);
        Check.False(original.Query("PRAGMA table_info(park_state);").Any(r => (string?)r["name"] == "computer_guid"), "sauvegarde avant ajout GUID");
        Check.Equal("original", (string)original.Scalar("SELECT extension FROM park_state WHERE computer_key='PC1';")!, "original récupérable");
    }

    [Test]
    public static async Task Sweep_refreshes_keep_the_original_physical_key_and_extensions_without_regressing_dates_or_overflowing_attempts()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); await Apply(db, Request(db, Update()));
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Execute("ALTER TABLE park_state ADD COLUMN extension BLOB;"); sql.Execute("UPDATE park_state SET extension=X'010203',attempts=2147483647;"); }
        var before = (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single();
        var fresh = Update(status: "LU", at: Fixtures.Now.AddMinutes(1)) with { Computer = "PCNEW", ComputerDn = "CN=PCNEW," + Fixtures.Postes };
        Check.Equal(1, (await Apply(db, Request(db, fresh))).Updated, "même GUID renommé actualisé");
        var read = (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single();
        Check.Equal(before.StorageKey, read.StorageKey, "clé historique inchangée"); Check.Equal(before.PreservedFingerprint, read.PreservedFingerprint, "colonnes supplémentaires conservées");
        Check.Equal(int.MaxValue, read.Attempts, "compteur saturé sans débordement"); Check.Equal("PCNEW", read.Computer, "nom Windows courant");
        Check.Equal(1, (await Apply(db, Request(db, fresh with { Status = "REFUSE" }))).Ignored, "réponse simultanée sans ordre certain ignorée");
        Check.Equal(1, (await Apply(db, Request(db, Update(at: Fixtures.Now.AddDays(-1))))).Ignored, "ancienne réponse ignorée");
        Check.Equal("LU", (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single().Status, "succès récent non remplacé");
    }

    [Test]
    public static async Task A_committed_pass_is_not_replayed_after_memory_reset_and_old_generation_results_cannot_resurrect_rows()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var request = Request(db, Update());
        await Apply(db, request);
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Execute("DELETE FROM park_state;"); sql.Execute("UPDATE domenia_v2_sweep_state SET generation=generation+1 WHERE id=1;"); }
        Check.True((await Apply(db, request)).AlreadyRecorded, "reçu original relu sans rejeu");
        Check.Equal(0L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "ancien passage ne ressuscite pas la mémoire");
        var late = Request(db, Update("PC2")); Check.False((await db.CheckRelationSweepsAsync(late, CancellationToken.None)).Current, "autre réponse tardive d’une ancienne génération");
        await Check.ThrowsAsync<DomeniaOperationException>(() => Apply(db, late), "transaction recontrôle la génération");
        await Check.ThrowsAsync<DomeniaOperationException>(() => Apply(db, request with { Updates = [Update(status: "REFUSE")] }), "même identifiant avec contenu différent");
        Check.Equal(1, (await Apply(db, late with { Generation = 1 })).Updated, "nouveau geste de la nouvelle génération accepté");
    }

    [Test]
    public static async Task A_trigger_changing_a_legacy_extension_rolls_back_the_whole_pass_and_its_receipt()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); await Apply(db, Request(db, Update()));
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Execute("ALTER TABLE park_state ADD COLUMN extension TEXT DEFAULT 'original';");
            sql.Script("CREATE TRIGGER changed_extension AFTER UPDATE OF status ON park_state BEGIN UPDATE park_state SET extension='modifié' WHERE computer_key=NEW.computer_key; END;");
        }
        var request = Request(db, Update(status: "REFUSE", at: Fixtures.Now.AddMinutes(1)));
        await Check.ThrowsAsync<InvalidDataException>(() => Apply(db, request), "relecture détecte une colonne non autorisée");
        var row = (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single();
        Check.Equal("CONFIRME", row.Status, "statut restauré par rollback"); Check.Equal(1, row.Attempts, "aucun faux compteur");
        using var check = new SqliteDatabase(db.Path, true);
        Check.Equal("original", (string)check.Scalar("SELECT extension FROM park_state;")!, "extension intacte");
        Check.Equal(0L, (long)check.Scalar("SELECT count(*) FROM domenia_v2_sweep_writes WHERE id=?1;", request.BatchId)!, "aucun reçu de succès");
    }

    [Test]
    public static async Task Sweep_writes_refuse_ambiguous_GUIDs_invalid_cells_and_unbounded_or_foreign_requests()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); await Apply(db, Request(db, Update()));
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Execute("INSERT INTO park_state(computer_key,computer,computer_guid,computer_dn,attempts) SELECT 'duplicate',computer,computer_guid,computer_dn,0 FROM park_state;"); }
        var next = Request(db, Update(at: Fixtures.Now.AddMinutes(1)));
        Check.False((await db.CheckRelationSweepsAsync(next, CancellationToken.None)).Current, "GUID ambigu");
        await Check.ThrowsAsync<DomeniaOperationException>(() => Apply(db, next), "pas de choix arbitraire");
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("DELETE FROM park_state WHERE computer_key='duplicate';"); sql.Execute("UPDATE park_state SET attempts=-1;"); }
        Check.False((await db.CheckRelationSweepsAsync(next, CancellationToken.None)).Current, "cellule invalide préservée");
        foreach (var invalid in new[] { Update() with { ComputerDn = "CN=PC1,DC=foreign,DC=local" }, Update() with { Status = "COMMANDE" }, Update(at: Fixtures.Now.AddHours(1)), Update() with { Computer = "pc1;cmd" } })
        { await Check.ThrowsAsync<ArgumentException>(() => Apply(db, Request(db, invalid)), "requête hors contrat"); }
        await Check.ThrowsAsync<ArgumentException>(() => Apply(db, Request(db, Enumerable.Range(1, 51).Select(i => Update("PC" + i)).ToArray())), "cinquante maximum");
        var absent = new DomeniaDatabase(folder.File("absent.db"), Fixtures.Root, TestClock.Fixed()); var cache = new SqliteDirectoryCache(absent);
        await Check.ThrowsAsync<ArgumentException>(() => cache.ApplyRelationSweepsAsync(Request(absent, Update() with { ComputerGuid = Guid.Empty }), CancellationToken.None), "validation avant initialisation");
        Check.False(File.Exists(absent.Path), "pas de création sur requête invalide");
    }

    [Test]
    public static async Task Concurrent_passes_keep_the_latest_observation_and_identical_batch_ids_increment_only_once()
    {
        using var folder = new TemporaryFolder(); var db = await Open(folder); var request = Request(db, Update());
        var same = await Task.WhenAll(Apply(db, request), Apply(db, request));
        Check.Equal(1, same.Count(r => r.AlreadyRecorded), "une seule application du lot concurrent");
        Check.Equal(1, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single().Attempts, "une tentative seulement");
        await Task.WhenAll(Apply(db, Request(db, Update(status: "REFUSE", at: Fixtures.Now.AddSeconds(1)))), Apply(db, Request(db, Update(status: "LU", at: Fixtures.Now.AddSeconds(2)))));
        var row = (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single();
        Check.Equal(Fixtures.Now.AddSeconds(2), row.At!.Value, "date la plus récente quel que soit l’ordre du verrou"); Check.Equal("LU", row.Status, "état correspondant à la date récente");
        Check.True(row.Attempts is 2 or 3, "seuls les passages acceptés comptent");
    }
}
