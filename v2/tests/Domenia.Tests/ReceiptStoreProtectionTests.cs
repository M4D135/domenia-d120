using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static partial class ReceiptStoreTests
{
    [Test]
    public static async Task Receipt_directory_and_files_keep_owner_and_group_but_remove_other_principals()
    {
        using var folder = new TemporaryFolder();
        var directory = new DirectoryInfo(folder.Path);
        var before = directory.GetAccessControl(AccessControlSections.Owner | AccessControlSections.Group);
        var access = directory.GetAccessControl(AccessControlSections.Access);
        access.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.Read,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        directory.SetAccessControl(access);
        var path = folder.File(FileReceiptStore.DirectoryFileName);
        using var store = new FileReceiptStore(path, new RecordingJournal());
        await store.AppendAsync(Receipt(), CancellationToken.None);
        var after = directory.GetAccessControl(AccessControlSections.Owner | AccessControlSections.Group | AccessControlSections.Access);
        Check.Equal(before.GetOwner(typeof(SecurityIdentifier))?.Value, after.GetOwner(typeof(SecurityIdentifier))?.Value, "propriétaire du dossier inchangé");
        Check.Equal(before.GetGroup(typeof(SecurityIdentifier))?.Value, after.GetGroup(typeof(SecurityIdentifier))?.Value, "groupe du dossier inchangé");
        CheckReceiptAcl(after);
        CheckReceiptAcl(new FileInfo(path).GetAccessControl(AccessControlSections.Access));
        CheckReceiptAcl(new FileInfo(path + ".state").GetAccessControl(AccessControlSections.Access));
    }

    [Test]
    public static void Redirected_and_alternate_receipt_paths_are_rejected_before_opening()
    {
        Check.Throws<IOException>(() => new FileReceiptStore(@"\\server\share\receipts.jsonl", new RecordingJournal()), "UNC refusé sans accès réseau");
        using var folder = new TemporaryFolder();
        Check.Throws<IOException>(() => new FileReceiptStore(folder.File("receipts.jsonl:hidden"), new RecordingJournal()), "flux alternatif refusé");
        Check.Throws<IOException>(() => new FileReceiptStore(@"C:\receipts.jsonl", new RecordingJournal()), "ne jamais réécrire la DACL de la racine du disque");
    }

    [Test]
    public static async Task Equal_length_and_timestamp_replacement_does_not_hide_changed_receipts()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(FileReceiptStore.DirectoryFileName);
        using var store = new FileReceiptStore(path, new RecordingJournal());
        var done = Completed(Receipt());
        await store.AppendAsync(done, CancellationToken.None);
        Check.Equal(0, (await store.ReadAllAsync(CancellationToken.None)).Unreadable, "preuve initiale lisible");
        var stamp = File.GetLastWriteTimeUtc(path);
        var replacement = FileReceiptStore.Serialize(done with { Result = WriteResult.Unknown });
        Check.Equal(new FileInfo(path).Length, (long)replacement.Length, "remplacement exactement de même longueur");
        await File.WriteAllBytesAsync(path, replacement);
        File.SetLastWriteTimeUtc(path, stamp);
        var reread = await store.ReadAllAsync(CancellationToken.None);
        Check.True(reread.Unreadable > 0, "version contradictoire détectée même sans variation de taille ou date");
        Check.Equal(WriteResult.Applied, reread.Receipts.Single().Result, "preuve connue conservée jusqu’à une réparation explicite");
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(Receipt(), CancellationToken.None), "aucun nouvel envoi dans un journal contradictoire");
    }

    [Test]
    public static void Receipt_parsing_rejects_changed_fingerprint_null_target_and_duplicate_properties()
    {
        var receipt = Receipt();
        var changed = receipt with { Plan = receipt.Plan with { Changes = [receipt.Plan.Changes[0] with { AfterValue = "autre" }] } };
        Check.Null(FileReceiptStore.Parse(FileReceiptStore.Serialize(changed)), "empreinte ne couvrant plus les valeurs attendues");
        Check.Null(FileReceiptStore.Parse(FileReceiptStore.Serialize(receipt with { Plan = receipt.Plan with { Target = null! } })), "cible absente sans exception du parseur");
        var duplicate = Encoding.UTF8.GetString(FileReceiptStore.Serialize(receipt)).Replace("\"version\":1", "\"version\":1,\"VERSION\":1", StringComparison.Ordinal);
        Check.Null(FileReceiptStore.Parse(Encoding.UTF8.GetBytes(duplicate)), "clés ambiguës refusées à toute profondeur");
    }

    [Test]
    public static async Task Two_receipt_instances_cannot_admit_two_new_sends_before_the_first_is_settled()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(FileReceiptStore.DirectoryFileName);
        using var first = new FileReceiptStore(path, new RecordingJournal());
        using var second = new FileReceiptStore(path, new RecordingJournal());
        var a = Receipt(); var b = Receipt(FakeWriteExecutor.OtherGuid);
        var attempts = new[] { Attempt(first, a), Attempt(second, b) };
        var accepted = await Task.WhenAll(attempts);
        Check.Equal(1, accepted.Count(ok => ok), "garde et persistance Sent atomiques entre instances");
        var current = await first.ReadAllAsync(CancellationToken.None);
        Check.Equal(1, current.Receipts.Length, "un seul reçu Sent durable");
        var sent = current.Receipts.Single();
        await second.AppendAsync(Completed(sent), CancellationToken.None);
        await first.AppendAsync(sent.Id == a.Id ? b : a, CancellationToken.None);
        Check.Equal(2, (await second.ReadAllAsync(CancellationToken.None)).Receipts.Length, "nouvel envoi admis seulement après résolution");

        static async Task<bool> Attempt(FileReceiptStore store, WriteReceipt receipt)
        {
            try { await store.AppendAsync(receipt, CancellationToken.None); return true; }
            catch (IOException) { return false; }
        }
    }

    [Test]
    public static async Task Torn_receipt_blocks_the_real_write_circuit_before_the_fake_executor_sends()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(FileReceiptStore.SimulationFileName);
        using var store = new FileReceiptStore(path, new RecordingJournal());
        var (context, circuit, executor, _) = WriteCircuitTests.FakeCircuit(store);
        using (context)
        {
            var plan = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
            await File.WriteAllTextAsync(path, LinePrefix + "\"id\":\"coupé", new UTF8Encoding(false));
            await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(plan.Plan.Id, plan.Token, null, null, CancellationToken.None), "ligne tronquée bloque un plan déjà préparé");
            Check.Equal(0, executor.Executes, "aucun appel d’écriture après corruption du journal");
        }
    }

    private static void CheckReceiptAcl(FileSystemSecurity security)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var expected = new[] { identity.User!.Value, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null).Value,
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null).Value }.ToHashSet(StringComparer.Ordinal);
        var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        Check.True(security.AreAccessRulesProtected, "DACL protégée de l’héritage");
        Check.True(expected.SetEquals(rules.Select(r => r.IdentityReference.Value)) && rules.Length == expected.Count, "utilisateur, SYSTEM et Administrateurs seulement");
        Check.True(rules.All(r => !r.IsInherited && r.AccessControlType == AccessControlType.Allow && r.FileSystemRights == FileSystemRights.FullControl), "droits exacts relus");
    }
}
