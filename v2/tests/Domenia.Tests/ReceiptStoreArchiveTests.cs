using System.Text;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static partial class ReceiptStoreTests
{
    [Test]
    public static async Task Compaction_archives_old_terminal_receipts_and_keeps_all_uncertain_evidence()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(FileReceiptStore.DirectoryFileName);
        var completed = Enumerable.Range(0, FileReceiptStore.ArchiveThreshold).Select(i =>
            Completed(Receipt()) with { At = TestClock.Reference.AddMinutes(i + 1), VerifiedAt = TestClock.Reference.AddMinutes(i + 1) }).ToArray();
        var unresolved = new[] { Receipt(), WriteReceipts.Completed(Receipt(), new(WriteResult.Unknown, "Réponse perdue."), null, TestClock.Reference.AddSeconds(1)) };
        // A historical fixture may contain several uncertain operations. New appends cannot create such concurrent sends.
        await File.WriteAllBytesAsync(path, completed.Concat(unresolved).SelectMany(FileReceiptStore.Serialize).ToArray());
        using var store = new FileReceiptStore(path, new RecordingJournal());
        var newest = Completed(Receipt()) with { At = TestClock.Reference.AddDays(1), VerifiedAt = TestClock.Reference.AddDays(1) };
        await store.AppendAsync(newest, CancellationToken.None);
        var active = File.ReadAllLines(path).Select(line => FileReceiptStore.Parse(Encoding.UTF8.GetBytes(line))!).ToArray();
        Check.Equal(FileReceiptStore.RetainedCompleted + unresolved.Length, active.Length, "256 reçus terminés et tous les incertains dans le journal actif");
        Check.True(unresolved.All(r => active.Any(a => a.Id == r.Id)), "aucun reçu non résolu retiré");
        Check.True(active.Any(r => r.Id == newest.Id), "reçu terminé le plus récent conservé actif");
        var directory = folder.File(Path.Combine("archive", "receipts"));
        var archived = Directory.GetFiles(directory, "*.jsonl");
        Check.Equal(completed.Length + 1 - FileReceiptStore.RetainedCompleted, archived.Length, "archives créées avant remplacement atomique");
        Check.True(archived.All(file => !WriteReceipts.IsPending(FileReceiptStore.Parse(File.ReadAllBytes(file))!)), "archives terminales uniquement");
        CheckReceiptAcl(new DirectoryInfo(directory).GetAccessControl(System.Security.AccessControl.AccessControlSections.Access));
        using var reopened = new FileReceiptStore(path, new RecordingJournal());
        var all = await reopened.ReadAllAsync(CancellationToken.None);
        Check.Equal(completed.Length + unresolved.Length + 1, all.Receipts.Length, "historique complet retrouvable après redémarrage");
        Check.Equal(unresolved.Length, all.Receipts.Count(WriteReceipts.IsPending), "réservations incertaines conservées");
        Check.Equal(0, all.Unreadable, "archive relue sans faux enregistrement manquant");
        Check.True(File.Exists(path + ".state"), "témoin créé pour la migration du journal historique en place");
    }

    [Test]
    public static async Task Interrupted_compaction_duplicate_is_folded_but_corrupt_archive_remains_blocking()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(FileReceiptStore.DirectoryFileName);
        var done = Completed(Receipt());
        using var store = new FileReceiptStore(path, new RecordingJournal());
        await store.AppendAsync(done, CancellationToken.None);
        var archive = folder.File(Path.Combine("archive", "receipts"));
        Directory.CreateDirectory(archive);
        var file = Path.Combine(archive, done.Id + ".jsonl");
        await File.WriteAllBytesAsync(file, FileReceiptStore.Serialize(done));
        var interrupted = await store.ReadAllAsync(CancellationToken.None);
        Check.Equal(1, interrupted.Receipts.Length, "copie archivée avant remplacement ne double pas le reçu");
        Check.Equal(0, interrupted.Unreadable, "copie strictement identique acceptée");
        await File.WriteAllTextAsync(file, "{", new UTF8Encoding(false));
        Check.True((await store.ReadAllAsync(CancellationToken.None)).Unreadable > 0, "archive incomplète n’est pas ignorée");
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(Receipt(), CancellationToken.None), "archive illisible empêche un nouvel envoi");
        Check.Equal("{", await File.ReadAllTextAsync(file), "preuve corrompue laissée en place pour vérification manuelle");
    }

    [Test]
    public static async Task Excess_uncertain_receipts_and_unexpected_archive_files_require_manual_review()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File(FileReceiptStore.DirectoryFileName);
        var fixture = Enumerable.Range(0, FileReceiptStore.MaximumPending + 1).Select(_ => Receipt()).SelectMany(FileReceiptStore.Serialize).ToArray();
        await File.WriteAllBytesAsync(path, fixture);
        using var store = new FileReceiptStore(path, new RecordingJournal());
        await Check.ThrowsAsync<IOException>(() => store.ReadAllAsync(CancellationToken.None), "plus de 512 incertains demande vérification");
        await Check.ThrowsAsync<IOException>(() => store.AppendAsync(Receipt(), CancellationToken.None), "aucun nouveau Sent");
        Check.True(fixture.AsSpan().SequenceEqual(File.ReadAllBytes(path)), "aucune preuve retirée face à la limite");
        using var otherFolder = new TemporaryFolder();
        var archive = otherFolder.File(Path.Combine("archive", "receipts"));
        Directory.CreateDirectory(archive);
        var unexpected = Path.Combine(archive, "preuve-inconnue.txt");
        await File.WriteAllTextAsync(unexpected, "conserver", new UTF8Encoding(false));
        using var other = new FileReceiptStore(otherFolder.File(FileReceiptStore.DirectoryFileName), new RecordingJournal());
        await Check.ThrowsAsync<IOException>(() => other.ReadAllAsync(CancellationToken.None), "format d’archive inattendu signalé");
        Check.True(File.Exists(unexpected), "aucun nettoyage opportuniste");
    }
}
