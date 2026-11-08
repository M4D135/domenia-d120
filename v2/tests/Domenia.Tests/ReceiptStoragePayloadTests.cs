using System.Text;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class ReceiptStoragePayloadTests
{
    private static string LargeAnnex(int count = 200, int width = 600) => BackupPreferencesRules.Snapshot(Enumerable.Range(0, count).ToDictionary(
        n => WorkingScope.PreferenceKey($"DC=domain{n},DC=local"),
        n => JsonSerializer.SerializeToElement(new { dn = "OU=" + new string('a', width) + $",DC=domain{n},DC=local", subtree = true })));

    [Test]
    public static async Task Native_backup_with_a_large_valid_annex_passes_the_real_durable_circuit_and_cold_read()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var cache = new CompatibleDirectoryCache(folder.File("app"), folder.File("data"), "test.local", clock);
        await (await cache.DatabaseAsync(default)).InitializeAsync(default);
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock,
            connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        var executor = new AdStorageBackupLocalExecutor(source);
        var restoreExecutor = new AdStorageRestoreExecutor(source);
        var receiptPath = folder.File("receipts/receipts.jsonl");
        using var receipts = new FileReceiptStore(receiptPath, new RecordingJournal());
        using var context = new EngineContext(ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "test.local")),
            source, new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(AdSettingsReader).Assembly]),
            writers: WriteExecutors.From([executor, restoreExecutor]), receipts: receipts);
        var annex = LargeAnnex(500, 3000); Check.True(Encoding.UTF8.GetByteCount(annex) > FileReceiptStore.MaxLineBytes, "annexe réellement au-delà de l’ancienne borne");
        var circuit = WriteCircuit.From(context);
        var planned = await circuit.PlanAsync(await executor.PlanBackupAsync(StoragePolicyRules.Default, annex, "manual", default), default);
        Check.True(Encoding.UTF8.GetByteCount(planned.Plan.Details) < FileReceiptStore.MaxLineBytes, "détails techniques bornés sans recopier l’annexe");
        Check.Contains(BackupPreferencesRules.Sha256(annex), planned.Plan.Details, "empreinte du document exact dans les détails");
        Check.Contains(Encoding.UTF8.GetByteCount(annex).ToString(System.Globalization.CultureInfo.InvariantCulture) + " octets", planned.Plan.Details, "taille exacte annoncée");
        Check.False(planned.Plan.Details.Contains(annex, StringComparison.Ordinal), "aucune deuxième copie du contenu dans le texte technique");
        Check.Equal(annex, planned.Plan.Changes.Single(c => c.Attribute == "backup.preferences").AfterValue, "la valeur exécutable reste intégrale");
        Check.True(WritePlans.IsIntact(planned.Plan), "empreinte du plan conservée après la présentation bornée");
        var result = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, default);
        Check.Equal(WriteResult.Applied, result.Result, "copie native réellement exécutée après reçu durable");
        Check.Equal(VerificationState.Verified, result.Verification, "copie et annexe relues par le circuit");
        using var cold = new FileReceiptStore(receiptPath, new RecordingJournal());
        var log = await cold.ReadAllAsync(default); Check.Equal(0, log.Unreadable, "aucun grand reçu perdu au redémarrage");
        var stored = log.Receipts.Single();
        Check.True(WritePlans.IsIntact(stored.Plan), "plan et empreinte entiers relus");
        Check.Equal(annex, stored.Plan.Changes.Single(c => c.Attribute == "backup.preferences").AfterValue, "annexe entière, sans troncature");
        Check.Equal(VerificationState.Verified, stored.Verification, "dernier état durable récupéré");
        Check.True(FileReceiptStore.Serialize(stored).Length > FileReceiptStore.MaxLineBytes, "la preuve utilise vraiment l’exception de stockage");
        Check.Equal(1, File.ReadLines(receiptPath).Count(), "les trois grandes versions ont réellement déclenché la compaction et gardé la dernière");
        var database = await cache.DatabaseAsync(default);
        var backup = (await cache.InspectLocalStoreAsync(false, false, default)).Backups.Single();
        var backupPath = Path.Combine(Path.GetDirectoryName(database.Path)!, "Backups", backup.FileName);
        var restore = await circuit.PlanAsync(await restoreExecutor.PlanRestoreFileAsync(backupPath, default), default);
        var payload = restore.Plan.Changes.Single(c => c.Attribute == "switch.proof").AfterValue!;
        Check.True(Encoding.UTF8.GetByteCount(restore.Plan.Details) < FileReceiptStore.MaxLineBytes, "preuve de restauration non dupliquée dans les détails");
        Check.Contains(BackupPreferencesRules.Sha256(payload), restore.Plan.Details, "empreinte de la preuve exacte annoncée");
        Check.True(WritePlans.IsIntact(restore.Plan), "preuve complète toujours couverte par l’empreinte du plan");
        try
        {
            var restored = await circuit.ExecuteAsync(restore.Plan.Id, restore.Token, restore.Plan.Confirmation.TypedName, null, default);
            Check.Equal(WriteResult.Applied, restored.Result, "restauration native réellement exécutée avec grande preuve durable");
            Check.Equal(VerificationState.Verified, restored.Verification, "base restaurée et marqueur relus");
            var reopened = new CompatibleDirectoryCache(folder.File("app"), folder.File("data"), "test.local", clock);
            var active = await reopened.InspectLocalStoreAsync(false, false, default);
            Check.True(active.Available && active.StoreId != database.StoreId, "nouvelle base sélectionnée à froid");
            Check.True(active.Backups.Any(b => b.Preferences?.Json == annex && BackupPreferencesRules.IsBound(b)), "grande annexe exacte retrouvée via marqueur et copie restaurée");
            using var finalStore = new FileReceiptStore(receiptPath, new RecordingJournal());
            var finalLog = await finalStore.ReadAllAsync(default);
            Check.Equal(0, finalLog.Unreadable, "preuve de restauration >64 Kio lisible à froid");
            Check.Equal(2, finalLog.Receipts.Length, "copie et restauration conservent chacune leur reçu");
            var restoreProof = finalLog.Receipts.Single(r => r.Plan.Kind == StorageWritePlans.Restore);
            Check.True(FileReceiptStore.Serialize(restoreProof).Length > FileReceiptStore.MaxLineBytes, "exception appliquée à une vraie preuve de bascule");
            Check.Equal(VerificationState.Verified, restoreProof.Verification, "relecture durable de la restauration");
        }
        finally
        {
            foreach (var file in Directory.EnumerateFiles(folder.Path, "*", SearchOption.AllDirectories))
                File.SetAttributes(file, File.GetAttributes(file) & ~FileAttributes.ReadOnly);
        }
    }

    [Test]
    public static async Task Only_the_closed_storage_payload_gets_the_larger_limit_and_the_upper_limit_stays_enforced()
    {
        using var folder = new TemporaryFolder();
        var ordinary = Sent(FakeWriteExecutor.Draft(FakeWriteExecutor.TargetGuid));
        var oversized = ordinary with { Details = [new("Détail", new string('a', FileReceiptStore.MaxLineBytes))] };
        using var store = new FileReceiptStore(folder.File("receipts/receipts.jsonl"), new RecordingJournal());
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(oversized, default), "reçu non stockage conserve sa borne de 64 Kio");
        Check.Null(FileReceiptStore.Parse(Raw(oversized)), "lecture refuse aussi un autre type trop volumineux");
        var draft = FakeWriteExecutor.Draft(FakeWriteExecutor.TargetGuid) with { Kind = StorageWritePlans.Backup,
            Target = ordinary.Plan.Target with { Kind = StorageWritePlans.TargetKind },
            Changes = [new("backup.preferences", "Annexe", WriteChangeKind.Add, null, "Préférences", null, LargeAnnex())] };
        var qualified = Sent(draft);
        Check.NotNull(FileReceiptStore.Parse(Raw(qualified)), "type exact, plan intact et annexe valide acceptés");
        var homonym = Sent(FakeWriteExecutor.Draft(FakeWriteExecutor.TargetGuid) with { Changes = draft.Changes });
        Check.Contains(draft.Changes[0].AfterValue!, homonym.Plan.Details, "un attribut homonyme d’une autre opération ne reçoit pas le traitement stockage");
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(homonym, default), "type et cible étrangers gardent la borne normale");
        var badPayload = Sent(draft with { Changes = [draft.Changes[0] with { AfterValue = "{\"inconnue\":\"" + new string('a', FileReceiptStore.MaxLineBytes) + "\"}" }] });
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(badPayload, default), "une fausse annexe ne bénéficie pas de l’exception");
        Check.Null(FileReceiptStore.Parse(Raw(badPayload)), "fausse annexe comptée illisible sans exception du parseur");
        var extra = qualified with { Details = oversized.Details };
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(extra, default), "les autres champs du reçu stockage gardent ensemble leur borne 64 Kio");
        Check.Null(FileReceiptStore.Parse(new byte[FileReceiptStore.MaxStorageLineBytes]), "borne haute refusée avant parsing JSON");
        var tooLarge = qualified with { Details = [new("Trop long", new string('a', FileReceiptStore.MaxStorageLineBytes))] };
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(tooLarge, default), "sortie sérialisée arrêtée à la borne haute");
        Check.False(File.Exists(folder.File("receipts/receipts.jsonl")), "tous les refus précèdent l’écriture du journal");
        Check.Equal(64L * 1024 * 1024, FileReceiptStore.MaxFileBytes, "borne du journal complet inchangée");
    }

    private static WriteReceipt Sent(WritePlanDraft draft)
    {
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), "test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
        return WriteReceipts.Sent(plan, WritePlans.NewId(), Fixtures.Now, new("Contrôle", "Préconditions relues"));
    }
    private static byte[] Raw(WriteReceipt receipt) => JsonSerializer.SerializeToUtf8Bytes(new { format = FileReceiptStore.Format, version = 1, receipt }, Domenia.Bridge.BridgeJson.Options);
}
