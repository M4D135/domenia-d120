using Domenia.Core;

namespace Domenia.App;

internal sealed partial class Composition
{
    public string ReportIncident(string operation, Exception exception) => SessionIncidents.From(context).Report(operation, exception);
    public bool OffersInitialLogin(bool capture, bool e2e) => InitialLogin.ShouldOffer(context.Mode, context.Launch, capture, e2e);

    /// <summary>Runs before the first web navigation, off the UI thread; every network callback follows a native choice.</summary>
    public async Task PresentInitialLoginAsync(CancellationToken token)
    {
        var window = context.Readers.Require<IInitialLoginWindow>();
        var connected = await InitialLogin.RunAsync(
            (feedback, ct) => window.ChooseAsync(LoginPresentation.Appearance(context, null), feedback, LoginPreferences.SuggestedLogin(context.Preferences), ct),
            ct => AttemptAsync(async () =>
            {
                var session = await LoginPresentation.RunAsync(context, null, context.Directory.ConnectAsync, ct).ConfigureAwait(false);
                return new InitialLoginAttempt(session.Connection == ConnectionState.Connected);
            }, ct),
            ct => AttemptAsync(async () =>
            {
                var appearance = LoginPresentation.Appearance(context, null);
                var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
                var preferences = LoginPreferences.Read(context.Preferences);
                var request = new CredentialWindowRequest("Se connecter avec un compte", LoginPreferences.SuggestedLogin(context.Preferences) ?? "",
                    "", appearance.Theme,
                    [], false, context.Preferences.Persistent ? "Le coffre Windows est facultatif. Aucune mémorisation du mot de passe sans votre choix explicite."
                        : "Préférences indisponibles : l’identifiant ne sera pas proposé au prochain démarrage. Le coffre Windows reste un choix distinct.")
                { CanEditLogin = true, Appearance = appearance, LoginDomain = session.Domain,
                    OfferRememberLogin = context.Preferences.Persistent, RememberLogin = context.Preferences.Persistent && preferences.RememberLogin,
                    SavedVault = preferences, OfferVaultSave = context.Mode != AppMode.Simulation, AllowNativeVaultDelete = context.Mode != AppMode.Simulation,
                    VaultDeleted = target => LoginPreferences.ForgetVaultIdentityAsync(context.Preferences, target) };
                using var entry = await context.Readers.Require<IAccountsCredentialWindow>().AskAsync(request, ct).ConfigureAwait(false);
                if (entry is null) return new InitialLoginAttempt(false, "Saisie annulée ; aucun essai de connexion envoyé.");
                var result = await LoginPresentation.RunAsync(context, null,
                    stop => AccountAccess.From(context).SwitchAsync(entry.Login ?? "", entry.Password, stop), ct).ConfigureAwait(false);
                if (result.Result.Success && entry.Remember) await SaveInitialVaultAsync(entry, result.Identity).ConfigureAwait(false);
                var notice = await LoginPreferences.TrySaveChoiceAsync(context.Preferences, entry.Login ?? "", entry.RememberLogin, result.Result.Success, ct).ConfigureAwait(false);
                if (notice is not null)
                {
                    TechnicalLog.Warning("Entrée initiale : choix de mémorisation de l’identifiant non enregistré ; session inchangée, aucun nouvel essai.");
                    if (result.Result.Success) ShowLoginPreferenceWarning(notice);
                }
                return new InitialLoginAttempt(result.Result.Success, result.Result.Success ? null
                    : result.Result.Message + " " + result.Result.Hint + (notice is null ? "" : " " + notice));
            }, ct), token, async ct =>
            {
                var connectedNow = (await context.Directory.GetSessionAsync(ct).ConfigureAwait(false)).Connection == ConnectionState.Connected;
                if (connectedNow) TechnicalLog.Warning("Entrée initiale : la session est déjà ouverte malgré l’échec d’une étape locale ; état réel conservé, aucun nouvel essai.");
                return connectedNow;
            }).ConfigureAwait(false);
        TechnicalLog.Info(connected ? "Entrée initiale : connexion validée après choix explicite ; aucune collecte lancée."
            : "Entrée initiale : poursuite hors connexion après choix de l’opérateur ; aucun essai supplémentaire.");
    }

