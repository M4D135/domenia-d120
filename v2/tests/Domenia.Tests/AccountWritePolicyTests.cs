using System.Globalization;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class AccountWritePolicyTests
{
    [Test]
    public static void Both_screens_refuse_protected_disable_and_keep_the_historical_plan_kinds()
    {
        var user = Fixtures.User("Camille");
        var accounts = AccountActivation.Draft(user, false, null, Fixtures.Domain, "dc.test.local", Fixtures.Now, TimeZoneInfo.Utc);
        var fiche = ObjectWrites.Enabled(Entry(user), false, "dc.test.local");
        Check.Equal("account.disable", accounts.Kind, "ancien contrat Comptes");
        Check.Equal("account.enabled", fiche.Kind, "ancien contrat Fiche");
        Check.True(fiche.Confirmation.TypedNameRequired, "confirmation Fiche non affaiblie");
        user = user with { AdminCount = 1 };
        var a = Check.Throws<DomeniaOperationException>(() => AccountActivation.Draft(user, false, null, Fixtures.Domain, null, Fixtures.Now, TimeZoneInfo.Utc), "Comptes protégé");
        var f = Check.Throws<DomeniaOperationException>(() => ObjectWrites.Enabled(Entry(user), false, null), "Fiche protégée");
        Check.Equal(AccountWrites.ProtectedAccount, a.Code, "code Comptes conservé");
        Check.Equal(FicheErrors.Protected, f.Code, "code Fiche conservé");
        Check.False(AccountsRules.Actions(user, null).Disable.Available, "refus visible avant le clic");
        Check.False(Sheet(user).Actions.Single(a => a.Id == "disable").Available, "même refus visible sur la Fiche");
    }

    [Test]
    public static void Both_screens_refuse_password_never_expires_and_keep_the_historical_password_kinds()
    {
        var user = Fixtures.User("Camille");
        var accounts = AccountMustChangePassword.Draft(user, null, Fixtures.Now, TimeZoneInfo.Utc);
        var fiche = ObjectWrites.ExpirePassword(Entry(user), null, TimeZoneInfo.Utc);
        Check.Equal("account.mustChangePassword", accounts.Kind, "ancien contrat Comptes");
        Check.Equal("password.expire", fiche.Kind, "ancien contrat Fiche");
        user = user with { UserAccountControl = user.UserAccountControl | AdValues.DontExpirePassword };
        var a = Check.Throws<DomeniaOperationException>(() => AccountMustChangePassword.Draft(user, null, Fixtures.Now, TimeZoneInfo.Utc), "Comptes sans effet");
        var f = Check.Throws<DomeniaOperationException>(() => ObjectWrites.ExpirePassword(Entry(user), null, TimeZoneInfo.Utc), "Fiche sans effet");
        Check.Equal(WriteErrors.NothingToDo, a.Code, "refus précis Comptes");
        Check.Equal(WriteErrors.NothingToDo, f.Code, "même refus Fiche");
        Check.False(AccountsRules.Actions(user, null).MustChange.Available, "action indisponible avec explication");
        Check.False(Sheet(user).Actions.Single(a => a.Id == "expirePassword").Available, "Fiche indisponible avant le clic");
    }

    [Test]
    public static void Changed_protection_is_checked_before_the_already_done_shortcut_on_both_screens()
    {
        var user = Fixtures.User("Camille");
        var a = Seal(AccountActivation.Draft(user, false, null, Fixtures.Domain, null, Fixtures.Now, TimeZoneInfo.Utc));
        var f = Seal(ObjectWrites.Enabled(Entry(user), false, null));
        Check.True(AccountActivation.Check(a, user, false).Current, "Comptes initial admissible");
        Check.True(ObjectWrites.Check(f, Entry(user), _ => false).Current, "Fiche initiale admissible");
        user = user with { AdminCount = 1, UserAccountControl = user.UserAccountControl | AdValues.AccountDisabled };
        Check.False(AccountActivation.Check(a, user, false).Current, "protection avant déjà fait Comptes");
        Check.False(ObjectWrites.Check(f, Entry(user), _ => false).Current, "protection avant déjà fait Fiche");
    }

    [Test]
    public static void A_zero_password_stamp_is_not_verified_when_the_obligation_became_ineffective()
    {
        var user = Fixtures.User("Camille");
        var a = Seal(AccountMustChangePassword.Draft(user, null, Fixtures.Now, TimeZoneInfo.Utc));
        var f = Seal(ObjectWrites.ExpirePassword(Entry(user), null, TimeZoneInfo.Utc));
        Check.True(AccountMustChangePassword.Check(a, user).Current, "Comptes initial admissible");
        Check.True(ObjectWrites.Check(f, Entry(user), _ => false).Current, "Fiche initiale admissible");
        user = user with { PasswordLastSet = 0, UserAccountControl = user.UserAccountControl | AdValues.DontExpirePassword };
        Check.False(AccountMustChangePassword.Check(a, user).Current, "aucun faux déjà fait Comptes");
        Check.False(ObjectWrites.Check(f, Entry(user), _ => false).Current, "aucun faux déjà fait Fiche");
        Check.Equal(VerificationState.Mismatch, AccountMustChangePassword.Verify(user, null).State, "Comptes ne confirme pas zéro seul");
        Check.Equal(VerificationState.Mismatch, ObjectWrites.Verify(f, Entry(user), _ => false).State, "Fiche ne confirme pas zéro seul");
    }

    [Test]
    public static async Task Both_simulated_screens_still_apply_valid_scalar_intents_and_verify_the_effect()
    {
        foreach (var fiche in new[] { false, true })
        {
            var source = Source();
            var user = Standard(source);
            var (stateWriter, disabled) = await Disable(source, user, fiche);
            Check.True((await stateWriter.CheckAsync(disabled, CancellationToken.None)).Current, "désactivation préparée");
            Check.Equal(WriteResult.Applied, (await stateWriter.ExecuteAsync(disabled, CancellationToken.None)).Result, "désactivation effective");
            Check.Equal(VerificationState.Verified, (await stateWriter.VerifyAsync(disabled, CancellationToken.None)).State, "désactivation relue");
            IWriteExecutor enable = fiche ? new SimulatedAccountEnabledExecutor(source) : new SimulatedAccountEnableExecutor(source);
            var enabled = Seal(fiche ? await ((SimulatedAccountEnabledExecutor)enable).PlanAsync(user.DistinguishedName, true, CancellationToken.None)
                : await ((SimulatedAccountEnableExecutor)enable).PlanAsync(user.DistinguishedName, CancellationToken.None));
            Check.Equal(WriteResult.Applied, (await enable.ExecuteAsync(enabled, CancellationToken.None)).Result, "réactivation effective");
            var (passwordWriter, password) = await Password(source, user, fiche);
            Check.True((await passwordWriter.CheckAsync(password, CancellationToken.None)).Current, "mot de passe préparé");
            Check.Equal(WriteResult.Applied, (await passwordWriter.ExecuteAsync(password, CancellationToken.None)).Result, "obligation effective");
            Check.Equal(VerificationState.Verified, (await passwordWriter.VerifyAsync(password, CancellationToken.None)).State, "obligation relue");
            Check.Equal(user.UserAccountControl, source.CurrentDirectory.Users.Single(u => u.ObjectGuid == user.ObjectGuid).UserAccountControl, "aucun autre bit modifié");
        }
    }

    [Test]
    public static async Task Both_simulated_screens_recheck_a_real_options_write_before_sending_an_old_password_plan()
    {
        foreach (var fiche in new[] { false, true })
        {
            var source = Source();
            var user = Standard(source);
            var (writer, plan) = await Password(source, user, fiche);
            Check.True((await writer.CheckAsync(plan, CancellationToken.None)).Current, "plan admissible avant le changement");
            var options = new SimulatedAccountOptionsExecutor(source);
            var change = Seal(await options.PlanAsync(user.DistinguishedName, new Dictionary<string, bool> { ["passwordNeverExpires"] = true }, FicheSecurityPolicy.Default, CancellationToken.None));
            Check.Equal(WriteResult.Applied, (await options.ExecuteAsync(change, CancellationToken.None)).Result, "vraie mutation concurrente de l’overlay");
            Check.Equal(VerificationState.Verified, (await options.VerifyAsync(change, CancellationToken.None)).State, "option relue");
            var version = source.Overlay.Version;
            var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, CancellationToken.None), "ancien plan envoyé directement");
            Check.Equal(WriteErrors.Stale, refusal.Code, "refus de précondition");
            Check.Equal(version, source.Overlay.Version, "aucune nouvelle mutation");
            Check.Equal(user.PasswordLastSet, source.CurrentDirectory.Users.Single(u => u.ObjectGuid == user.ObjectGuid).PasswordLastSet, "pwdLastSet conservé");
        }
    }

    [Test]
    public static async Task Both_simulated_screens_reject_a_disable_after_the_target_becomes_the_session_account()
    {
        foreach (var fiche in new[] { false, true })
        {
            var source = Source();
            var user = Standard(source);
            var (writer, plan) = await Disable(source, user, fiche);
            Check.True((await writer.CheckAsync(plan, CancellationToken.None)).Current, "plan admissible avant changement de session");
            using var password = PasswordSecrets.FromText("Fictif-2026!");
            var opened = await new SimulatedAccountsReader(source).OpenSessionAsync(new(source.CurrentDirectory.Domain.NetbiosName + "\\" + user.SamAccountName, CredentialRules.Directory, null), password, CancellationToken.None);
            Check.True(opened.Answer.Success, "session cible réellement ouverte");
            Check.Equal(user.DistinguishedName, source.CurrentSession.Account.Dn, "identité courante requalifiée");
            var version = source.Overlay.Version;
            var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, CancellationToken.None), "ancien plan envoyé directement");
            Check.Equal(WriteErrors.Stale, refusal.Code, "auto-désactivation refusée");
            Check.Equal(version, source.Overlay.Version, "aucune mutation");
            Check.False(AdValues.IsDisabled(source.CurrentDirectory.Users.Single(u => u.ObjectGuid == user.ObjectGuid).UserAccountControl), "session encore active");
        }
    }

    private static SimulatedDirectorySource Source() => new(SimulationOptions.Default with { Latency = SimulationLatency.None }, TestClock.Fixed());
    private static DirectoryUser Standard(SimulatedDirectorySource source) => source.CurrentDirectory.Users.First(u => u.AdminCount != 1
        && !AdValues.IsDisabled(u.UserAccountControl) && !AdValues.HasFlag(u.UserAccountControl, AdValues.DontExpirePassword)
        && (AccountsRules.AccountExpiry(u) is not { } expiry || expiry > source.Clock.GetUtcNow())
        && AccountState.ClassifyPassword(u, source.CurrentDirectory.Domain.PasswordPolicy.MaxPasswordAge, source.Clock.GetUtcNow(), TimeSpan.Zero) != PasswordClass.Expired
        && AccountsRules.LockOf(u) != AccountLock.Locked && u.PasswordLastSet is > 0 && !AccountsRules.HasRid(u, AccountsRules.KrbtgtRid)
        && !FicheValues.SameDn(u.DistinguishedName, source.CurrentSession.Account.Dn));
    private static WritePlan Seal(WritePlanDraft draft) => WritePlans.Seal(draft, WritePlans.NewId(), "TEST\\operateur", AppMode.Simulation, Fixtures.Now, TimeZoneInfo.Utc);
    private static async Task<(IWriteExecutor Writer, WritePlan Plan)> Disable(SimulatedDirectorySource source, DirectoryUser user, bool fiche)
    {
        if (fiche) { var writer = new SimulatedAccountEnabledExecutor(source); return (writer, Seal(await writer.PlanAsync(user.DistinguishedName, false, CancellationToken.None))); }
        var accounts = new SimulatedAccountDisableExecutor(source);
        return (accounts, Seal(await accounts.PlanAsync(user.DistinguishedName, null, CancellationToken.None)));
    }
    private static async Task<(IWriteExecutor Writer, WritePlan Plan)> Password(SimulatedDirectorySource source, DirectoryUser user, bool fiche)
    {
        if (fiche) { var writer = new SimulatedPasswordExpireExecutor(source); return (writer, Seal(await writer.PlanAsync(user.DistinguishedName, CancellationToken.None))); }
        var accounts = new SimulatedAccountMustChangePasswordExecutor(source);
        return (accounts, Seal(await accounts.PlanAsync(user.DistinguishedName, CancellationToken.None)));
    }
    private static FicheSheet Sheet(DirectoryUser user) => FicheSheets.Build(Entry(user), new FicheContext(
        "Simulation", Fixtures.Now, "dc.test.local", false, Fixtures.Now, TimeZoneInfo.Utc, Fixtures.Root,
        new Dictionary<string, FicheSummary>(), [], null, null, null, true, null,
        FicheDiagnostics.Interval(null, "notRead"), FicheSecurityPolicy.Default));
    private static FicheEntry Entry(DirectoryUser user) => FicheEntry.Create(FicheKind.User, user.ObjectGuid, user.DistinguishedName, user.Cn,
        new Dictionary<string, IEnumerable<string?>>
        {
            ["userAccountControl"] = [user.UserAccountControl.ToString(CultureInfo.InvariantCulture)],
            ["pwdLastSet"] = [user.PasswordLastSet?.ToString(CultureInfo.InvariantCulture)],
            ["adminCount"] = [user.AdminCount?.ToString(CultureInfo.InvariantCulture)],
            ["objectSid"] = [user.Sid], ["sAMAccountName"] = [user.SamAccountName],
        });
}
