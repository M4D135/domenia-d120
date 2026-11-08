namespace Domenia.Core;

/// <summary>Local admission evidence only: no password copy, authentication or lease use.</summary>
public readonly record struct DirectoryReadPreview(long SelectionVersion, bool OneShot);

/// <summary>A credential selection for one bounded directory gesture, with guards before contact and publication.</summary>
public sealed class AccountReadLease : IDisposable
{
    private readonly Action<bool> check;
    private int disposed;
    private readonly Action? released;
    internal AccountReadLease(SessionSnapshot session, RemoteProbeCredential? credential, string key, Action<bool> check, Action? released = null)
    { Session = session; Credential = credential; AccountKey = key; this.check = check; this.released = released; }
    public SessionSnapshot Session { get; }
    [System.Text.Json.Serialization.JsonIgnore]
    public RemoteProbeCredential? Credential { get; }
    public string AccountKey { get; }
    public string Account => Credential?.Account ?? Session.Account.Login;
    public void EnsureCurrent() { ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this); check(false); }
    public void BeforeContact() { ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this); check(true); }
    public void Dispose() { if (Interlocked.Exchange(ref disposed, 1) == 0) { try { Credential?.Dispose(); } finally { released?.Invoke(); } } }
}

public sealed partial class AccountAccess
{
    private readonly Dictionary<long, int> activeDirectoryReads = [];
    public int DirectoryReadsInvalidatedBy(long sourceEpoch) { lock (gate) return activeDirectoryReads.GetValueOrDefault(sourceEpoch); }
    public long SelectionVersion { get { lock (gate) { return generation; } } }

    public async Task<DirectoryReadPreview> PreviewDirectoryReadAsync(string scope, string? target, CancellationToken token)
    {
        scope = AccessOperationContext.DirectoryScope(scope);
        if (!CredentialRules.IsDirectoryReadScope(scope))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Ressource de lecture LDAP inconnue."); }
        await SessionAsync(token).ConfigureAwait(false);
        lock (gate)
        {
            Sweep(clock.GetUtcNow());
            var key = CredentialRules.SecretTargetKey(scope, target);
            var selected = key is not null && temporary.TryGetValue(key, out var scoped) ? scoped : temporary.GetValueOrDefault(scope)
                ?? (scope.StartsWith(CredentialRules.DirectoryOperationPrefix, StringComparison.Ordinal) ? temporary.GetValueOrDefault(CredentialRules.Directory) : null);
            return new(generation, selected?.Lease.Mode == LeaseMode.OneShot);
        }
    }

    /// <summary>Atomic copy + generation. Reading a passive label never enters this method or consumes a lease.</summary>
    public async Task<AccountReadLease> AcquireDirectoryReadAsync(string scope, string? target, CancellationToken token, long? expectedSelectionVersion = null)
    {
        scope = AccessOperationContext.DirectoryScope(scope);
        OperationCredentialScope.RequireDirectory(scope);
        if (!CredentialRules.IsDirectoryReadScope(scope))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Ressource de lecture LDAP inconnue."); }
        var session = await SessionAsync(token).ConfigureAwait(false);
        lock (gate)
        {
            var selectionBefore = generation;
            SelectionReadScope.BeforeAcquire(this, selectionBefore);
            var credential = AcquireForRead(scope, target, expectedSelectionVersion);
            try
            {
                // Remove a spent one-shot now, before sealing the generation. A later UI poll must not invalidate
                // the already authorized gesture merely by sweeping its consumed, caller-owned credential.
                Sweep(clock.GetUtcNow());
                var captured = generation;
                SelectionReadScope.Acquired(this, selectionBefore, captured);
                var key = Key(session, credential?.Account ?? session.Account.Login, null);
                void Check(bool before)
                {
                    lock (gate)
                    {
                        if (generation != captured || lastSession?.Epoch != session.Epoch)
                        { throw new DomeniaOperationException(EpochChanged, "Compte modifié pendant la lecture LDAP ; résultat écarté."); }
                        if (before && PausedLocked(key) is not null)
                        { throw new DomeniaOperationException(MachineErrors.AccountPaused, "Compte en pause après un rejet ; aucun nouvel essai LDAP."); }
                    }
                }
                if (!activeDirectoryReads.ContainsKey(session.Epoch) && activeDirectoryReads.Count >= 64)
                    throw new DomeniaOperationException("operation.siteBusy", "Des lectures de sessions précédentes terminent encore leur nettoyage ; aucun nouvel accès envoyé.");
                activeDirectoryReads[session.Epoch] = activeDirectoryReads.GetValueOrDefault(session.Epoch) + 1;
                return new(session, credential, key, Check, () =>
                {
                    lock (gate)
                    {
                        if (activeDirectoryReads.TryGetValue(session.Epoch, out var count))
                        { if (count == 1) activeDirectoryReads.Remove(session.Epoch); else activeDirectoryReads[session.Epoch] = count - 1; }
                    }
                });
            }
            catch { credential?.Dispose(); throw; }
        }
    }
}
