using System.Collections.Immutable;
using System.Security;

namespace Domenia.Core;

public sealed record CredentialWindowRequest(string Title, string Login, string Purpose, string Theme,
    ImmutableArray<CredentialVaultTarget> VaultTargets, bool CanUseVault, string? VaultReason)
{
    public bool CanEditLogin { get; init; }
}

/// <summary>Owned native entry, never serialized to the web view.</summary>
public sealed class CredentialWindowEntry(SecureString password, bool remember, string? login = null) : IDisposable
{
    public SecureString Password { get; } = password;
    public bool Remember { get; } = remember;
    public string? Login { get; } = login;
    public void Dispose() => Password.Dispose();
}

public interface IAccountsCredentialWindow : IScreenReader
{
    Task<CredentialWindowEntry?> AskAsync(CredentialWindowRequest request, CancellationToken cancellationToken);
}

/// <summary>A short-lived single-use handoff from successful authentication to the separately classified local vault write.</summary>
public sealed class CredentialVaultProofs : IDisposable
{
    private readonly Lock gate = new();
    private readonly Dictionary<string, Proof> entries = [];
    private bool disposed;
    private readonly ITimer expiry;
    private readonly TimeProvider clock;
    public CredentialVaultProofs(TimeProvider clock)
    {
        this.clock = clock;
        expiry = clock.CreateTimer(static state => ((CredentialVaultProofs)state!).Purge(), this, TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(15));
    }

    public string Stage(ImmutableArray<CredentialVaultTarget> targets, SecureString password, long epoch)
    {
        if (targets.Length is 0 or > 2) { throw new ArgumentException("Usages du coffre hors limites."); }
        ArgumentNullException.ThrowIfNull(password);
        if (password.Length is 0 or > CredentialVaultRules.MaxSecretBytes / 2) { throw new ArgumentException("Secret du coffre hors limites."); }
        foreach (var target in targets) { _ = target.Key; }
        if (targets.Any(target => !target.DomainDn.Equals(targets[0].DomainDn, StringComparison.OrdinalIgnoreCase)
                || !target.Account.Equals(targets[0].Account, StringComparison.OrdinalIgnoreCase))
            || targets.Length == 2 && !targets.Select(target => target.Scope).ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(["Laps", "BitLocker"]))
        { throw new ArgumentException("Une authentification ne confirme qu’un seul compte et ses usages exacts."); }
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            PurgeLocked();
            if (entries.Count >= 8) { throw new DomeniaOperationException(CredentialVaultRules.Failed, "Trop de demandes de mémorisation en attente."); }
            var ticket = Guid.NewGuid().ToString("N");
            var secret = password.Copy(); secret.MakeReadOnly();
            entries.Add(ticket, new(targets, secret, epoch, clock.GetUtcNow() + TimeSpan.FromSeconds(60)));
            return ticket;
        }
    }

    public Proof Take(string ticket, long epoch)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            PurgeLocked();
            if (!entries.Remove(ticket, out var proof)) { throw Missing(); }
            if (proof.Epoch != epoch) { proof.Dispose(); throw Missing(); }
            return proof;
        }
    }

    private static DomeniaOperationException Missing() => new(CredentialVaultRules.Failed, "Confirmation d’authentification absente, utilisée ou expirée ; aucun secret enregistré.");
    private void Purge() { lock (gate) { if (!disposed) { PurgeLocked(); } } }
    private void PurgeLocked()
    {
        foreach (var pair in entries.Where(p => p.Value.Expires <= clock.GetUtcNow()).ToArray()) { entries.Remove(pair.Key); pair.Value.Dispose(); }
    }
    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) { return; }
            disposed = true; expiry.Dispose();
            foreach (var proof in entries.Values) { proof.Dispose(); }
            entries.Clear();
        }
    }
    public sealed class Proof(ImmutableArray<CredentialVaultTarget> targets, SecureString password, long epoch, DateTimeOffset expires) : IDisposable
    {
        public ImmutableArray<CredentialVaultTarget> Targets { get; } = targets;
        public SecureString Password { get; } = password;
        public long Epoch { get; } = epoch;
        internal DateTimeOffset Expires => expires;
        public void Dispose() => Password.Dispose();
    }
}
