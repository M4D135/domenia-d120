using System.Collections.Immutable;
using System.Security;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class AccountAccessLifetimeTests
{
    [Test]
    public static async Task Refusal_bursts_are_coalesced_and_dismissal_freezes_the_same_target_for_sixty_seconds()
    {
        var bridge = new SimulatedBridge(); using var owner = bridge.Context;
        var access = AccountAccess.From(owner); await access.OverviewAsync(CancellationToken.None);
        for (var i = 0; i < 20; i++) access.RegisterRefusal(CredentialRules.Remote, "Inventaire", "PC-42", "accessDenied", null, false);
        var request = (await access.OverviewAsync(CancellationToken.None)).Pending.Single(p => p.Target == "PC-42");
        var at = request.At;
        bridge.Clock.Advance(TimeSpan.FromSeconds(10));
        access.RegisterRefusal(CredentialRules.Remote, "Inventaire", "pc-42", "accessDenied", null, true);
        var repeated = (await access.OverviewAsync(CancellationToken.None)).Pending.Single(p => p.Id == request.Id);
        Check.Equal(at, repeated.At, "rafale ne repousse pas artificiellement la date de première notification"); Check.True(repeated.Interactive, "geste explicite mémorisé sans doublon");
        await access.DismissAsync(request.Id, CancellationToken.None);
        for (var i = 0; i < 20; i++) access.RegisterRefusal(CredentialRules.Remote, "Inventaire", "PC-42", "badCredentials", null, false);
        Check.False((await access.OverviewAsync(CancellationToken.None)).Pending.Any(p => string.Equals(p.Target, "PC-42", StringComparison.OrdinalIgnoreCase)), "aucune nouvelle demande pendant le gel");
        Check.True((await access.RevisionAsync(CancellationToken.None)).Paused > 0, "masquer la notification ne réautorise jamais un compte rejeté");
        bridge.Clock.Advance(TimeSpan.FromSeconds(59)); access.RegisterRefusal(CredentialRules.Remote, "Inventaire", "PC-42", "accessDenied", null, false);
        Check.False((await access.OverviewAsync(CancellationToken.None)).Pending.Any(p => p.Target == "PC-42"), "gel encore actif à59s");
        bridge.Clock.Advance(TimeSpan.FromSeconds(1)); access.RegisterRefusal(CredentialRules.Remote, "Inventaire", "PC-42", "accessDenied", null, false);
        Check.Equal(1, (await access.OverviewAsync(CancellationToken.None)).Pending.Count(p => p.Target == "PC-42"), "nouvelle demande unique après60s");
        Check.True(access.Refusals().Length <= AccountAccess.RefusalCapacity, "historique borné indépendamment des notifications");
    }

    [Test]
    public static async Task Host_sweep_expires_memory_without_a_page_read_and_invalidates_a_changed_domain()
    {
        var bridge = new SimulatedBridge(); using var owner = bridge.Context; var access = AccountAccess.From(owner);
        var first = await access.OverviewAsync(CancellationToken.None); var request = first.Pending.First();
        using var password = PasswordSecrets.FromText("lifetime-fixture");
        Check.True((await access.RecoverAsync(request.Id, @"EXAMPLE\adm-j.martin", password, LeaseMode.Inactivity, 1, null, CancellationToken.None)).Result.Success, "vrai parcours de validation et mémoire");
        var before = access.SelectionVersion;
        bridge.Clock.Advance(TimeSpan.FromMinutes(2)); access.SweepLocal(bridge.Source.PeekSession());
        Check.True(access.SelectionVersion > before, "le pulse a lui-même retiré le bail sans Overview ou acquisition");
        using var read = await access.AcquireDirectoryReadAsync(CredentialRules.Directory, null, CancellationToken.None);
        var current = bridge.Source.PeekSession() ?? throw new TestFailureException("Snapshot simulé déjà créé attendu");
        access.SweepLocal(current with { Epoch = current.Epoch + 1 });
        Check.Equal(AccountAccess.EpochChanged, Check.Throws<DomeniaOperationException>(read.BeforeContact, "autre époque interdit la lecture déjà préparée").Code, "aucun contact après changement de session");
    }

    [Test]
    public static async Task Closing_cancels_validation_but_waits_for_real_return_and_rejects_a_late_success()
    {
        var clock = TestClock.Fixed(); var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        var reader = new DelayedAccounts(); using var access = new AccountAccess(source, reader, new MemoryPreferenceStore(), new OperationJournal(), clock, new RecordingJournal(), AppMode.Simulation, _ => Task.FromResult(0));
        using var password = PasswordSecrets.FromText("close-fixture");
        var attempt = access.ActivateAsync(AccessUsage.Remote, @"EXAMPLE\adm-j.martin", password, CancellationToken.None);
        await reader.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var idle = access.BeginClose(); await reader.Cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Check.False(idle.IsCompleted, "annulation ne prétend pas que le fournisseur est revenu");
        access.Dispose(); Check.False(idle.IsCompleted, "Dispose ne libère pas les objets encore utilisés par la validation");
        reader.Release.TrySetResult();
        await Check.ThrowsAsync<DomeniaOperationException>(() => attempt, "réponse de succès tardive non publiée ni installée");
        await idle.WaitAsync(TimeSpan.FromSeconds(5)); Check.False(access.ValidationActive, "fin physique observée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => access.TestAsync(AccessUsage.Remote, @"EXAMPLE\adm-j.martin", password, CancellationToken.None), "aucune nouvelle validation pendant fermeture");
        Check.Equal(1, reader.Calls, "aucun essai supplémentaire");
    }

    private sealed class DelayedAccounts : IAccountsAccessReader
    {
        internal TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource Cancelled { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal int Calls { get; private set; }
        public async Task<CredentialAnswer> ValidateAsync(CredentialRequest request, SecureString password, CancellationToken token)
        {
            Calls++; using var registration = token.Register(() => Cancelled.TrySetResult()); Entered.TrySetResult();
            await Release.Task.ConfigureAwait(false); return new(true, "ok", request.Login, null, null);
        }
        public Task<ImmutableArray<AccessRequestSeed>> InitialRequestsAsync(CancellationToken token) => Task.FromResult(ImmutableArray<AccessRequestSeed>.Empty);
        public Task<string?> SessionSidAsync(CancellationToken token) => Task.FromResult<string?>(null);
        public Task<RemoteProbeAnswer> ProbeAsync(string computer, RemoteProbeCredential credential, CancellationToken token) => throw new TestFailureException("Aucun essai distant");
        public Task<SessionOpenAnswer> OpenSessionAsync(CredentialRequest request, SecureString password, CancellationToken token) => throw new TestFailureException("Aucun changement de session");
        public Task<ConnectionSecretSwap> SwapConnectionPasswordAsync(SecureString password, CancellationToken token) => throw new TestFailureException("Aucune correction de secret");
        public bool SessionSwitchAvailable => false;
        public bool Simulated => true;
        public DateTimeOffset? SessionStartedAt => null;
    }
}
