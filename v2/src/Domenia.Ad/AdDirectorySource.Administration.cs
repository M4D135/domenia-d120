using System.Runtime.InteropServices;
using System.Security;
using System.Security.Cryptography;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Ad;

public sealed partial class AdDirectorySource
{
    private AdministrationIdentity administration = AdministrationIdentity.Unknown;
    internal static readonly TimeSpan TargetAdministrationLifetime = TimeSpan.FromMinutes(10);
    private MachineAdministrationPrincipal? connectionPrincipal;
    private AdEntry? connectionAdministrationSubject;
    private long connectionPrincipalAt;
    // Ephemeral, source-owned binding: alternate credentials cannot inherit a proof issued to
    // a different secret with the same login. Neither key nor digests leave this object.
    private readonly byte[] administrationProofKey = RandomNumberGenerator.GetBytes(32);
    private sealed record BoundAdministration(AdministrationIdentity Identity, byte[] SecretBinding, MachineAdministrationPrincipal? Principal,
        long At, string CanonicalKey, string AccountSid);
    private readonly Dictionary<string, BoundAdministration> validatedAdministrations = new(StringComparer.Ordinal);

    private sealed record LocalAdministration(QueryComputerIdentity Computer, string AccountSid, byte[]? SecretBinding, long At);
    private readonly Dictionary<(string Account, Guid Computer, bool Connection), LocalAdministration> localAdministrations = new();

    internal AdministrationIdentity AdministrationForCredential(long expectedEpoch, string login, string target,
        SecureString? secret, bool connectionIdentity) => AdministrationForCore(expectedEpoch, login, target, secret, connectionIdentity);

