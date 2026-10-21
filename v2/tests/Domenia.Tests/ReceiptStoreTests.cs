using System.Text;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>Durable receipts in JSON Lines (FileReceiptStore): atomic appends, versions folded, torn and unreadable lines.</summary>
internal static class ReceiptStoreTests
{
    private const string LinePrefix = "{\"format\":\"domenia.receipt\",\"version\":1,\"receipt\":{";

    private static WriteReceipt Receipt(string? guid = null)
    {
        var plan = WritePlans.Seal(FakeWriteExecutor.Draft(guid ?? FakeWriteExecutor.TargetGuid), WritePlans.NewId(), @"TEST\adm", AppMode.Simulation, TestClock.Reference, TestClock.Paris);
        return WriteReceipts.Sent(plan, WritePlans.NewId(), TestClock.Reference, new ReceiptDetail("Préconditions", "Objet relu\u00A0: inchangé."));
    }

    private static WriteReceipt Completed(WriteReceipt sent) =>
        WriteReceipts.Verified(
            WriteReceipts.Completed(sent, new WriteOutcome(WriteResult.Applied, "Description remplacée."), null, TestClock.Reference.AddSeconds(1)),
            new WriteVerification(VerificationState.Verified, "Description relue conforme."),
            TestClock.Reference.AddSeconds(2));

