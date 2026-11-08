using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static partial class AdAccountsAccessTests
{
    [Test]
    public static async Task Cold_explicit_login_discovers_without_password_then_pins_one_controller()
    {
        using var initial = new AdBoundaryTests.RecordingAdConnection();
        using var discovery = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\Desktop", TestClock.Fixed(), connection: initial);
        var candidate = new Connection("Bob", 1002); var calls = 0;
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = options =>
        {
            calls++;
            if (calls == 1) { Check.Null(options.Credential, "découverte Windows sans le mot de passe saisi"); Check.Null(options.Server, "un choix Windows"); return discovery; }
            Check.Equal(2, calls, "un seul contrôleur explicite"); Check.Equal("DC1.test.local", options.Server, "contrôleur épinglé avant secret");
            Check.Equal("Bob", options.Credential!.UserName, "secret seulement pour le bind explicite");
            Check.Equal(TimeSpan.FromSeconds(6), options.ConnectTimeout, "budget par contrôleur effectif"); return candidate;
        } };
        using var password = Secret('b');
        var answer = await reader.OpenSessionAsync(new(@"TEST\Bob", CredentialRules.Directory, null), password, default);
        Check.True(answer.Answer.Success, "chaîne complète découverte puis validation"); Check.Equal(2, calls, "aucune rotation ni repli");
        Check.True(answer.Answer.Aliases.Contains("Bob@test.local") && answer.Answer.Aliases.Contains(@"test.local\Bob"), "alias issus de la même identité AD exacte");
        Check.Equal(0, initial.Calls, "ancienne connexion non utilisée pour tester le secret");
    }

    [Test]
    public static async Task Core_close_during_real_candidate_validation_fences_native_adoption()
    {
        using var source = Source(out var previous);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var candidate = new Connection("Bob", 1002) { Wait = release.Task };
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = _ => { entered.TrySetResult(); return candidate; } };
        using var access = new AccountAccess(source, reader, new MemoryPreferenceStore(), new OperationJournal(), source.Clock, new RecordingJournal(), AppMode.Directory, _ => Task.FromResult(0));
        using var password = Secret('b'); var epoch = source.Epoch;
        var opening = access.SwitchAsync(@"TEST\Bob", password, default);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var closed = access.BeginClose(); release.TrySetResult();
        await Check.ThrowsAsync<DomeniaOperationException>(() => opening, "résultat de validation ignoré après fermeture");
        await closed.WaitAsync(TimeSpan.FromSeconds(5)); await candidate.Closed.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Check.Equal(epoch, source.Epoch, "aucune adoption native tardive"); Check.False(previous.Disposed, "ancienne connexion conservée");
    }

    [Test]
    public static async Task Cancellation_after_atomic_adoption_reports_the_already_opened_session()
    {
        using var source = Source(out var previous); using var stop = new CancellationTokenSource();
        previous.OnDispose = stop.Cancel;
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = _ => new Connection("Bob", 1002) };
        using var access = new AccountAccess(source, reader, new MemoryPreferenceStore(), new OperationJournal(), source.Clock, new RecordingJournal(), AppMode.Directory, _ => Task.FromResult(0));
        using var password = Secret('b');
        var result = await access.SwitchAsync(@"TEST\Bob", password, stop.Token);
        Check.True(stop.IsCancellationRequested && result.Result.Success, "annulation arrivée après le point d’adoption, aucune fausse promesse d’annulation");
        Check.Equal(@"TEST\Bob", (await source.GetSessionAsync(default)).Account.Login, "état réel publié");
    }

    [Test]
    public static async Task Alias_conflict_never_reassigns_a_previously_authenticated_name_to_another_SID()
    {
        using var source = Source(out _); var rid = 1002;
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = _ => new Connection("Bob", rid) };
        using var access = new AccountAccess(source, reader, new MemoryPreferenceStore(), new OperationJournal(), source.Clock, new RecordingJournal(), AppMode.Directory, _ => Task.FromResult(0));
        using var password = Secret('b');
        Check.True((await access.TestAsync(AccessUsage.Remote, @"TEST\Bob", password, default)).Success, "première identité");
        var key = CredentialRules.AccountKey("Bob@test.local", "test.local", "TEST", null);
        Check.Equal("sid:" + Fixtures.Domain.DomainSid + "-1002", access.AuthenticationIdentity(key), "UPN et SAM partagent le même gate");
        rid = 1003;
        Check.False((await access.TestAsync(AccessUsage.Remote, @"TEST\Bob", password, default)).Success, "SID différent, identité déclarée ambiguë");
        Check.Throws<DomeniaOperationException>(() => access.AuthenticationIdentity(key), "aucune réattribution silencieuse");
    }
    [Test]
    public static async Task Failed_discovery_never_constructs_a_connection_with_the_explicit_secret()
    {
        using var initial = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\Desktop", TestClock.Fixed(), connection: initial);
        var calls = 0;
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = options =>
        {
            calls++; Check.Null(options.Credential, "aucun secret dans la phase de découverte");
            return new Connection("unused", 1002) { Failure = new DomeniaOperationException(AdErrors.Unavailable, "DC inaccessible") };
        } };
        using var password = Secret('b');
        var result = await reader.OpenSessionAsync(new(@"TEST\Bob", CredentialRules.Directory, null), password, default);
        Check.False(result.Answer.Success, "refus avant bind explicite"); Check.Equal("unreachable", result.Answer.Kind, "pas une erreur de mot de passe");
        Check.Equal(1, calls, "aucune seconde tentative sur le domaine ni sur un autre contrôleur");
    }

    [Test]
    public static async Task Correction_preserves_refusal_history_and_pause_after_local_session_resampling_until_old_copies_return()
    {
        using var source = Source(out _); using var oldPassword = Secret('o'); using var corrected = Secret('n');
        var supplied = new System.Net.NetworkCredential("Alice", oldPassword, "TEST");
        var oldConnection = new AdConnection(new("DC1.test.local", "test.local") { Credential = supplied }); supplied.SecurePassword = null;
        source.AdoptConnection(oldConnection, Fixtures.Domain, Identity("Alice", 1001), source.Epoch, false);
        using var physicalCopy = oldConnection.CopyCredential();
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = options => options.Credential is null
            ? new AdBoundaryTests.RecordingAdConnection() : new Connection("Alice", 1001) };
        using var owner = new EngineContext(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Joined, "test.local")), source,
            new MemoryPreferenceStore(), source.Clock, new RecordingJournal());
        var access = owner.Shared(_ => new AccountAccess(source, reader, owner.Preferences, owner.Journal, source.Clock, owner.Log, AppMode.Directory, _ => Task.FromResult(0)));
        await access.OverviewAsync(default);
        using var outstanding = await access.AcquireDirectoryReadAsync(CredentialRules.Directory, null, default);
        var oldEpoch = source.Epoch;
        Check.Equal(1, access.DirectoryReadsInvalidatedBy(oldEpoch), "bail réellement détenu");
        access.RegisterRefusal(CredentialRules.Directory, "Lecture", null, "badCredentials", null, true);
        var count = access.Refusals().Length;
        var result = await access.CorrectConnectionAsync(corrected, default);
        Check.True(result.Success, "correction explicite du même SID");
        Check.Contains("lecture de l’ancienne session invalidée", result.Message, "décompte réel, aucune promesse de fin physique");
        Check.Contains("nettoyage natif", result.Message, "travail encore détenu clairement dit");
        Check.Throws<DomeniaOperationException>(outstanding.BeforeContact, "ancien bail ne peut plus envoyer");
        Check.True((await access.RevisionAsync(default)).Paused > 0, "pause conservée après relecture de la nouvelle époque native");
        Check.Equal(count, access.Refusals().Length, "historique typé conservé");
        Check.Equal(1, physicalCopy.Password!.Length, "la correction n’efface pas le secret qu’un appel détient encore");
        outstanding.Dispose(); Check.Equal(0, access.DirectoryReadsInvalidatedBy(oldEpoch), "libération au vrai retour, pas à l’annulation");
    }

}
