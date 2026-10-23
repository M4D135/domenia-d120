using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Ad;

internal sealed class AdQueryMemory(AdDirectorySource source)
{
    private static readonly ConditionalWeakTable<AdDirectorySource, AdQueryMemory> Memories = new();
    private readonly SemaphoreSlim gate = new(1, 1);
    private QueryStoredReadings current = QueryStoredReadings.Empty;
    private long epoch = -1;
    internal static AdQueryMemory For(AdDirectorySource source) => Memories.GetValue(source, s => new(s));

    private void Ensure(long expected)
    { if (source.Epoch != expected) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée ; résultats de requête écartés."); } }

    internal async Task<QueryStoredReadings> ReadAsync(long expected, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            Ensure(expected);
            if (epoch != expected) { current = QueryStoredReadings.Empty; epoch = expected; }
            if (source.LocalStore is IQueryResultsStore store) { current = await store.ReadQueryResultsAsync(token).ConfigureAwait(false); Ensure(expected); }
            return current;
        }
        finally { gate.Release(); }
    }

    internal async Task SaveAsync(DirectoryComputer computer, ImmutableArray<ProbeReading> probes, ImmutableArray<StoredWmiResult> details, long expected, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            Ensure(expected);
            if (epoch != expected) { current = QueryStoredReadings.Empty; epoch = expected; }
            var next = new QueryComputerReadings(computer.ObjectGuid, computer.DistinguishedName, computer.WhenCreated, probes, details);
            QueryReadingRules.Validate(next, source.Clock.GetUtcNow());
            if (source.LocalStore is IQueryResultsStore store) { current = await store.SaveQueryResultsAsync(next, token).ConfigureAwait(false); Ensure(expected); return; }
            var old = current.Computers.FirstOrDefault(c => c.Computer == computer.ObjectGuid);
            next = QueryReadingRules.Merge(old, next);
            current = new(checked(current.Revision + 1), [.. current.Computers.Where(c => c.Computer != computer.ObjectGuid), next]);
        }
        finally { gate.Release(); }
    }
}
