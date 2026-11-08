using System.Collections.Immutable;
using System.Security;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Tests;

public sealed class SecretRecoverySource(AdDirectorySource source) : IDirectorySource
{
    public bool Accept { get; set; } = true;
    public bool Cancel { get; set; }
    public int Validations { get; set; }
    public DirectorySourceKind Kind => source.Kind;
    public Task<SessionSnapshot> GetSessionAsync(CancellationToken token) => source.GetSessionAsync(token);
    public Task<DirectoryState> ReadLocalAsync(CancellationToken token) => source.ReadLocalAsync(token);
    public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken token) => throw new TestFailureException("Aucune collecte implicite");
}
public sealed class SecretRecoveryReader(SecretRecoverySource source) : IAccountsAccessReader, IAccountsCredentialWindow
{
    public bool Simulated => false;
    public bool SessionSwitchAvailable => false;
    public DateTimeOffset? SessionStartedAt => null;
    public Task<CredentialAnswer> ValidateAsync(CredentialRequest request, SecureString password, CancellationToken token)
    { source.Validations++; return Task.FromResult(new CredentialAnswer(source.Accept, source.Accept ? "ok" : "badCredentials", source.Accept ? request.Login : null, null, null)); }
    public Task<CredentialWindowEntry?> AskAsync(CredentialWindowRequest request, CancellationToken token) => Task.FromResult<CredentialWindowEntry?>(source.Cancel ? null : new(PasswordSecrets.FromText("fixture-password-only"), false, @"TEST\reader"));
    public Task<ImmutableArray<AccessRequestSeed>> InitialRequestsAsync(CancellationToken token) => Task.FromResult(ImmutableArray<AccessRequestSeed>.Empty);
    public Task<string?> SessionSidAsync(CancellationToken token) => Task.FromResult<string?>(null);
    public Task<RemoteProbeAnswer> ProbeAsync(string computer, RemoteProbeCredential credential, CancellationToken token) => throw new TestFailureException("Aucune sonde");
    public Task<SessionOpenAnswer> OpenSessionAsync(CredentialRequest request, SecureString password, CancellationToken token) => throw new TestFailureException("Aucun changement de session");
    public Task<ConnectionSecretSwap> SwapConnectionPasswordAsync(SecureString password, CancellationToken token) => throw new TestFailureException("Aucune écriture");
}

internal static class SecretMetadataRecoveryTests
{
    private sealed class ChangingPreferences : IPreferenceStore
    {
        private readonly MemoryPreferenceStore inner = new();
        internal Func<Task>? AfterSave { get; set; }
        public bool Persistent => false;
        public bool TryGet(string key, out JsonElement value) => inner.TryGet(key, out value);
        public async Task SetAsync(string key, JsonElement? value, CancellationToken token)
        {
            await inner.SetAsync(key, value, token);
            var callback = AfterSave; AfterSave = null;
            if (callback is not null) await callback();
        }
    }

    [Test]
    public static async Task Other_account_changed_during_remembering_never_admits_the_explicit_followup_under_another_identity()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        var ldap = new AdBoundaryTests.RecordingAdConnection(); var selected = 0;
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache)
        { ReadConnectionFactory = _ => { selected++; return ldap; } };
        var fixture = new SecretRecoverySource(source); var prefs = new ChangingPreferences();
        var readers = ScreenReaders.Discover(fixture, [typeof(SecretRecoveryReader).Assembly]);
        using var context = new EngineContext(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Unknown, null)), source, prefs, TestClock.Fixed(), new RecordingJournal(), readers);
        var access = AccountAccess.From(context);
        prefs.AfterSave = () => access.ForgetAsync("temporary:" + CredentialRules.SecretTargetKey(CredentialRules.Laps, pc.DistinguishedName), CancellationToken.None);
        ldap.SearchAnswer = _ => throw new TestFailureException("Aucun LDAP après changement du compte installé");
        var failure = await Check.ThrowsAsync<DomeniaOperationException>(() => new AdPosteReader(source)
            .UseOtherAccountAsync(pc.DistinguishedName, "laps", CancellationToken.None, retryRead: true), "relecture refusée avant admission");
        Check.Equal(AccountAccess.EpochChanged, failure.Code, "génération d’installation scellée, pas celle de l’Overview plus tardif");
        Check.Equal(1, fixture.Validations, "une validation explicite"); Check.Equal(0, selected, "aucune connexion pour un autre compte");
        Check.Equal(0, ldap.Searches.Count, "aucune relecture ni secret");
    }

    [Test]
    public static async Task Actual_other_account_flow_retries_only_explicit_metadata_once_and_never_a_secret()
    {
        foreach (var (retry, accept, cancel) in new[] { (false, true, false), (true, true, false), (true, false, false), (true, true, true) })
        {
            var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
            var ldap = new AdBoundaryTests.RecordingAdConnection();
            var selected = new List<string>();
            using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache)
            { ReadConnectionFactory = credential => { selected.Add(credential?.Account ?? "session"); return ldap; } };
            var fixture = new SecretRecoverySource(source) { Accept = accept, Cancel = cancel };
            var readers = ScreenReaders.Discover(fixture, [typeof(SecretRecoveryReader).Assembly]);
            using var context = new EngineContext(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Unknown, null)), source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(), readers);
            ldap.SearchAnswer = _ => [AdPosteNetworkTests.Entry(pc)];
            var result = await new AdPosteReader(source).UseOtherAccountAsync(pc.DistinguishedName, "laps", CancellationToken.None, retryRead: retry);
            Check.Equal(retry && accept && !cancel, result.ReadRetried, "le geste explicite et la validation sont nécessaires");
            Check.Equal(cancel ? 0 : 1, fixture.Validations, "un essai d’identité au plus");
            Check.Equal(retry && accept && !cancel ? 1 : 0, ldap.Searches.Count, "une seule lecture de métadonnées, aucune boucle");
            Check.True(ldap.Searches.All(q => q.SizeLimit == 2 && q.Budget <= TimeSpan.FromSeconds(12)
                && q.Attributes.All(a => a is "objectGUID" or "objectClass" or "msLAPS-PasswordExpirationTime" or "ms-Mcs-AdmPwdExpirationTime")), "bornes réelles et aucune demande de valeur secrète");
            if (result.ReadRetried)
            { Check.NotNull(result.Laps, "réponse native projetée"); Check.Null(result.BitLocker, "une seule ressource"); Check.True(selected.All(a => a == @"TEST\reader"), "compte validé exact sans repli"); }
        }
    }
}
