using System.Security;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>
/// Accounts Domenia works with (Domenia 1 CPT-001 to CPT-021, docs/ops/comptes.md § 5): pauses by account key, forgetting with
/// the refusals tied to it, remembered identifiers per usage, « Changer de compte », refusals while a write or a validation
/// runs, configuration of Domenia.config.json. Written with the code, run at the very end in the VM (decision of 21/10).
/// </summary>
internal static class AccountsAccessTests
{
    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static JsonElement Row(JsonElement state, string resourceKey) =>
        state.GetProperty("inUse").EnumerateArray().First(r => r.GetProperty("resourceKey").GetString() == resourceKey);

    private static bool Paused(JsonElement row) => row.GetProperty("state").GetString()!.StartsWith("En pause", StringComparison.Ordinal);

    private static DirectoryComputer Answering(SimulatedBridge bridge) =>
        bridge.Source.CurrentDirectory.Computers.First(c => !AdValues.IsDisabled(c.UserAccountControl)
            && c.DistinguishedName.Contains("OU=Postes", StringComparison.OrdinalIgnoreCase)
            && !bridge.Source.World.Presence.NeverAnswer.Contains(c.ObjectGuid));

    private static AccountAccess Access(SimulatedBridge bridge, Func<CancellationToken, Task<int>>? pendingWrites = null) =>
        pendingWrites is null
            ? AccountAccess.From(bridge.Context)
            : new AccountAccess(bridge.Source, bridge.Context.Readers.Find<IAccountsAccessReader>(), new MemoryPreferenceStore(), new OperationJournal(), bridge.Clock, new RecordingJournal(), AppMode.Simulation, pendingWrites);

    private static SecureString Secret(string text) => PasswordSecrets.FromText(text);

    [Test]
    public static async Task A_refused_authentication_pauses_the_account_on_every_resource_that_uses_it()
    {
        var bridge = new SimulatedBridge();
        var access = Access(bridge);
        var before = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.state"));
        Check.False(Paused(Row(before, CredentialRules.Directory)), "aucune pause au départ (le refus fictif est un droit refusé)");
        // A BitLocker read refused for its credentials: the account it used is the session account (no Secrets account).
        access.RegisterRefusal(CredentialRules.BitLocker, "Lecture de la clé BitLocker", null, "badCredentials", null, interactive: true);
        var state = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.state"));
        Check.True(Paused(Row(state, CredentialRules.BitLocker)), "BitLocker en pause");
        Check.True(Paused(Row(state, CredentialRules.Directory)), "même compte : l’annuaire est en pause aussi (clé de compte, Domenia 1)");
        Check.True(Paused(Row(state, CredentialRules.Laps)), "LAPS utilise le même compte");
        Check.Contains("compte en pause", state.GetProperty("summary").GetString(), "résumé");
        Check.True(access.Refusals().Length >= 1, "refus gardé pour le diagnostic des verrouillages");
        var revision = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.revision"));
        Check.Equal(1, revision.GetProperty("paused").GetInt32(), "un compte en pause");
        Check.True(revision.GetProperty("pending").GetInt32() >= 2, "accès à revoir comptés (LAPS fictif, BitLocker)");
        Check.NotNull(revision.GetProperty("oldestPendingId").GetString(), "la plus ancienne demande pour la pastille");
    }

