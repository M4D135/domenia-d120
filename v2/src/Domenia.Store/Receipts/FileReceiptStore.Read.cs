using Domenia.Core;

namespace Domenia.Store;

public sealed partial class FileReceiptStore
{
    private ReceiptLog Read(CancellationToken token)
    {
        ProtectReceiptRoot();
        using var machineLock = new Mutex(false, lockName);
        if (!Acquire(machineLock, token)) { throw new IOException("Journal des reçus occupé ; état non confirmé."); }
        try
        {
            return ReadReceiptsLocked(token);
        }
        finally { machineLock.ReleaseMutex(); }
    }
    private ReceiptLog ReadReceiptsLocked(CancellationToken token) => ReadReceiptsLocked(token, null, out _, out _);

    private ReceiptLog ReadReceiptsLocked(CancellationToken token, string? lookup, out WriteReceipt? physical, out long totalBytes)
    {
        token.ThrowIfCancellationRequested();
        ValidateReceiptPath(path); ValidateReceiptPath(MarkerPath);
        var present = File.Exists(path);
        var missing = !present && File.Exists(MarkerPath);
        if (present) { EnsureReceiptMarker(); }
        else if (missing) { EnsureReceiptMarker(); }
        var current = new Dictionary<string, WriteReceipt>(StringComparer.Ordinal);
        var unreadable = missing ? 1 : 0;
        long bytes = 0;
        if (present) { ReadReceiptFile(path, current, ref unreadable, ref bytes, token); }
        var archives = ArchiveFiles();
        if (!present && archives.Length > 0) { EnsureReceiptMarker(); unreadable++; }
        foreach (var archived in archives)
        {
            var archivedRows = new Dictionary<string, WriteReceipt>(StringComparer.Ordinal);
            ReadReceiptFile(archived, archivedRows, ref unreadable, ref bytes, token);
            if (archivedRows.Count != 1 || archivedRows.Values.Any(r => r.Id != Path.GetFileNameWithoutExtension(archived) || WriteReceipts.IsPending(r))) { unreadable++; }
            foreach (var receipt in archivedRows.Values) { FoldReceipt(current, receipt, ref unreadable); }
        }
        totalBytes = bytes;
        physical = lookup is not null && current.TryGetValue(lookup, out var observed) ? observed : null;
        foreach (var old in known.Values)
        {
            if (!current.TryGetValue(old.Id, out var next) || next.Version < old.Version
                || old.Plan.Fingerprint != next.Plan.Fingerprint || old.SentAt != next.SentAt
                || next.Version == old.Version && !Serialize(old).AsSpan().SequenceEqual(Serialize(next))
                || next.Version > old.Version && !WriteReceiptStates.CanFollow(old, next))
            { current[old.Id] = old; unreadable++; }
        }
        if (current.Values.Count(WriteReceipts.IsPending) > MaximumPending)
        { throw new ReceiptCapacityException("Plus de 512 reçus non résolus ; vérification manuelle requise."); }
        foreach (var receipt in current.Values) { known[receipt.Id] = receipt; }
        if (unreadable > unreadableTraced) { log.Warning($"Reçus {Path.GetFileName(path)} : {unreadable} enregistrement(s) illisible(s) ou manquant(s), écritures bloquées."); }
        unreadableTraced = unreadable;
        return new([.. current.Values], unreadable);
    }

    private void ReadReceiptFile(string file, Dictionary<string, WriteReceipt> current, ref int unreadable, ref long bytesRead, CancellationToken token = default)
    {
        token.ThrowIfCancellationRequested();
        ValidateReceiptPath(file); ProtectReceiptFile(file);
        using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 8192);
        bytesRead = checked(bytesRead + stream.Length);
        if (bytesRead > MaxFileBytes) { throw new ReceiptCapacityException("Les reçus et archives dépassent 64 Mio ; vérification manuelle requise."); }
        if (stream.Length == 0) { unreadable++; return; }
        var bytes = new byte[stream.Length]; stream.ReadExactly(bytes);
        var consumed = 0;
        while (consumed < bytes.Length)
        {
            token.ThrowIfCancellationRequested();
            var end = bytes.AsSpan(consumed).IndexOf((byte)'\n');
            if (end < 0) { unreadable++; break; }
            var line = bytes.AsMemory(consumed, end); consumed += end + 1;
            if (line.Length > 0 && line.Span[^1] == (byte)'\r') { line = line[..^1]; }
            if (line.IsEmpty) { continue; }
            if (line.Length >= MaxStorageLineBytes || Parse(line) is not { } receipt) { unreadable++; continue; }
            FoldReceipt(current, receipt, ref unreadable);
        }
    }

    private static void FoldReceipt(Dictionary<string, WriteReceipt> current, WriteReceipt receipt, ref int unreadable)
    {
        if (current.TryGetValue(receipt.Id, out var old))
        {
            if (old.Plan.Fingerprint != receipt.Plan.Fingerprint || old.SentAt != receipt.SentAt
                || old.Version == receipt.Version && !Serialize(old).AsSpan().SequenceEqual(Serialize(receipt)))
            { unreadable++; return; }
            if (old.Version >= receipt.Version)
            { if (old.Version > receipt.Version && !WriteReceiptStates.CanFollow(receipt, old)) unreadable++; return; }
            if (!WriteReceiptStates.CanFollow(old, receipt)) { unreadable++; return; }
        }
        current[receipt.Id] = receipt;
    }

}
