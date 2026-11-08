using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static partial class AdFicheWriteTests
{
    [Test]
    public static async Task Fiche_forced_change_refuses_never_expire_at_preview_and_rechecks_before_send()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        var writer = new AdPasswordExpireExecutor(source);
        var plan = Seal(await writer.PlanAsync(Dn, CancellationToken.None));
        Check.True((await writer.CheckAsync(plan, CancellationToken.None)).Current, "plan initial admissible");
        var before = (string)ldap.Objects[Dn]["pwdLastSet"][0];
        ldap.Objects[Dn]["userAccountControl"] = ["66048"];
        var preview = await Check.ThrowsAsync<DomeniaOperationException>(() => writer.PlanAsync(Dn, CancellationToken.None), "pas de plan sans effet");
        Check.Equal(WriteErrors.NothingToDo, preview.Code, "même refus que Comptes");
        var send = await Check.ThrowsAsync<DomeniaOperationException>(() => writer.ExecuteAsync(plan, CancellationToken.None), "ancienne confirmation caduque");
        Check.Equal(WriteErrors.Stale, send.Code, "relecture avant Modify");
        Check.Equal(before, (string)ldap.Objects[Dn]["pwdLastSet"][0], "valeur initiale conservée");
        ldap.Objects[Dn]["pwdLastSet"] = ["0"];
        Check.Equal(VerificationState.Mismatch, (await writer.VerifyAsync(plan, CancellationToken.None)).State, "aucun faux succès même avec zéro");
        Check.Equal(0, ldap.Writes, "aucun envoi");
    }

    [Test]
    public static async Task Fiche_protected_reactivation_keeps_the_stronger_typed_confirmation()
    {
        using var ldap = new Connection(); using var source = Source(ldap);
        ldap.Objects[Dn]["userAccountControl"] = ["514"]; ldap.Objects[Dn]["adminCount"] = ["1"];
        var writer = new AdAccountEnabledExecutor(source);
        var plan = Seal(await writer.PlanAsync(Dn, true, CancellationToken.None));
        Check.True(plan.Confirmation.TypedNameRequired, "confirmation forte conservée");
        Check.Equal("compte", plan.Confirmation.TypedName, "identité du compte");
        Check.True((await writer.CheckAsync(plan, CancellationToken.None)).Current, "le plan fort reste exécutable");
        Check.Equal(WriteResult.Applied, (await writer.ExecuteAsync(plan, CancellationToken.None)).Result, "réactivation admise");
        Check.Equal("512", (string)ldap.Objects[Dn]["userAccountControl"][0], "seul ACCOUNTDISABLE retiré");
        Check.Equal(1, ldap.Writes, "un seul envoi");
    }
}
