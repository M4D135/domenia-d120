using System.Globalization;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Fresh account writes, pinned to one session and controller. No cache supplies a precondition.</summary>
public abstract class AdAccountWriteExecutor(AdDirectorySource source) : IWriteExecutor
{
    private protected AdDirectorySource Source { get; } = source;
    public abstract string Kind { get; }
    private protected abstract string Attribute { get; }
    private protected abstract WritePrecheck CheckUser(WritePlan plan, DirectoryUser? user);
    private protected abstract bool IsDone(WritePlan plan, DirectoryUser user);
    private protected abstract WriteVerification VerifyUser(WritePlan plan, DirectoryUser? user);

    private protected async Task<WritePlanDraft> PrepareAsync(string dn,
        Func<DirectoryUser, DomainInfo, SessionSnapshot, WritePlanDraft> draft, CancellationToken token)
    {
        AdFicheObjects.ValidateDn(dn);
        var domain = await Source.DomainAsync(token).ConfigureAwait(false);
        var session = await Source.GetSessionAsync(token).ConfigureAwait(false);
        using var lease = Source.AcquireWriteLease(session);
        var user = await ReadAtDnAsync(dn, token).ConfigureAwait(false)
            ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Ce nom ne désigne aucun compte utilisateur ; aucune écriture préparée.");
        AccountWrites.EnsureNotSystem(user);
        return draft(user, domain, session) with { Origin = WritePlanOrigin.From(session) };
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ValidatePlan(plan);
        var session = await Source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = Source.AcquireWriteLease(session);
        EnsureController(plan);
        var user = await ReadAtDnAsync(plan.Target.Dn, cancellationToken).ConfigureAwait(false);
        return CheckCurrent(plan, user, session);
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ValidatePlan(plan);
        var session = await Source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = Source.AcquireWriteLease(session);
        EnsureController(plan);
        // Recheck even when called directly, and after the durable receipt could have taken time to flush.
        var user = await ReadAtDnAsync(plan.Target.Dn, cancellationToken).ConfigureAwait(false);
        var check = CheckCurrent(plan, user, session);
        if (!check.Current) { throw WriteErrors.Refusal(WriteErrors.Stale, check.Detail); }
        if (IsDone(plan, user!)) { return new(WriteResult.NoChange, "État demandé déjà relu sur le contrôleur ; aucune modification envoyée."); }
        var change = plan.Changes.Single();
        IReadOnlyList<AdModification> modifications;
        if (Attribute is AccountActivation.Attribute or AccountExpiration.Attribute)
        {
            // One atomic Modify, without permissive-modify: a concurrent value must not be overwritten.
            var before = Attribute == AccountActivation.Attribute ? AccountWrites.Raw(user!.UserAccountControl)
                : AccountWrites.Raw(user!.AccountExpires!.Value);
            modifications = [new(Attribute, AdModificationKind.Delete, [before]), new(Attribute, AdModificationKind.Add, [change.AfterValue!])];
        }
        else
        {
            // AD owns lockoutTime/pwdLastSet. Only their supported reset to zero is sent.
            modifications = [new(Attribute, AdModificationKind.Replace, ["0"])];
        }
        await Source.Connection.ModifyAsync(GuidDn(plan), modifications, cancellationToken).ConfigureAwait(false);
        return new(WriteResult.Applied, "Modification acceptée par " + plan.Controller + " ; résultat à confirmer par relecture.");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ValidatePlan(plan);
        var domain = await Source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var session = await Source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = Source.AcquireWriteLease(session);
        EnsureController(plan);
        var id = Guid.ParseExact(plan.Target.ObjectGuid, "D");
        var rows = await Source.Connection.SearchAsync(new(domain.RootDn, AdObjectAccess.GuidFilter(id), AdSearchScope.Subtree, AdDirectoryMapper.UserAttributes)
        { SizeLimit = 2, PageSize = 1, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10) }, cancellationToken).ConfigureAwait(false);
        if (rows.Count > 1 || rows.Any(e => e.Guid("objectGUID") != id || !ScopeRules.Contains(new(domain.RootDn, "", true), e.DistinguishedName)))
        { throw AdAttributeRange.Incomplete(); }
        var user = rows.Count == 0 ? null : Project(rows[0]);
        var verification = VerifyUser(plan, user);
        if (user is not null)
        {
            try
            {
                await Source.RememberObjectsAsync(new(domain, Source.Clock.GetUtcNow(), false, [], [user], [], []), session.Epoch, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is System.IO.IOException or UnauthorizedAccessException)
            { return verification with { Detail = verification.Detail + " La base locale n’a pas pu enregistrer cette relecture." }; }
        }
        return verification;
    }

