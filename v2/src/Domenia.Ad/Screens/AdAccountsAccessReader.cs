using System.Collections.Immutable;
using System.Security;
using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.Ad;

/// <summary>Explicit access gestures: one authentication, no retry or Windows-identity fallback.</summary>
public sealed class AdAccountsAccessReader(AdDirectorySource source) : IAccountsAccessReader, IDisposable
{
    private readonly Lock gate = new();
    private Pending? pending;
    private bool disposed;
    internal Func<AdConnectionOptions, IAdConnection> ConnectionFactory { get; init; } = AdConnectionFactory.Create;
    internal Func<MachineProbeRequest, MachineWorkstation, bool, CancellationToken, Task<MachineTrialObservation>>? ProbeOverride { get; init; }
    public bool Simulated => false;
    public bool SessionSwitchAvailable => true;
    public DateTimeOffset? SessionStartedAt => source.SessionStartedAt;
    public Task<ImmutableArray<AccessRequestSeed>> InitialRequestsAsync(CancellationToken cancellationToken)
    { cancellationToken.ThrowIfCancellationRequested(); return Task.FromResult(ImmutableArray<AccessRequestSeed>.Empty); }
    public Task<string?> SessionSidAsync(CancellationToken cancellationToken)
    { cancellationToken.ThrowIfCancellationRequested(); return Task.FromResult(source.SessionSid); }

    public async Task<CredentialAnswer> ValidateAsync(CredentialRequest request, SecureString password, CancellationToken cancellationToken)
    {
        ClearPending();
        var input = Check(request, password);
        if (input is not null) { return input; }
        if (CredentialRules.IsLocalAccount(request.Login, request.Target)) { return await ValidateLocalAsync(request, password, cancellationToken).ConfigureAwait(false); }
        var epoch = source.Epoch;
        try
        {
            var candidate = await AdCredentialValidation.RunAsync(source, request, password, ConnectionFactory, cancellationToken).ConfigureAwait(false);
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (source.Epoch != epoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée pendant la validation."); }
                var answer = candidate.Answer;
                if (request.Scope == CredentialRules.Directory && source.IsExplicitSession && candidate.Identity.Sid is not null && candidate.Identity.Sid == source.SessionSid)
                {
                    lock (gate)
                    {
                        ObjectDisposedException.ThrowIf(disposed, this);
                        pending = new(candidate, password, epoch, source.Clock);
                        candidate = null!; // the proof owns this connection until use, replacement or its 30 s expiry
                    }
                }
                return answer;
            }
            finally { candidate?.Dispose(); }
        }
        catch (DomeniaOperationException ex) { return AdCredentialValidation.Failure(ex); }
    }

    public async Task<SessionOpenAnswer> OpenSessionAsync(CredentialRequest request, SecureString password, CancellationToken cancellationToken)
    {
        ClearPending();
        var input = Check(request, password);
        if (input is not null) { return new(input, null); }
        if (request.Scope != CredentialRules.Directory) { return new(new(false, "input", null, null, "Le changement de session exige un compte d’annuaire."), null); }
        var epoch = source.Epoch;
        try
        {
            using var candidate = await AdCredentialValidation.RunAsync(source, request, password, ConnectionFactory, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (candidate.Identity.Sid is null || candidate.Identity.Identity.Dn is null)
            { return new(new(false, "identityMismatch", null, candidate.Connection.Server, "Compte authentifié mais identité du domaine non confirmée ; session conservée."), null); }
            var answer = candidate.Answer;
            lock (gate)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                cancellationToken.ThrowIfCancellationRequested();
                candidate.Adopt(source, epoch, correction: false);
            }
            return new(answer, candidate.Identity.Identity);
        }
        catch (DomeniaOperationException ex) { return new(AdCredentialValidation.Failure(ex), null); }
    }

