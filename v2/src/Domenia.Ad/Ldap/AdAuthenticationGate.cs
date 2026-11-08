using System.DirectoryServices.Protocols;
using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Serializes binds for copies of the same selected identity. A credential rejection stops queued and future
/// binds until the user selects a new credential; a transport outage or missing permission does not poison the account.</summary>
internal sealed class AdAuthenticationGate
{
    private static readonly ConditionalWeakTable<AdDirectorySource, Selection> Selections = new();
    private readonly SemaphoreSlim binds = new(1, 1);
    private int rejected;

    internal static AdAuthenticationGate ForSelection(AdDirectorySource source, string accountKey, long epoch, long version)
    {
        var selection = Selections.GetValue(source, static _ => new());
        lock (selection)
        {
            if (epoch < selection.Epoch || epoch == selection.Epoch && version < selection.Version)
                throw new DomeniaOperationException(AccountAccess.EpochChanged, "Ancienne sélection des comptes ; aucune nouvelle connexion LDAP.");
            if (selection.Epoch != epoch || selection.Version != version)
            { selection.Accounts.Clear(); selection.Epoch = epoch; selection.Version = version; }
            if (selection.Accounts.TryGetValue(accountKey, out var existing)) return existing;
            // A selection can contain only a bounded set of accounts; never forget a rejected identity to admit another.
            if (selection.Accounts.Count >= 64)
                throw new DomeniaOperationException("operation.siteBusy", "Limite des comptes de lecture atteinte ; sélectionnez de nouveau le compte avant de continuer.");
            var next = new AdAuthenticationGate(); selection.Accounts.Add(accountKey, next); return next;
        }
    }

    private sealed class Selection
    {
        internal long Epoch = -1, Version = -1;
        internal readonly Dictionary<string, AdAuthenticationGate> Accounts = new(StringComparer.Ordinal);
    }

    internal void RequireAvailable()
    {
        if (Volatile.Read(ref rejected) != 0)
            throw new DomeniaOperationException(AdErrors.Credentials,
                "[DOMENIA:CredentialPaused;0;0x00000000] Compte suspendu après un refus d’identifiants. Choisissez un autre compte ou reconnectez-vous ; aucune nouvelle tentative automatique.");
    }

    internal void ObserveFailure(Exception error)
    {
        if (error is LdapException { ErrorCode: 49 } or DomeniaOperationException { Code: AdErrors.Credentials }
            || error is DirectoryOperationException { Response: { } response } && (int)response.ResultCode == 49)
            Interlocked.Exchange(ref rejected, 1);
    }

    internal async Task BindAsync(Func<Task> bind, CancellationToken token)
    {
        RequireAvailable();
        using (AuthenticationTrace.Step(AuthenticationStage.TransportQueue))
        {
            if (!await binds.WaitAsync(TimeSpan.FromSeconds(120), token).ConfigureAwait(false))
                throw new DomeniaOperationException(AdErrors.Timeout, "Attente locale du compte dépassée ; aucun nouvel essai d’authentification envoyé.");
        }
        try
        {
            token.ThrowIfCancellationRequested(); RequireAvailable();
            try { await bind().ConfigureAwait(false); }
            catch (Exception error) { ObserveFailure(error); throw; }
        }
        finally { binds.Release(); }
    }
}
