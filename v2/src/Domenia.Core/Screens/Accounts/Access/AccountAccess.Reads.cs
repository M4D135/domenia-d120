namespace Domenia.Core;

/// <summary>A credential selection for one bounded directory gesture, with guards before contact and publication.</summary>
public sealed class AccountReadLease : IDisposable
{
    private readonly Action<bool> check;
    private bool disposed;
    internal AccountReadLease(SessionSnapshot session, RemoteProbeCredential? credential, string key, Action<bool> check)
    { Session = session; Credential = credential; AccountKey = key; this.check = check; }
    public SessionSnapshot Session { get; }
    [System.Text.Json.Serialization.JsonIgnore]
    public RemoteProbeCredential? Credential { get; }
    public string AccountKey { get; }
    public string Account => Credential?.Account ?? Session.Account.Login;
    public void EnsureCurrent() { ObjectDisposedException.ThrowIf(disposed, this); check(false); }
    public void BeforeContact() { ObjectDisposedException.ThrowIf(disposed, this); check(true); }
    public void Dispose() { if (!disposed) { disposed = true; Credential?.Dispose(); } }
}

public sealed partial class AccountAccess
{
    public long SelectionVersion { get { lock (gate) { return generation; } } }
    /// <summary>Atomic copy + generation. Reading a passive label never enters this method or consumes a lease.</summary>
    public async Task<AccountReadLease> AcquireDirectoryReadAsync(string scope, string? target, CancellationToken token)
    {
        if (scope is not (CredentialRules.Directory or CredentialRules.Laps or CredentialRules.BitLocker))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Ressource de lecture LDAP inconnue."); }
        var session = await SessionAsync(token).ConfigureAwait(false);
        lock (gate)
        {
            var credential = AcquireForRead(scope, target);
            try
            {
                // Remove a spent one-shot now, before sealing the generation. A later UI poll must not invalidate
                // the already authorized gesture merely by sweeping its consumed, caller-owned credential.
                Sweep(clock.GetUtcNow());
                var captured = generation;
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
                return new(session, credential, key, Check);
            }
            catch { credential?.Dispose(); throw; }
        }
    }
}
