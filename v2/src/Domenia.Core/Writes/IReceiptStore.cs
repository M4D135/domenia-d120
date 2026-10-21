using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Receipts read back from a store: the latest version of each receipt, and how many records could not be read.</summary>
public sealed record ReceiptLog(ImmutableArray<WriteReceipt> Receipts, int Unreadable);

/// <summary>
/// Durable receipts of the writes (operation class LocalWrite, docs/WRITES.md § 4): receipts.jsonl in the user data folder,
/// receipts-simulation.jsonl in simulation, one record per line, appended atomically. A record is one version of a receipt;
/// the latest version of an identifier wins. Implementations never keep a secret: a plan holds none.
/// </summary>
public interface IReceiptStore
{
    /// <summary>False when the receipts live in memory only (capture mode, no data folder, tests).</summary>
    bool Persistent { get; }

    /// <summary>
    /// Appends one version of a receipt. Throws <see cref="IOException"/> or <see cref="UnauthorizedAccessException"/> when it is
    /// not durably written: the circuit then sends nothing (version 1) or tells the operator (later versions).
    /// </summary>
    Task AppendAsync(WriteReceipt receipt, CancellationToken cancellationToken);

    /// <summary>
    /// Every receipt, latest version of each. Throws <see cref="IOException"/> when the store cannot be read for now: the circuit
    /// then refuses new writes (fail closed, Domenia 1 OPE-022).
    /// </summary>
    Task<ReceiptLog> ReadAllAsync(CancellationToken cancellationToken);
}

/// <summary>Receipts kept in memory only: nothing is read or written on disk.</summary>
public sealed class MemoryReceiptStore : IReceiptStore
{
    private readonly Lock gate = new();
    private readonly Dictionary<string, WriteReceipt> receipts = new(StringComparer.Ordinal);

    public bool Persistent => false;

    /// <summary>Number of records appended (tests).</summary>
    public int Appends { get; private set; }

    public Task AppendAsync(WriteReceipt receipt, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            if (!receipts.TryGetValue(receipt.Id, out var known) || known.Version <= receipt.Version)
            {
                receipts[receipt.Id] = receipt;
            }
            Appends++;
        }
        return Task.CompletedTask;
    }

    public Task<ReceiptLog> ReadAllAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            return Task.FromResult(new ReceiptLog([.. receipts.Values], 0));
        }
    }
}
