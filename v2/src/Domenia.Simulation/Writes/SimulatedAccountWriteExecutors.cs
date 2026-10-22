using System.Security;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Account writes of the Comptes screen in simulation (docs/WRITES.md § 6): each executor reads the fictitious directory as the
/// session sees it and writes only to the in-memory overlay of <see cref="SimulatedDirectorySource"/> (no network, no disk, no
/// real effect). The rules are those of Active Directory (Domenia.Core, Writes/Accounts); each step waits its realistic delay
/// (« latency/screen/write/… »). Found by WriteExecutors.Discover (one public constructor taking the source).
/// </summary>
public abstract class SimulatedAccountWriteExecutor
{
    private const string NotAUserMessage = "Ce nom distinctif ne désigne aucun compte utilisateur de l’annuaire fictif\u00A0: aucune écriture préparée.";
    private const string VanishedMessage = "Le compte n’existe plus dans l’annuaire fictif\u00A0: rien n’a été modifié.";

    private protected SimulatedAccountWriteExecutor(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        Source = source;
    }

    private protected SimulatedDirectorySource Source { get; }

    private protected string? Controller => Source.World.Session.Controller?.DnsName;

    private protected DateTimeOffset Now => Source.Clock.GetUtcNow();

    private protected TimeZoneInfo Zone => Source.World.TimeZone;

    private protected async Task<DirectoryUser> ReadForPlanAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await Source.SimulateScreenLatencyAsync("write/plan", 90, 220, cancellationToken).ConfigureAwait(false);
        return SimulatedAccounts.FindByDn(Source.CurrentDirectory, dn) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, NotAUserMessage);
    }

    private protected async Task<DirectoryUser?> ReadForCheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Source.SimulateScreenLatencyAsync("write/check", 60, 140, cancellationToken).ConfigureAwait(false);
        return SimulatedAccounts.FindByGuid(Source.CurrentDirectory, plan.Target.ObjectGuid);
    }

    private protected async Task<DirectoryUser?> ReadForVerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Source.SimulateScreenLatencyAsync("write/verify", 90, 200, cancellationToken).ConfigureAwait(false);
        return SimulatedAccounts.FindByGuid(Source.CurrentDirectory, plan.Target.ObjectGuid);
    }

    /// <summary>
    /// Sends the change once to the overlay: <paramref name="done"/> tells whether the account is already in the requested state
    /// (nothing written, « already done »), <paramref name="apply"/> gives the account after the write.
    /// </summary>
    private protected async Task<WriteOutcome> SendAsync(WritePlan plan, Func<DirectoryUser, bool> done, Func<DirectoryUser, DateTimeOffset, long, DirectoryUser> apply, string applied, string already)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Source.SimulateScreenLatencyAsync("write/execute", 280, 620, CancellationToken.None).ConfigureAwait(false);
        if (!Guid.TryParseExact(plan.Target.ObjectGuid, "D", out var id))
        {
            throw WriteErrors.Refusal(WriteErrors.TargetUnknown, VanishedMessage);
        }
        var now = Now;
        var wrote = false;
        var after = Source.UpdateUser(id, (user, usn) =>
        {
            if (done(user))
            {
                return null;
            }
            wrote = true;
            return apply(user, now, usn);
        }) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, VanishedMessage);
        _ = after;
        var where = Controller is null ? "." : ", comme le ferait " + Controller + ".";
        return wrote
            ? new WriteOutcome(WriteResult.Applied, applied + " dans l’annuaire fictif (en mémoire, aucun effet réel)" + where)
            : new WriteOutcome(WriteResult.NoChange, already + FrenchText.Colon + "aucune écriture.");
    }
}

/// <summary>Enable of a user account in simulation.</summary>
public sealed class SimulatedAccountEnableExecutor(SimulatedDirectorySource source) : SimulatedAccountWriteExecutor(source), IAccountEnableExecutor
{
    public string Kind => AccountActivation.EnableKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken)
    {
        var user = await ReadForPlanAsync(dn, cancellationToken).ConfigureAwait(false);
        return AccountActivation.Draft(user, true, null, Source.CurrentDirectory.Domain, Controller, Now, Zone);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken) =>
        AccountActivation.Check(plan, await ReadForCheckAsync(plan, cancellationToken).ConfigureAwait(false), true);

    public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken) =>
        SendAsync(plan, u => AccountActivation.IsDone(u, true), (u, now, usn) => AccountActivation.Apply(u, true, now, usn), "Bit «\u00A0compte désactivé\u00A0» retiré", "Compte déjà activé");

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) =>
        AccountActivation.Verify(await ReadForVerifyAsync(plan, cancellationToken).ConfigureAwait(false), true, Controller);
}

/// <summary>Disable of a user account in simulation.</summary>
public sealed class SimulatedAccountDisableExecutor(SimulatedDirectorySource source) : SimulatedAccountWriteExecutor(source), IAccountDisableExecutor
{
    public string Kind => AccountActivation.DisableKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, string? operatorDn, CancellationToken cancellationToken)
    {
        var user = await ReadForPlanAsync(dn, cancellationToken).ConfigureAwait(false);
        return AccountActivation.Draft(user, false, operatorDn, Source.CurrentDirectory.Domain, Controller, Now, Zone);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken) =>
        AccountActivation.Check(plan, await ReadForCheckAsync(plan, cancellationToken).ConfigureAwait(false), false);

    public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken) =>
        SendAsync(plan, u => AccountActivation.IsDone(u, false), (u, now, usn) => AccountActivation.Apply(u, false, now, usn), "Bit «\u00A0compte désactivé\u00A0» ajouté", "Compte déjà désactivé");

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) =>
        AccountActivation.Verify(await ReadForVerifyAsync(plan, cancellationToken).ConfigureAwait(false), false, Controller);
}

