using System.Runtime.InteropServices;
using System.Security;
using Domenia.Core;
using Domenia.Bridge;
using System.Text.Json;
using Domenia.Inventory;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>Source reserved for discovery of the read-only vault fixture; no real source or secret is used.</summary>
public sealed class ReadOnlyVaultSource : IDirectorySource
{
    public DirectorySourceKind Kind => DirectorySourceKind.ActiveDirectory;
    public int Accesses { get; private set; }
    internal TestFailureException Refuse() { Accesses++; return new("Le refus de capacité doit précéder toute lecture de source ou du coffre."); }
    public Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken) => throw Refuse();
    public Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken) => throw Refuse();
    public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken cancellationToken) => throw Refuse();
}

public sealed class ReadOnlyVaultReader(ReadOnlyVaultSource source) : IAccountsCredentialVault
{
    public bool Available => true;
    public SecureString? Read(CredentialVaultTarget target) => throw source.Refuse();
}

internal static class CredentialVaultTests
{
    [Test]
    public static void Vault_keys_match_Domenia1_without_aliasing_authorities_or_usages()
    {
        const string expected = "Domenia:v1:e1ba251d2cc38ac751198473ede6f6f90b81e5b4643a0c2272fea0a917d09b73";
        Check.Equal(expected, CredentialVaultRules.Key("DC=cnamts,DC=local", "Remote", "CNAMTS\\Alice"), "clé D1 à composants préfixés par leur longueur");
        Check.Equal(expected, CredentialVaultRules.Key(" dc=CNAMTS,dc=LOCAL ", "remote", "cnamts\\alice "), "normalisation D1 exacte");
        var keys = new[] { "CNAMTS\\Alice", "Alice@cnamts.local", "Alice", "OTHER\\Alice" }
            .Select(account => CredentialVaultRules.Key(Fixtures.Root, "Remote", account)).ToArray();
        Check.Equal(4, keys.Distinct().Count(), "autorités et formes distinctes sans preuve d’alias");
        Check.False(CredentialVaultRules.Key(Fixtures.Root, "Laps", "TEST\\Alice") == CredentialVaultRules.Key(Fixtures.Root, "BitLocker", "TEST\\Alice"), "usages distincts");
    }

    [Test]
    public static void Local_vault_keys_require_the_exact_machine_and_reject_unknown_scopes()
    {
        _ = CredentialVaultRules.Key(Fixtures.Root, "RemoteLocal:pc-01", "PC-01\\Admin");
        _ = CredentialVaultRules.Key(Fixtures.Root, "RemoteLocal:pc-01", ".\\Admin");
        foreach (var (scope, account) in new[] { ("Remote", ".\\Admin"), ("RemoteLocal:pc-02", "PC-01\\Admin"), ("RemoteLocal:PC-01", "PC-01\\Admin"), ("Unknown", "TEST\\Alice"), ("AD:bad operation", "TEST\\Alice") })
        { Check.Throws<ArgumentException>(() => CredentialVaultRules.Key(Fixtures.Root, scope, account), "contexte invalide"); }
        Check.Throws<ArgumentException>(() => CredentialVaultRules.Key("DC=test\nDC=local", "Remote", "TEST\\Alice"), "séparateur de contrôle refusé");
    }

    [Test]
    public static void Vault_writes_need_a_current_single_use_proof_and_own_their_secret_copy()
    {
        var clock = new Clock(); using var proofs = new CredentialVaultProofs(clock);
        using var secret = Secret('a');
        var ticket = proofs.Stage([new(Fixtures.Root, "Remote", "TEST\\Alice")], secret, 7);
        using var proof = proofs.Take(ticket, 7);
        Check.Equal(1, proof.Password.Length, "copie propre à la preuve");
        Check.True(proof.Password.IsReadOnly(), "copie figée");
        Check.Throws<DomeniaOperationException>(() => proofs.Take(ticket, 7), "preuve consommée");
        var old = proofs.Stage([new(Fixtures.Root, "Remote", "TEST\\Alice")], secret, 7);
        Check.Throws<DomeniaOperationException>(() => proofs.Take(old, 8), "autre session refusée");
        var expired = proofs.Stage([new(Fixtures.Root, "Remote", "TEST\\Alice")], secret, 7);
        clock.Now += TimeSpan.FromSeconds(61);
        Check.Throws<DomeniaOperationException>(() => proofs.Take(expired, 7), "preuve expirée");
    }

