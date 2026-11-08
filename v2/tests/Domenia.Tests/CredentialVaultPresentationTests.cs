using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class CredentialVaultPresentationTests
{
    [Test]
    public static void Same_short_name_is_a_presentation_match_only_within_the_admitted_domain_and_exact_storage_key()
    {
        var domain = new DomainIdentity("test.local", "TEST", Fixtures.Root);
        var saved = new ConnectionPreferences(true, @"TEST\Alice", Fixtures.Root, @"TEST\Alice");
        foreach (var login in new[] { "Alice", @"TEST\ALICE", "alice@test.local" })
        {
            var choice = CredentialVaultChoice.Read(domain, login, saved, true);
            Check.True(choice.Available, "même nom dans le domaine : " + login);
            Check.Equal(new CredentialVaultTarget(Fixtures.Root, CredentialRules.Directory, @"TEST\Alice").Key, choice.Target!.Key, "clé exacte enregistrée, pas une recherche approchée");
        }
        Check.False(CredentialVaultChoice.Read(domain, @"OTHER\Alice", saved, true).Available, "autorité étrangère refusée");
        Check.False(CredentialVaultChoice.Read(domain, "Bob", saved, true).Available, "autre utilisateur");
        Check.False(CredentialVaultChoice.Read(domain, "Alice", saved with { VaultDomain = "DC=other,DC=local" }, true).Available, "autre domaine");
        Check.False(CredentialVaultChoice.Read(domain, "Alice", saved, false).Available, "coffre absent ou mode fictif");
        Check.True(CredentialVaultChoice.Read(domain with { RootDn = null }, "Alice", saved, true).Available, "relecture locale de l’identité du domaine joint avant connexion");
        Check.False(CredentialVaultChoice.Read(domain with { RootDn = null }, "Alice", saved with { VaultDomain = "OU=Other," + Fixtures.Root }, true).Available, "aucune racine inventée à partir d’un sous-conteneur");
    }

    [Test]
    public static async Task Forgetting_exact_identity_preserves_a_concurrently_replaced_account()
    {
        using var folder = new TemporaryFolder();
        using var preferences = new FilePreferenceStore(folder.File("vault-presentation.json"), new RecordingJournal());
        var saved = new ConnectionPreferences(true, "Alice", Fixtures.Root, @"TEST\Bob");
        await preferences.SetAsync(SettingsViewRules.ConnectionKey, SettingsViewRules.ToJson(saved), default);
        await LoginPreferences.ForgetVaultIdentityAsync(preferences, new(Fixtures.Root, CredentialRules.Directory, @"TEST\Alice"));
        Check.Equal(@"TEST\Bob", LoginPreferences.Read(preferences).VaultUser, "aucune autre identité effacée");
        await LoginPreferences.ForgetVaultIdentityAsync(preferences, new(Fixtures.Root, CredentialRules.Directory, @"TEST\Bob"));
        using var reopened = new FilePreferenceStore(folder.File("vault-presentation.json"), new RecordingJournal());
        Check.Equal("", LoginPreferences.Read(reopened).VaultUser, "identité exacte réellement retirée du disque");
        Check.Equal("Alice", LoginPreferences.Read(reopened).LastLogin, "préférence de saisie conservée indépendamment");
    }
}
