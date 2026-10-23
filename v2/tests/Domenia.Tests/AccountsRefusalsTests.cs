using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>
/// Refusals of the Comptes screen that the first tests did not cover (critique of the screen, tour 1): scope outside the
/// domain or unknown, krbtgt and the session account protected, typed name of a privileged account checked again on every
/// new plan, preconditions changed between the plan and the execution, directory mode without executor, lockout read refused
/// before any read for a SID that cannot filter the log. Written with the code, run at the very end in the VM.
/// </summary>
internal static class AccountsRefusalsTests
{
    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static async Task<JsonElement> ExecuteAsync(SimulatedBridge bridge, JsonElement planned, string? typedName = null) =>
        SimulatedBridge.Json(await bridge.CallAsync("write.execute", Args(new
        {
            planId = planned.GetProperty("plan").GetProperty("id").GetString(),
            token = planned.GetProperty("token").GetString(),
            typedName,
        })));

    private static async Task<BridgeResponse> ExecuteRawAsync(SimulatedBridge bridge, JsonElement planned, string? typedName = null) =>
        await bridge.CallAsync("write.execute", Args(new
        {
            planId = planned.GetProperty("plan").GetProperty("id").GetString(),
            token = planned.GetProperty("token").GetString(),
            typedName,
        }));

    private static DirectoryUser Ordinary(SimulatedBridge bridge, string ou) =>
        bridge.Source.CurrentDirectory.Users.First(u => u.DistinguishedName.Contains(ou, StringComparison.Ordinal) && !AdValues.IsDisabled(u.UserAccountControl)
            && u.AdminCount != 1 && u.PasswordLastSet is > 0 && !AdValues.HasFlag(u.UserAccountControl, AdValues.DontExpirePassword)
            && AccountsRules.LockOf(u) == AccountLock.Unlocked);

    [Test]
    public static async Task The_scope_of_the_section_refuses_another_domain_and_an_unknown_ou()
    {
        var bridge = new SimulatedBridge();
        var other = await bridge.CallAsync("accounts.scope.set", Args(new { dn = "OU=Postes,DC=autre,DC=com", subtree = true }));
        Check.Equal(DomeniaErrors.ScopeOutsideDomain, other.Error?.Code, "autre domaine");
        var unknown = await bridge.CallAsync("accounts.scope.set", Args(new { dn = "OU=Inexistante,DC=example,DC=local", subtree = false }));
        Check.Equal(DomeniaErrors.ScopeUnknown, unknown.Error?.Code, "OU inconnue de l’index local");
        var scope = SimulatedBridge.Json(await bridge.CallAsync("accounts.scope.get"));
        Check.Equal("working", scope.GetProperty("origin").GetString(), "rien n’a changé");
    }

