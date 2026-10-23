using System.Net;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>One selected LDAP identity, one connection, no account fallback; no value is cached or traced by this wrapper.</summary>
internal sealed class AdReadAccess : IDisposable
{
    private readonly AdDirectorySource source;
    private readonly AccountReadLease? lease;
    private readonly IAdConnection connection;
    private readonly bool owns;
    private readonly string scope;
    private readonly string? target;
    private readonly long epoch;
    private readonly string root;
    private readonly bool windowsSession;
    private AdRootDse? bound;
    private bool disposed;
    internal string Account { get; }
    internal string AccountKey { get; }
    internal string? Controller => connection.Server;

    private AdReadAccess(AdDirectorySource source, AccountReadLease? lease, SessionSnapshot session, IAdConnection connection, bool owns, string scope, string? target)
    {
        this.source = source; this.lease = lease; this.connection = connection; this.owns = owns; this.scope = scope; this.target = target;
        epoch = session.Epoch; root = session.Domain?.RootDn ?? throw new DomeniaOperationException(AdErrors.NotConnected, "Domaine de lecture non établi.");
        windowsSession = session.Authentication.Method == AuthenticationMethod.WindowsSession && lease?.Credential is null;
        Account = lease?.Account ?? session.Account.Login;
        AccountKey = lease?.AccountKey ?? CredentialRules.AccountKey(Account, session.Domain?.DnsName, session.Domain?.NetbiosName, null);
    }

    internal static async Task<AdReadAccess> AcquireAsync(AdDirectorySource source, string scope, string? target, CancellationToken token,
        Func<RemoteProbeCredential?, IAdConnection>? factory = null)
    {
        if (scope is not (CredentialRules.Directory or CredentialRules.Laps or CredentialRules.BitLocker)) { throw new ArgumentException("Ressource LDAP inconnue.", nameof(scope)); }
        var session = await source.GetSessionAsync(token).ConfigureAwait(false);
        AccountReadLease? lease = null; IAdConnection? connection = null; var owns = false;
        try
        {
            if (source.AccountContext is { } context) { lease = await AccountAccess.From(context).AcquireDirectoryReadAsync(scope, target, token).ConfigureAwait(false); }
            if (lease?.Session.Epoch != session.Epoch && lease is not null) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée avant la lecture LDAP."); }
            if (source.Epoch != session.Epoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée avant la lecture LDAP."); }
            var selected = lease?.Credential;
            if (selected is not null)
            {
                var valid = CredentialRules.CheckContext(scope, selected.Account, target, new[] { session.Domain?.DnsName, session.Domain?.NetbiosName }.OfType<string>().ToArray());
                if (!valid.Valid || selected.Password is null || selected.Session)
                { throw new DomeniaOperationException(AccountAccess.ContextRefused, "Compte LDAP sélectionné incomplet ou hors contexte ; aucun autre compte essayé."); }
            }
            if (factory is not null) { connection = factory(selected); owns = true; }
            else if (source.Connection is AdConnection native)
            {
                NetworkCredential? credential = null;
                try
                {
                    if (selected is not null)
                    {
                        var name = CredentialRules.Parse(selected.Account);
                        credential = new(name.Form == AccountNameForm.Upn ? selected.Account : name.Name, selected.Password!, name.Form == AccountNameForm.Upn ? "" : name.Authority);
                    }
                    connection = native.ForRead(credential); owns = true;
                }
                finally { if (credential is not null) { using var empty = new System.Security.SecureString(); credential.SecurePassword = empty; } }
            }
            else if (selected is null) { connection = source.Connection; }
            else { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Transport LDAP du compte choisi indisponible ; aucun repli sur la session."); }
            var result = new AdReadAccess(source, lease, session, connection, owns, scope, target);
            result.EnsureCurrent(); return result;
        }
        catch { if (owns) { connection?.Dispose(); } lease?.Dispose(); throw; }
    }

    internal void EnsureCurrent()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (source.Epoch != epoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée pendant la lecture LDAP ; résultat écarté."); }
        lease?.EnsureCurrent();
    }

    private void BeforeContact() { EnsureCurrent(); lease?.BeforeContact(); }

    internal RemoteProbeCredential CopyNativeCredential()
    {
        BeforeContact();
        if (connection is AdConnection native)
        {
            using var copy = native.CopyCredential();
            if (copy.Password is null && !windowsSession)
            { throw new DomeniaOperationException(MachineErrors.PasswordMissing, "Secret de l’identité LDAP sélectionnée indisponible ; aucun repli Windows."); }
            var login = copy.User is null ? Account : string.IsNullOrEmpty(copy.Domain) ? copy.User : copy.Domain + "\\" + copy.User;
            return new(login, copy.Password?.Copy(), windowsSession);
        }
        if (lease?.Credential is { } selected) { return new(selected.Account, selected.Password?.Copy(), selected.Session); }
        if (windowsSession) { return new(Account, null, true); }
        throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Identité native du lecteur LDAP indisponible.");
    }

    internal void ReportNativeRefusal(bool authentication)
    {
        EnsureCurrent();
        if (source.AccountContext is { } context)
        { AccountAccess.From(context).RegisterRefusal(scope, "Lecture du journal Sécurité du contrôleur", target,
            authentication ? "badCredentials" : "accessDenied", AccountKey, true); }
    }

    internal async Task<IReadOnlyList<AdEntry>> SearchAsync(AdSearchRequest request, CancellationToken token)
    {
        AdFicheObjects.ValidateDn(request.BaseDn); AdFicheObjects.EnsureDomain(request.BaseDn, root);
        BeforeContact();
        try
        {
            if (bound is null)
            {
                var remote = await connection.RootDseAsync(token).ConfigureAwait(false); EnsureCurrent();
                if (!DistinguishedName.AreEqual(remote.DefaultNamingContext, root))
                { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Le contrôleur ne sert pas le domaine sélectionné ; aucun objet demandé."); }
                bound = remote;
            }
            BeforeContact();
            var rows = await connection.SearchAsync(request, token).ConfigureAwait(false); EnsureCurrent();
            return rows;
        }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.Credentials or AdErrors.AccessDenied)
        {
            EnsureCurrent();
            if (source.AccountContext is { } context)
            { AccountAccess.From(context).RegisterRefusal(scope, "Lecture LDAP " + CredentialRules.ScopeLabel(scope), target, ex.Code == AdErrors.Credentials ? "badCredentials" : "accessDenied", AccountKey, true); }
            throw;
        }
    }

    public void Dispose()
    { if (!disposed) { disposed = true; if (owns) { connection.Dispose(); } lease?.Dispose(); } }
}
