using System.Net;
using System.Security;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>One bind, bounded caller wait, and a candidate owned by the worker until it really finishes.</summary>
internal static class AdCredentialValidation
{
    private static readonly SemaphoreSlim Workers = new(4, 4);

    internal sealed class Candidate(IAdConnection connection, DomainInfo domain, AdSessionIdentity identity) : IDisposable
    {
        private bool transferred;
        internal IAdConnection Connection => connection;
        internal DomainInfo Domain => domain;
        internal AdSessionIdentity Identity => identity;
        internal CredentialAnswer Answer => new(true, "ok", identity.Identity.Login, connection.Server, identity.Sid is null ? "Authentifié ; objet de ce compte non lisible dans ce domaine." : null, identity.Sid);
        internal void Adopt(AdDirectorySource source, long epoch, bool correction)
        {
            source.AdoptConnection(connection, domain, identity, epoch, correction);
            transferred = true;
        }
        public void Dispose() { if (!transferred) { connection.Dispose(); } }
    }

    internal static async Task<Candidate> RunAsync(AdDirectorySource source, CredentialRequest request, SecureString password,
        Func<AdConnectionOptions, IAdConnection> factory, CancellationToken cancellationToken)
    {
        if (!await Workers.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        { throw new DomeniaOperationException(AdErrors.Timeout, "Une validation native précédente se termine encore ; aucun nouvel essai envoyé."); }
        IAdConnection candidate;
        try
        {
            var name = CredentialRules.Parse(request.Login);
            var credential = new NetworkCredential(name.Form == AccountNameForm.Upn ? request.Login : name.Name, password,
                name.Form == AccountNameForm.DownLevel ? name.Authority : "");
            try { candidate = factory(new(source.ControllerName, source.KnownDomain?.DnsName ?? source.JoinedDomain) { Credential = credential, ConnectTimeout = TimeSpan.FromSeconds(6) }); }
            finally { credential.SecurePassword = null; }
        }
        catch { Workers.Release(); throw; }
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var known = source.KnownDomain;
        var task = ValidateCoreAsync(candidate, known, source.JoinedDomain, request.Login, stop.Token);
        try
        {
            return await task.WaitAsync(TimeSpan.FromSeconds(AccountAccess.ValidationTimeoutSeconds), source.Clock, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            stop.Cancel();
            _ = task.ContinueWith(static completed =>
            {
                if (completed.Status == TaskStatus.RanToCompletion) { completed.Result.Dispose(); }
                else { _ = completed.Exception; }
            }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            if (ex is OperationCanceledException) { throw; }
            throw new DomeniaOperationException(AdErrors.Timeout, AdErrors.TimeoutMessage);
        }
        finally
        {
            _ = task.ContinueWith(_ => { stop.Dispose(); Workers.Release(); }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }
    }

    private static async Task<Candidate> ValidateCoreAsync(IAdConnection connection, DomainInfo? known, string? joinedDomain, string login, CancellationToken token)
    {
        try
        {
            if (known is null) { known = await AdDirectoryReader.ReadDomainAsync(connection, token).ConfigureAwait(false); }
            else
            {
                var root = await connection.RootDseAsync(token).ConfigureAwait(false);
                if (!DistinguishedName.AreEqual(root.DefaultNamingContext, known.RootDn))
                { throw new DomeniaOperationException(AdErrors.Credentials, "Contrôleur d’un autre domaine : connexion refusée."); }
                var rows = await connection.SearchAsync(new(known.RootDn, "(objectClass=domainDNS)", AdSearchScope.Base, ["objectSid"])
                { SizeLimit = 2, PageSize = 1, Timeout = TimeSpan.FromSeconds(4), Budget = TimeSpan.FromSeconds(4) }, token).ConfigureAwait(false);
                if (rows.Count != 1 || !DistinguishedName.AreEqual(rows[0].DistinguishedName, known.RootDn) || rows[0].Sid("objectSid") != known.DomainSid)
                { throw new DomeniaOperationException(AdErrors.Credentials, "SID du domaine non confirmé : connexion refusée."); }
            }
            if (joinedDomain is not null && !known.DnsName.Equals(joinedDomain, StringComparison.OrdinalIgnoreCase))
            { throw new DomeniaOperationException(AdErrors.Credentials, "La connexion doit rester dans le domaine de cette session."); }
            var identity = await AdSessionIdentity.ReadAsync(connection, known, login, null, true, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            return new(connection, known, identity);
        }
        catch { connection.Dispose(); throw; }
    }

    internal static CredentialAnswer Failure(DomeniaOperationException error) => new(false, error.Code switch
    {
        AdErrors.Credentials => error.Data["authenticationKind"] as string ?? "badCredentials",
        AdErrors.Timeout => "timeout",
        AdErrors.NotConnected or AdErrors.Unavailable => "unreachable",
        AdErrors.NoSuchObject => "unknownAccount",
        AdErrors.AccessDenied => "accessDenied",
        AccountAccess.EpochChanged => "cancelled",
        _ => "failed",
    }, null, null, error.Message);
}
