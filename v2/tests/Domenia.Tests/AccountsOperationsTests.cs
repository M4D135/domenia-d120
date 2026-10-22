using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>Operations of the Comptes screen through the real bridge in simulation (docs/ops/comptes.md).</summary>
internal static class AccountsOperationsTests
{
    private const string People = "OU=Utilisateurs,DC=example,DC=local";
    private const string StrongPassword = "Vélo-Bleu-2026!";

    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static string[] Names(JsonElement element) => [.. element.EnumerateObject().Select(p => p.Name)];

    private static DirectoryUser User(SimulatedBridge bridge, string displayName) =>
        bridge.Source.CurrentDirectory.Users.First(u => u.DisplayName == displayName);

    private static async Task<JsonElement> ScopeToPeopleAsync(SimulatedBridge bridge) =>
        SimulatedBridge.Json(await bridge.CallAsync("accounts.scope.set", Args(new { dn = People, subtree = true })));

    private static async Task<JsonElement> ExecuteAsync(SimulatedBridge bridge, JsonElement planned, string? typedName = null) =>
        SimulatedBridge.Json(await bridge.CallAsync("write.execute", Args(new
        {
            planId = planned.GetProperty("plan").GetProperty("id").GetString(),
            token = planned.GetProperty("token").GetString(),
            typedName,
        })));

    [Test]
    public static async Task The_list_starts_on_the_working_ou_and_proposes_the_ous_that_hold_accounts()
    {
        var bridge = new SimulatedBridge();
        var list = SimulatedBridge.Json(await bridge.CallAsync("accounts.list"));
        Check.True(Names(list).SequenceEqual(["scope", "tooWide", "readAt", "controller", "simulated", "policy", "counts", "rows", "truncated", "limit", "suggestions"]), "forme\u00A0: " + string.Join(",", Names(list)));
        Check.Equal("working", list.GetProperty("scope").GetProperty("origin").GetString(), "OU de travail par défaut");
        Check.Equal(0, list.GetProperty("rows").GetArrayLength(), "l’OU Postes ne contient aucun utilisateur");
        Check.True(list.GetProperty("suggestions").EnumerateArray().Any(s => s.GetProperty("name").GetString() == "Utilisateurs"), "Utilisateurs proposée");
    }

    [Test]
    public static async Task The_section_scope_is_an_ou_never_the_whole_domain()
    {
        var bridge = new SimulatedBridge();
        var root = await bridge.CallAsync("accounts.scope.set", Args(new { dn = "DC=example,DC=local", subtree = true }));
        Check.Equal("scope.tooWide", root.Error?.Code, "racine refusée");
        var scope = await ScopeToPeopleAsync(bridge);
        Check.Equal("section", scope.GetProperty("origin").GetString(), "choix de la section");
        var list = SimulatedBridge.Json(await bridge.CallAsync("accounts.list"));
        var counts = list.GetProperty("counts");
        Check.Equal(1236, counts.GetProperty("total").GetInt32(), "personnes de l’OU Utilisateurs");
        Check.Equal(7, counts.GetProperty("locked").GetInt32(), "verrouillés exacts");
        Check.Equal(2, counts.GetProperty("lockExpired").GetInt32(), "verrouillages échus");
        Check.True(list.GetProperty("rows").EnumerateArray().All(r => r.GetProperty("dn").GetString()!.EndsWith(People, StringComparison.OrdinalIgnoreCase)), "aucun compte hors périmètre");
        var reset = SimulatedBridge.Json(await bridge.CallAsync("accounts.scope.reset"));
        Check.Equal("working", reset.GetProperty("origin").GetString(), "retour à l’OU de travail");
    }

    [Test]
    public static async Task Detail_of_a_locked_account_shows_the_support_band_and_its_actions()
    {
        var bridge = new SimulatedBridge();
        var camille = User(bridge, "Camille Bernard");
        var detail = SimulatedBridge.Json(await bridge.CallAsync("accounts.detail", Args(new { dn = camille.DistinguishedName })));
        Check.Equal("locked", detail.GetProperty("account").GetProperty("lock").GetString(), "verrouillée");
        Check.Equal("alert", detail.GetProperty("band").GetProperty("tone").GetString(), "bandeau en alerte");
        Check.True(detail.GetProperty("actions").GetProperty("unlock").GetProperty("available").GetBoolean(), "déverrouillage proposé");
        var unknown = await bridge.CallAsync("accounts.detail", Args(new { dn = "CN=Personne,OU=Utilisateurs,DC=example,DC=local" }));
        Check.Equal(AccountsRules.UnknownAccount, unknown.Error?.Code, "compte inconnu");
    }