    private async Task<DirectoryUser?> ReadAtDnAsync(string dn, CancellationToken token)
    {
        var entry = await new AdFicheObjects(Source).ReadExactAsync(dn, AdDirectoryMapper.UserAttributes, TimeSpan.FromSeconds(10), token).ConfigureAwait(false);
        return entry is null ? null : Project(entry);
    }

    private DirectoryUser? Project(AdEntry entry)
    {
        var classes = entry.Strings("objectClass");
        if (!classes.Contains("user", StringComparer.OrdinalIgnoreCase) || classes.Any(c => c.Equals("computer", StringComparison.OrdinalIgnoreCase)
            || c.Equals("msDS-ManagedServiceAccount", StringComparison.OrdinalIgnoreCase) || c.Equals("msDS-GroupManagedServiceAccount", StringComparison.OrdinalIgnoreCase))) { return null; }
        if (entry.Int("userAccountControl") is null || entry.Guid("objectGUID") is not { } id || id == Guid.Empty || entry.Long(Attribute) is null)
        { throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Un attribut nécessaire du compte est illisible ; aucune valeur absente n’est interprétée comme zéro."); }
        return AdDirectoryMapper.User(entry) ?? throw AdAttributeRange.Incomplete();
    }

    private WritePrecheck CheckCurrent(WritePlan plan, DirectoryUser? user, SessionSnapshot session)
    {
        if (!string.Equals(plan.Operator, session.Account.Login, StringComparison.OrdinalIgnoreCase))
        { return WritePrecheck.Stale("Le compte opérateur diffère de celui du plan ; rien n’a été envoyé."); }
        if (user is not null)
        {
            AccountWrites.EnsureNotSystem(user);
            if (Kind == AccountMustChangePassword.Kind && AdValues.HasFlag(user.UserAccountControl, AdValues.DontExpirePassword))
            { return WritePrecheck.Stale("Le mot de passe du compte est désormais sans expiration ; préparez un nouveau plan."); }
            if (Kind == AccountActivation.DisableKind && (session.Account.Dn is null || FicheValues.SameDn(user.DistinguishedName, session.Account.Dn)))
            { return WritePrecheck.Stale("Le compte de session ne peut pas être désactivé ; rien n’a été envoyé."); }
            if (user.AdminCount == 1 && (!plan.Confirmation.TypedNameRequired || plan.Confirmation.TypedName != user.SamAccountName))
            { return WritePrecheck.Stale("La protection ou le nom du compte a changé ; préparez une nouvelle confirmation."); }
        }
        return CheckUser(plan, user);
    }

    private void ValidatePlan(WritePlan plan)
    {
        if (plan.Kind != Kind || plan.Mode != AppInfoBuilder.DirectoryModeText || plan.Simulated || !WritePlans.IsIntact(plan) || plan.Changes.Length != 1
            || plan.Changes[0].Attribute != Attribute || !Guid.TryParseExact(plan.Target.ObjectGuid, "D", out var guid) || guid == Guid.Empty
            || !long.TryParse(plan.Changes[0].AfterValue, NumberStyles.None, CultureInfo.InvariantCulture, out var after) || after < 0)
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Plan d’écriture non conforme ; rien n’a été envoyé."); }
        if (Attribute == AccountActivation.Attribute)
        {
            if (!int.TryParse(plan.Changes[0].BeforeValue, NumberStyles.None, CultureInfo.InvariantCulture, out var before)
                || after != (Kind == AccountActivation.EnableKind ? before & ~AdValues.AccountDisabled : before | AdValues.AccountDisabled))
            { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Seul le bit de désactivation peut changer."); }
        }
        else if (Attribute != AccountExpiration.Attribute && after != 0)
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Seule la remise à zéro est autorisée pour cet attribut."); }
    }

    private void EnsureController(WritePlan plan)
    {
        if (string.IsNullOrWhiteSpace(plan.Controller) || !string.Equals(plan.Controller, Source.ControllerName, StringComparison.OrdinalIgnoreCase))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Contrôleur différent de celui du plan ; aucune écriture envoyée."); }
    }

    internal static string GuidDn(WritePlan plan) => "<GUID=" + Guid.ParseExact(plan.Target.ObjectGuid, "D").ToString("D") + ">";
}

public sealed class AdAccountUnlockExecutor(AdDirectorySource source) : AdAccountWriteExecutor(source), IAccountUnlockExecutor
{
    public override string Kind => AccountUnlock.Kind;
    private protected override string Attribute => AccountUnlock.Attribute;
    public Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken) => PrepareAsync(dn,
        (u, d, s) => AccountUnlock.Draft(u, d, s.Controller?.DnsName, Source.Clock.GetUtcNow(), Source.Zone), cancellationToken);
    private protected override WritePrecheck CheckUser(WritePlan plan, DirectoryUser? user) => AccountUnlock.Check(plan, user, Source.Zone);
    private protected override bool IsDone(WritePlan plan, DirectoryUser user) => AccountUnlock.IsUnlocked(user);
    private protected override WriteVerification VerifyUser(WritePlan plan, DirectoryUser? user) => user is not null && user.ComputedAccountControl is null
        ? new(VerificationState.Unknown, "État calculé du verrouillage illisible ; la remise à zéro seule ne prouve pas le déverrouillage.") : AccountUnlock.Verify(user, plan.Controller);
}

public sealed class AdAccountEnableExecutor(AdDirectorySource source) : AdAccountWriteExecutor(source), IAccountEnableExecutor
{
    public override string Kind => AccountActivation.EnableKind;
    private protected override string Attribute => AccountActivation.Attribute;
    public Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken) => PrepareAsync(dn,
        (u, d, s) => AccountActivation.Draft(u, true, s.Account.Dn, d, s.Controller?.DnsName, Source.Clock.GetUtcNow(), Source.Zone), cancellationToken);
    private protected override WritePrecheck CheckUser(WritePlan plan, DirectoryUser? user) => AccountActivation.Check(plan, user, true);
    private protected override bool IsDone(WritePlan plan, DirectoryUser user) => AccountActivation.IsDone(user, true);
    private protected override WriteVerification VerifyUser(WritePlan plan, DirectoryUser? user) => AccountActivation.Verify(user, true, plan.Controller);
}

