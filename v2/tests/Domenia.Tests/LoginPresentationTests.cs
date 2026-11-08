using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class LoginPresentationTests
{
    [Test]
    public static async Task Bare_login_is_submittable_before_any_AD_connection_in_both_directory_startup_modes()
    {
        foreach (var variable in new string?[] { null, "0" })
        {
            var mode = ModeResolver.Resolve([], variable, () => new(DomainJoinState.Joined, "test.local"));
            using var ldap = new AdBoundaryTests.RecordingAdConnection();
            using var source = new Domenia.Ad.AdDirectorySource(mode.JoinedDomain, () => @"TEST\desktop", TestClock.Fixed(), connection: ldap);
            var session = await source.GetSessionAsync(CancellationToken.None);
            var request = new CredentialWindowRequest("Connexion", "", "", "system", [], false, null)
                { CanEditLogin = true, LoginDomain = session.Domain };
            Check.Equal(ConnectionState.Disconnected, session.Connection, "aucune connexion pour remplir la fenêtre");
            Check.Equal(0, ldap.Calls, "aucun appel LDAP avant le geste de validation");
            Check.True(request.CanSubmit("adm-123", 12, false), "nom simple et mot de passe activent Valider");
            Check.Equal(@"test.local\adm-123", DirectoryLogin.Resolve("adm-123", request.LoginDomain), "domaine prêt avant le premier essai");
            Check.False(request.CanSubmit("adm-123", 0, false), "mot de passe obligatoire");
            Check.False(request.CanSubmit("adm-123", 12, true), "mot de passe révélé à masquer");
            Check.False(request.CanSubmit("adm@", 12, false), "forme incomplète refusée");
            Check.True((request with { LoginDomain = null }).CanSubmit("adm-123", 12, false), "un domaine inconnu doit produire un message, pas un bouton muet");
        }
    }

    [Test]
    public static async Task A_cache_without_domain_names_does_not_hide_the_local_join_domain_at_login()
    {
        var cache = new AdAccueilTests.FleetCache(Fixtures.Snapshot() with { Domain = Fixtures.Domain with { DnsName = "", NetbiosName = "" } });
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new Domenia.Ad.AdDirectorySource("test.local", () => @"TEST\desktop", TestClock.Fixed(), connection: ldap, localStore: cache);
        var session = await source.GetSessionAsync(CancellationToken.None);
        Check.Equal(@"test.local\adm-123", DirectoryLogin.Resolve("adm-123", session.Domain), "le cache incomplet ne retire pas le domaine local");
        Check.Equal(0, ldap.Calls, "lecture locale seulement");
    }

    [Test]
    public static async Task Startup_suggests_the_opted_in_identifier_and_forgetting_removes_it()
    {
        var preferences = new MemoryPreferenceStore();
        Check.Null(LoginPreferences.SuggestedLogin(preferences), "session Windows proposée par défaut");
        await LoginPreferences.SaveChoiceAsync(preferences, "adm-123", true, false, CancellationToken.None);
        Check.Null(LoginPreferences.SuggestedLogin(preferences), "échec non mémorisé");
        Check.Equal(0, preferences.Writes, "pas d’écriture après échec");
        await LoginPreferences.SaveChoiceAsync(preferences, " adm-123 ", true, true, CancellationToken.None);
        Check.Equal("adm-123", LoginPreferences.SuggestedLogin(preferences), "identifiant saisi proposé à la place de Windows");
        var saved = LoginPreferences.Read(preferences);
        Check.True(saved.RememberLogin, "préférence visible dans Paramètres");
        Check.Equal("adm-123", SettingsViewRules.ConnectionView(saved, false).LastLogin, "même réglage dans le login et la GUI");
        await LoginPreferences.SaveChoiceAsync(preferences, "erreur-de-saisie", true, false, CancellationToken.None);
        Check.Equal("adm-123", LoginPreferences.SuggestedLogin(preferences), "une erreur ultérieure conserve le compte valide");
        await LoginPreferences.SaveChoiceAsync(preferences, "adm-456", false, true, CancellationToken.None);
        Check.Null(LoginPreferences.SuggestedLogin(preferences), "décocher oublie le compte");
        Check.Equal("", LoginPreferences.Read(preferences).LastLogin, "identifiant retiré du document");
        await preferences.SetAsync(SettingsViewRules.ConnectionKey, SettingsViewRules.ToJson(new(true, "adm@", "", "")), CancellationToken.None);
        Check.Null(LoginPreferences.SuggestedLogin(preferences), "ancienne préférence invalide jamais proposée");
    }

    [Test]
    public static async Task Successful_GUI_switch_remembers_the_entered_name_only_with_the_latest_persisted_opt_in()
    {
        var preferences = new PersistentLoginPreferences();
        await preferences.SetAsync(SettingsViewRules.ConnectionKey, SettingsViewRules.ToJson(new(true, "ancien", "TEST", "coffre")), CancellationToken.None);
        var writes = preferences.Writes;
        Check.Null(await LoginPreferences.TryRememberAuthenticatedLoginAsync(preferences, "nouveau", false, CancellationToken.None), "échec de connexion sans mémorisation");
        Check.Equal(writes, preferences.Writes, "aucune écriture après refus d’authentification");
        Check.Null(await LoginPreferences.TryRememberAuthenticatedLoginAsync(preferences, " nouveau ", true, CancellationToken.None), "choix enregistré après succès");
        var saved = LoginPreferences.Read(preferences);
        Check.Equal("nouveau", saved.LastLogin, "nom tel que saisi, sans qualification ajoutée");
        Check.Equal("coffre", saved.VaultUser, "préférences du coffre préservées sans lire de secret");
        preferences.BeforeNextUpdate = () => preferences.SetAsync(SettingsViewRules.ConnectionKey,
            SettingsViewRules.ToJson(new(false, "", "TEST", "coffre")), CancellationToken.None);
        Check.Null(await LoginPreferences.TryRememberAuthenticatedLoginAsync(preferences, "tardif", true, CancellationToken.None), "oubli concurrent respecté");
        Check.False(LoginPreferences.Read(preferences).RememberLogin, "la réussite tardive ne réactive pas la case");
        Check.Equal("", LoginPreferences.Read(preferences).LastLogin, "le compte oublié ne réapparaît pas");
        var memory = new MemoryPreferenceStore();
        await LoginPreferences.TrySaveChoiceAsync(memory, "sans-dossier", true, true, CancellationToken.None);
        await LoginPreferences.TryRememberAuthenticatedLoginAsync(memory, "sans-dossier", true, CancellationToken.None);
        Check.Equal(0, memory.Writes, "aucune promesse de mémorisation avec un profil seulement en mémoire");
    }

    [Test]
    public static async Task A_preference_write_failure_reports_a_notice_without_repeating_successful_login()
    {
        var preferences = new PersistentLoginPreferences { FailWrites = true };
        var attempts = 0; string? notice = null;
        var connected = await InitialLogin.RunAsync((_, _) => Task.FromResult(InitialLoginChoice.OtherAccount),
            _ => throw new InvalidOperationException("aucun repli sur la session Windows"), async token =>
            {
                attempts++;
                notice = await LoginPreferences.TrySaveChoiceAsync(preferences, "adm-123", true, true, token);
                return new InitialLoginAttempt(true);
            }, CancellationToken.None);
        Check.True(connected, "connexion réussie conservée malgré la préférence non écrite");
        Check.Equal(1, attempts, "aucune seconde authentification");
        Check.Equal(LoginPreferences.SaveFailure, notice, "avertissement local à présenter à l’opérateur");
        Check.Null(LoginPreferences.SuggestedLogin(preferences), "aucun identifiant prétendu mémorisé");
        Check.Equal(LoginPreferences.SaveFailure, await LoginPreferences.TryRememberAuthenticatedLoginAsync(preferences, "adm-123", true, CancellationToken.None), "la GUI reçoit le même avertissement visible");
    }

    private sealed class PersistentLoginPreferences : IAtomicPreferenceStore
    {
        private readonly MemoryPreferenceStore inner = new();
        public bool Persistent => true;
        public int Writes => inner.Writes;
        internal bool FailWrites { get; init; }
        internal Func<Task>? BeforeNextUpdate { get; set; }
        public bool TryGet(string key, out JsonElement value) => inner.TryGet(key, out value);
        public Task SetAsync(string key, JsonElement? value, CancellationToken token) => inner.SetAsync(key, value, token);
        public Task<JsonElement?> ReadLatestAsync(string key, CancellationToken token) => inner.ReadLatestAsync(key, token);
        public async Task<JsonElement?> UpdateAsync(string key, Func<JsonElement?, JsonElement?> update, CancellationToken token)
        {
            if (BeforeNextUpdate is { } before) { BeforeNextUpdate = null; await before(); }
            if (FailWrites) throw new IOException("préférences indisponibles");
            return await inner.UpdateAsync(key, update, token);
        }
    }

    [Test]
    public static void A_simple_login_uses_only_the_session_domain()
    {
        var domain = new DomainIdentity("test.local", "TEST", "DC=test,DC=local");
        Check.Equal(@"TEST\adm-123", DirectoryLogin.Resolve(" adm-123 ", domain), "nom simple dans le domaine courant");
        Check.Equal(@"test.local\adm-123", DirectoryLogin.Resolve("adm-123", domain with { NetbiosName = null }), "domaine joint DNS utilisable avant la première connexion, sans inventer un UPN");
        Check.Equal(@"OTHER\adm-123", DirectoryLogin.Resolve(@"OTHER\adm-123", domain), "domaine explicite conservé pour les contrôles de contexte");
        Check.Equal("adm-123@alternate.example", DirectoryLogin.Resolve("adm-123@alternate.example", domain), "UPN explicite conservé");
        Check.Null(DirectoryLogin.Resolve("adm-123", null), "aucun repli implicite vers le poste ou le compte Windows");
        Check.Contains("Le nom du compte suffit", DirectoryLogin.Hint("adm-123", domain), "le format qualifié n’est plus imposé");
        foreach (var invalid in new[] { "", " ", @"TEST\", @"\adm", "adm@", "@test.local", "a b", "a\nb", new string('x', 105) })
            Check.Null(DirectoryLogin.Resolve(invalid, domain), "saisie invalide refusée avant authentification");
        Check.False(CredentialRules.CheckContext(CredentialRules.Directory,
            DirectoryLogin.Resolve(@".\admin", domain)!, null, ["TEST", "test.local"]).Valid, "un compte local reste interdit pour l’annuaire");
    }

    [Test]
    public static async Task A_simple_login_opens_the_same_directory_account_as_a_qualified_login()
    {
        var bridge = new SimulatedBridge();
        using var password = PasswordSecrets.FromText("test-login-only");
        var result = await AccountAccess.From(bridge.Context).SwitchAsync("adm-j.martin", password, CancellationToken.None);
        Check.True(result.Result.Success, "le compte simple traverse la résolution et la validation de la session");
        var session = await bridge.Source.GetSessionAsync(CancellationToken.None);
        Check.Equal(@"EXAMPLE\adm-j.martin", session.Account.Login, "la session porte l’identité qualifiée");
        Check.False(bridge.Log.Lines.Any(line => line.Contains("test-login-only", StringComparison.Ordinal)), "aucun secret journalisé");
    }

    [Test]
    public static async Task The_GUI_switch_also_accepts_a_bare_login_before_opening_the_credential_window()
    {
        var bridge = new SimulatedBridge();
        var result = SimulatedBridge.Json(await bridge.CallAsync("accounts.connection.switch",
            JsonSerializer.Serialize(new { login = "adm-j.martin", password = "test-login-only" })));
        Check.True(result.GetProperty("result").GetProperty("success").GetBoolean(), "nom simple accepté par la passerelle");
        Check.Equal(@"EXAMPLE\adm-j.martin", (await bridge.Source.GetSessionAsync(CancellationToken.None)).Account.Login, "même identité qualifiée dans la GUI");
    }

    [Test]
    public static void Initial_login_is_offered_only_for_normal_directory_launches()
    {
        Check.True(InitialLogin.ShouldOffer(AppMode.Directory, LaunchOptions.Default, false, false), "vraie entrée de connexion au démarrage annuaire");
        Check.False(InitialLogin.ShouldOffer(AppMode.Simulation, LaunchOptions.Default, false, false), "simulation sans login réel");
        Check.False(InitialLogin.ShouldOffer(AppMode.Directory, LaunchOptions.Default, true, false), "capture inchangée");
        Check.False(InitialLogin.ShouldOffer(AppMode.Directory, LaunchOptions.Default, false, true), "E2E reste piloté par ses étapes");
        foreach (var option in new[] { "--no-auto-connect", "-NoAutoConnect" })
        {
            var parsed = LaunchArguments.Parse([option]);
            Check.True(parsed.Valid, "option historique reconnue");
            Check.False(InitialLogin.ShouldOffer(AppMode.Directory, parsed.Options, false, false), "l’option évite aussi le choix initial");
        }
    }

    [Test]
    public static async Task Initial_login_waits_for_a_choice_and_offline_never_authenticates()
    {
        var choice = new TaskCompletionSource<InitialLoginChoice>(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        Task<InitialLoginAttempt> Authenticate(CancellationToken _) { calls++; return Task.FromResult(new InitialLoginAttempt(true)); }
        var running = InitialLogin.RunAsync((_, _) => choice.Task, Authenticate, Authenticate, CancellationToken.None);
        Check.Equal(0, calls, "afficher le choix ne lance rien");
        Check.False(running.IsCompleted, "le choix de l’opérateur reste attendu");
        choice.SetResult(InitialLoginChoice.Offline);
        Check.False(await running, "annulation du choix continue hors connexion");
        Check.Equal(0, calls, "aucune identité Windows ou alternative essayée implicitement");
    }

    [Test]
    public static async Task Initial_login_connects_the_chosen_identity_once()
    {
        var windows = 0; var other = 0; var prompts = 0;
        var connected = await InitialLogin.RunAsync((_, _) => { prompts++; return Task.FromResult(InitialLoginChoice.WindowsIdentity); },
            _ => { windows++; return Task.FromResult(new InitialLoginAttempt(true)); },
            _ => { other++; return Task.FromResult(new InitialLoginAttempt(true)); }, CancellationToken.None);
        Check.True(connected, "résultat de la tentative native transmis au démarrage");
        Check.Equal(1, prompts, "pas de second choix après succès");
        Check.Equal(1, windows, "un seul essai Windows"); Check.Equal(0, other, "aucun repli sur un autre compte");
    }

    [Test]
    public static async Task Initial_login_failure_returns_to_choice_without_retrying()
    {
        var selectedAgain = new TaskCompletionSource<InitialLoginChoice>(TaskCreationOptions.RunContinuationsAsynchronously);
        var promptReturned = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0; var prompts = 0;
        var running = InitialLogin.RunAsync((feedback, _) =>
        {
            if (++prompts == 1) return Task.FromResult(InitialLoginChoice.WindowsIdentity);
            Check.Equal("Essai refusé", feedback, "échec visible au prochain choix");
            promptReturned.SetResult(); return selectedAgain.Task;
        }, _ => { calls++; return Task.FromResult(new InitialLoginAttempt(false, "Essai refusé")); },
            _ => throw new InvalidOperationException("Autre compte non choisi."), CancellationToken.None);
        await promptReturned.Task;
        Check.Equal(1, calls, "aucun réessai pendant le choix");
        selectedAgain.SetResult(InitialLoginChoice.Offline);
        Check.False(await running, "hors connexion après refus"); Check.Equal(1, calls, "tentative non rejouée");
    }

    [Test]
    public static async Task Initial_login_cancelled_other_account_returns_to_choice_without_windows_fallback()
    {
        var prompts = 0; var entries = 0;
        var connected = await InitialLogin.RunAsync((feedback, _) =>
        {
            if (++prompts == 1) return Task.FromResult(InitialLoginChoice.OtherAccount);
            Check.Equal("Saisie annulée ; aucun essai envoyé.", feedback, "annulation honnête de la saisie");
            return Task.FromResult(InitialLoginChoice.Offline);
        }, _ => throw new InvalidOperationException("L’identité Windows n’a pas été choisie."),
            _ => { entries++; return Task.FromResult(new InitialLoginAttempt(false, "Saisie annulée ; aucun essai envoyé.")); }, CancellationToken.None,
            _ => throw new InvalidOperationException("La saisie annulée n’a pas pu publier une session."));
        Check.False(connected, "aucune connexion publiée"); Check.Equal(2, prompts, "retour au choix initial");
        Check.Equal(1, entries, "saisie ouverte une fois");
    }

    [Test]
    public static async Task Initial_login_shutdown_cannot_publish_a_late_result_or_prompt_again()
    {
        using var stopped = new CancellationTokenSource(); var prompts = 0;
        await Check.ThrowsAsync<OperationCanceledException>(() => InitialLogin.RunAsync((_, _) =>
        {
            prompts++; return Task.FromResult(InitialLoginChoice.WindowsIdentity);
        }, _ => { stopped.Cancel(); return Task.FromResult(new InitialLoginAttempt(true)); },
            _ => throw new InvalidOperationException("Autre compte non choisi."), stopped.Token), "fin tardive après fermeture refusée");
        Check.Equal(1, prompts, "aucune nouvelle fenêtre après fermeture");
    }

    [Test]
    public static async Task Initial_login_preserves_a_session_committed_before_a_local_followup_failed()
    {
        var prompts = 0; var attempts = 0; var localReads = 0;
        var connected = await InitialLogin.RunAsync((_, _) =>
        {
            prompts++; return Task.FromResult(InitialLoginChoice.OtherAccount);
        }, _ => throw new InvalidOperationException("Aucun repli Windows autorisé."),
            _ => { attempts++; return Task.FromResult(new InitialLoginAttempt(false, "Préférence non enregistrée après ouverture.", ReconcileSession: true)); },
            CancellationToken.None, _ => { localReads++; return Task.FromResult(true); });
        Check.True(connected, "l’état réellement publié prime sur l’erreur locale après authentification");
        Check.Equal(1, prompts, "ne pas offrir hors connexion alors que la source est connectée");
        Check.Equal(1, attempts, "aucune authentification répétée"); Check.Equal(1, localReads, "contrôle local unique");
    }

    [Test]
    public static async Task Initial_login_does_not_invent_offline_state_when_the_local_state_is_unreadable()
    {
        var prompts = 0;
        await Check.ThrowsAsync<IOException>(() => InitialLogin.RunAsync((_, _) =>
        {
            prompts++; return Task.FromResult(InitialLoginChoice.WindowsIdentity);
        }, _ => Task.FromResult(new InitialLoginAttempt(false, "Étape locale échouée.", ReconcileSession: true)),
            _ => throw new InvalidOperationException("Autre compte non choisi."), CancellationToken.None,
            _ => throw new IOException("État local inaccessible.")), "l’hôte doit annoncer l’échec, sans nouvel essai");
        Check.Equal(1, prompts, "pas de choix hors connexion trompeur après un état inconnu");
    }

    [Test]
    public static void Diagnostic_is_closed_bounded_and_freezes_after_the_terminal_result()
    {
        var clock = new Clock(); var trace = new AuthenticationTrace(clock);
        using (trace.Attach())
        {
            using (AuthenticationTrace.Step(AuthenticationStage.ControllerAndBind)) clock.Advance(125);
            Check.Contains("125 ms", trace.Text, "durée réelle de la phase");
            for (var i = 0; i < 100; i++) using (AuthenticationTrace.Step(AuthenticationStage.RootDse)) clock.Advance(1);
            Check.Equal(128, trace.Text.Split(Environment.NewLine).Length, "borne de mémoire ferme");
            trace.CancellationRequested(); trace.Finish(true, false);
            var terminal = trace.Text;
            using (AuthenticationTrace.Step(AuthenticationStage.AccountIdentity)) clock.Advance(1);
            trace.Finish(false, false);
            Check.Equal(terminal, trace.Text, "retour natif tardif ne réécrit jamais le verdict affiché");
            Check.Contains("Validation annulée", terminal, "annulation distinguée d’une réussite");
        }
    }

    [Test]
    public static async Task Parallel_authentications_do_not_mix_diagnostics_and_scope_is_restored()
    {
        var first = new AuthenticationTrace(new Clock()); var second = new AuthenticationTrace(new Clock());
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var task = Task.Run(async () =>
        {
            using var attached = first.Attach(); using var step = AuthenticationTrace.Step(AuthenticationStage.ControllerAndBind);
            entered.SetResult(); await release.Task;
        });
        await entered.Task;
        try
        {
            using (second.Attach()) using (AuthenticationTrace.Step(AuthenticationStage.AccountIdentity)) { }
            using (AuthenticationTrace.Step(AuthenticationStage.RootDse)) { }
            Check.Contains("identité du compte", second.Text, "second contexte effectif");
            Check.False(second.Text.Contains("RootDSE", StringComparison.Ordinal), "contexte retiré après Dispose");
            Check.False(first.Text.Contains("identité du compte", StringComparison.Ordinal), "aucun mélange des comptes en vol");
        }
        finally { release.TrySetResult(); await task; }
        Check.Contains("liaison LDAP", first.Text, "première phase conservée après reprise");
    }

    [Test]
    public static void Nested_scope_and_unknown_stage_never_expose_arbitrary_payload()
    {
        var a = new AuthenticationTrace(new Clock()); var b = new AuthenticationTrace(new Clock());
        using (a.Attach())
        {
            using (b.Attach()) using (AuthenticationTrace.Step(AuthenticationStage.AccountIdentity)) { }
            using (AuthenticationTrace.Step((AuthenticationStage)123456789)) { }
        }
        Check.Contains("Validation", a.Text, "stage inconnu ramené au libellé fermé");
        Check.False(a.Text.Contains("123456789", StringComparison.Ordinal), "aucune valeur libre convertie en trace");
        Check.False(a.Text.Contains("compte", StringComparison.Ordinal), "scope enfant isolé");
    }

    [Test]
    public static void Standard_and_debug_keep_the_same_shell_rights_and_reject_ambiguous_modes()
    {
        var debug = ShellPolicies.Parse(Encoding.UTF8.GetBytes("""{"Auth":{"LoginWindowMode":"Debug"},"UI":{"AllowExpertProfile":false}}"""));
        Check.True(debug.LoginDiagnostic, "mode effectivement consommé"); Check.False(debug.ExpertAllowed, "aucun droit accordé par diagnostic");
        Check.False(ShellPolicies.Parse(Encoding.UTF8.GetBytes("""{"Auth":{"LoginWindowMode":"Standard"}}""")).LoginDiagnostic, "mode ordinaire");
        foreach (var json in new[] { """{"Auth":{"LoginWindowMode":"unknown-private-text"}}""", """{"Auth":{"LoginWindowMode":"Debug","loginwindowmode":"Standard"}}""" })
        {
            var guardedJson = json.Insert(1, "\"UI\":{\"AllowExpertProfile\":false},");
            var policy = ShellPolicies.Parse(Encoding.UTF8.GetBytes(guardedJson));
            Check.False(policy.ExpertAllowed, "mode de diagnostic invalide ne retire pas une restriction indépendante");
            Check.False(policy.LoginDiagnostic, "mode inconnu ou ambigu refusé"); Check.True(policy.Problem is not null, "problème explicite");
            Check.False(policy.Problem!.Contains("private", StringComparison.Ordinal), "contenu non journalisé");
        }
    }

    [Test]
    public static async Task Theme_choice_is_local_persisted_and_never_calls_authentication()
    {
        var preferences = new MemoryPreferenceStore();
        var source = new SimulatedDirectorySource(SimulationOptions.Default, TestClock.Fixed());
        using var context = new EngineContext(new(AppMode.Simulation, ModeReason.Demonstration, "test", null, null, []), source, preferences, TestClock.Fixed(), new RecordingJournal());
        var appearance = LoginPresentation.Appearance(context, "light"); Check.Equal("light", appearance.Theme, "thème courant initial");
        await appearance.SaveTheme!("dark", CancellationToken.None);
        Check.Equal("dark", LoginPresentation.Appearance(context, "light").Theme, "thème propre à la prochaine connexion");
        Check.Equal(0L, source.Overlay.Version, "aucun effet annuaire");
        await Check.ThrowsAsync<InvalidDataException>(() => appearance.SaveTheme("arbitrary", CancellationToken.None), "thème fermé");
        Check.Equal(1, preferences.Writes, "aucune écriture sur valeur refusée");
        var calls = 0;
        var answer = await LoginPresentation.RunAsync(context, "light", _ => { calls++; return Task.FromResult(42); }, CancellationToken.None);
        Check.Equal(42, answer, "même résultat du moteur"); Check.Equal(1, calls, "un seul essai, pas de doublon de présentation");
    }

    [Test]
    public static async Task Initial_login_inherits_the_gui_theme_until_a_login_choice_is_saved()
    {
        var preferences = new MemoryPreferenceStore();
        var source = new SimulatedDirectorySource(SimulationOptions.Default, TestClock.Fixed());
        using var context = new EngineContext(new(AppMode.Simulation, ModeReason.Demonstration, "test", null, null, []), source, preferences, TestClock.Fixed(), new RecordingJournal());
        Check.Equal("system", LoginPresentation.Appearance(context, null).Theme, "premier lancement suit Windows, pas un sombre imposé");
        Check.Equal(0, preferences.Writes, "l’héritage ne crée pas de préférence de connexion implicite");
        await preferences.SetAsync(ShellInterfaceRules.InterfaceKey, JsonSerializer.SerializeToElement(new { theme = "light" }), CancellationToken.None);
        Check.Equal("light", LoginPresentation.Appearance(context, null).Theme, "choix clair du GUI repris avant navigation");
        await preferences.SetAsync(ShellInterfaceRules.InterfaceKey, JsonSerializer.SerializeToElement(new { theme = "dark" }), CancellationToken.None);
        var inherited = LoginPresentation.Appearance(context, null);
        Check.Equal("dark", inherited.Theme, "le login continue de suivre un changement du GUI");
        await inherited.SaveTheme!("contrast", CancellationToken.None);
        Check.Equal("contrast", LoginPresentation.Appearance(context, "light").Theme, "contraste de connexion explicite conservé face au GUI clair");
        await inherited.SaveTheme("system", CancellationToken.None);
        Check.Equal("system", LoginPresentation.Appearance(context, "light").Theme, "choix explicite Windows transmis à la fenêtre native");
        Check.Equal(0L, source.Overlay.Version, "préférences sans effet annuaire");
    }

    [Test]
    public static async Task Invalid_login_theme_does_not_mask_a_valid_gui_preference()
    {
        var preferences = new MemoryPreferenceStore();
        using var context = new EngineContext(new(AppMode.Simulation, ModeReason.Demonstration, "test", null, null, []),
            new SimulatedDirectorySource(SimulationOptions.Default, TestClock.Fixed()), preferences, TestClock.Fixed(), new RecordingJournal());
        await preferences.SetAsync(LoginPresentation.ThemeKey, JsonSerializer.SerializeToElement("unknown"), CancellationToken.None);
        await preferences.SetAsync(ShellInterfaceRules.InterfaceKey, JsonSerializer.SerializeToElement(new { theme = "light" }), CancellationToken.None);
        Check.Equal("light", LoginPresentation.Appearance(context, null).Theme, "valeur login non reconnue ignorée");
        Check.Equal("dark", LoginPresentation.Appearance(context, "dark").Theme, "thème résolu de la page courante utilisé lorsqu’il est fourni");
        await preferences.SetAsync(LoginPresentation.ThemeKey, JsonSerializer.SerializeToElement(7), CancellationToken.None);
        await preferences.SetAsync(ShellInterfaceRules.InterfaceKey, JsonSerializer.SerializeToElement(new[] { "dark" }), CancellationToken.None);
        Check.Equal("system", LoginPresentation.Appearance(context, "invalid").Theme, "formes de préférence inattendues sans exception ni sombre forcé");
    }

    private sealed class Clock : TimeProvider
    {
        private long milliseconds;
        public override long TimestampFrequency => 1000;
        public override long GetTimestamp() => milliseconds;
        public override DateTimeOffset GetUtcNow() => TestClock.Reference.AddMilliseconds(milliseconds);
        internal void Advance(int amount) => milliseconds += amount;
    }
}