/// <summary>Forced password change in simulation (pwdLastSet = 0).</summary>
public sealed class SimulatedAccountMustChangePasswordExecutor(SimulatedDirectorySource source) : SimulatedAccountWriteExecutor(source), IAccountMustChangePasswordExecutor
{
    public string Kind => AccountMustChangePassword.Kind;

    public async Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken)
    {
        var user = await ReadForPlanAsync(dn, cancellationToken).ConfigureAwait(false);
        return AccountMustChangePassword.Draft(user, Controller, Now, Zone);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken) =>
        AccountMustChangePassword.Check(plan, await ReadForCheckAsync(plan, cancellationToken).ConfigureAwait(false));

    public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken) =>
        SendAsync(plan, AccountMustChangePassword.IsDone, AccountMustChangePassword.Apply, "pwdLastSet remis à 0", "Changement déjà exigé");

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) =>
        AccountMustChangePassword.Verify(await ReadForVerifyAsync(plan, cancellationToken).ConfigureAwait(false), Controller);
}

/// <summary>Expiration date of a user account in simulation.</summary>
public sealed class SimulatedAccountExpirationExecutor(SimulatedDirectorySource source) : SimulatedAccountWriteExecutor(source), IAccountExpirationExecutor
{
    public string Kind => AccountExpiration.Kind;

    public async Task<WritePlanDraft> PlanAsync(string dn, DateOnly? date, CancellationToken cancellationToken)
    {
        var user = await ReadForPlanAsync(dn, cancellationToken).ConfigureAwait(false);
        return AccountExpiration.Draft(user, date, Controller, Now, Zone);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken) =>
        AccountExpiration.Check(plan, await ReadForCheckAsync(plan, cancellationToken).ConfigureAwait(false), Zone);

    public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken) =>
        SendAsync(plan, u => AccountExpiration.IsDone(u, plan, Zone), (u, now, usn) => AccountExpiration.Apply(u, plan, now, usn), "accountExpires écrit", "Expiration déjà à la valeur demandée");

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) =>
        AccountExpiration.Verify(await ReadForVerifyAsync(plan, cancellationToken).ConfigureAwait(false), plan, Zone);
}

/// <summary>
/// Password reset in simulation. The new password is held for its sealed plan only (<see cref="PasswordSecrets"/>), taken
/// once at the execution, checked to be non empty (the fictitious directory keeps no password) and disposed at once: it is
/// never written anywhere, not even in the overlay.
/// </summary>
public sealed class SimulatedAccountPasswordResetExecutor : SimulatedAccountWriteExecutor, IAccountPasswordResetExecutor, IDisposable
{
    private readonly PasswordSecrets secrets;

    public SimulatedAccountPasswordResetExecutor(SimulatedDirectorySource source) : base(source)
    {
        secrets = new PasswordSecrets(source.Clock);
    }

    public string Kind => AccountPasswordReset.Kind;

    public async Task<WritePlanDraft> PlanAsync(string dn, PasswordResetOptions options, SecureString password, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(password);
        var user = await ReadForPlanAsync(dn, cancellationToken).ConfigureAwait(false);
        var domain = Source.CurrentDirectory.Domain;
        AccountWrites.EnsureNotSystem(user);
        AccountPasswordReset.EnsurePolicy(password, user, domain);
        return AccountPasswordReset.Draft(user, options, domain, Controller, Now, Zone);
    }

    public void Hold(string planId, DateTimeOffset expiresAt, SecureString password) => secrets.Hold(planId, expiresAt, password);

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken) =>
        AccountPasswordReset.Check(plan, await ReadForCheckAsync(plan, cancellationToken).ConfigureAwait(false), secrets.Contains(plan.Id));

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        using var secret = secrets.Take(plan.Id) ?? throw WriteErrors.Refusal(WriteErrors.Stale, AccountPasswordReset.SecretGoneMessage);
        if (secret.Length == 0)
        {
            throw WriteErrors.Refusal(AccountPasswordReset.PolicyRefused, "Mot de passe vide refusé" + FrenchText.Colon + "rien n’a été modifié.");
        }
        var maxAge = Source.CurrentDirectory.Domain.PasswordPolicy.MaxPasswordAge;
        // Always written: a reset sets a new password even when the flags look the same.
        return await SendAsync(plan, _ => false, (u, now, usn) => AccountPasswordReset.Apply(u, plan, maxAge, now, usn), "Mot de passe réinitialisé", "Mot de passe déjà réinitialisé").ConfigureAwait(false);
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) =>
        AccountPasswordReset.Verify(await ReadForVerifyAsync(plan, cancellationToken).ConfigureAwait(false), plan);

    public void Dispose() => secrets.Dispose();
}
