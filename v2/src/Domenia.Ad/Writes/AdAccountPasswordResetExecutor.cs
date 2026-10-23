using System.Globalization;
using System.Security;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>One password reset with the effective policy, native secret lifetime and an outcome-aware readback.</summary>
public abstract class AdPasswordResetWriteExecutor : AdAccountWriteExecutor, IWriteOutcomeVerifier, IDisposable
{
    private readonly PasswordSecrets secrets;
    private protected AdPasswordResetWriteExecutor(AdDirectorySource source) : base(source) { secrets = new(source.Clock); }
    private protected override string Attribute => AccountPasswordReset.LastSetAttribute;

    private protected Task<WritePlanDraft> PrepareResetAsync(string dn, PasswordResetOptions options, SecureString? password,
        Func<DirectoryUser, DomainInfo, WritePlanDraft, WritePlanDraft> finish, CancellationToken cancellationToken) =>
        PrepareAsync(dn, async (user, domain, session) =>
        {
            _ = PasswordConnection();
            _ = AdConnection.PasswordPolicyControl((await Source.Connection.RootDseAsync(cancellationToken).ConfigureAwait(false)).SupportedControls);
            var effective = await EffectiveDomainAsync(user, domain, cancellationToken).ConfigureAwait(false);
            if (password is not null) { AccountPasswordReset.EnsurePolicy(password, user, effective); }
            var current = await ReadAtDnAsync(dn, cancellationToken).ConfigureAwait(false);
            if (current?.ObjectGuid != user.ObjectGuid || current.UsnChanged != user.UsnChanged)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Le compte a changé pendant la lecture de sa stratégie ; préparez un nouveau plan."); }
            return finish(user, effective, AccountPasswordReset.Draft(user, options, effective, session.Controller?.DnsName, Source.Clock.GetUtcNow(), Source.Zone) with { Kind = Kind });
        }, cancellationToken);

    public void Hold(string planId, DateTimeOffset expiresAt, SecureString password) => secrets.Hold(planId, expiresAt, password);

    private protected override WritePrecheck CheckUser(WritePlan plan, DirectoryUser? user)
    {
        var check = AccountPasswordReset.Check(plan, user, secrets.Contains(plan.Id));
        if (check.Current && AccountWrites.Changes(plan, AccountPasswordReset.LockoutAttribute)
            && AccountWrites.PlannedBefore(plan, AccountPasswordReset.LockoutAttribute) != AccountWrites.Raw(user!.LockoutTime!.Value))
        { return WritePrecheck.Stale("Le verrouillage a changé depuis le plan ; aucun mot de passe envoyé."); }
        return check;
    }
    private protected override bool IsDone(WritePlan plan, DirectoryUser user) => false;