    [Test]
    public static async Task Forgetting_a_temporary_account_clears_the_refusals_tied_to_it()
    {
        var bridge = new SimulatedBridge();
        var access = Access(bridge);
        var state = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.state"));
        var id = state.GetProperty("pending")[0].GetProperty("id").GetString();
        var recovered = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.recover", Args(new { id, login = @"EXAMPLE\adm-s.leroy", password = "essai", lease = "inactivity", minutes = 30, target = (string?)null })));
        Check.True(recovered.GetProperty("result").GetProperty("success").GetBoolean(), "compte temporaire LAPS");
        // The temporary account is refused in turn: LAPS is paused.
        access.RegisterRefusal(CredentialRules.Laps, "Lecture du mot de passe LAPS", null, "badCredentials", null, interactive: false);
        var paused = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.state"));
        Check.True(Paused(Row(paused, CredentialRules.Laps)), "LAPS en pause après le refus du compte temporaire");
        Check.False(Paused(Row(paused, CredentialRules.Directory)), "l’annuaire garde son compte, sans pause");
        var forgotten = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.forget", Args(new { key = "temporary:" + CredentialRules.Laps })));
        Check.False(Paused(Row(forgotten, CredentialRules.Laps)), "Oublier efface les refus liés (CPT-011)");
        Check.Equal(@"EXAMPLE\" + SimulationProfile.SessionLogin, Row(forgotten, CredentialRules.Laps).GetProperty("account").GetString(), "retour au compte configuré");
        var again = await bridge.CallAsync("accounts.access.forget", Args(new { key = "temporary:" + CredentialRules.Laps }));
        Check.Equal(AccountAccess.KeyUnknown, again.Error?.Code, "plus rien à oublier");
    }

    [Test]
    public static async Task Remembered_identifiers_are_kept_per_usage_and_a_local_account_never_prefills_the_postes_account()
    {
        var bridge = new SimulatedBridge();
        var access = Access(bridge);
        var state = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.state"));
        var laps = state.GetProperty("pending")[0].GetProperty("id").GetString();
        _ = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.recover", Args(new { id = laps, login = @"EXAMPLE\adm-j.martin", password = "essai", lease = "once", minutes = 30, target = (string?)null })));
        var afterLaps = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.state"));
        Check.Equal(@"EXAMPLE\adm-j.martin", afterLaps.GetProperty("secrets").GetProperty("remembered").GetProperty("account").GetString(), "mémorisé sous LAPS, relu pour le compte Secrets");
        var computer = Answering(bridge);
        access.RegisterRefusal(CredentialRules.Remote, "Inventaire du poste", computer.Name, "accessDenied", null, interactive: true);
        var pending = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.state")).GetProperty("pending").EnumerateArray().First(p => p.GetProperty("scope").GetString() == CredentialRules.Remote);
        var local = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.recover", Args(new
        {
            id = pending.GetProperty("id").GetString(),
            login = computer.Name + @"\administrateur",
            password = "essai-local",
            lease = "inactivity",
            minutes = 15,
            target = computer.Name,
        })));
        Check.True(local.GetProperty("result").GetProperty("success").GetBoolean(), "compte local validé pour son poste");
        Check.Equal(JsonValueKind.Null, local.GetProperty("state").GetProperty("remote").GetProperty("remembered").ValueKind, "un compte local ne préremplit jamais le compte Postes");
        Check.True(local.GetProperty("state").GetProperty("memory").EnumerateArray().Any(m => m.GetProperty("key").GetString()!.StartsWith("temporary:" + CredentialRules.RemoteLocalPrefix, StringComparison.Ordinal)), "gardé sous RemoteLocal|POSTE");
        var trial = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.tryRemote", Args(new { computer = computer.Name })));
        Check.Equal("compte local temporaire de ce poste", trial.GetProperty("origin").GetString(), "l’essai prend le compte local de ce poste");
        var forgotten = SimulatedBridge.Json(await bridge.CallAsync("accounts.remembered.forget", Args(new { usage = "secrets" })));
        Check.Equal(JsonValueKind.Null, forgotten.GetProperty("secrets").GetProperty("remembered").ValueKind, "identifiant oublié pour LAPS et BitLocker aussi");
    }

    [Test]
    public static async Task Trial_on_a_workstation_says_ok_only_for_an_explicit_success()
    {
        var bridge = new SimulatedBridge();
        var reader = bridge.Context.Readers.Require<IAccountsAccessReader>();
        var computer = Answering(bridge);
        using var unknownSecret = Secret("x");
        using var unknownCredential = new RemoteProbeCredential(@"EXAMPLE\personne", unknownSecret.Copy(), false);
        var unknown = await reader.ProbeAsync(computer.Name, unknownCredential, CancellationToken.None);
        Check.Equal("authRejected", unknown.Outcome, "un compte inconnu est refusé, jamais « OK »");
        var session = await reader.ProbeAsync(computer.Name, new RemoteProbeCredential(@"EXAMPLE\j.martin", null, true), CancellationToken.None);
        Check.True(session.Outcome is "observed" or "denied", "la session elle-même");
        var absent = await bridge.CallAsync("accounts.access.tryRemote", Args(new { computer = "PC-INCONNU-99" }));
        Check.True(absent.Error is null || absent.Error.Code == AccountAccess.ComputerUnknown, "poste inconnu dit");
    }

    [Test]
    public static async Task No_account_changes_while_a_write_waits_for_its_re_read()
    {
        var bridge = new SimulatedBridge();
        var access = Access(bridge, _ => Task.FromResult(1));
        using var secret = Secret("essai");
        var activate = await Check.ThrowsAsync<DomeniaOperationException>(() => access.ActivateAsync(AccessUsage.Remote, @"EXAMPLE\adm-j.martin", secret, CancellationToken.None), "activation refusée");
        Check.Equal(AccountAccess.WritePending, activate.Code, "écriture à vérifier");
        Check.Equal(AccountAccess.WritePending, (await Check.ThrowsAsync<DomeniaOperationException>(() => access.ForgetAllAsync(CancellationToken.None), "tout oublier")).Code, "tout oublier refusé");
        Check.Equal(AccountAccess.WritePending, (await Check.ThrowsAsync<DomeniaOperationException>(() => access.ForgetAsync("temporary:ReadLaps", CancellationToken.None), "oublier")).Code, "oublier refusé");
        Check.Equal(AccountAccess.WritePending, (await Check.ThrowsAsync<DomeniaOperationException>(() => access.ClearAsync(AccessUsage.Secrets, CancellationToken.None), "effacer")).Code, "effacer refusé");
        Check.Equal(AccountAccess.WritePending, (await Check.ThrowsAsync<DomeniaOperationException>(() => access.SwitchAsync(@"EXAMPLE\adm-j.martin", secret, CancellationToken.None), "changer de compte")).Code, "changement de compte refusé");
    }

    [Test]
    public static async Task One_validation_at_a_time_and_cancel_keeps_the_previous_account()
    {
        var bridge = new SimulatedBridge(SimulationLatency.Realistic);
        var first = bridge.CallAsync("accounts.access.test", Args(new { usage = "remote", login = @"EXAMPLE\adm-j.martin", password = "essai" }));
        await Task.Delay(250);
        var second = await bridge.CallAsync("accounts.access.test", Args(new { usage = "secrets", login = @"EXAMPLE\adm-j.martin", password = "essai" }));
        Check.Equal(AccountAccess.ValidationBusy, second.Error?.Code, "une seule validation à la fois");
        var revision = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.revision"));
        Check.True(revision.GetProperty("validating").GetBoolean(), "validation en cours dite");
        var cancel = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.cancel"));
        Check.True(cancel.GetProperty("cancelled").GetBoolean(), "annulée");
        var result = SimulatedBridge.Json(await first);
        Check.Equal("cancelled", result.GetProperty("kind").GetString(), "résultat « annulée »");
        Check.False(result.GetProperty("success").GetBoolean(), "rien n’est activé");
        var none = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.cancel"));
        Check.False(none.GetProperty("cancelled").GetBoolean(), "plus rien à annuler");
    }

    [Test]
    public static async Task One_trial_at_a_time()
    {
        var bridge = new SimulatedBridge(SimulationLatency.Realistic);
        var computer = Answering(bridge);
        var first = bridge.CallAsync("accounts.access.tryRemote", Args(new { computer = computer.Name }));
        await Task.Delay(200);
        var second = await bridge.CallAsync("accounts.access.tryRemote", Args(new { computer = computer.Name }));
        Check.Equal(AccountAccess.TrialBusy, second.Error?.Code, "un essai à la fois");
        Check.Null((await first).Error, "le premier essai va jusqu’au bout");
    }

    [Test]
    public static async Task Changing_account_starts_a_new_epoch_and_forgets_the_former_session()
    {
        var bridge = new SimulatedBridge();
        var state = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.state"));
        Check.True(state.GetProperty("connection").GetProperty("relogin").GetProperty("available").GetBoolean(), "changer de compte proposé en simulation");
        var epoch = state.GetProperty("epoch").GetInt64();
        _ = await bridge.CallAsync("accounts.access.activate", Args(new { usage = "remote", login = @"EXAMPLE\adm-j.martin", password = "essai" }));
        var refused = SimulatedBridge.Json(await bridge.CallAsync("accounts.connection.switch", Args(new { login = @"EXAMPLE\personne", password = "x" })));
        Check.False(refused.GetProperty("result").GetProperty("success").GetBoolean(), "compte inconnu refusé");
        Check.Equal(epoch, refused.GetProperty("epoch").GetInt64(), "même époque après un refus");
        var local = await bridge.CallAsync("accounts.connection.switch", Args(new { login = @".\administrateur", password = "x" }));
        Check.Equal(AccountAccess.ContextRefused, local.Error?.Code, "un compte local n’ouvre jamais de session d’annuaire");
        var switched = SimulatedBridge.Json(await bridge.CallAsync("accounts.connection.switch", Args(new { login = @"EXAMPLE\adm-j.martin", password = "secret-du-changement" })));
        Check.True(switched.GetProperty("result").GetProperty("success").GetBoolean(), "session ouverte");
        Check.Equal(epoch + 1, switched.GetProperty("epoch").GetInt64(), "nouvelle époque");
        var session = SimulatedBridge.Json(await bridge.CallAsync("session.info"));
        Check.Contains("adm-j.martin", session.GetRawText(), "la session suit le nouveau compte");
        var after = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.state"));
        Check.False(after.GetProperty("remote").GetProperty("active").GetBoolean(), "compte Postes de la session précédente oublié");
        Check.Equal(0, after.GetProperty("pending").GetArrayLength(), "accès à revoir de la session précédente oubliés");
        Check.Equal(@"EXAMPLE\adm-j.martin", after.GetProperty("connection").GetProperty("identity").GetString(), "nouvelle identité");
        Check.False(switched.GetRawText().Contains("secret-du-changement", StringComparison.Ordinal), "aucun mot de passe renvoyé");
        Check.False(bridge.Log.Lines.Any(l => l.Contains("secret-du-changement", StringComparison.Ordinal)), "aucun mot de passe journalisé");
    }

    [Test]
    public static async Task Correction_of_the_connection_password_is_refused_in_simulation()
    {
        var bridge = new SimulatedBridge();
        var refused = await bridge.CallAsync("accounts.connection.correct", Args(new { password = "essai" }));
        Check.Equal(AccountAccess.CorrectionUnavailable, refused.Error?.Code, "la session de simulation n’a aucun mot de passe");
    }

    [Test]
    public static async Task The_page_refreshes_on_the_revision_only()
    {
        var bridge = new SimulatedBridge();
        var first = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.revision"));
        var same = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.revision"));
        Check.Equal(first.GetProperty("revision").GetInt64(), same.GetProperty("revision").GetInt64(), "rien n’a changé : même révision");
        _ = await bridge.CallAsync("accounts.access.activate", Args(new { usage = "secrets", login = @"EXAMPLE\adm-j.martin", password = "essai" }));
        var changed = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.revision"));
        Check.True(changed.GetProperty("revision").GetInt64() > first.GetProperty("revision").GetInt64(), "un compte activé change la révision");
        Check.True(bridge.Registry.TryGet("accounts.access.revision", out var definition) && definition.Class == OperationClass.Local, "lecture locale, aucun réseau");
    }

    // ---------------------------------------------------------------- Domenia.config.json

    [Test]
    public static void Configuration_reads_the_settings_of_domenia_1_with_their_bounds()
    {
        var defaults = AccountsConfiguration.Parse("{}"u8);
        Check.True(defaults.ForcePasswordChangeOnReset, "changement obligatoire coché par défaut");
        Check.Equal(CredentialRules.DefaultLeaseMinutes, defaults.AlternateCredentialIdleMinutes, "bail par défaut");
        Check.True(defaults.Transports.UseWinRm, "défauts de Domenia 1\u00A0: tout transport admis, les intrusifs exigent encore une autorisation");
        var read = AccountsConfiguration.Parse("""{"security":{"ForcePasswordChangeOnReset":false,"AlternateCredentialIdleMinutes":9999},"Remote":{"UseWinRM":false}}"""u8);
        Check.Equal(ConfigurationFileState.Read, read.State, "fichier lu");
        Check.False(read.ForcePasswordChangeOnReset, "réglage lu (nom sans casse)");
        Check.Equal(CredentialRules.MaxLeaseMinutes, read.AlternateCredentialIdleMinutes, "borné à 480 min");
        Check.False(read.Transports.UseWinRm, "Remote.UseWinRM lu");
        Check.True(read.Transports.UseCim, "valeur absente\u00A0: défaut de Domenia 1");
        Check.Contains("Domenia.config.json", read.Transports.Source, "source dite");
        var duplicate = AccountsConfiguration.Parse("""{"Security":{"ForcePasswordChangeOnReset":false,"forcePasswordChangeOnReset":true}}"""u8);
        Check.Equal(ConfigurationFileState.Invalid, duplicate.State, "clé en double : fichier ignoré");
        Check.True(duplicate.ForcePasswordChangeOnReset, "défauts de Domenia 1");
        var broken = AccountsConfiguration.Parse("{ pas du json"u8);
        Check.Equal(ConfigurationFileState.Invalid, broken.State, "JSON illisible");
        Check.False(broken.Source.Contains("pas du json", StringComparison.Ordinal), "le contenu n’est jamais cité");
        var bom = AccountsConfiguration.Parse([0xEF, 0xBB, 0xBF, (byte)'{', (byte)'}']);
        Check.Equal(ConfigurationFileState.Read, bom.State, "marque d’ordre d’octets tolérée");
        var wrongType = AccountsConfiguration.Parse("""{"Security":{"ForcePasswordChangeOnReset":"non"}}"""u8);
        Check.True(wrongType.ForcePasswordChangeOnReset, "valeur d’un autre type : défaut");
    }

    [Test]
    public static async Task The_detail_serves_the_reset_defaults_and_the_transports_their_settings()
    {
        var bridge = new SimulatedBridge();
        var camille = bridge.Source.CurrentDirectory.Users.First(u => u.DisplayName == "Camille Bernard");
        var detail = SimulatedBridge.Json(await bridge.CallAsync("accounts.detail", Args(new { dn = camille.DistinguishedName })));
        var defaults = detail.GetProperty("resetDefaults");
        Check.True(defaults.GetProperty("mustChange").GetBoolean(), "Security.ForcePasswordChangeOnReset (défaut de Domenia 1)");
        Check.Equal(AccountsConfiguration.RevealSeconds, defaults.GetProperty("revealSeconds").GetInt32(), "masquage après 5 s");
        Check.True(detail.GetProperty("policy").GetProperty("complexityRequired").GetBoolean(), "complexité du domaine servie");
        var transports = SimulatedBridge.Json(await bridge.CallAsync("accounts.transports"));
        Check.False(transports.GetProperty("consentActive").GetBoolean(), "aucune autorisation d’intervention");
        InterventionConsentBoard.From(bridge.Context).Publish("PC-PAR-0001", bridge.Clock.GetUtcNow() + TimeSpan.FromMinutes(5));
        var consent = SimulatedBridge.Json(await bridge.CallAsync("accounts.transports"));
        Check.True(consent.GetProperty("consentActive").GetBoolean(), "autorisation en cours lue");
        Check.Contains("PC-PAR-0001", consent.GetProperty("consentText").GetString(), "poste dit");
        bridge.Clock.Advance(TimeSpan.FromMinutes(6));
        var expired = SimulatedBridge.Json(await bridge.CallAsync("accounts.transports"));
        Check.False(expired.GetProperty("consentActive").GetBoolean(), "une autorisation couvre 5 minutes");
    }

    [Test]
    public static void Password_policy_follows_the_complexity_of_the_domain()
    {
        var user = Fixtures.User("Camille Bernard") with { SamAccountName = "c.bernard", DisplayName = "Camille Bernard" };
        var simple = AccountPasswordReset.CheckPolicy("bernardbernard", user, 12, complexity: false);
        Check.Equal(1, simple.Length, "sans complexité : la longueur seule (le contrôleur décide du reste)");
        Check.True(simple[0].Met, "longueur suffisante");
        var complex = AccountPasswordReset.CheckPolicy("bernardbernard", user, 12, complexity: true);
        Check.False(complex.All(r => r.Met), "avec complexité : classes et nom vérifiés");
        var zero = AccountPasswordReset.CheckPolicy("a", user, 0, complexity: false);
        Check.True(zero[0].Met, "longueur minimale 0 : 1 caractère au moins, comme le moteur");
    }

    [Test]
    public static void Password_reset_compares_the_controller_with_the_controller()
    {
        var user = Fixtures.User("Bob");
        var draft = AccountPasswordReset.Draft(user, new PasswordResetOptions(false, false), Fixtures.Domain, "DC1.test.local", Fixtures.Now, TestClock.Paris);
        var lastSet = draft.Changes.Single(c => c.Attribute == "pwdLastSet");
        Check.Equal(AccountWrites.Raw(user.PasswordLastSet ?? 0), lastSet.BeforeValue, "valeur brute « avant » gardée dans le plan, même sans changement exigé");
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\adm", AppMode.Directory, Fixtures.Now, TestClock.Paris);
        Check.False(AccountPasswordReset.RequiresChange(plan), "aucun changement exigé");
        Check.False(AccountPasswordReset.Check(plan, user with { PasswordLastSet = (user.PasswordLastSet ?? 0) + 10 }, secretHeld: true).Current, "pwdLastSet changé entre-temps : rien n’est envoyé");
        // The controller writes a later value, whatever the clock of this workstation says.
        var written = user with { PasswordLastSet = (user.PasswordLastSet ?? 0) + 1 };
        Check.Equal(VerificationState.Verified, AccountPasswordReset.Verify(written, plan).State, "relu postérieur à la valeur avant");
        Check.Equal(VerificationState.Mismatch, AccountPasswordReset.Verify(user, plan).State, "valeur inchangée : écart");
    }

    [Test]
    public static void Password_secrets_are_purged_by_their_timer_and_with_the_executors()
    {
        var clock = TestClock.Fixed();
        var secrets = new PasswordSecrets(clock);
        using var secret = Secret("Vélo-Bleu-2026!");
        secrets.Hold("a", clock.GetUtcNow() + TimeSpan.FromMinutes(5), secret);
        Check.True(secrets.Drop("a"), "détruit au refus du plan");
        Check.False(secrets.Drop("a"), "plus rien à détruire");
        secrets.Hold("b", clock.GetUtcNow() + TimeSpan.FromMinutes(5), secret);
        secrets.Dispose();
        Check.Equal(0, secrets.Count, "détruit avec l’exécuteur");
        secrets.Dispose();
        Check.True(true, "une seconde libération est sans effet");
    }

    [Test]
    public static async Task A_password_gone_from_memory_is_refused_before_anything_is_sent()
    {
        var bridge = new SimulatedBridge();
        var camille = bridge.Source.CurrentDirectory.Users.First(u => u.DisplayName == "Camille Bernard");
        var planned = SimulatedBridge.Json(await bridge.CallAsync("accounts.password.plan", Args(new { dn = camille.DistinguishedName, password = "Vélo-Bleu-2026!", mustChange = true, unlock = false })));
        // The executors are released (context closing): the secret held for the plan is destroyed with them.
        bridge.Context.Writers.Dispose();
        var refused = await bridge.CallAsync("write.execute", Args(new
        {
            planId = planned.GetProperty("plan").GetProperty("id").GetString(),
            token = planned.GetProperty("token").GetString(),
            typedName = (string?)null,
        }));
        Check.Equal(WriteErrors.Stale, refused.Error?.Code, "rien n’est envoyé sans le mot de passe en mémoire");
        Check.Contains("plus en mémoire", refused.Error?.Message, "raison dite");
        Check.Equal(camille.PasswordLastSet, bridge.Source.CurrentDirectory.Users.First(u => u.DisplayName == "Camille Bernard").PasswordLastSet, "surcouche inchangée");
    }
}
