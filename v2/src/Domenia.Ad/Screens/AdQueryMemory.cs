using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Ad;

internal sealed class AdQueryMemory(AdDirectorySource source)
{
    private static readonly ConditionalWeakTable<AdDirectorySource, AdQueryMemory> Memories = new();
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Lock failureGate = new();
    private readonly Dictionary<(Guid Computer, string Dn, DateTimeOffset Created), QueryComputerReadings> failures = [];
    private long failureEpoch = -1;
    private long failureRevision;
    private QueryStoredReadings current = QueryStoredReadings.Empty;
    private long epoch = -1;
    internal static AdQueryMemory For(AdDirectorySource source) => Memories.GetValue(source, s => new(s));

    private void Ensure(long expected)
    { if (source.Epoch != expected) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée ; résultats de requête écartés."); } }
    private void ResetFailures(long expected)
    { if (failureEpoch != expected) { failures.Clear(); failureEpoch = expected; failureRevision = 0; } }

    /// <summary>A failed attempt invalidates the session verdict before any fallible disk operation.</summary>
    internal QueryComputerReadings? Invalidate(DirectoryComputer computer, string requestKey, long expected) =>
        Invalidate(computer, [], [new(requestKey, source.Clock.GetUtcNow(), false, 0, false, false)], expected);

    internal QueryComputerReadings? Invalidate(DirectoryComputer computer, ImmutableArray<ProbeReading> probes, ImmutableArray<StoredWmiResult> details, long expected)
    {
        var failure = new QueryComputerReadings(computer.ObjectGuid, computer.DistinguishedName, computer.WhenCreated, probes, details);
        lock (failureGate)
        {
            // Session changes must neither install an old failure nor replace the exception that caused it.
            if (source.Epoch != expected) { return null; }
            ResetFailures(expected);
            var identity = (computer.ObjectGuid, computer.DistinguishedName.ToUpperInvariant(), computer.WhenCreated);
            failures[identity] = QueryReadingRules.Merge(failures.GetValueOrDefault(identity), failure);
            failureRevision++;
        }
        return failure;
    }

    private QueryStoredReadings WithFailures(QueryStoredReadings stored, long expected)
    {
        lock (failureGate)
        {
            Ensure(expected); ResetFailures(expected);
            var computers = stored.Computers.ToDictionary(c => c.Computer);
            foreach (var failure in failures.Values)
            {
                if (!computers.TryGetValue(failure.Computer, out var old)) { computers[failure.Computer] = failure; }
                else if (old.Created == failure.Created && DistinguishedName.AreEqual(old.Dn, failure.Dn))
                {
                    // A failed session attempt wins even if a stored clock is slightly ahead. Only a later
                    // successful save through this session explicitly clears the failure overlay.
                    var retained = old with { Details = [.. old.Details.Where(d => !failure.Details.Any(f => f.RequestKey == d.RequestKey))],
                        Probes = [.. old.Probes.Where(p => !failure.Probes.Any(f => f.ProbeId == p.ProbeId))] };
                    computers[failure.Computer] = QueryReadingRules.Merge(retained, failure);
                }
                // A failure of an old DN or incarnation is never transferred to a new identity.
            }
            return stored with { Computers = [.. computers.Values], TransientRevision = failureRevision };
        }
    }

    private void ClearSucceeded(QueryComputerReadings next, long expected)
    {
        lock (failureGate)
        {
            Ensure(expected); ResetFailures(expected);
            foreach (var (identity, failed) in failures.Where(p => p.Value.Computer == next.Computer && p.Value.Created == next.Created
                && DistinguishedName.AreEqual(p.Value.Dn, next.Dn)).ToArray())
            {
                var remaining = failed.Details.Where(d => !next.Details.Any(n => n.RequestKey == d.RequestKey && n.Success && n.At >= d.At)).ToImmutableArray();
                var probes = failed.Probes.Where(p => !next.Probes.Any(n => n.ProbeId == p.ProbeId && n.Error is null && n.CheckedAt >= p.CheckedAt)).ToImmutableArray();
                if (remaining.Length == failed.Details.Length && probes.Length == failed.Probes.Length) { continue; }
                if (remaining.IsEmpty && probes.IsEmpty) { failures.Remove(identity); } else { failures[identity] = failed with { Details = remaining, Probes = probes }; }
                failureRevision++;
            }
        }
    }

    internal async Task PersistFailureAsync(QueryComputerReadings? failure, Exception original)
    {
        if (failure is null || source.LocalStore is not IQueryResultsStore store) { return; }
        using var persistence = new CancellationTokenSource(TimeSpan.FromSeconds(2), source.Clock);
        try
        {
            var write = store.SaveQueryResultsAsync(failure, persistence.Token);
            _ = write.ContinueWith(t => { _ = t.Exception; }, CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            await write.WaitAsync(persistence.Token).ConfigureAwait(false);
        }
        catch (Exception storageError)
        {
            original.Data["query.invalidation"] = "Échec invalidé pour cette session ; persistance non confirmée (" + storageError.GetType().Name + ").";
            try
            {
                source.AccountContext?.Log.Warning("Requêtes : invalidation locale non persistée (" + storageError.GetType().Name + ") ; l’erreur initiale est conservée.");
                source.AccountContext?.Journal.Add(new(source.Clock.GetUtcNow(), "Requêtes : dernier échec conservé en mémoire ; la base locale n’a pas confirmé son enregistrement.", Tone.Warn));
            }
            catch (Exception diagnosticError) { original.Data["query.invalidation.diagnostic"] = diagnosticError.GetType().Name; }
        }
    }

    internal async Task<QueryStoredReadings> ReadAsync(long expected, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            Ensure(expected);
            if (epoch != expected) { current = QueryStoredReadings.Empty; epoch = expected; }
            if (source.LocalStore is IQueryResultsStore store) { current = await store.ReadQueryResultsAsync(token).ConfigureAwait(false); Ensure(expected); }
            return WithFailures(current, expected);
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
            if (source.LocalStore is IQueryResultsStore store) { current = await store.SaveQueryResultsAsync(next, token).ConfigureAwait(false); Ensure(expected); }
            else
            {
                var merged = QueryReadingRules.Merge(current.Computers.FirstOrDefault(c => c.Computer == computer.ObjectGuid), next);
                current = new(checked(current.Revision + 1), [.. current.Computers.Where(c => c.Computer != computer.ObjectGuid), merged]);
            }
            ClearSucceeded(next, expected);
        }
        finally { gate.Release(); }
    }
}