    public override async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ValidatePlan(plan);
        var session = await Source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = Source.AcquireWriteLease(session);
        EnsureController(plan);
        var user = await ReadAtDnAsync(plan.Target.Dn, cancellationToken).ConfigureAwait(false);
        var check = CheckCurrent(plan, user, session);
        if (!check.Current) { secrets.Drop(plan.Id); throw WriteErrors.Refusal(WriteErrors.Stale, check.Detail); }
        using var secret = secrets.Take(plan.Id) ?? throw WriteErrors.Refusal(WriteErrors.Stale, AccountPasswordReset.SecretGoneMessage);
        var effective = await EffectiveDomainAsync(user!, await Source.DomainAsync(cancellationToken).ConfigureAwait(false), cancellationToken).ConfigureAwait(false);
        AccountPasswordReset.EnsurePolicy(secret, user!, effective);
        // Policy reads are bounded, but may span a concurrent account update. Recheck before the only Modify.
        var last = await ReadAtDnAsync(plan.Target.Dn, cancellationToken).ConfigureAwait(false);
        if (last?.ObjectGuid != user!.ObjectGuid || last.UsnChanged != user.UsnChanged)
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Compte modifié pendant la vérification de sa stratégie ; aucun mot de passe envoyé."); }
        await PasswordConnection().ResetPasswordAsync(user.ObjectGuid, secret, AccountPasswordReset.RequiresChange(plan),
            AccountWrites.Changes(plan, AccountPasswordReset.LockoutAttribute), cancellationToken).ConfigureAwait(false);
        return new(WriteResult.Applied, "Le contrôleur a accepté la réinitialisation et ses options dans une seule requête ; le secret n’est ni relu ni testé par authentification.");
    }

    private async Task<DomainInfo> EffectiveDomainAsync(DirectoryUser user, DomainInfo domain, CancellationToken token)
    {
        var policy = await new AdFicheReader(Source).PasswordPolicyAsync(user.DistinguishedName, token).ConfigureAwait(false);
        if (policy.MinLength is not { } min || policy.Complexity is not { } complexity || policy.History is not { } history
            || !policy.MaxAgeNever && policy.MaxAge is null)
        { throw WriteErrors.Refusal(AccountPasswordReset.PolicyRefused, "Stratégie effective du compte incomplète ; aucun mot de passe envoyé."); }
        return domain with { PasswordPolicy = domain.PasswordPolicy with
        { MinPasswordLength = min, ComplexityRequired = complexity, PasswordHistoryLength = history, MaxPasswordAge = policy.MaxAgeNever ? TimeSpan.Zero : policy.MaxAge!.Value } };
    }

    private protected override WriteVerification VerifyUser(WritePlan plan, DirectoryUser? user) => VerifyPassword(plan, user, WriteResult.Unknown);

    private static WriteVerification VerifyPassword(WritePlan plan, DirectoryUser? user, WriteResult result)
    {
        if (result is WriteResult.Unknown or WriteResult.Sent)
        { return new(VerificationState.Unknown, "La réponse du contrôleur manque. Les dates et options ne prouvent pas la valeur du mot de passe ; une revue manuelle est nécessaire, sans nouvel envoi automatique."); }
        if (user is not null && AccountPasswordReset.RequiresChange(plan) && AdValues.HasFlag(user.UserAccountControl, AdValues.DontExpirePassword))
        { return new(VerificationState.Mismatch, "Le mot de passe n’expire jamais ; pwdLastSet à zéro ne prouve pas un changement imposé effectif."); }
        var read = AccountPasswordReset.Verify(user, plan);
        if (user is not null && AccountWrites.Changes(plan, AccountPasswordReset.LockoutAttribute))
        {
            if (user.ComputedAccountControl is null)
            { return new(VerificationState.Unknown, "État calculé du verrouillage illisible ; réinitialisation à vérifier."); }
            if (AdValues.HasFlag(user.ComputedAccountControl.Value, AdValues.LockedOut))
            { return new(VerificationState.Mismatch, "Le compte est encore verrouillé à la relecture."); }
        }
        return read.State == VerificationState.Verified && result == WriteResult.Applied
            ? new(VerificationState.Verified, "Réinitialisation acceptée par le contrôleur et options relues conformes. Le mot de passe n’est ni lu ni essayé par authentification.")
            : read.State == VerificationState.Verified ? new(VerificationState.Unknown, "Options relues conformes, sans acceptation de cette réinitialisation.") : read;
    }

    public Task<WriteVerification> VerifyOutcomeAsync(WritePlan plan, WriteResult result, CancellationToken cancellationToken) =>
        ReadAndVerifyAsync(plan, (p, user) => VerifyPassword(p, user, result), cancellationToken);

    private IAdPasswordConnection PasswordConnection() => Source.Connection as IAdPasswordConnection
        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Transport sécurisé de réinitialisation indisponible.");

    private protected override void ValidatePlan(WritePlan plan)
    {
        if (plan.Kind != Kind || plan.Mode != AppInfoBuilder.DirectoryModeText || plan.Simulated || !WritePlans.IsIntact(plan)
            || !Guid.TryParseExact(plan.Target.ObjectGuid, "D", out var guid) || guid == Guid.Empty || plan.Changes.Length is < 2 or > 3
            || plan.Changes[0] is not { Attribute: AccountPasswordReset.PasswordAttribute, Kind: WriteChangeKind.Reset, BeforeValue: null, AfterValue: null }
            || plan.Changes[1] is not { Attribute: AccountPasswordReset.LastSetAttribute, AfterValue: null or "0" }
            || !long.TryParse(plan.Changes[1].BeforeValue, NumberStyles.None, CultureInfo.InvariantCulture, out _)
            || plan.Changes.Length == 3 && (plan.Changes[2] is not { Attribute: AccountPasswordReset.LockoutAttribute, AfterValue: "0" }
                || !long.TryParse(plan.Changes[2].BeforeValue, NumberStyles.None, CultureInfo.InvariantCulture, out _)))
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Plan de réinitialisation non conforme ; aucun mot de passe envoyé."); }
    }
    public void Dispose() => secrets.Dispose();
}

public sealed class AdAccountPasswordResetExecutor(AdDirectorySource source) : AdPasswordResetWriteExecutor(source), IAccountPasswordResetExecutor
{
    public override string Kind => AccountPasswordReset.Kind;
    public Task<WritePlanDraft> PlanAsync(string dn, PasswordResetOptions options, SecureString password, CancellationToken cancellationToken) =>
        PrepareResetAsync(dn, options, password, (_, _, draft) => draft, cancellationToken);
}