public sealed class AdAccountDisableExecutor(AdDirectorySource source) : AdAccountWriteExecutor(source), IAccountDisableExecutor
{
    public override string Kind => AccountActivation.DisableKind;
    private protected override string Attribute => AccountActivation.Attribute;
    public Task<WritePlanDraft> PlanAsync(string dn, string? operatorDn, CancellationToken cancellationToken) => PrepareAsync(dn,
        (u, d, s) => s.Account.Dn is null ? throw WriteErrors.Refusal(AccountWrites.ProtectedAccount, "Identité du compte de session non résolue ; désactivation refusée.")
            : AccountActivation.Draft(u, false, s.Account.Dn, d, s.Controller?.DnsName, Source.Clock.GetUtcNow(), Source.Zone), cancellationToken);
    private protected override WritePrecheck CheckUser(WritePlan plan, DirectoryUser? user) => AccountActivation.Check(plan, user, false);
    private protected override bool IsDone(WritePlan plan, DirectoryUser user) => AccountActivation.IsDone(user, false);
    private protected override WriteVerification VerifyUser(WritePlan plan, DirectoryUser? user) => AccountActivation.Verify(user, false, plan.Controller);
}

public sealed class AdAccountMustChangePasswordExecutor(AdDirectorySource source) : AdAccountWriteExecutor(source), IAccountMustChangePasswordExecutor
{
    public override string Kind => AccountMustChangePassword.Kind;
    private protected override string Attribute => AccountMustChangePassword.Attribute;
    public Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken) => PrepareAsync(dn,
        (u, d, s) => AccountMustChangePassword.Draft(u, s.Controller?.DnsName, Source.Clock.GetUtcNow(), Source.Zone), cancellationToken);
    private protected override WritePrecheck CheckUser(WritePlan plan, DirectoryUser? user) => AccountMustChangePassword.Check(plan, user);
    private protected override bool IsDone(WritePlan plan, DirectoryUser user) => AccountMustChangePassword.IsDone(user);
    private protected override WriteVerification VerifyUser(WritePlan plan, DirectoryUser? user) => user is not null && AdValues.HasFlag(user.UserAccountControl, AdValues.DontExpirePassword)
        ? new(VerificationState.Mismatch, "Le mot de passe du compte n’expire jamais ; le changement imposé n’est pas effectif.") : AccountMustChangePassword.Verify(user, plan.Controller);
}

public sealed class AdAccountExpirationExecutor(AdDirectorySource source) : AdAccountWriteExecutor(source), IAccountExpirationExecutor
{
    public override string Kind => AccountExpiration.Kind;
    private protected override string Attribute => AccountExpiration.Attribute;
    public Task<WritePlanDraft> PlanAsync(string dn, DateOnly? date, CancellationToken cancellationToken) => PrepareAsync(dn,
        (u, d, s) => AccountExpiration.Draft(u, date, s.Controller?.DnsName, Source.Clock.GetUtcNow(), Source.Zone), cancellationToken);
    private protected override WritePrecheck CheckUser(WritePlan plan, DirectoryUser? user) => AccountExpiration.Check(plan, user, Source.Zone);
    private protected override bool IsDone(WritePlan plan, DirectoryUser user) => AccountExpiration.IsDone(user, plan, Source.Zone);
    private protected override WriteVerification VerifyUser(WritePlan plan, DirectoryUser? user) => AccountExpiration.Verify(user, plan, Source.Zone);
}
