namespace Domenia.Core;

/// <summary>The same identifier-only preference used by Settings and the native startup dialog. Never reads a vault.</summary>
public static class LoginPreferences
{
    public const string SaveFailure = "Le choix de mémorisation de l’identifiant n’a pas pu être enregistré. Ce réglage ne contient aucun mot de passe. Vérifiez ce réglage dans Paramètres.";

    public static ConnectionPreferences Read(IPreferenceStore preferences) =>
        SettingsViewRules.ReadConnection(preferences.TryGet(SettingsViewRules.ConnectionKey, out var value) ? value : null);

    public static string? SuggestedLogin(IPreferenceStore preferences)
    {
        var saved = Read(preferences);
        return saved.RememberLogin && DirectoryLogin.IsValidInput(saved.LastLogin) ? saved.LastLogin : null;
    }

    public static async Task SaveChoiceAsync(IPreferenceStore preferences, string login, bool remember, bool authenticated, CancellationToken token)
    {
        if (remember && !authenticated) return;
        if (remember && (!DirectoryLogin.IsValidInput(login) || login.Trim().Length > SettingsViewRules.MaxLoginLength))
            throw new InvalidDataException("Identifiant non mémorisable.");
        ConnectionPreferences Next(ConnectionPreferences current) => current with { RememberLogin = remember, LastLogin = remember ? login.Trim() : "" };
        if (preferences is IAtomicPreferenceStore atomic)
            await atomic.UpdateAsync(SettingsViewRules.ConnectionKey, current => SettingsViewRules.ToJson(Next(SettingsViewRules.ReadConnection(current))), token).ConfigureAwait(false);
        else
            await preferences.SetAsync(SettingsViewRules.ConnectionKey, SettingsViewRules.ToJson(Next(Read(preferences))), token).ConfigureAwait(false);
    }

    /// <summary>A local preference failure must never turn a successful authentication into a new login attempt.</summary>
    public static Task<string?> TrySaveChoiceAsync(IPreferenceStore preferences, string login, bool remember, bool authenticated, CancellationToken token) =>
        ReportFailureAsync(() => preferences.Persistent ? SaveChoiceAsync(preferences, login, remember, authenticated, token)
            : Task.CompletedTask);

    /// <summary>Remember a successful GUI switch only while the latest persisted opt-in is still enabled.</summary>
    public static Task<string?> TryRememberAuthenticatedLoginAsync(IPreferenceStore preferences, string login, bool authenticated, CancellationToken token) =>
        ReportFailureAsync(async () =>
        {
            if (!authenticated || !preferences.Persistent) return;
            if (!DirectoryLogin.IsValidInput(login) || login.Trim().Length > SettingsViewRules.MaxLoginLength)
                throw new InvalidDataException("Identifiant non mémorisable.");
            if (preferences is not IAtomicPreferenceStore atomic)
                throw new InvalidOperationException("La mémorisation requiert une mise à jour atomique des préférences.");
            await atomic.UpdateAsync(SettingsViewRules.ConnectionKey, current =>
            {
                var latest = SettingsViewRules.ReadConnection(current);
                return latest.RememberLogin ? SettingsViewRules.ToJson(latest with { LastLogin = login.Trim() }) : current;
            }, token).ConfigureAwait(false);
        });

    /// <summary>Non-secret identity of the last confirmed Windows vault write; never reads the stored password.</summary>
    public static Task<string?> TryRememberVaultIdentityAsync(IPreferenceStore preferences, CredentialVaultTarget target) =>
        ReportFailureAsync(async () =>
        {
            if (!preferences.Persistent) return;
            _ = target.Key; // The same closed validation as the actual vault write.
            if (preferences is not IAtomicPreferenceStore atomic)
                throw new InvalidOperationException("La mémorisation requiert une mise à jour atomique des préférences.");
            await atomic.UpdateAsync(SettingsViewRules.ConnectionKey, current =>
            {
                var latest = SettingsViewRules.ReadConnection(current);
                return SettingsViewRules.ToJson(latest with { VaultDomain = target.DomainDn, VaultUser = target.Account });
            }, CancellationToken.None).ConfigureAwait(false);
        });

    public static async Task ForgetVaultIdentityAsync(IPreferenceStore preferences, CredentialVaultTarget target)
    {
        if (!preferences.Persistent) return;
        if (preferences is not IAtomicPreferenceStore atomic) throw new InvalidOperationException("Mise à jour atomique indisponible.");
        await atomic.UpdateAsync(SettingsViewRules.ConnectionKey, current =>
        {
            var latest = SettingsViewRules.ReadConnection(current);
            return latest.VaultUser.Equals(target.Account, StringComparison.OrdinalIgnoreCase)
                && latest.VaultDomain.Length > 0 && DistinguishedName.AreEqual(latest.VaultDomain, target.DomainDn)
                ? SettingsViewRules.ToJson(latest with { VaultUser = "", VaultDomain = "" }) : current;
        }, CancellationToken.None).ConfigureAwait(false);
    }

    private static async Task<string?> ReportFailureAsync(Func<Task> save)
    {
        try { await save().ConfigureAwait(false); return null; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException or InvalidDataException)
        { return SaveFailure; }
    }
}
