using Domenia.Core;

namespace Domenia.Inventory;

/// <summary>Native WMI calls retain their own credential until they actually end, even after the caller stops waiting.</summary>
internal static class WmiReadWorkers
{
    private static readonly SemaphoreSlim Workers = new(6, 6);
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
