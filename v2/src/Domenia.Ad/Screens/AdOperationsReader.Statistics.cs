using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdOperationsReader : IOperationsStatisticsWriter
{
    public async Task PersistStatisticsAsync(CancellationToken cancellationToken)
    {
        if (source.LocalStore is not IOperationsLocalStore || source.AccountContext is not { } context) { return; }
        var samples = OperationActivity.From(context).Samples();
        if (samples.IsEmpty) { return; }
        await saving.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var before = await Store.ReadOperationsAsync(cancellationToken).ConfigureAwait(false);
            var merged = before.Samples.Concat(samples.Select(s => s with { Session = false })).DistinctBy(s => (s.Operation, s.At, s.DurationMs))
                .OrderByDescending(s => s.At).Take(10000).OrderBy(s => s.At).ToImmutableArray();
            if (merged.SequenceEqual(before.Samples)) { return; }
            await Store.UpdateOperationsAsync(before.Revision, before with { Revision = before.Revision + 1, Samples = merged }, cancellationToken).ConfigureAwait(false);
        }
        finally { saving.Release(); }
    }
}
