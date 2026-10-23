using Domenia.Core;

namespace Domenia.Store;

public sealed partial class FileReceiptStore
{
    public const int ArchiveThreshold = 384;
    public const int RetainedCompleted = 256;
    public const int MaximumPending = 512;
    public const int MaximumArchiveFiles = 4096;
    private string ArchiveDirectory => Path.Combine(Path.GetDirectoryName(path)!, "archive", Path.GetFileNameWithoutExtension(path));

    private string[] ArchiveFiles()
    {
        ValidateReceiptPath(Path.Combine(ArchiveDirectory, "receipt-path-check"));
        if (!Directory.Exists(ArchiveDirectory)) { return []; }
        ProtectReceiptDirectory(new(Path.GetDirectoryName(ArchiveDirectory)!));
        ProtectReceiptDirectory(new(ArchiveDirectory));
        var files = Directory.EnumerateFileSystemEntries(ArchiveDirectory).Take(MaximumArchiveFiles + 1).ToArray();
        if (files.Length > MaximumArchiveFiles || files.Any(f => Directory.Exists(f) || Path.GetExtension(f) != ".jsonl" || !WritePlans.IsPlanId(Path.GetFileNameWithoutExtension(f))))
        { throw new IOException("Archive de reçus hors contrat ou au-delà de 4096 fichiers ; vérification manuelle requise."); }
        foreach (var file in files) { ValidateReceiptPath(file); }
        return files.Order(StringComparer.Ordinal).ToArray();
    }

    /// <summary>Called under the same machine-wide lock as append; archives are durable before replacing the active log.</summary>
    private void CompactReceipts()
    {
        var current = new Dictionary<string, WriteReceipt>(StringComparer.Ordinal); var bad = 0; long bytes = 0;
        ReadReceiptFile(path, current, ref bad, ref bytes);
        if (bad != 0) { log.Warning("Compaction des reçus refusée : journal incomplet ou illisible conservé intégralement."); return; }
        var pending = current.Values.Count(WriteReceipts.IsPending);
        if (pending > MaximumPending) { throw new IOException("Plus de 512 reçus non résolus ; vérification manuelle requise, aucun reçu supprimé."); }
        // Also collapse the many versions of a few receipts before they can exhaust the active byte budget.
        if (current.Count <= ArchiveThreshold && bytes < 4 * 1024 * 1024) { return; }
        var completed = current.Values.Where(r => !WriteReceipts.IsPending(r)).OrderByDescending(r => r.At).ThenBy(r => r.Id, StringComparer.Ordinal).ToArray();
        var archive = completed.Skip(RetainedCompleted).ToArray();
        var existing = ArchiveFiles();
        if (existing.Length + archive.Count(r => !File.Exists(Path.Combine(ArchiveDirectory, r.Id + ".jsonl"))) > MaximumArchiveFiles)
        { throw new IOException("Archive de reçus pleine ; aucun reçu supprimé, vérification manuelle requise."); }
        if (archive.Length > 0)
        {
            Directory.CreateDirectory(ArchiveDirectory);
            ProtectReceiptDirectory(new(Path.GetDirectoryName(ArchiveDirectory)!)); ProtectReceiptDirectory(new(ArchiveDirectory));
            foreach (var receipt in archive) { ArchiveReceipt(receipt); }
        }
        var retained = current.Values.Where(WriteReceipts.IsPending).Concat(completed.Take(RetainedCompleted)).OrderBy(r => r.At).ThenBy(r => r.Id, StringComparer.Ordinal).ToArray();
        var temp = path + ".compact-" + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            WriteReceiptFile(temp, retained);
            var check = new Dictionary<string, WriteReceipt>(StringComparer.Ordinal); var invalid = 0; long length = 0;
            ReadReceiptFile(temp, check, ref invalid, ref length);
            if (invalid != 0 || check.Count != retained.Length || retained.Any(r => !check.TryGetValue(r.Id, out var actual) || !Serialize(r).AsSpan().SequenceEqual(Serialize(actual))))
            { throw new IOException("Compaction des reçus non relue à l’identique ; journal initial conservé."); }
            ValidateReceiptPath(path); File.Replace(temp, path, null); ProtectReceiptFile(path);
            log.Info($"Reçus compactés : {retained.Length} conservés dans le journal, {archive.Length} archivés ; aucun reçu incertain retiré.");
        }
        finally { if (File.Exists(temp)) { ValidateReceiptPath(temp); File.Delete(temp); } }
    }

    private void ArchiveReceipt(WriteReceipt receipt)
    {
        if (WriteReceipts.IsPending(receipt)) { throw new InvalidDataException("Un reçu incertain ne peut pas être archivé."); }
        var target = Path.Combine(ArchiveDirectory, receipt.Id + ".jsonl"); ValidateReceiptPath(target);
        var exists = File.Exists(target);
        if (exists)
        {
            var prior = new Dictionary<string, WriteReceipt>(StringComparer.Ordinal); var invalid = 0; long bytes = 0;
            ReadReceiptFile(target, prior, ref invalid, ref bytes);
            if (invalid != 0 || prior.Count != 1 || !prior.TryGetValue(receipt.Id, out var old) || old.Plan.Fingerprint != receipt.Plan.Fingerprint
                || old.SentAt != receipt.SentAt || WriteReceipts.IsPending(old)) { throw new IOException("Archive existante contradictoire ; aucun remplacement ni retrait du reçu actif."); }
            if (old.Version > receipt.Version || old.Version == receipt.Version && Serialize(old).AsSpan().SequenceEqual(Serialize(receipt))) { return; }
            if (old.Version == receipt.Version) { throw new IOException("Deux versions différentes du même reçu ; aucune archive remplacée."); }
        }
        // Temporary archive lives next to the active log, never among the final receipt files.
        var temp = path + ".archive-" + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            WriteReceiptFile(temp, [receipt]);
            if (!File.ReadAllBytes(temp).AsSpan().SequenceEqual(Serialize(receipt))) { throw new IOException("Archive non relue à l’identique."); }
            if (exists) { File.Replace(temp, target, null); } else { File.Move(temp, target); }
            ProtectReceiptFile(target);
        }
        finally { if (File.Exists(temp)) { ValidateReceiptPath(temp); File.Delete(temp); } }
    }

    private static void WriteReceiptFile(string file, IReadOnlyList<WriteReceipt> receipts)
    {
        ValidateReceiptPath(file);
        using var stream = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None, 8192, FileOptions.WriteThrough);
        ProtectReceiptFile(file);
        foreach (var receipt in receipts)
        {
            var bytes = Serialize(receipt);
            if (bytes.Length > MaxLineBytes || stream.Position + bytes.Length > MaxFileBytes) { throw new IOException("Compaction hors limites ; original conservé."); }
            stream.Write(bytes);
        }
        stream.Flush(true);
    }
}