    public Task<ConnectionSecretSwap> SwapConnectionPasswordAsync(SecureString password, CancellationToken cancellationToken)
    {
        Pending? proof;
        lock (gate) { proof = pending; pending = null; }
        using (proof)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var previous = (source.Connection as AdConnection)?.CopyCredential(tracked: false);
            if (proof is null || !source.IsExplicitSession || !proof.Adopt(source, password, cancellationToken))
            { throw new DomeniaOperationException(AccountAccess.CorrectionUnavailable, "Validation du même secret absente ou expirée : aucune connexion remplacée."); }
            // Old LDAP connection is closed, its epoch invalidated. Other protocol workers own their copy until their return.
            var other = previous?.Password is { } oldSecret && SecureCredentialCopies.Contains(oldSecret, (source.Connection as AdConnection)?.TrackedCredential);
            return Task.FromResult(new ConnectionSecretSwap(true, 0, other));
        }
    }

    public async Task<RemoteProbeAnswer> ProbeAsync(string computer, RemoteProbeCredential credential, CancellationToken cancellationToken)
    {
        var epoch = source.Epoch;
        var workstation = await new AdMachineAccountReader(source).FindWorkstationAsync(computer, cancellationToken).ConfigureAwait(false);
        if (workstation is null) { return new("unknown", "target", null, "Choisissez un poste connu de l’annuaire local."); }
        AdCredentialCopy? owned = null;
        try
        {
            var account = credential.Account;
            var password = credential.Password;
            var origin = MachineAccountSource.Remote;
            if (credential.Session)
            {
                if (source.Connection is not AdConnection connection) { return new("unknown", "credentialsMissing", null, "Identité de connexion indisponible pour cet accès Windows."); }
                owned = connection.CopyCredential();
                password = owned.Password;
                account = connection.ExplicitLogin ?? credential.Account;
                origin = connection.UsesWindowsIdentity ? MachineAccountSource.Windows : MachineAccountSource.Connection;
            }
            var observation = await Probe(new(computer, origin, account, password), workstation, false, cancellationToken).ConfigureAwait(false);
            if (source.Epoch != epoch) { return new("unknown", "sessionChanged", null, "Session modifiée pendant l’essai ; résultat écarté."); }
            return new(observation.Outcome.ToLowerInvariant() switch { "authrejected" => "authRejected", var value => value },
                observation.Category?.ToLowerInvariant() switch { "credentialsrejected" => "credentialsRejected", "accessdenied" => "accessDenied", "accountstate" => "accountState", var value => value }, observation.Caption, observation.ErrorText);
        }
        finally { owned?.Dispose(); }
    }

    private async Task<CredentialAnswer> ValidateLocalAsync(CredentialRequest request, SecureString password, CancellationToken token)
    {
        var workstation = await new AdMachineAccountReader(source).FindWorkstationAsync(request.Target!, token).ConfigureAwait(false);
        if (workstation is null) { return new(false, "workstationUnreachable", null, null, "Le poste cible doit être identifié dans l’annuaire local."); }
        var epoch = source.Epoch;
        var name = CredentialRules.Parse(request.Login);
        var account = workstation.Name + "\\" + name.Name;
        var observation = await Probe(new(workstation.Name, MachineAccountSource.TemporaryLocal, account, password), workstation, true, token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        if (source.Epoch != epoch) { return new(false, "cancelled", null, null, "Session modifiée pendant l’essai."); }
        var confirmed = observation.ConfirmedComputerName;
        if (observation.Outcome == "Observed" && string.Equals(confirmed, workstation.Name, StringComparison.OrdinalIgnoreCase))
        { return new(true, "ok", confirmed + "\\" + name.Name, workstation.DnsHostName ?? workstation.Name, "Compte local accepté et nom du poste relu par CIM."); }
        return new(false, observation.Outcome switch { "AuthRejected" => "badCredentials", "Denied" => "accessDenied", "Timeout" => "workstationUnreachable", _ => "failed" }, null, workstation.Name, observation.ErrorText);
    }

    private Task<MachineTrialObservation> Probe(MachineProbeRequest request, MachineWorkstation workstation, bool confirmName, CancellationToken token) =>
        ProbeOverride is { } callback ? callback(request, workstation, confirmName, token) : new WmiMachineAccessProbe(source.Clock).ReadAsync(request, workstation, token, confirmName);

    private CredentialAnswer? Check(CredentialRequest request, SecureString password)
    {
        ArgumentNullException.ThrowIfNull(request); ArgumentNullException.ThrowIfNull(password);
        if (!CredentialRules.IsWellFormed(request.Login) || request.Login != request.Login.Trim() || password.Length is 0 or > CredentialRules.MaxPasswordLength)
        { return new(false, "input", null, null, "Compte ou mot de passe incomplet."); }
        var known = source.KnownDomain;
        string[] names = [.. new[] { known?.DnsName, known?.NetbiosName, source.JoinedDomain }.OfType<string>()];
        var context = CredentialRules.CheckContext(request.Scope, request.Login, request.Target, names);
        if (!context.Valid) { return new(false, "input", null, null, context.Reason); }
        return null;
    }

    private void ClearPending()
    {
        Pending? before;
        lock (gate) { ObjectDisposedException.ThrowIf(disposed, this); before = pending; pending = null; }
        before?.Dispose();
    }
    public void Dispose()
    {
        Pending? before;
        lock (gate) { if (disposed) { return; } disposed = true; before = pending; pending = null; }
        before?.Dispose();
    }

    private sealed class Pending : IDisposable
    {
        private readonly Lock sync = new();
        private readonly AdCredentialValidation.Candidate candidate;
        private readonly SecureString secret;
        private readonly long epoch;
        private readonly ITimer expiry;
        private bool expired;
        internal Pending(AdCredentialValidation.Candidate candidate, SecureString password, long epoch, TimeProvider clock)
        {
            this.candidate = candidate; secret = password.Copy(); secret.MakeReadOnly(); this.epoch = epoch;
            expiry = clock.CreateTimer(_ => Dispose(), null, TimeSpan.FromSeconds(30), Timeout.InfiniteTimeSpan);
        }
        internal bool Adopt(AdDirectorySource source, SecureString password, CancellationToken token)
        {
            lock (sync)
            {
                token.ThrowIfCancellationRequested();
                if (expired || !SameSecret(secret, password)) { return false; }
                candidate.Adopt(source, epoch, correction: true);
                return true;
            }
        }
        public void Dispose()
        {
            lock (sync)
            {
                if (expired) { return; }
                expired = true; expiry.Dispose(); secret.Dispose(); candidate.Dispose();
            }
        }
    }

    internal static bool SameSecret(SecureString first, SecureString second) => SecureCredentialCopies.Equal(first, second);
}