    [Test]
    public static async Task Versions_are_appended_one_line_each_and_the_latest_wins()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(FileReceiptStore.SimulationFileName);
        using var store = new FileReceiptStore(path, new RecordingJournal());
        var sent = Receipt();
        var done = Completed(sent);
        await store.AppendAsync(sent, CancellationToken.None);
        await store.AppendAsync(WriteReceipts.Completed(sent, new WriteOutcome(WriteResult.Applied, "Description remplacée."), null, TestClock.Reference.AddSeconds(1)), CancellationToken.None);
        await store.AppendAsync(done, CancellationToken.None);
        var lines = File.ReadAllLines(path, Encoding.UTF8);
        Check.Equal(3, lines.Length, "une ligne par version");
        Check.True(lines.All(l => l.StartsWith(LinePrefix, StringComparison.Ordinal)), "format et version de chaque ligne");
        var log = await store.ReadAllAsync(CancellationToken.None);
        var read = log.Receipts.Single();
        Check.Equal(0, log.Unreadable, "tout est lisible");
        Check.Equal(3, read.Version, "dernière version");
        Check.Equal(WriteResult.Applied, read.Result, "résultat");
        Check.Equal(VerificationState.Verified, read.Verification, "relecture");
        Check.Equal(3, read.Details.Length, "détails");
        // Same content as written, field for field (contract serialization of both).
        Check.Equal(JsonSerializer.Serialize(done, BridgeJson.Options), JsonSerializer.Serialize(read, BridgeJson.Options), "relu à l’identique");
        Check.True(WritePlans.IsIntact(read.Plan), "plan relu intact (empreinte)");
    }

    [Test]
    public static async Task Two_instances_see_each_other_appends()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(FileReceiptStore.DirectoryFileName);
        using var first = new FileReceiptStore(path, new RecordingJournal());
        using var second = new FileReceiptStore(path, new RecordingJournal());
        var a = Receipt();
        await first.AppendAsync(a, CancellationToken.None);
        Check.Equal(1, (await first.ReadAllAsync(CancellationToken.None)).Receipts.Length, "première instance");
        var b = Receipt(FakeWriteExecutor.OtherGuid);
        await second.AppendAsync(b, CancellationToken.None);
        await second.AppendAsync(Completed(a), CancellationToken.None);
        var seen = await first.ReadAllAsync(CancellationToken.None);
        Check.Equal(2, seen.Receipts.Length, "lecture incrémentale : l’ajout de l’autre instance est vu");
        Check.Equal(3, seen.Receipts.Single(r => r.Id == a.Id).Version, "version de l’autre instance");
    }

    [Test]
    public static async Task A_torn_last_line_is_closed_by_the_next_append_and_never_swallows_it()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(FileReceiptStore.SimulationFileName);
        var recorder = new RecordingJournal();
        using var store = new FileReceiptStore(path, recorder);
        await store.AppendAsync(Receipt(), CancellationToken.None);
        await File.AppendAllTextAsync(path, LinePrefix + "\"id\":\"coupé", Encoding.UTF8);
        var waiting = await store.ReadAllAsync(CancellationToken.None);
        Check.Equal(1, waiting.Receipts.Length, "la ligne coupée attend : rien de perdu");
        Check.Equal(0, waiting.Unreadable, "une ligne sans fin n’est pas encore illisible");
        var next = Receipt(FakeWriteExecutor.OtherGuid);
        await store.AppendAsync(next, CancellationToken.None);
        var log = await store.ReadAllAsync(CancellationToken.None);
        Check.Equal(2, log.Receipts.Length, "le reçu ajouté après la coupure est lu");
        Check.True(log.Receipts.Any(r => r.Id == next.Id), "jamais avalé par la ligne coupée");
        Check.Equal(1, log.Unreadable, "la ligne coupée est comptée illisible");
        Check.True(recorder.Lines.Any(l => l.Contains("dernière ligne interrompue fermée", StringComparison.Ordinal)), "tracé");
    }

    [Test]
    public static async Task Unreadable_lines_are_counted_never_fatal()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(FileReceiptStore.SimulationFileName);
        var good = Receipt();
        var text = "pas du JSON\n"
            + "{\"format\":\"autre\",\"version\":1,\"receipt\":{}}\n"
            + LinePrefix.Replace("\"version\":1", "\"version\":2", StringComparison.Ordinal) + "}}\n"
            + "{\"format\":\"domenia.receipt\",\"version\":1,\"receipt\":{\"id\":\"pas-un-id\"}}\n"
            + "\n"
            + Encoding.UTF8.GetString(FileReceiptStore.Serialize(good));
        await File.WriteAllTextAsync(path, text, new UTF8Encoding(false));
        var recorder = new RecordingJournal();
        using var store = new FileReceiptStore(path, recorder);
        var log = await store.ReadAllAsync(CancellationToken.None);
        Check.Equal(good.Id, log.Receipts.Single().Id, "le reçu valable est lu");
        Check.Equal(4, log.Unreadable, "quatre lignes illisibles, la ligne vide ignorée");
        Check.True(recorder.Lines.Any(l => l.Contains("4 enregistrement(s) illisible(s)", StringComparison.Ordinal)), "tracé une fois");
        Check.False(recorder.Lines.Any(l => l.Contains("pas du JSON", StringComparison.Ordinal)), "jamais le contenu d’une ligne");
    }

    [Test]
    public static async Task A_shortened_file_is_read_again_from_the_start()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(FileReceiptStore.SimulationFileName);
        using var store = new FileReceiptStore(path, new RecordingJournal());
        var a = Receipt();
        await store.AppendAsync(a, CancellationToken.None);
        await store.AppendAsync(Receipt(FakeWriteExecutor.OtherGuid), CancellationToken.None);
        Check.Equal(2, (await store.ReadAllAsync(CancellationToken.None)).Receipts.Length, "deux reçus");
        await File.WriteAllBytesAsync(path, FileReceiptStore.Serialize(a));
        var log = await store.ReadAllAsync(CancellationToken.None);
        Check.Equal(a.Id, log.Receipts.Single().Id, "relu depuis le début");
        File.Delete(path);
        Check.Equal(0, (await store.ReadAllAsync(CancellationToken.None)).Receipts.Length, "fichier absent : aucun reçu");
    }

    [Test]
    public static async Task An_oversized_file_refuses_reads_and_appends()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(FileReceiptStore.DirectoryFileName);
        await using (var stream = new FileStream(path, FileMode.Create, FileAccess.Write))
        {
            stream.SetLength(FileReceiptStore.MaxFileBytes + 1);
        }
        using var store = new FileReceiptStore(path, new RecordingJournal());
        await Check.ThrowsAsync<IOException>(() => store.ReadAllAsync(CancellationToken.None), "lecture refusée : le circuit refuse alors toute écriture");
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(Receipt(), CancellationToken.None), "ajout refusé");
    }

    [Test]
    public static void Names_paths_and_locks_of_the_receipts()
    {
        Check.Equal("receipts.jsonl", FileReceiptStore.FileNameFor(AppMode.Directory), "mode annuaire");
        Check.Equal("receipts-simulation.jsonl", FileReceiptStore.FileNameFor(AppMode.Simulation), "simulation : fichier séparé");
        var name = FileReceiptStore.LockNameFor(@"C:\Users\x\AppData\Local\Domenia\receipts.jsonl");
        Check.True(name.StartsWith(@"Global\Domenia.Receipts.", StringComparison.Ordinal) && name.Length == @"Global\Domenia.Receipts.".Length + 32, "verrou commun aux instances, sans donnée");
        Check.Equal(name, FileReceiptStore.LockNameFor(@"c:\users\X\appdata\local\domenia\RECEIPTS.jsonl"), "casse ignorée (NTFS)");
        Check.Throws<ArgumentException>(() => new FileReceiptStore("receipts.jsonl", new RecordingJournal()), "chemin relatif refusé");
        Check.Null(FileReceiptStore.Parse(Encoding.UTF8.GetBytes("{}")), "objet vide : pas un reçu");
    }
}
