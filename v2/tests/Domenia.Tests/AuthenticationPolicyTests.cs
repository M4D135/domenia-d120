using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AuthenticationPolicyTests
{
    [Test]
    public static void Effective_policy_and_report_agree_on_one_controller_and_bounded_waits()
    {
        var configuration = RuntimeConfiguration.Read("""{"Auth":{"AllowWindowsSession":false,"LoginTimeoutSeconds":8,"PerServerTimeoutSeconds":25,"MaxServerCandidates":12}}"""u8.ToArray(), "fixture");
        var policy = AuthenticationPolicy.Read(configuration);
        Check.False(policy.AllowWindowsSession, "refus effectif"); Check.Equal(8, policy.TotalSeconds, "budget total appliqué");
        Check.Equal(8, policy.PerServerSeconds, "un appel ne dépasse pas le budget total");
        Check.Equal(1, configuration.Integer("Auth", "MaxServerCandidates", 0), "aucune rotation de mot de passe sur plusieurs contrôleurs");
        Check.Equal(30, AuthenticationPolicy.Read().TotalSeconds, "défaut réel");
    }

    [Test]
    public static void Windows_choice_distinguishes_domain_identity_from_local_system_and_machine_accounts()
    {
        var allowed = WindowsSessionChoice.Read(true, false, "test.local", @"TEST\Alice", "PC1");
        Check.True(allowed.Available, "identité Windows de domaine admissible"); Check.Contains(@"TEST\Alice", allowed.Label, "compte réellement proposé");
        foreach (var login in new[] { @"PC1\Alice", @".\Alice", @"TEST\PC1$", @"nt authority\system", @"NT SERVICE\fixture", @"IIS APPPOOL\fixture", @"TEST\DWM-1", "Alice" })
            Check.False(WindowsSessionChoice.Read(true, false, "test.local", login, "PC1").Available, "identité non utilisable : " + login);
        Check.False(WindowsSessionChoice.Read(false, false, "test.local", @"TEST\Alice", "PC1").Available, "configuration prioritaire");
        Check.False(WindowsSessionChoice.Read(true, false, null, @"TEST\Alice", "PC1").Available, "aucun domaine joint");
        Check.False(WindowsSessionChoice.Read(true, true, "test.local", @"TEST\Alice", "PC1").Available, "aucun vrai bind en simulation");
    }

    [Test]
    public static async Task Disabled_Windows_choice_is_enforced_before_any_native_directory_read()
    {
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\Alice", TestClock.Fixed(), connection: ldap);
        var config = RuntimeConfiguration.Read("""{"Auth":{"AllowWindowsSession":false}}"""u8.ToArray(), "fixture");
        using var owner = new EngineContext(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Joined, "test.local")), source,
            new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(), configuration: config);
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => source.ConnectAsync(default), "garde moteur, pas seulement bouton grisé");
        Check.Equal("accounts.windowsSessionUnavailable", refused.Code, "raison structurée"); Check.Equal(0, ldap.Calls, "aucun contact RootDSE");
        Check.Equal(ConnectionState.Disconnected, (await source.GetSessionAsync(default)).Connection, "consultation locale disponible");
    }

    [Test]
    public static void Technical_codes_are_allowlisted_and_internal_failures_never_become_bad_passwords()
    {
        var trace = new AuthenticationTrace(TestClock.Fixed());
        using (trace.Attach())
        {
            AuthenticationTrace.NativeAuthentication(OperationFailure.LdapAuthenticationCode("error, data 775, v0"));
            AuthenticationTrace.NativeAuthentication(OperationFailure.LdapAuthenticationCode("dc775.test.local token=private"));
            AuthenticationTrace.NativeAuthentication(0xBAD);
        }
        Check.Contains("LDAP 49 / 0x775", trace.Text, "code natif utile conservé");
        Check.False(trace.Text.Contains("private", StringComparison.Ordinal) || trace.Text.Contains("0xBAD", StringComparison.Ordinal), "aucune donnée serveur libre");
        Check.Null(OperationFailure.LdapAuthenticationCode("dc775.test.local"), "nom du contrôleur jamais pris pour sous-code");
        Check.Equal("failed", AdCredentialValidation.Failure(new(AdErrors.Credentials, "contexte interne")).Kind, "pas de preuve LDAP49");
        Check.Equal("identityMismatch", AdCredentialValidation.Failure(new(AccountAccess.ContextRefused, "SID différent")).Kind, "incohérence d’identité distincte");
        Check.Equal("timeout", AdCredentialValidation.Failure(new(AdErrors.Timeout, "délai")).Kind, "délai distinct");
        foreach (var kind in new[] { "unknownAccount", "badCredentials", "passwordExpired", "mustChange", "disabled", "accountExpired", "restricted", "locked", "unreachable", "timeout", "cancelled", "failed" })
        {
            var text = CredentialRules.FailureText(kind);
            Check.True(text.Message.Length > 0 && text.Hint.Length > 0, "résultat et prochaine étape pour " + kind);
            Check.False((text.Message + text.Hint).Contains("data 775", StringComparison.Ordinal), "le code reste dans le diagnostic");
        }
    }
    [Test]
    public static async Task Reveal_duration_is_bounded_once_and_served_by_the_real_account_handlers()
    {
        foreach (var pair in new[] { (0, 1), (17, 17), (90, 30) })
        {
            var bytes = System.Text.Encoding.UTF8.GetBytes("{\"Security\":{\"SecretRevealSeconds\":" + pair.Item1 + "}}");
            var config = RuntimeConfiguration.Read(bytes, "fixture");
            Check.Equal(pair.Item2, config.Accounts.SecretRevealSeconds, "projection typée bornée");
            Check.Equal(pair.Item2, config.Integer("Security", "SecretRevealSeconds", -1), "rapport identique");
            var bridge = new SimulatedBridge(configuration: config);
            try
            {
                var overview = SimulatedBridge.Json(await bridge.CallAsync("accounts.access.state"));
                Check.Equal(pair.Item2, overview.GetProperty("revealSeconds").GetInt32(), "véritable accès, aucun secret");
                var user = bridge.Source.CurrentDirectory.Users.First();
                var detail = SimulatedBridge.Json(await bridge.CallAsync("accounts.detail", System.Text.Json.JsonSerializer.Serialize(new { dn = user.DistinguishedName })));
                Check.Equal(pair.Item2, detail.GetProperty("resetDefaults").GetProperty("revealSeconds").GetInt32(), "réinitialisation web");
                var file = new Domenia.Store.AccountsConfigurationFile(bridge.Source);
                file.Configure(config);
                Check.Equal(pair.Item2, (await file.CurrentAsync(default)).SecretRevealSeconds, "lecteur composé utilise le snapshot sans seconde lecture fichier");
            }
            finally { bridge.Dispatcher.Dispose(); bridge.Context.Dispose(); }
        }
        Check.Equal(5, RuntimeConfiguration.Default.Accounts.SecretRevealSeconds, "défaut");
        Check.Equal(5, RuntimeConfiguration.Read("""{"Security":{"SecretRevealSeconds":"long"}}"""u8.ToArray(), "fixture").Accounts.SecretRevealSeconds, "type incorrect");
        Check.Equal(ConfigurationFileState.Invalid, AccountsConfiguration.Parse("""{"Security":{"SecretRevealSeconds":9,"secretrevealseconds":11}}"""u8).State, "doublon refusé");
    }

}