    [Test]
    public static void One_authentication_cannot_authorize_a_different_vault_account()
    {
        using var proofs = new CredentialVaultProofs(new Clock()); using var secret = Secret('x');
        Check.Throws<ArgumentException>(() => proofs.Stage([new(Fixtures.Root, "Laps", "TEST\\Alice"), new(Fixtures.Root, "BitLocker", "TEST\\Bob")], secret, 1), "autre compte refusé");
        Check.Throws<ArgumentException>(() => proofs.Stage([new(Fixtures.Root, "Remote", "TEST\\Alice"), new(Fixtures.Root, "Directory", "TEST\\Alice")], secret, 1), "autre couple d’usages refusé");
        var ticket = proofs.Stage([new(Fixtures.Root, "Laps", "TEST\\Alice"), new(Fixtures.Root, "BitLocker", "TEST\\Alice")], secret, 1);
        using var proof = proofs.Take(ticket, 1);
        Check.Equal(2, proof.Targets.Length, "compte Secrets : deux usages précis");
    }

    [Test]
    public static void Native_vault_is_unavailable_in_simulation_before_any_Windows_call()
    {
        var source = new SimulatedDirectorySource(SimulationOptions.Default, TestClock.Fixed());
        var vault = new WindowsCredentialVault(source);
        var target = new CredentialVaultTarget(Fixtures.Root, "Remote", "TEST\\Alice");
        using var password = Secret('x');
        IAccountsCredentialVault reader = vault;
        var mutations = (IAccountsCredentialVaultMutations)vault;
        using var discovered = ScreenReaders.Discover(source, [typeof(WindowsCredentialVault).Assembly]);
        Check.True(discovered.Require<IAccountsCredentialVault>() is WindowsCredentialVault, "lecteur natif toujours découvert avec la source du mode");
        Check.False(discovered.Interfaces.Contains(nameof(IAccountsCredentialVaultMutations)), "mutation jamais enregistrée comme lecteur");
        Check.False(vault.Available, "coffre natif coupé en simulation");
        Check.Throws<DomeniaOperationException>(() => reader.Read(target), "pas de lecture native");
        Check.Throws<DomeniaOperationException>(() => mutations.Write(target, password), "pas d’écriture native");
        Check.Throws<DomeniaOperationException>(() => mutations.Delete(target), "pas de suppression native");
    }

