using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static partial class AdAccountWriteTests
{
    [Test]
    public static async Task Accounts_protected_disable_is_refused_at_plan_and_again_at_direct_send()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var writer = new AdAccountDisableExecutor(source);
        var plan = Seal(await writer.PlanAsync(Dn, null, CancellationToken.None));
        Check.True((await writer.CheckAsync(plan, CancellationToken.None)).Current, "plan initial réellement admissible");
        ldap.Values["adminCount"] = ["1"];
        var refusedPlan = await Check.ThrowsAsync<DomeniaOperationException>(() => writer.PlanAsync(Dn, null, CancellationToken.None), "nouveau plan protégé");
        Check.Equal(AccountWrites.ProtectedAccount, refusedPlan.Code, "protection ferme");
        var refusedSend = await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, CancellationToken.None), "protection apparue après le plan");
        Check.Equal(WriteErrors.Stale, refusedSend.Code, "requalification avant Modify");
        Check.Equal(0, ldap.Writes, "aucun Modify");
        Check.Equal("512", (string)ldap.Values["userAccountControl"][0], "UAC intact");
    }

    [Test]
    public static async Task Accounts_forced_change_rechecks_never_expire_even_when_pwdLastSet_already_became_zero()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var writer = new AdAccountMustChangePasswordExecutor(source);
        var plan = Seal(await writer.PlanAsync(Dn, CancellationToken.None));
        Check.True((await writer.CheckAsync(plan, CancellationToken.None)).Current, "plan initial admissible");
        ldap.Values["userAccountControl"] = ["66048"]; ldap.Values["pwdLastSet"] = ["0"];
        var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, CancellationToken.None), "pas de faux déjà fait");
        Check.Equal(WriteErrors.Stale, refusal.Code, "état devenu incompatible");
        Check.Equal(VerificationState.Mismatch, (await writer.VerifyAsync(plan, CancellationToken.None)).State, "zéro ne prouve pas une obligation effective");
        Check.Equal(0, ldap.Writes, "aucun envoi");
    }

    [Test]
    public static async Task Accounts_critical_object_appearing_after_preview_blocks_the_direct_send()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var writer = new AdAccountMustChangePasswordExecutor(source);
        var plan = Seal(await writer.PlanAsync(Dn, CancellationToken.None));
        Check.True((await writer.CheckAsync(plan, CancellationToken.None)).Current, "avant protection");
        var before = (string)ldap.Values["pwdLastSet"][0];
        ldap.Values["isCriticalSystemObject"] = ["TRUE"];
        var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, CancellationToken.None), "attribut système relu");
        Check.Equal(FicheErrors.Protected, refusal.Code, "protection la plus stricte conservée");
        Check.Equal(0, ldap.Writes, "aucun envoi"); Check.Equal(before, (string)ldap.Values["pwdLastSet"][0], "mot de passe intact");
    }
}