    [Test]
    public static async Task Krbtgt_is_never_written_and_a_privileged_account_asks_for_its_name_on_every_plan()
    {
        var bridge = new SimulatedBridge();
        var users = bridge.Source.CurrentDirectory.Users;
        var krbtgt = users.First(u => u.SamAccountName == "krbtgt");
        var enable = await bridge.CallAsync("accounts.enable.plan", Args(new { dn = krbtgt.DistinguishedName }));
        Check.Equal(AccountWrites.ProtectedAccount, enable.Error?.Code, "krbtgt jamais écrit");
        var reset = await bridge.CallAsync("accounts.password.plan", Args(new { dn = krbtgt.DistinguishedName, password = "Vélo-Bleu-2026!", mustChange = false, unlock = false }));
        Check.Equal(AccountWrites.ProtectedAccount, reset.Error?.Code, "ni son mot de passe");
        var detail = SimulatedBridge.Json(await bridge.CallAsync("accounts.detail", Args(new { dn = krbtgt.DistinguishedName })));
        Check.False(detail.GetProperty("actions").GetProperty("expiration").GetProperty("available").GetBoolean(), "expiration grisée");
        Check.NotNull(detail.GetProperty("actions").GetProperty("expiration").GetProperty("reason").GetString(), "avec sa raison");

        var privileged = users.First(u => u.AdminCount == 1 && u.SamAccountName != "krbtgt" && !AdValues.IsDisabled(u.UserAccountControl)
            && u.SamAccountName != SimulationProfile.SessionLogin && u.PasswordLastSet is > 0
            && !AdValues.HasFlag(u.UserAccountControl, AdValues.DontExpirePassword));
        foreach (var operation in new[] { "accounts.mustChange.plan", "accounts.disable.plan" })
        {
            var planned = SimulatedBridge.Json(await bridge.CallAsync(operation, Args(new { dn = privileged.DistinguishedName })));
            var confirmation = planned.GetProperty("plan").GetProperty("confirmation");
            Check.True(confirmation.GetProperty("typedNameRequired").GetBoolean(), "saisie du nom exigée (" + operation + ")");
            Check.Equal(privileged.SamAccountName, confirmation.GetProperty("typedName").GetString(), "nom à saisir");
            var refused = await ExecuteRawAsync(bridge, planned, typedName: privileged.SamAccountName.ToUpperInvariant());
            Check.Equal(WriteErrors.ConfirmationMismatch, refused.Error?.Code, "casse comprise, revérifiée par le moteur");
            var again = await ExecuteRawAsync(bridge, planned, typedName: privileged.SamAccountName);
            Check.Equal(WriteErrors.TokenUsed, again.Error?.Code, "plan dépensé par le refus");
        }
        var plannedOk = SimulatedBridge.Json(await bridge.CallAsync("accounts.mustChange.plan", Args(new { dn = privileged.DistinguishedName })));
        Check.Equal("verified", (await ExecuteAsync(bridge, plannedOk, privileged.SamAccountName)).GetProperty("verification").GetString(), "nom exact : écrit et relu");
    }

    [Test]
    public static async Task A_plan_whose_target_changed_meanwhile_sends_nothing()
    {
        var bridge = new SimulatedBridge();
        var target = Ordinary(bridge, "OU=Finances,OU=Paris");

        // Forced change planned, then the password reset (without forced change) runs first: pwdLastSet changed.
        var must = SimulatedBridge.Json(await bridge.CallAsync("accounts.mustChange.plan", Args(new { dn = target.DistinguishedName })));
        var reset = SimulatedBridge.Json(await bridge.CallAsync("accounts.password.plan", Args(new { dn = target.DistinguishedName, password = "Vélo-Bleu-2026!", mustChange = false, unlock = false })));
        Check.Equal("verified", (await ExecuteAsync(bridge, reset)).GetProperty("verification").GetString(), "réinitialisation relue (pwdLastSet postérieur)");
        var staleMust = await ExecuteRawAsync(bridge, must);
        Check.Equal(WriteErrors.Stale, staleMust.Error?.Code, "changement imposé : pwdLastSet changé entre-temps");

        // A second reset planned before a forced change: its « before » no longer holds.
        var secondReset = SimulatedBridge.Json(await bridge.CallAsync("accounts.password.plan", Args(new { dn = target.DistinguishedName, password = "Autre-Vélo-2027!", mustChange = false, unlock = false })));
        var mustNow = SimulatedBridge.Json(await bridge.CallAsync("accounts.mustChange.plan", Args(new { dn = target.DistinguishedName })));
        Check.Equal("verified", (await ExecuteAsync(bridge, mustNow)).GetProperty("verification").GetString(), "changement imposé relu");
        Check.Equal(WriteErrors.Stale, (await ExecuteRawAsync(bridge, secondReset)).Error?.Code, "réinitialisation : pwdLastSet changé entre-temps");

        // Two expirations planned: the first one executed, the second one finds another day.
        var first = SimulatedBridge.Json(await bridge.CallAsync("accounts.expiration.plan", Args(new { dn = target.DistinguishedName, date = "2027-03-31" })));
        var second = SimulatedBridge.Json(await bridge.CallAsync("accounts.expiration.plan", Args(new { dn = target.DistinguishedName, date = "2027-06-30" })));
        Check.Equal("verified", (await ExecuteAsync(bridge, first)).GetProperty("verification").GetString(), "première expiration relue");
        Check.Equal(WriteErrors.Stale, (await ExecuteRawAsync(bridge, second)).Error?.Code, "expiration : jour changé entre-temps");
    }

