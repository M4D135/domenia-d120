using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Ad;

internal sealed record AdSyncBatch(string Id, string Label, long Epoch, DateTimeOffset At, DateTimeOffset Expires,
    ImmutableArray<IndexRecord> Rows, SyncStateEntry? Coverage, ImmutableArray<AbsenceRecord> Absences, ImmutableArray<Guid> ResolvedGaps)
{
    internal string StoreId { get; init; } = "";
    internal string DomainDn { get; init; } = "";
    internal long Revision { get; init; }
    internal string BeforeSha256 { get; init; } = "";
    internal AdSyncBatch AtBase(SyncLocalState local) => this with { StoreId = local.StoreId, DomainDn = local.DomainDn, Revision = local.Revision, BeforeSha256 = SyncLocalIdentity.Fingerprint(local) };
}

internal sealed class AdSyncState(AdDirectorySource source) : IDisposable
{
    private static readonly ConditionalWeakTable<AdDirectorySource, AdSyncState> States = new();
    internal static AdSyncState For(AdDirectorySource source) => States.GetValue(source, static s => new(s));
    internal static void Release(AdDirectorySource source)
    { if (States.TryGetValue(source, out var state)) { state.Dispose(); States.Remove(source); } }
    private readonly string sessionId = WritePlans.NewId();
    private bool closed;
    private int staging;
    internal readonly Lock Gate = new();
    internal readonly Dictionary<string, (SyncEstimate Value, long Epoch)> Estimates = new(StringComparer.Ordinal);
    internal readonly Dictionary<string, ISyncBatchLease> Batches = new(StringComparer.Ordinal);
    internal CancellationTokenSource? Stop;
    internal SyncRunInfo? Running;
    internal void Purge()
    {
        var now = source.Clock.GetUtcNow();
        foreach (var id in Estimates.Where(x => x.Value.Value.ExpiresAt <= now || x.Value.Epoch != source.Epoch).Select(x => x.Key).ToArray()) { Estimates.Remove(id); }
        foreach (var id in Batches.Where(x => x.Value.Header.Expires <= now || x.Value.Header.Epoch != source.Epoch).Select(x => x.Key).ToArray()) { Remove(id); }
    }
    internal async Task HoldAsync(AdSyncBatch batch, CancellationToken token)
    {
        var spool = source.LocalStore as ISyncBatchSpool
            ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Conservation temporaire de la lecture indisponible.");
        lock (Gate)
        {
            Purge();
            EnsureCurrent(batch.Epoch);
            if (Batches.Count + staging >= 8) { throw new DomeniaOperationException("sync.batchCapacity", "Huit lectures attendent leur enregistrement ; enregistrez ou ignorez un lot."); }
            staging++;
        }
        ISyncBatchLease? lease = null;
        try
        {
            var header = new SyncBatchHeader(batch.Id, batch.Label, sessionId, batch.Epoch, batch.At, batch.Expires,
                batch.StoreId, batch.DomainDn, batch.Revision, batch.BeforeSha256, batch.Coverage,
                batch.Rows.Length, batch.Absences.Length, batch.ResolvedGaps.Length);
            lease = await spool.StageSyncBatchAsync(new(header, batch.Rows, batch.Absences, batch.ResolvedGaps), token).ConfigureAwait(false);
            lock (Gate)
            {
                EnsureCurrent(batch.Epoch);
                if (Batches.Values.Sum(x => x.Bytes) + lease.Bytes > 512L * 1024 * 1024)
                { throw new DomeniaOperationException("sync.batchCapacity", "Les lectures en attente dépassent 512 Mio ; enregistrez ou ignorez un lot."); }
                Batches.Add(batch.Id, lease); lease = null;
            }
        }
        finally { lease?.Dispose(); lock (Gate) { staging--; } }
    }

    internal async Task<AdSyncBatch> ReadAsync(string id, CancellationToken token)
    {
        ISyncBatchLease held;
        lock (Gate)
        {
            Purge();
            held = Batches.GetValueOrDefault(id) ?? throw new DomeniaOperationException(SyncErrors.BatchUnknown, SyncErrors.BatchUnknownMessage);
            EnsureCurrent(held.Header.Epoch);
        }
        var batch = await held.ReadAsync(token).ConfigureAwait(false);
        lock (Gate)
        {
            EnsureCurrent(batch.Header.Epoch);
            if (batch.Header != held.Header || batch.Header.SessionId != sessionId || batch.Header.Expires <= source.Clock.GetUtcNow()
                || !Batches.TryGetValue(id, out var current) || !ReferenceEquals(current, held))
            { throw new DomeniaOperationException(SyncErrors.BatchUnknown, "Lot temporaire modifié, expiré ou abandonné."); }
        }
        var h = batch.Header;
        return new(h.Id, h.Label, h.Epoch, h.At, h.Expires, batch.Rows, h.Coverage, batch.Absences, batch.ResolvedGaps)
        { StoreId = h.StoreId, DomainDn = h.DomainDn, Revision = h.Revision, BeforeSha256 = h.BeforeSha256 };
    }

    internal bool Remove(string id)
    {
        lock (Gate)
        {
            if (!Batches.Remove(id, out var lease)) { return false; }
            lease.Dispose(); return true;
        }
    }
    private void EnsureCurrent(long epoch)
    { if (closed || source.Epoch != epoch) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée ou fermée : lot écarté."); } }
    public void Dispose()
    {
        lock (Gate)
        {
            closed = true;
            foreach (var lease in Batches.Values) { lease.Dispose(); }
            Batches.Clear(); Estimates.Clear();
        }
    }
}