    [Test]
    public static async Task Vault_local_write_routes_refuse_a_reader_without_mutation_capability_before_source_or_secret_access()
    {
        var source = new ReadOnlyVaultSource();
        var decision = ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "test.local"));
        using var context = new EngineContext(decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(),
            ScreenReaders.Discover(source, [typeof(ReadOnlyVaultReader).Assembly]));
        Check.True(context.Readers.Require<IAccountsCredentialVault>() is ReadOnlyVaultReader, "vrai lecteur découvert, capacité d’écriture absente");
        foreach (var operation in new AccountsVaultOperations().CreateOperations(context))
        {
            Check.Equal(OperationClass.LocalWrite, operation.Class, "classification de mutation conservée");
            var arguments = operation.Name == "accounts.vault.save"
                ? JsonSerializer.SerializeToElement(new { ticket = new string('a', 32) })
                : JsonSerializer.SerializeToElement(new { usage = "remote", login = "TEST\\Alice" });
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => operation.Handler(arguments, new(_ => { }, "vault", operation.Name), default),
                "absence de capacité mutante refusée par le gestionnaire réel");
            Check.Equal(CredentialVaultRules.Unavailable, error.Code, "refus de coffre explicite");
            Check.Contains("lecture seule", error.Message, "motif précis sans recours à une autre implémentation");
        }
        Check.Equal(0, source.Accesses, "aucune session, lecture de secret ou acquisition réseau");
    }

    [Test]
    public static void Native_vault_layout_and_returned_identity_are_checked_before_using_a_blob()
    {
        Check.Equal(80, Marshal.SizeOf<WindowsCredentialVault.NativeCredential>(), "CREDENTIALW x64 du SDK");
        var target = CredentialVaultRules.Key(Fixtures.Root, "Remote", "TEST\\Alice");
        var value = new WindowsCredentialVault.NativeCredential { Type = 1, Target = target, UserName = "TEST\\Alice", Blob = new IntPtr(123), BlobSize = 2, Persist = 2 };
        WindowsCredentialVault.Validate(value, target, "test\\alice"); // validation only: never dereferences this pointer
        var wrong = value; wrong.UserName = "TEST\\Bob";
        Check.Throws<DomeniaOperationException>(() => WindowsCredentialVault.Validate(wrong, target, "TEST\\Alice"), "autre identité refusée");
        foreach (var size in new uint[] { 0, 1, 2561, uint.MaxValue })
        {
            var bad = value; bad.BlobSize = size;
            Check.Throws<DomeniaOperationException>(() => WindowsCredentialVault.Validate(bad, target, "TEST\\Alice"), "taille native refusée");
        }
    }

    [Test]
    public static async Task Real_account_entry_refuses_a_password_in_the_web_message_before_requesting_a_native_window()
    {
        var source = new UnavailableDirectorySource("cnamts.local", () => "CNAMTS\\Alice");
        var decision = ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        using var context = new EngineContext(decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal());
        var values = new Dictionary<string, JsonElement> { ["password"] = JsonSerializer.SerializeToElement("fictitious-test-input") };
        await Check.ThrowsAsync<BridgeOperationException>(() => AccountsCredentialEntry.AskAsync(context, values, "CNAMTS\\Alice", "Remote", null, "Tester", CancellationToken.None), "secret JSON refusé sans fenêtre ni réseau");
        var operations = new AccountsVaultOperations().CreateOperations(context).ToArray();
        Check.Equal(2, operations.Length, "enregistrer et oublier");
        Check.True(operations.All(operation => operation.Class == OperationClass.LocalWrite), "écritures locales explicites du coffre");
    }

    [Test]
    public static void Vault_handoff_never_contains_a_password_and_only_the_confirmed_domain_can_be_saved()
    {
        var verdict = new AccessValidation(true, "ok", "Validé", "", "TEST\\Alice", "DC1.test.local", Tone.Ok, "Non mesurés", false, TestClock.Reference)
        { VaultSaveTicket = "0123456789abcdef0123456789abcdef" };
        var json = JsonSerializer.Serialize(verdict);
        Check.False(json.Contains("Password", StringComparison.OrdinalIgnoreCase), "pas de propriété secrète dans le verdict");
        Check.True(json.Contains(verdict.VaultSaveTicket, StringComparison.Ordinal), "seule la confirmation opaque rejoint la page");
        var targets = AccountsCredentialEntry.Targets(Fixtures.Root, "Secrets", "TEST\\Alice", null);
        Check.Equal(2, targets.Length, "les deux usages Secrets restent séparés");
        Check.Equal("Laps", targets[0].Scope, "entrée historique LAPS lue en premier");
    }

    private static SecureString Secret(char value) { var result = new SecureString(); result.AppendChar(value); result.MakeReadOnly(); return result; }

    [Test]
    public static async Task Real_reset_and_workstation_operations_reject_even_a_null_web_password_before_readers_or_writers()
    {
        var source = new UnavailableDirectorySource("cnamts.local", () => "CNAMTS\\Alice");
        var decision = ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        using var context = new EngineContext(decision, source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal());
        var registry = OperationModules.CreateRegistry(context, OperationModules.Discover([typeof(AccountsOperations).Assembly]));
        var responses = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(registry, responses.Add, AdmissionGuards.For(AppMode.Directory));
        foreach (var password in new string?[] { null, "fictitious-test-input" })
        {
            foreach (var op in new[] { "machine.account.use", "machine.account.trial", "accounts.password.plan" })
            {
                object args = op == "accounts.password.plan"
                    ? new { dn = "CN=Alice,OU=Domenia-Tests,DC=cnamts,DC=local", password, mustChange = true, unlock = false }
                    : new { account = "CNAMTS\\Alice", target = "PC-01", password };
                await dispatcher.HandleAsync(JsonSerializer.Serialize(new { id = Guid.NewGuid().ToString("N"), op, args }), CancellationToken.None);
                Check.Equal(DomeniaErrors.ArgumentsInvalid, responses[^1].Error?.Code, "secret web refusé avant tout lecteur, exécuteur ou fenêtre : " + op);
            }
        }
        Check.Equal(0L, MachineAccountService.From(context).Generation, "aucun compte poste modifié");
    }
    private sealed class Clock : TimeProvider
    {
        internal DateTimeOffset Now { get; set; } = TestClock.Reference;
        public override DateTimeOffset GetUtcNow() => Now;
    }
}
