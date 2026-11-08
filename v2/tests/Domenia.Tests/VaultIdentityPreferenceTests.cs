using System.Security;
using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.Tests;

public sealed class VaultPreferenceSource : IDirectorySource
{
    internal readonly SimulatedDirectorySource Local = new(SimulationOptions.Default, TestClock.Fixed());
    public DirectorySourceKind Kind => DirectorySourceKind.ActiveDirectory;
    public bool RefuseWrite { get; set; }
    public int Writes { get; set; }
    public int SessionAttempts { get; set; }
    public int WindowsOpened { get; set; }
    public Task<SessionSnapshot> GetSessionAsync(CancellationToken token) => Local.GetSessionAsync(token);
    public Task<DirectoryState> ReadLocalAsync(CancellationToken token) => throw new TestFailureException("aucune lecture demandée");
    public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken token) => throw new TestFailureException("aucune collecte demandée");
}

public sealed class VaultPreferenceReader(VaultPreferenceSource source) : IAccountsCredentialVault, IAccountsCredentialVaultMutations
{
    public bool Available => true;
    public SecureString? Read(CredentialVaultTarget target) => throw new TestFailureException("aucune lecture de secret pour retenir une identité");
    public void Write(CredentialVaultTarget target, SecureString password)
    {
        _ = target.Key;
        if (source.RefuseWrite) throw new DomeniaOperationException(CredentialVaultRules.Failed, "Refus de coffre du scénario");
        source.Writes++;
    }
    public bool Delete(CredentialVaultTarget target) => throw new TestFailureException("aucune suppression de coffre demandée");
}

public sealed class PreferenceAccountReader(VaultPreferenceSource source) : IAccountsAccessReader, IAccountsCredentialWindow
{
    private readonly SimulatedAccountsReader reader = new(source.Local);
    public bool SessionSwitchAvailable => true;
    public bool Simulated => true;
    public DateTimeOffset? SessionStartedAt => reader.SessionStartedAt;
    public Task<CredentialAnswer> ValidateAsync(CredentialRequest request, SecureString password, CancellationToken token) => reader.ValidateAsync(request, password, token);
    public Task<RemoteProbeAnswer> ProbeAsync(string computer, RemoteProbeCredential credential, CancellationToken token) => throw new TestFailureException("aucune sonde implicite");
    public Task<ImmutableArray<AccessRequestSeed>> InitialRequestsAsync(CancellationToken token) => Task.FromResult(ImmutableArray<AccessRequestSeed>.Empty);
    public Task<string?> SessionSidAsync(CancellationToken token) => reader.SessionSidAsync(token);
    public Task<SessionOpenAnswer> OpenSessionAsync(CredentialRequest request, SecureString password, CancellationToken token)
    { source.SessionAttempts++; return reader.OpenSessionAsync(request, password, token); }
    public Task<ConnectionSecretSwap> SwapConnectionPasswordAsync(SecureString password, CancellationToken token) => throw new TestFailureException("aucune correction implicite");
    public Task<CredentialWindowEntry?> AskAsync(CredentialWindowRequest request, CancellationToken token)
    { source.WindowsOpened++; return Task.FromResult<CredentialWindowEntry?>(new(PasswordSecrets.FromText("fixture-only-dialog"), false)); }
}