    private AdministrationIdentity AdministrationForCore(long expectedEpoch, string login, string? target,
        SecureString? secret, bool connectionIdentity)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (epoch != expectedEpoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée avant la vérification du compte d’administration."); }
            if (AdministrationOverride is { } fixture) { return fixture; }
            var key = AdministrationKey(login);
            var connected = account is { } current && key == AdministrationKey(current.Login);
            var global = connectionIdentity
                ? connected ? administration : AdministrationIdentity.Unknown
                : validatedAdministrations.TryGetValue(key, out var validated)
                    && AdministrationSecretMatches(validated.SecretBinding, secret)
                    ? validated.Identity : AdministrationIdentity.Unknown;
            if (global.AllowsRemote) return global;
            if (target is not null && state is { } picture && AdComputerIndex.For(picture.Directory).Find(target) is { } computer)
            {
                var localKey = CredentialRules.AccountKey(login, domain?.DnsName, domain?.NetbiosName, target);
                var proofKey = (localKey, computer.ObjectGuid, connectionIdentity);
                if (localAdministrations.TryGetValue(proofKey, out var proof))
                {
                    if (!Fresh(proof.At) || !proof.Computer.Matches(computer))
                    { RemoveLocalProof(proofKey); return global; }
                    // A connection proof belongs to this immutable authenticated connection/epoch.
                    // An alternate account must present the exact secret, even if its login is the same.
                    var samePrincipal = CredentialRules.IsLocalAccount(login, target)
                        || validatedAdministrations.TryGetValue(key, out var domainProof) && domainProof.Principal?.AccountSid == proof.AccountSid;
                    if (connectionIdentity ? connected && proof.AccountSid == accountSid
                        : samePrincipal && proof.SecretBinding is { } binding && AdministrationSecretMatches(binding, secret))
                    { return new(AdministrationIdentityState.Administrator, "Administration de cette cible confirmée explicitement ; preuve temporaire de dix minutes, sans droit accordé sur les autres postes."); }
                }
            }
            return global;
        }
    }

    internal void RequireAdministration(long expectedEpoch, string login, string target, SecureString? secret, bool connectionIdentity)
        => RequireAdministrationProof(AdministrationForCredential(expectedEpoch, login, target, secret, connectionIdentity), login, target);

    private void RequireAdministrationProof(AdministrationIdentity proof, string login, string target)
    {
        if (!proof.AllowsRemote && AccountContext is { } context)
        {
            var known = KnownDomain;
            AccountAccess.From(context).RegisterRefusal(CredentialRules.Remote, "Action distante : validation d’administration requise", target,
                "administrationRequired", CredentialRules.AccountKey(login, known?.DnsName, known?.NetbiosName, target), true);
        }
        proof.EnsureRemote();
    }

    internal void RecordAdministration(AdSessionIdentity identity, long expectedEpoch, SecureString secret)
    {
        lock (gate)
        {
            if (epoch != expectedEpoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée pendant la validation du rôle d’administration."); }
            if (identity.Sid is null || identity.Identity.Dn is null) { return; }
            if (identity.Sid == accountSid)
            {
                if (!SamePrincipalEvidence(connectionPrincipal, identity.AdministrationPrincipal))
                    foreach (var target in localAdministrations.Keys.Where(k => k.Connection).ToArray()) RemoveLocalProof(target);
                administration = identity.Administration; SetConnectionPrincipal(identity);
            }
            var binding = AdministrationSecretBinding(secret);
            if (binding is null) { return; }
            if (validatedAdministrations.Count >= 64) { ClearDomainAdministrations(); }
            var key = AdministrationKey(identity.Identity.Login);
            var alias = identity.AuthenticatedLogin is { } authenticated ? AdministrationKey(authenticated) : key;
            InvalidateChangedPrincipal(key, identity.Sid, identity.AdministrationPrincipal, secret);
            if (alias != key) InvalidateChangedPrincipal(alias, identity.Sid, identity.AdministrationPrincipal, secret);
            if (validatedAdministrations.Remove(key, out var previous)) { CryptographicOperations.ZeroMemory(previous.SecretBinding); }
            validatedAdministrations[key] = new(identity.Administration, binding, identity.AdministrationPrincipal, Clock.GetTimestamp(), key, identity.Sid);
            if (alias != key)
            {
                if (validatedAdministrations.Remove(alias, out var oldAlias)) CryptographicOperations.ZeroMemory(oldAlias.SecretBinding);
                validatedAdministrations[alias] = new(identity.Administration, binding.ToArray(), identity.AdministrationPrincipal, Clock.GetTimestamp(), key, identity.Sid);
            }
        }
    }

    private void InvalidateChangedPrincipal(string key, string sid, MachineAdministrationPrincipal? principal, SecureString secret)
    {
        // Old aliases may not be used by this new validation. They still belong to the canonical identity
        // and must lose their evidence together when its groups, SID or secret have changed.
        foreach (var pair in validatedAdministrations.Where(p => p.Key == key || p.Value.CanonicalKey == key || p.Value.AccountSid == sid).ToArray())
        {
            if (pair.Value.AccountSid == sid && SamePrincipalEvidence(pair.Value.Principal, principal)
                && AdministrationSecretMatches(pair.Value.SecretBinding, secret)) continue;
            foreach (var target in localAdministrations.Keys.Where(k => !k.Connection && k.Account == pair.Key).ToArray()) RemoveLocalProof(target);
            validatedAdministrations.Remove(pair.Key);
            CryptographicOperations.ZeroMemory(pair.Value.SecretBinding);
        }
    }

    private static bool SamePrincipalEvidence(MachineAdministrationPrincipal? first, MachineAdministrationPrincipal? second)
        => first is not null && second is not null && first.AccountSid == second.AccountSid
            && first.GroupSids.Length == second.GroupSids.Length && first.GroupSids.ToHashSet(StringComparer.Ordinal).SetEquals(second.GroupSids);

    internal void ForgetLocalAdministration(string login, string target)
    {
        lock (gate)
        {
            if (state is not { } picture || AdComputerIndex.For(picture.Directory).Find(target) is not { } computer) return;
            var key = CredentialRules.AccountKey(login, domain?.DnsName, domain?.NetbiosName, target);
            RemoveLocalProof((key, computer.ObjectGuid, false)); RemoveLocalProof((key, computer.ObjectGuid, true));
        }
    }

    internal bool RecordLocalAdministration(MachineWorkstation workstation, string login, string sid, long expectedEpoch, SecureString? secret,
        bool connectionIdentity = false, QueryComputerIdentity? expectedComputer = null)
    {
        lock (gate)
        {
            if (epoch != expectedEpoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée pendant la validation locale."); }
            if (!AccountsRules.IsDomainSid(sid)) return false;
            if (!CredentialRules.IsLocalAccount(login, workstation.Name)
                && AdministrationPrincipalFor(expectedEpoch, login, secret, connectionIdentity)?.AccountSid != sid) return false;
            var computer = state is { } picture ? AdComputerIndex.For(picture.Directory).Find(workstation.Id) : null;
            if (computer is null || !string.Equals(computer.Name, workstation.Name, StringComparison.OrdinalIgnoreCase)
                || expectedComputer is null || !expectedComputer.Matches(computer)
                || !string.Equals(computer.DnsHostName, workstation.DnsHostName, StringComparison.OrdinalIgnoreCase)
                || !DistinguishedName.AreEqual(computer.DistinguishedName, workstation.Dn)) return false;
            var binding = AdministrationSecretBinding(secret);
            if (binding is null && !connectionIdentity) return false;
            if (localAdministrations.Count >= 64) { ClearLocalAdministrations(); }
            var key = (CredentialRules.AccountKey(login, domain?.DnsName, domain?.NetbiosName, workstation.Name), computer.ObjectGuid, connectionIdentity);
            RemoveLocalProof(key);
            localAdministrations[key] = new(QueryComputerIdentity.Of(computer), sid, binding, Clock.GetTimestamp());
            return true;
        }
    }

    internal QueryComputerIdentity CaptureAdministrationTarget(MachineWorkstation workstation, long expectedEpoch)
    {
        lock (gate)
        {
            if (epoch != expectedEpoch) throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée avant l’essai.");
            var computer = state is { } picture ? AdComputerIndex.For(picture.Directory).Find(workstation.Id) : null;
            if (computer is null || !string.Equals(computer.Name, workstation.Name, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(computer.DnsHostName, workstation.DnsHostName, StringComparison.OrdinalIgnoreCase)
                || !DistinguishedName.AreEqual(computer.DistinguishedName, workstation.Dn))
                throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Identité de la cible modifiée avant l’essai.");
            return QueryComputerIdentity.Of(computer);
        }
    }

    internal MachineAdministrationPrincipal? AdministrationPrincipalFor(long expectedEpoch, string login, SecureString? secret, bool connectionIdentity)
    {
        lock (gate)
        {
            if (epoch != expectedEpoch) throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée avant la validation d’administration.");
            var key = AdministrationKey(login);
            var principal = connectionIdentity
                ? account is { } current && key == AdministrationKey(current.Login) && Fresh(connectionPrincipalAt) ? connectionPrincipal : null
                : validatedAdministrations.TryGetValue(key, out var proof) && Fresh(proof.At) && AdministrationSecretMatches(proof.SecretBinding, secret) ? proof.Principal : null;
            return principal?.IsBounded == true ? principal with { Account = login } : null;
        }
    }

    // Only called by an explicit account trial. Uses the existing authenticated connection: no bind,
    // no credential fallback, no refresh in campaign admission, and the original GUID/SID must still match.
    internal async Task RefreshConnectionAdministrationAsync(long expectedEpoch, CancellationToken token)
    {
        AdEntry? subject; DomainInfo? known; IAdConnection active;
        lock (gate)
        {
            if (epoch != expectedEpoch) throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée avant la validation.");
            subject = connectionAdministrationSubject; known = domain; active = connection;
        }
        if (subject is null || known is null) return;
        var evidence = await AdAdministrationIdentity.ReadEvidenceAsync(active, known, subject, token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        lock (gate)
        {
            if (epoch != expectedEpoch || !ReferenceEquals(connection, active))
                throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée pendant la validation.");
            administration = evidence.Identity; connectionPrincipal = evidence.Principal; connectionPrincipalAt = Clock.GetTimestamp();
            // New group evidence must not leave an older target proof active after a failed or changed read.
            foreach (var key in localAdministrations.Keys.Where(k => k.Connection).ToArray()) RemoveLocalProof(key);
        }
    }

    private bool Fresh(long timestamp) => Clock.GetElapsedTime(timestamp) is var age && age >= TimeSpan.Zero && age < TargetAdministrationLifetime;
    private void SetConnectionPrincipal(AdSessionIdentity identity)
    { connectionPrincipal = identity.AdministrationPrincipal; connectionAdministrationSubject = identity.AdministrationSubject; connectionPrincipalAt = Clock.GetTimestamp(); }
    private void RemoveLocalProof((string Account, Guid Computer, bool Connection) key)
    { if (localAdministrations.Remove(key, out var proof) && proof.SecretBinding is { } binding) CryptographicOperations.ZeroMemory(binding); }

    // Call only while holding the source gate. No managed plaintext string is created.
    private byte[]? AdministrationSecretBinding(SecureString? secret)
    {
        if (secret is null || secret.Length is 0 or > CredentialRules.MaxPasswordLength) { return null; }
        var bytes = new byte[checked(secret.Length * 2)];
        var pointer = IntPtr.Zero;
        try
        {
            pointer = Marshal.SecureStringToBSTR(secret);
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
            return HMACSHA256.HashData(administrationProofKey, bytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
            if (pointer != IntPtr.Zero) { Marshal.ZeroFreeBSTR(pointer); }
        }
    }

    private bool AdministrationSecretMatches(byte[] expected, SecureString? secret)
    {
        var actual = AdministrationSecretBinding(secret);
        if (actual is null) { return false; }
        try { return CryptographicOperations.FixedTimeEquals(expected, actual); }
        finally { CryptographicOperations.ZeroMemory(actual); }
    }

    private void ClearDomainAdministrations()
    {
        foreach (var proof in validatedAdministrations.Values) { CryptographicOperations.ZeroMemory(proof.SecretBinding); }
        validatedAdministrations.Clear();
    }

    private void ClearLocalAdministrations()
    {
        foreach (var proof in localAdministrations.Values) { if (proof.SecretBinding is { } binding) CryptographicOperations.ZeroMemory(binding); }
        localAdministrations.Clear();
    }

    private void ClearAdministrationProofs(bool rotate = true)
    {
        ClearDomainAdministrations(); ClearLocalAdministrations();
        connectionPrincipal = null;
        connectionAdministrationSubject = null;
        CryptographicOperations.ZeroMemory(administrationProofKey);
        if (rotate) { RandomNumberGenerator.Fill(administrationProofKey); }
    }

    private string AdministrationKey(string login) => CredentialRules.AccountKey(login, domain?.DnsName ?? joinedDomain, domain?.NetbiosName, null);
}
