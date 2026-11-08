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
        private IDisposable? retirement;
        private int disposed;
        internal IAdConnection Connection => connection;
        internal DomainInfo Domain => domain;
        internal AdSessionIdentity Identity => identity;
        internal CredentialAnswer Answer => new(true, "ok", identity.Identity.Login, connection.Server, identity.Sid is null ? "Authentifié ; objet de ce compte non lisible dans ce domaine." : null, identity.Sid) { Aliases = identity.Aliases };
        internal void Adopt(AdDirectorySource source, long epoch, bool correction)
        {
            retirement = source.CommitConnectionAdoption(connection, domain, identity, epoch, correction);
            transferred = true;
        }
        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            if (!transferred) connection.Dispose();
            Interlocked.Exchange(ref retirement, null)?.Dispose();
        }
    }

    internal static async Task<Candidate> RunAsync(AdDirectorySource source, CredentialRequest request, SecureString password,
        Func<AdConnectionOptions, IAdConnection> factory, CancellationToken cancellationToken)
    {
        OperationCredentialScope.RequireAuthentication();
        if (!await Workers.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        { throw new DomeniaOperationException(AdErrors.Timeout, "Une validation native précédente se termine encore ; aucun nouvel essai envoyé."); }
        var policy = AuthenticationPolicy.Read(source.AccountContext?.Configuration);
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        Task<Candidate> task;
        try
        {
            var passwordCopy = password.Copy(); passwordCopy.MakeReadOnly();
            task = DiscoverAndValidateAsync(source, request, passwordCopy, factory, policy, stop.Token);
        }
        catch { stop.Dispose(); Workers.Release(); throw; }
        try
        {
            return await task.WaitAsync(TimeSpan.FromSeconds(policy.TotalSeconds), source.Clock, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            _ = stop.CancelAsync().ContinueWith(static ended => { _ = ended.Exception; }, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
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

    private static async Task<Candidate> DiscoverAndValidateAsync(AdDirectorySource source, CredentialRequest request, SecureString password,
        Func<AdConnectionOptions, IAdConnection> factory, AuthenticationPolicy policy, CancellationToken token)
    {
        using (password)
        {
            var known = source.KnownDomain; var controller = source.ControllerName;
            if (known is null || string.IsNullOrWhiteSpace(controller))
            {
                using var step = AuthenticationTrace.Step(AuthenticationStage.ControllerSetup);
                using var discovery = factory(new(null, source.JoinedDomain ?? known?.DnsName) { ConnectTimeout = TimeSpan.FromSeconds(policy.PerServerSeconds) });
                var root = await discovery.RootDseAsync(token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                if (!ControllerName(root.DnsHostName)) throw ContextFailure("Contrôleur découvert non qualifié ; aucun mot de passe envoyé.");
                controller = root.DnsHostName;
                var observed = await AdDirectoryReader.ReadDomainAsync(discovery, token).ConfigureAwait(false);
                if (known is not null && (!DistinguishedName.AreEqual(known.RootDn, observed.RootDn) || known.DomainSid != observed.DomainSid))
                    throw ContextFailure("Domaine découvert différent ; aucun mot de passe envoyé.");
                known = observed;
            }
            token.ThrowIfCancellationRequested();
            if (!ControllerName(controller) || known is null || source.JoinedDomain is { } joined && !known.DnsName.Equals(joined, StringComparison.OrdinalIgnoreCase))
                throw ContextFailure("Contrôleur ou domaine non confirmé ; aucun mot de passe envoyé.");
            var name = CredentialRules.Parse(request.Login);
            var credential = new NetworkCredential(name.Form == AccountNameForm.Upn ? request.Login : name.Name, password,
                name.Form == AccountNameForm.DownLevel ? name.Authority : "");
            IAdConnection candidate;
            try { candidate = factory(new(controller, known.DnsName) { Credential = credential, ConnectTimeout = TimeSpan.FromSeconds(policy.PerServerSeconds) }); }
            finally { credential.SecurePassword = null; }
            return await ValidateCoreAsync(candidate, known, source.JoinedDomain, request.Login, controller!, token).ConfigureAwait(false);
        }
    }
    private static bool ControllerName(string? name) => name is { Length: > 0 and <= 253 } && name.Contains('.')
        && name.Split('.').All(label => label.Length is > 0 and <= 63 && label.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_'));
    private static DomeniaOperationException ContextFailure(string text) => new(AccountAccess.ContextRefused, text);

    private static async Task<Candidate> ValidateCoreAsync(IAdConnection connection, DomainInfo? known, string? joinedDomain, string login, string controller, CancellationToken token)
    {
        try
        {
            if (known is null) { known = await AdDirectoryReader.ReadDomainAsync(connection, token).ConfigureAwait(false); }
            else
            {
                var root = await connection.RootDseAsync(token).ConfigureAwait(false);
                if (!DistinguishedName.AreEqual(root.DefaultNamingContext, known.RootDn) || !string.Equals(root.DnsHostName, controller, StringComparison.OrdinalIgnoreCase))
                { throw ContextFailure("Contrôleur d’un autre domaine : connexion refusée."); }
                var rows = await connection.SearchAsync(new(known.RootDn, "(objectClass=domainDNS)", AdSearchScope.Base, ["objectSid"])
                { SizeLimit = 2, PageSize = 1, Timeout = TimeSpan.FromSeconds(4), Budget = TimeSpan.FromSeconds(4) }, token).ConfigureAwait(false);
                if (rows.Count != 1 || !DistinguishedName.AreEqual(rows[0].DistinguishedName, known.RootDn) || rows[0].Sid("objectSid") != known.DomainSid)
                { throw ContextFailure("SID du domaine non confirmé : connexion refusée."); }
            }
            if (joinedDomain is not null && !known.DnsName.Equals(joinedDomain, StringComparison.OrdinalIgnoreCase))
            { throw ContextFailure("La connexion doit rester dans le domaine de cette session."); }
            var identity = await AdSessionIdentity.ReadAsync(connection, known, login, null, true, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            return new(connection, known, identity);
        }
        catch { connection.Dispose(); throw; }
    }

    internal static CredentialAnswer Failure(DomeniaOperationException error) => new(false, error.Code switch
    {
        AdErrors.Credentials => error.Data["authenticationKind"] as string ?? "failed",
        AccountAccess.ContextRefused => "identityMismatch",
        AdErrors.Timeout => "timeout",
        AdErrors.NotConnected or AdErrors.Unavailable => "unreachable",
        AdErrors.NoSuchObject => "unknownAccount",
        AdErrors.AccessDenied => "accessDenied",
        AccountAccess.EpochChanged => "cancelled",
        _ => "failed",
    }, null, null, error.Message) { TechnicalCode = error.Data["authenticationCode"] as string };
}
