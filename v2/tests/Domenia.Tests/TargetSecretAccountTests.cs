using Domenia.Ad;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class TargetSecretAccountTests
{
    private const string Admin = @"EXAMPLE\adm-j.martin";

    private static async Task<(SimulatedBridge Bridge, AccountAccess Access, string First, string Second)> Fixture()
    {
        var bridge = new SimulatedBridge(); var access = AccountAccess.From(bridge.Context);
        await access.OverviewAsync(CancellationToken.None);
        var root = (await bridge.Context.Directory.GetSessionAsync(CancellationToken.None)).Domain!.RootDn!;
        return (bridge, access, "CN=PC1,OU=Postes," + root, "CN=PC2,OU=Postes," + root);
    }
    private static async Task<string> Pending(AccountAccess access, string scope, string dn)
    {
        access.RegisterRefusal(scope, "Lecture secrète", dn, "accessDenied", null, true);
        return (await access.OverviewAsync(CancellationToken.None)).Pending.First(p => p.Scope == scope && p.Target == dn).Id;
    }
    private static async Task Recover(AccountAccess access, string scope, string dn)
    {
        var id = await Pending(access, scope, dn); using var password = PasswordSecrets.FromText("target-secret-fixture!");
        Check.True((await access.RecoverAsync(id, Admin, password, LeaseMode.Inactivity, 30, dn, CancellationToken.None, targetOnly: true)).Result.Success, "compte de domaine validé");
    }

    [Test]
    public static async Task Targeted_secret_account_is_used_only_for_its_DN_and_resource_and_leaves_other_requests_pending()
    {
        var (bridge, access, first, second) = await Fixture(); using var owner = bridge.Context;
        var pendingSecond = await Pending(access, CredentialRules.Laps, second);
        var pendingOther = await Pending(access, CredentialRules.BitLocker, first);
        await Recover(access, CredentialRules.Laps, first);
        using var selected = await access.AcquireDirectoryReadAsync(CredentialRules.Laps, first.ToLowerInvariant(), CancellationToken.None);
        using var otherPoste = await access.AcquireDirectoryReadAsync(CredentialRules.Laps, second, CancellationToken.None);
        using var otherResource = await access.AcquireDirectoryReadAsync(CredentialRules.BitLocker, first, CancellationToken.None);
        Check.Equal(Admin, selected.Account, "même DN normalisé");
        Check.False(otherPoste.Account == Admin, "autre poste sans ce compte"); Check.False(otherResource.Account == Admin, "autre ressource sans ce compte");
        var state = await access.OverviewAsync(CancellationToken.None);
        Check.True(state.Pending.Any(p => p.Id == pendingSecond) && state.Pending.Any(p => p.Id == pendingOther), "demandes étrangères conservées");
        Check.True(state.Memory.Any(m => m.Resource.Contains("PC1", StringComparison.Ordinal) && m.Account == Admin), "compte ciblé visible et oubliable");
    }

    [Test]
    public static async Task Targeted_secret_account_can_be_forgotten_and_a_new_Secrets_account_replaces_targeted_leases()
    {
        var (bridge, access, first, second) = await Fixture(); using var owner = bridge.Context;
        await Recover(access, CredentialRules.Laps, first);
        var key = "temporary:" + CredentialRules.SecretTargetKey(CredentialRules.Laps, first);
        await access.ForgetAsync(key, CancellationToken.None);
        using (var current = await access.AcquireDirectoryReadAsync(CredentialRules.Laps, first, CancellationToken.None))
        { Check.False(current.Account == Admin, "compte ciblé retiré"); }
        await Recover(access, CredentialRules.Laps, first); await Recover(access, CredentialRules.BitLocker, second);
        using var password = PasswordSecrets.FromText("target-secondary-fixture!");
        Check.True((await access.ActivateAsync(AccessUsage.Secrets, Admin, password, CancellationToken.None)).Result.Success, "choix global explicite");
        var state = await access.OverviewAsync(CancellationToken.None);
        Check.False(state.Memory.Any(m => m.Key.StartsWith("temporary:" + CredentialRules.Laps + "|", StringComparison.Ordinal)
            || m.Key.StartsWith("temporary:" + CredentialRules.BitLocker + "|", StringComparison.Ordinal)), "anciens choix ciblés remplacés");
    }

    [Test]
    public static async Task Targeted_secret_recovery_refuses_another_target_before_activation()
    {
        var (bridge, access, first, second) = await Fixture(); using var owner = bridge.Context;
        var id = await Pending(access, CredentialRules.Laps, first); using var password = PasswordSecrets.FromText("target-wrong-fixture!");
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => access.RecoverAsync(id, Admin, password, LeaseMode.Inactivity, 30, second, CancellationToken.None, targetOnly: true), "autre DN refusé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, error.Code, "demande non élargie");
        Check.True((await access.OverviewAsync(CancellationToken.None)).Pending.Any(p => p.Id == id), "demande initiale intacte");
    }

    [Test]
    public static async Task An_authentication_rejection_pauses_the_selected_target_account_without_trying_the_default_account()
    {
        var (bridge, access, first, _) = await Fixture(); using var owner = bridge.Context;
        await Recover(access, CredentialRules.Laps, first);
        using var selected = await access.AcquireDirectoryReadAsync(CredentialRules.Laps, first, CancellationToken.None);
        access.RegisterRefusal(CredentialRules.Laps, "Lecture LAPS", first, "badCredentials", selected.AccountKey, true);
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => access.AcquireDirectoryReadAsync(CredentialRules.Laps, first, CancellationToken.None), "pas d’essai suivant");
        Check.Equal(MachineErrors.AccountPaused, error.Code, "pause du compte ciblé");
        using var ordinary = await access.AcquireDirectoryReadAsync(CredentialRules.BitLocker, first, CancellationToken.None);
        Check.False(ordinary.Account == Admin, "compte distinct inchangé pour l’autre ressource");
    }

    [Test]
    public static async Task Native_secret_account_request_requires_the_host_before_any_LDAP_contact()
    {
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap);
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => new AdPosteReader(source).UseOtherAccountAsync("CN=PC1," + Fixtures.Postes, "laps", CancellationToken.None), "pas de fenêtre native");
        Check.Equal(Domenia.Core.Poste.PosteErrors.HostUnavailable, error.Code, "précondition de l’hôte"); Check.Equal(0, ldap.Calls, "aucun contact");
    }
}