    [Test]
    public static void Enable_and_disable_preconditions_compare_the_whole_account_control()
    {
        var user = Fixtures.User("Bob");
        var draft = AccountActivation.Draft(user, false, null, Fixtures.Domain, "DC1.test.local", Fixtures.Now, TestClock.Paris);
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\adm", AppMode.Directory, Fixtures.Now, TestClock.Paris);
        Check.True(AccountActivation.Check(plan, user, false).Current, "inchangé : valable");
        var changed = user with { UserAccountControl = AdValues.NormalAccount | AdValues.DontExpirePassword };
        Check.False(AccountActivation.Check(plan, changed, false).Current, "un autre bit a changé : rien n’est envoyé");
        Check.False(AccountActivation.Check(plan, null, false).Current, "compte disparu : rien n’est envoyé");
    }

    [Test]
    public static async Task Directory_mode_refuses_every_plan_of_the_screen_until_domenia_ad_exists()
    {
        var clock = TestClock.Fixed();
        var source = new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun");
        var decision = ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        using var context = new EngineContext(decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal());
        var registry = OperationModules.CreateRegistry(context, OperationModules.Discover([typeof(AccountsOperations).Assembly]));
        var sent = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(registry, sent.Add, AdmissionGuards.For(AppMode.Directory));
        const string Dn = "CN=Camille Bernard,OU=Lyon,DC=cnamts,DC=local";
        string[] calls =
        [
            Args(new { id = "e", op = "accounts.enable.plan", args = new { dn = Dn } }),
            Args(new { id = "d", op = "accounts.disable.plan", args = new { dn = Dn } }),
            Args(new { id = "m", op = "accounts.mustChange.plan", args = new { dn = Dn } }),
            Args(new { id = "x", op = "accounts.expiration.plan", args = new { dn = Dn, date = "2027-01-31" } }),
            Args(new { id = "p", op = "accounts.password.plan", args = new { dn = Dn, generate = false, mustChange = true, unlock = false } }),
            Args(new { id = "l", op = "accounts.list", args = new { } }),
            Args(new { id = "b", op = "accounts.batch.preview", args = new { action = "unlock", dns = new[] { Dn } } }),
        ];
        foreach (var call in calls)
        {
            await dispatcher.HandleAsync(call, CancellationToken.None);
            Check.Equal(DomeniaErrors.SourceUnavailable, sent[^1].Error?.Code, "aucun lecteur ni exécuteur tant que Domenia.Ad n’est pas branché : " + sent[^1].Operation);
        }
        Check.True(registry.TryGet("accounts.batch.plan", out var plan) && plan.Class == OperationClass.NetworkRead, "plan d’un lot : lecture du contrôleur en mode annuaire");
        Check.True(registry.TryGet("accounts.connection.switch", out var change) && change.Class == OperationClass.NetworkRead, "changer de compte : une validation réseau");
        await dispatcher.HandleAsync(Args(new { id = "s", op = "accounts.access.state", args = new { } }), CancellationToken.None);
        var state = JsonSerializer.SerializeToElement(sent[^1].Data, BridgeJson.Options);
        Check.False(state.GetProperty("connection").GetProperty("relogin").GetProperty("available").GetBoolean(), "changer de compte indisponible sans Domenia.Ad, avec sa raison");
    }

    [Test]
    public static void Lockouts_need_a_domain_sid_before_any_read()
    {
        Check.True(AccountsRules.IsDomainSid("S-1-5-21-1111111111-2222222222-3333333333-1105"), "SID de domaine");
        Check.False(AccountsRules.IsDomainSid("S-1-5-32-544"), "groupe intégré");
        Check.False(AccountsRules.IsDomainSid(null), "SID absent");
        Check.False(AccountsRules.IsDomainSid("S-1-5-21-1-2-3"), "sans RID");
        Check.False(AccountsRules.IsDomainSid("S-1-5-21-1-2-3-x"), "illisible");
    }
}