    private async Task SaveInitialVaultAsync(CredentialWindowEntry entry, string? identity)
    {
        try
        {
            var session = await context.Directory.GetSessionAsync(CancellationToken.None).ConfigureAwait(false);
            if (session.Connection != ConnectionState.Connected || session.Domain?.RootDn is not { Length: > 0 } root
                || identity != session.Account.Login || context.Readers.Find<IAccountsCredentialVault>() is not IAccountsCredentialVaultMutations vault)
                throw new InvalidOperationException("Contexte du coffre non confirmé.");
            var login = DirectoryLogin.Resolve(entry.Login ?? "", session.Domain) ?? throw new InvalidOperationException("Identifiant du coffre non confirmé.");
            var target = new CredentialVaultTarget(root, CredentialRules.Directory, login);
            vault.Write(target, entry.Password);
            var notice = await LoginPreferences.TryRememberVaultIdentityAsync(context.Preferences, target).ConfigureAwait(false);
            if (notice is not null) ShowLoginPreferenceWarning(notice);
        }
        catch (Exception error) when (error is DomeniaOperationException or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            TechnicalLog.Warning("Entrée initiale : mémorisation explicite du coffre non confirmée ; session conservée, aucun nouvel essai.");
            ShowLoginPreferenceWarning("Le compte est connecté, mais son mot de passe n’a pas pu être mémorisé dans le coffre Windows.");
        }
    }

    private static void ShowLoginPreferenceWarning(string message)
    {
        // The main window stays transparent until its normal readiness signal. Report only the local save failure,
        // on its UI thread, without changing the authenticated session or restarting the login sequence.
        var owner = Application.OpenForms.OfType<MainForm>().FirstOrDefault(form => !form.IsDisposed && form.IsHandleCreated);
        if (owner is null) return;
        try
        {
            owner.BeginInvoke(() =>
            {
                if (!owner.IsDisposed) MessageBox.Show(owner, "La connexion est établie.\n\n" + message,
                    "Domenia — Identifiant", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            });
        }
        catch (InvalidOperationException) { /* Closing the application must not trigger another authentication. */ }
    }

    private static async Task<InitialLoginAttempt> AttemptAsync(Func<Task<InitialLoginAttempt>> attempt, CancellationToken token)
    {
        var trace = new AuthenticationTrace(TimeProvider.System);
        using var attached = trace.Attach();
        var failed = true;
        var cancelled = false;
        try
        {
            var result = await attempt().ConfigureAwait(false);
            failed = !result.Connected;
            return result;
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            cancelled = true;
            TechnicalLog.Info("Entrée initiale : annulation signalée, appel terminé ; contrôle de l’état local sans réessai.");
            return new(false, "Connexion annulée après la fin de l’appel en cours. Aucun nouvel essai n’est lancé.", ReconcileSession: true);
        }
        catch (DomeniaOperationException error)
        {
            TechnicalLog.Warning("Entrée initiale : essai terminé avec signalement (" + error.Code + ") ; contrôle de l’état local sans réessai.");
            return new(false, error.Message, ReconcileSession: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            TechnicalLog.Warning("Entrée initiale : essai terminé avec signalement (" + error.GetType().Name + ") ; contrôle de l’état local sans réessai.");
            return new(false, "La connexion n’a pas pu être établie. Consultez le journal technique, choisissez une nouvelle tentative ou continuez hors connexion.", ReconcileSession: true);
        }
        finally
        {
            trace.Finish(cancelled || token.IsCancellationRequested, failed);
            TechnicalLog.Info("Entrée initiale : phases de connexion (découverte interne Windows non exposée, aucun candidat supposé)." + Environment.NewLine + trace.Text);
        }
    }
}
