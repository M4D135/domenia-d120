using System.Collections.Immutable;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

/// <summary>One recipe at a time, distinct workstations in a bounded queue. Completion includes every reader's
/// physical cleanup and local save, even when cancellation or a changed context stops the remaining queue.</summary>
internal static class QueryRefreshDispatcher
{
    internal sealed record Counts(int Requested, int Answered, int Failed);

    internal static async Task<Counts> RunAsync(IQueryWorkshopReader reader, IEnumerable<QueryMeasureRequest> requests,
        int concurrency, long epoch, long accountVersion, long machineGeneration,
        Func<QueryMeasureRequest, CancellationToken, Task> confirm, CancellationToken token)
    {
        var requested = 0; var answered = 0; var failed = 0;
        System.Runtime.ExceptionServices.ExceptionDispatchInfo? failure = null;
        IEnumerable<QueryMeasureRequest> Pending()
        {
            using var iterator = requests.GetEnumerator();
            while (Volatile.Read(ref failure) is null)
            {
                token.ThrowIfCancellationRequested();
                if (!iterator.MoveNext()) yield break;
                yield return iterator.Current;
            }
        }
        await Parallel.ForEachAsync(Pending(), new ParallelOptions
        { MaxDegreeOfParallelism = Math.Clamp(concurrency, 1, 6), CancellationToken = token }, async (request, stopping) =>
        {
            if (Volatile.Read(ref failure) is not null) return;
            try
            {
                await confirm(request, stopping).ConfigureAwait(false);
                stopping.ThrowIfCancellationRequested();
                var result = await reader.MeasureAsync(request with
                {
                    ExpectedEpoch = epoch, ExpectedAccountVersion = accountVersion,
                    ExpectedMachineGeneration = machineGeneration, OnlyOutcome = true, OwnsCampaign = true,
                }, stopping).ConfigureAwait(false);
                Interlocked.Add(ref requested, result.Requested);
                Interlocked.Add(ref answered, result.Answered);
                Interlocked.Add(ref failed, result.Failed + result.SkippedDisabled);
            }
            catch (Exception ex) when (!token.IsCancellationRequested)
            {
                // A one-shot consumed by a running host refuses later admissions. Preserve that authorized read
                // and its receipt; stop the queue, then surface the first failure after every admitted host ends.
                Interlocked.CompareExchange(ref failure, System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(ex), null);
            }
        }).ConfigureAwait(false);
        failure?.Throw();
        return new(requested, answered, failed);
    }
}
