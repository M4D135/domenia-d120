using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Ad;

internal sealed record AdSyncBatch(string Id, string Label, long Epoch, DateTimeOffset At, DateTimeOffset Expires,
    ImmutableArray<IndexRecord> Rows, SyncStateEntry? Coverage, ImmutableArray<AbsenceRecord> Absences, ImmutableArray<Guid> ResolvedGaps)
{
    internal string StoreId { get; init; } = "";
    internal long Revision { get; init; }
    internal string BeforeSha256 { get; init; } = "";
    internal AdSyncBatch AtBase(SyncLocalState local) => this with { StoreId = local.StoreId, Revision = local.Revision, BeforeSha256 = SyncLocalIdentity.Fingerprint(local) };
}

internal sealed class AdSyncState(AdDirectorySource source)
{
    private static readonly ConditionalWeakTable<AdDirectorySource, AdSyncState> States = new();
    internal static AdSyncState For(AdDirectorySource source) => States.GetValue(source, static s => new(s));
    internal readonly Lock Gate = new();
    internal readonly Dictionary<string, (SyncEstimate Value, long Epoch)> Estimates = new(StringComparer.Ordinal);
    internal readonly Dictionary<string, AdSyncBatch> Batches = new(StringComparer.Ordinal);
    internal CancellationTokenSource? Stop;
    internal SyncRunInfo? Running;
    internal void Purge()
    {
        var now = source.Clock.GetUtcNow();
        foreach (var id in Estimates.Where(x => x.Value.Value.ExpiresAt <= now || x.Value.Epoch != source.Epoch).Select(x => x.Key).ToArray()) { Estimates.Remove(id); }
        foreach (var id in Batches.Where(x => x.Value.Expires <= now || x.Value.Epoch != source.Epoch).Select(x => x.Key).ToArray()) { Batches.Remove(id); }
    }
    internal void Hold(AdSyncBatch batch)
    {
        lock (Gate)
        {
            Purge();
            if (source.Epoch != batch.Epoch) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée : lot écarté."); }
            if (Batches.Count >= 8) { throw new DomeniaOperationException("sync.batchCapacity", "Huit lectures attendent leur enregistrement ; enregistrez ou ignorez un lot."); }
            Batches.Add(batch.Id, batch);
        }
    }
}
