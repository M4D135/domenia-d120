using Domenia.Core;

namespace Domenia.Inventory;

/// <summary>Native WMI calls retain their own credential until they actually end, even after the caller stops waiting.</summary>
internal static class WmiReadWorkers
{
    private static readonly SemaphoreSlim Workers = new(6, 6);
    private static readonly AsyncLocal<Admission?> Current = new();
    internal static bool HasPhysicalAdmission => Current.Value is not null;
    internal static AdaptiveReadBudget.Lease? SiteAdmission => Current.Value?.Site;
    internal static IDisposable? BorrowPhysicalAdmission() => Current.Value?.Borrow();
    internal static long TakeQueueMilliseconds() => Current.Value?.TakeQueueMilliseconds() ?? 0;
    private sealed class Admission(AdaptiveReadBudget.Lease? site, IDisposable physical, long queueMilliseconds) : IDisposable
    {
        private readonly IDisposable? resource = RuntimeResources.Register(RuntimeResourceKind.Worker);
        private long queued = queueMilliseconds;
        private readonly Lock gate = new();
        private int references = 1;
        private bool workerActive = true;
        internal AdaptiveReadBudget.Lease? Site => site;
        internal long TakeQueueMilliseconds() => Interlocked.Exchange(ref queued, 0);
        internal IDisposable Borrow()
        {
            lock (gate)
            {
                ObjectDisposedException.ThrowIf(!workerActive, this);
                if (references != 1)
                    throw new DomeniaOperationException("machine.busy", "Un processus natif appartient déjà à ce worker ; aucun second processus envoyé.");
                references++;
                return new Reference(this);
            }
        }
        public void Dispose()
        {
            lock (gate)
            {
                if (!workerActive) return;
                workerActive = false;
                Release();
            }
        }
        private void Release()
        {
            if (--references != 0) return;
            // The worker has erased its credential and its child has confirmed OS exit.
            physical.Dispose(); site?.Dispose(); Workers.Release(); resource?.Dispose();
        }
        private void ReleaseChild() { lock (gate) { Release(); } }
        private sealed class Reference(Admission owner) : IDisposable
        {
            private int disposed;
            public void Dispose() { if (Interlocked.Exchange(ref disposed, 1) == 0) owner.ReleaseChild(); }
        }
    }

    /// <summary>Reserve capacity before starting a reader's timers. Native sessions borrow these reservations;
    /// the worker alone returns them, after disposing every session and its credential.</summary>
    internal static async ValueTask<Task<T>> StartAsync<T>(string host, RemoteProbeCredential? credential,
        Func<RemoteProbeCredential?, T> read, CancellationToken token, AdaptiveReadBudget? adaptive = null)
    {
        AdaptiveReadBudget.Lease? site = null;
        IDisposable? physical = null;
        RemoteProbeCredential? owned = null;
        Admission? admission = null;
        var workerReserved = false;
        var queuedAt = TimeProvider.System.GetTimestamp();
        try
        {
            if (!PhysicalWorkBudget.InWriteContext)
                site = await (adaptive ?? AdaptiveReadBudget.Cim).AcquireAsync(host, token).ConfigureAwait(false);
            // A busy subnet must not occupy all workers while a healthy subnet is ready to run.
            await Workers.WaitAsync(token).ConfigureAwait(false);
            workerReserved = true;
            physical = await PhysicalWorkBudget.AcquireAsync(PhysicalWorkRoute.Cim, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            site?.RequireContinuation();
            owned = credential is null ? null : new(credential.Account, credential.Password?.Copy(), credential.Session);
            admission = new(site, physical, ReadPerformance.Milliseconds(TimeProvider.System.GetElapsedTime(queuedAt)));
            return Task.Run(() =>
            {
                var previous = Current.Value;
                Current.Value = admission;
                try { using (owned) { token.ThrowIfCancellationRequested(); return read(owned); } }
                finally { Current.Value = previous; admission.Dispose(); }
            }, CancellationToken.None);
        }
        catch
        {
            owned?.Dispose();
            if (admission is not null) admission.Dispose();
            else { physical?.Dispose(); site?.Dispose(); if (workerReserved) Workers.Release(); }
            throw;
        }
    }

    // Non-waiting entry retained for explicit quota checks; production readers use StartAsync before their timers.
    internal static Task<T> Start<T>(RemoteProbeCredential? credential, Func<RemoteProbeCredential?, T> read, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (!Workers.Wait(0)) { throw new DomeniaOperationException("machine.busy", "Des lectures CIM se terminent encore ; aucune nouvelle lecture envoyée."); }
        RemoteProbeCredential? owned;
        try { owned = credential is null ? null : new(credential.Account, credential.Password?.Copy(), credential.Session); }
        catch { Workers.Release(); throw; }
        return Task.Run(() =>
        {
            try { using (owned) { token.ThrowIfCancellationRequested(); return read(owned); } }
            finally { Workers.Release(); }
        }, CancellationToken.None);
    }
}