internal static class VaultIdentityPreferenceTests
{
    [Test]
    public static async Task The_GUI_switch_remembers_the_entered_login_only_after_a_successful_explicit_authentication()
    {
        using var folder = new TemporaryFolder(); var source = new VaultPreferenceSource();
        using var preferences = new FilePreferenceStore(folder.File("login.json"), new RecordingJournal());
        await preferences.SetAsync(SettingsViewRules.ConnectionKey, SettingsViewRules.ToJson(new(true, "ancien", "", "")), default);
        var decision = ModeResolver.Resolve([], null, () => new(DomainJoinState.Joined, "test.local"));
        using var context = new EngineContext(decision, source, preferences, TestClock.Fixed(), new RecordingJournal(), ScreenReaders.Discover(source, [typeof(PreferenceAccountReader).Assembly]));
        var operation = new AccountsAccessOperations().CreateOperations(context).Single(o => o.Name == "accounts.connection.switch");
        async Task<AccessSwitch> Switch(string login) => (AccessSwitch)(await operation.Handler(JsonSerializer.SerializeToElement(new { login }), new(_ => { }, "switch", operation.Name), default))!;
        Check.False((await Switch("utilisateur-absent-fixture")).Result.Success, "refus par le vrai lecteur de scénario");
        Check.Equal("ancien", LoginPreferences.Read(preferences).LastLogin, "échec n’efface ni ne remplace le dernier succès");
        Check.True((await Switch("adm-j.martin")).Result.Success, "authentification explicite avec fenêtre native simulée");
        Check.Equal("adm-j.martin", LoginPreferences.Read(preferences).LastLogin, "forme saisie retenue, sans imposer le domaine");
        Check.Equal(2, source.SessionAttempts, "un essai par geste"); Check.Equal(2, source.WindowsOpened, "fenêtre demandée par chaque geste");
        Check.False(File.ReadAllText(folder.File("login.json")).Contains("fixture-only-dialog", StringComparison.Ordinal), "secret absent du document");
    }

    [Test]
    public static async Task The_actual_vault_operation_persists_only_successful_nonsecret_identity_and_settings_can_forget_it()
    {
        using var folder = new TemporaryFolder(); var source = new VaultPreferenceSource();
        using var preferences = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal());
        var decision = ModeResolver.Resolve([], null, () => new(DomainJoinState.Joined, "test.local"));
        using var context = new EngineContext(decision, source, preferences, TestClock.Fixed(), new RecordingJournal(), ScreenReaders.Discover(source, [typeof(VaultPreferenceReader).Assembly]));
        var session = await source.GetSessionAsync(default);
        var target = new CredentialVaultTarget(Fixtures.Root, "Remote", @"TEST\vault-user");
        using var secret = PasswordSecrets.FromText("fixture-only-vault-value");
        var proofs = context.Shared(c => new CredentialVaultProofs(c.Clock));
        var operation = new AccountsVaultOperations().CreateOperations(context).Single(o => o.Name == "accounts.vault.save");
        async Task<VaultReceipt> Save()
        {
            var ticket = proofs.Stage([target], secret, session.Epoch);
            return (VaultReceipt)(await operation.Handler(JsonSerializer.SerializeToElement(new { ticket }), new(_ => { }, "fixture", operation.Name), default))!;
        }
        source.RefuseWrite = true;
        Check.False((await Save()).Complete, "échec réel du mutateur remonte");
        Check.Equal("", LoginPreferences.Read(preferences).VaultUser, "aucune identité inventée après refus");
        source.RefuseWrite = false;
        Check.True((await Save()).Complete, "opération locale réussie");
        Check.Equal(1, source.Writes, "un seul succès du mutateur, pas de rejeu");
        var saved = LoginPreferences.Read(preferences);
        Check.Equal(target.Account, saved.VaultUser, "identité réellement mémorisée"); Check.Equal(target.DomainDn, saved.VaultDomain, "domaine du coffre exact");
        Check.False(saved.RememberLogin, "écriture du coffre ne coche pas la préférence de login");
        var view = SettingsViewRules.ConnectionView(saved, false);
        Check.Equal(target.Account, view.Vault!.User, "vue Paramètres peuplée");
        Check.False(File.ReadAllText(folder.File("preferences.json")).Contains("fixture-only-vault-value", StringComparison.Ordinal), "aucun secret dans les préférences");
        using (var reopened = new FilePreferenceStore(folder.File("preferences.json"), new RecordingJournal()))
            Check.Equal(target.Account, LoginPreferences.Read(reopened).VaultUser, "relecture du document durable");
        var forget = new SettingsOperations().CreateOperations(context).Single(o => o.Name == "settings.connection.forget");
        await forget.Handler(JsonSerializer.SerializeToElement(new { }), new(_ => { }, "forget", forget.Name), default);
        Check.Equal("", LoginPreferences.Read(preferences).VaultUser, "oubli explicite de la seule identité");
        Check.Equal(1, source.Writes, "aucune autre écriture de coffre après oubli des préférences");
    }
}