    [Test]
    public static async Task Lockouts_are_read_on_the_pdc_for_the_account_only()
    {
        var bridge = new SimulatedBridge();
        var camille = User(bridge, "Camille Bernard");
        var report = SimulatedBridge.Json(await bridge.CallAsync("accounts.lockouts", Args(new { dn = camille.DistinguishedName, hours = 168 })));
        Check.Equal("read", report.GetProperty("state").GetString(), "journal lu");
        Check.Equal("pdc", report.GetProperty("serverSource").GetString(), "émulateur PDC");
        Check.True(report.GetProperty("events").GetArrayLength() >= 1, "au moins le dernier verrouillage");
        Check.True(report.GetProperty("simulated").GetBoolean(), "données fictives dites");
        var again = SimulatedBridge.Json(await bridge.CallAsync("accounts.lockouts", Args(new { dn = camille.DistinguishedName, hours = 168 })));
        Check.Equal(report.GetProperty("events").GetRawText(), again.GetProperty("events").GetRawText(), "déterministe");
        var wrong = await bridge.CallAsync("accounts.lockouts", Args(new { dn = camille.DistinguishedName, hours = 9999 }));
        Check.Equal("arguments.invalid", wrong.Error?.Code, "fenêtre bornée");
    }

    [Test]
    public static async Task Disable_then_enable_run_once_each_on_the_overlay()
    {
        var bridge = new SimulatedBridge();
        var target = bridge.Source.CurrentDirectory.Users.First(u => u.DistinguishedName.Contains("OU=Logistique,OU=Lyon", StringComparison.Ordinal) && !AdValues.IsDisabled(u.UserAccountControl) && u.AdminCount != 1);
        var planned = SimulatedBridge.Json(await bridge.CallAsync("accounts.disable.plan", Args(new { dn = target.DistinguishedName })));
        Check.Equal(AccountActivation.DisableKind, planned.GetProperty("plan").GetProperty("kind").GetString(), "type");
        var receipt = await ExecuteAsync(bridge, planned);
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "appliquée");
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "vérifiée");
        Check.True(AdValues.IsDisabled(User(bridge, target.DisplayName!).UserAccountControl), "surcouche à jour");
        var again = await bridge.CallAsync("accounts.disable.plan", Args(new { dn = target.DistinguishedName }));
        Check.Equal(WriteErrors.NothingToDo, again.Error?.Code, "déjà désactivé");
        var enable = SimulatedBridge.Json(await bridge.CallAsync("accounts.enable.plan", Args(new { dn = target.DistinguishedName })));
        Check.Equal("verified", (await ExecuteAsync(bridge, enable)).GetProperty("verification").GetString(), "réactivé et relu");
        var self = await bridge.CallAsync("accounts.disable.plan", Args(new { dn = bridge.Source.CurrentDirectory.Users.First(u => u.SamAccountName == SimulationProfile.SessionLogin).DistinguishedName }));
        Check.Equal(AccountWrites.ProtectedAccount, self.Error?.Code, "jamais le compte de session");
    }

    [Test]
    public static async Task Password_reset_keeps_the_secret_out_of_plans_receipts_and_journals()
    {
        var bridge = new SimulatedBridge();
        var camille = User(bridge, "Camille Bernard");
        var weak = await bridge.CallAsync("accounts.password.plan", Args(new { dn = camille.DistinguishedName, password = "court", mustChange = true, unlock = true }));
        Check.Equal(AccountPasswordReset.PolicyRefused, weak.Error?.Code, "stratégie du domaine");
        var planned = SimulatedBridge.Json(await bridge.CallAsync("accounts.password.plan", Args(new { dn = camille.DistinguishedName, password = StrongPassword, mustChange = true, unlock = true })));
        Check.False(planned.GetRawText().Contains(StrongPassword, StringComparison.Ordinal), "le plan ne contient jamais le mot de passe");
        var receipt = await ExecuteAsync(bridge, planned);
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "relecture conforme");
        Check.False(receipt.GetRawText().Contains(StrongPassword, StringComparison.Ordinal), "le reçu non plus");
        Check.False(bridge.Log.Lines.Any(l => l.Contains(StrongPassword, StringComparison.Ordinal)), "ni le journal technique");
        var after = User(bridge, "Camille Bernard");
        Check.Equal(0L, after.PasswordLastSet, "changement exigé");
        Check.Equal(0L, after.LockoutTime, "déverrouillée dans la même écriture");
        var replay = await bridge.CallAsync("write.execute", Args(new { planId = planned.GetProperty("plan").GetProperty("id").GetString(), token = planned.GetProperty("token").GetString(), typedName = (string?)null }));
        Check.Equal(WriteErrors.TokenUsed, replay.Error?.Code, "jamais rejouée");
    }

    [Test]
    public static async Task Forced_change_and_expiration_plans_go_through_the_circuit()
    {
        var bridge = new SimulatedBridge();
        var target = bridge.Source.CurrentDirectory.Users.First(u => u.DistinguishedName.Contains("OU=Finances,OU=Paris", StringComparison.Ordinal) && u.PasswordLastSet is > 0
            && !AdValues.HasFlag(u.UserAccountControl, AdValues.DontExpirePassword) && u.AdminCount != 1);
        var must = SimulatedBridge.Json(await bridge.CallAsync("accounts.mustChange.plan", Args(new { dn = target.DistinguishedName })));
        Check.Equal("verified", (await ExecuteAsync(bridge, must)).GetProperty("verification").GetString(), "pwdLastSet relu à 0");
        var expiration = SimulatedBridge.Json(await bridge.CallAsync("accounts.expiration.plan", Args(new { dn = target.DistinguishedName, date = "2027-01-31" })));
        Check.Equal(AccountExpiration.Kind, expiration.GetProperty("plan").GetProperty("kind").GetString(), "type");
        Check.Equal("verified", (await ExecuteAsync(bridge, expiration)).GetProperty("verification").GetString(), "date relue par jour local");
        var missing = await bridge.CallAsync("accounts.expiration.plan", Args(new { dn = target.DistinguishedName }));
        Check.Equal("arguments.invalid", missing.Error?.Code, "date obligatoire (ou null)");
        var never = SimulatedBridge.Json(await bridge.CallAsync("accounts.expiration.plan", Args(new { dn = target.DistinguishedName, date = (string?)null })));
        Check.Contains("Supprimer", never.GetProperty("plan").GetProperty("title").GetString(), "suppression de l’expiration");
    }

    [Test]
    public static async Task Batch_preview_reads_the_candidates_and_writes_nothing()
    {
        var bridge = new SimulatedBridge();
        var locked = bridge.Source.CurrentDirectory.Users.Where(u => AccountsRules.LockOf(u) == AccountLock.Locked).Select(u => u.DistinguishedName).ToArray();
        var preview = SimulatedBridge.Json(await bridge.CallAsync("accounts.batch.preview", Args(new { action = "unlock", dns = locked })));
        Check.Equal(locked.Length, preview.GetProperty("count").GetInt32() + preview.GetProperty("excludedCount").GetInt32(), "chaque candidat est cible ou exclu");
        Check.Equal("typed", preview.GetProperty("confirmation").GetString(), "saisie du nombre");
        Check.Equal("accounts.unlock.plan", preview.GetProperty("planOperation").GetString(), "un plan par cible");
        Check.True(bridge.Source.CurrentDirectory.Users.Count(u => AccountsRules.LockOf(u) == AccountLock.Locked) == locked.Length, "rien n’est écrit");
        var bad = await bridge.CallAsync("accounts.batch.preview", Args(new { action = "delete", dns = locked }));
        Check.Equal("arguments.invalid", bad.Error?.Code, "action inconnue");
        var date = await bridge.CallAsync("accounts.batch.preview", Args(new { action = "unlock", dns = locked, date = "2027-01-01" }));
        Check.Equal("arguments.invalid", date.Error?.Code, "date seulement pour l’expiration");
    }

    [Test]
    public static async Task Access_state_lists_names_only_and_a_seeded_refusal_can_be_recovered()
    {
        var bridge = new SimulatedBridge();
        var state = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.state"));
        Check.Equal(@"EXAMPLE\" + SimulationProfile.SessionLogin, state.GetProperty("connection").GetProperty("identity").GetString(), "compte de connexion");
        Check.False(state.GetProperty("connection").GetProperty("correction").GetProperty("available").GetBoolean(), "rien à corriger en simulation");
        var pending = state.GetProperty("pending");
        Check.Equal(1, pending.GetArrayLength(), "un accès refusé fictif");
        var id = pending[0].GetProperty("id").GetString();
        var local = await bridge.CallAsync("accounts.access.recover", Args(new { id, login = @".\administrateur", password = "x", lease = "inactivity", minutes = 30, target = (string?)null }));
        Check.Equal(AccountAccess.ContextRefused, local.Error?.Code, "compte local refusé pour LAPS avant tout essai");
        var recovered = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.recover", Args(new { id, login = @"EXAMPLE\adm-j.martin", password = "secret-du-test", lease = "inactivity", minutes = 30, target = (string?)null })));
        Check.True(recovered.GetProperty("result").GetProperty("success").GetBoolean(), "compte validé");
        Check.Equal(0, recovered.GetProperty("state").GetProperty("pending").GetArrayLength(), "accès traité");
        Check.False(recovered.GetRawText().Contains("secret-du-test", StringComparison.Ordinal), "aucun mot de passe renvoyé");
        Check.True(recovered.GetProperty("state").GetProperty("memory").EnumerateArray().Any(m => m.GetProperty("account").GetString() == @"EXAMPLE\adm-j.martin"), "compte temporaire en mémoire");
        var forgotten = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.forgetAll"));
        Check.Equal(0, forgotten.GetProperty("memory").GetArrayLength(), "tout oublié");
    }

    [Test]
    public static async Task Secondary_accounts_are_validated_then_activated_and_their_name_remembered()
    {
        var bridge = new SimulatedBridge();
        var unknown = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.test", Args(new { usage = "remote", login = @"EXAMPLE\personne", password = "x" })));
        Check.False(unknown.GetProperty("success").GetBoolean(), "compte inconnu");
        Check.Equal("unknownAccount", unknown.GetProperty("kind").GetString(), "raison");
        var change = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.activate", Args(new { usage = "remote", login = @"EXAMPLE\adm-j.martin", password = "secret-du-test" })));
        Check.True(change.GetProperty("result").GetProperty("success").GetBoolean(), "validé");
        var remote = change.GetProperty("state").GetProperty("remote");
        Check.True(remote.GetProperty("active").GetBoolean(), "actif");
        Check.Equal(@"EXAMPLE\adm-j.martin", remote.GetProperty("remembered").GetProperty("account").GetString(), "identifiant mémorisé");
        Check.False(bridge.Log.Lines.Any(l => l.Contains("secret-du-test", StringComparison.Ordinal)), "aucun secret journalisé");
        var trial = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.tryRemote", Args(new { computer = "PC-PAR-0001" })));
        Check.Equal(@"EXAMPLE\adm-j.martin", trial.GetProperty("account").GetString(), "essai avec le compte Postes");
        var cleared = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.clear", Args(new { usage = "remote" })));
        Check.False(cleared.GetProperty("remote").GetProperty("active").GetBoolean(), "effacé");
    }

    [Test]
    public static async Task Requirements_and_transports_are_local_references()
    {
        var bridge = new SimulatedBridge();
        var requirements = SimulatedBridge.Json(await bridge.CallAsync("accounts.requirements"));
        Check.True(requirements.GetProperty("rows").GetArrayLength() > 100, "table complète");
        var transports = SimulatedBridge.Json(await bridge.CallAsync("accounts.transports"));
        Check.Equal(7, transports.GetProperty("rows").GetArrayLength(), "sept transports");
        Check.True(bridge.Registry.TryGet("accounts.requirements", out var definition) && definition.Class == OperationClass.Local, "lecture locale");
        Check.True(bridge.Registry.TryGet("accounts.lockouts", out var lockouts) && lockouts.Class == OperationClass.NetworkRead && lockouts.ServedInSimulation, "journal\u00A0: lecture réseau servie en simulation");
        Check.True(bridge.Registry.Names.Where(n => n.StartsWith("accounts.", StringComparison.Ordinal)).All(n => bridge.Registry.TryGet(n, out var d) && d.Class != OperationClass.Write), "aucune écriture déclarée par l’écran");
    }
}
