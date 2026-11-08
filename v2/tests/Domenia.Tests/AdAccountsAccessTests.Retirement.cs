using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static partial class AdAccountsAccessTests
{
    [Test]
    public static async Task Failure_disposing_the_previous_transport_cannot_close_or_deny_the_committed_session()
    {
        using var source = Source(out var previous);
        previous.OnDispose = () => throw new IOException("Synthetic cleanup failure");
        var candidate = new Connection("Bob", 1002);
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = _ => candidate };
        using var owner = new EngineContext(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Joined, "test.local")), source,
            new MemoryPreferenceStore(), source.Clock, new BrokenCleanupJournal());
        using var password = Secret('b');
        var result = await reader.OpenSessionAsync(new(@"TEST\Bob", CredentialRules.Directory, null), password, default);
        Check.True(result.Answer.Success, "adoption confirmée malgré ancien nettoyage défaillant");
        Check.False(candidate.Disposed, "la connexion adoptée reste détenue par la source");
        Check.True(ReferenceEquals(candidate, source.Connection), "propriétaire exact transféré");
        Check.Equal(@"TEST\Bob", (await source.GetSessionAsync(default)).Account.Login, "vérité de la session");
    }

    [Test]
    public static async Task Previous_transport_cleanup_runs_outside_the_account_publication_lock()
    {
        using var source = Source(out var previous);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        previous.OnDispose = () => { entered.TrySetResult(); release.Task.GetAwaiter().GetResult(); };
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = _ => new Connection("Bob", 1002) };
        using var access = new AccountAccess(source, reader, new MemoryPreferenceStore(), new OperationJournal(), source.Clock, new RecordingJournal(), AppMode.Directory, _ => Task.FromResult(0));
        using var password = Secret('b');
        var opening = Task.Run(() => access.SwitchAsync(@"TEST\Bob", password, default));
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            _ = await Task.Run(() => access.SelectionVersion).WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(@"TEST\Bob", (await source.GetSessionAsync(default)).Account.Login, "commit visible pendant nettoyage, verrou libre");
        }
        finally { release.TrySetResult(); }
        Check.True((await opening.WaitAsync(TimeSpan.FromSeconds(5))).Result.Success, "fin réelle du nettoyage puis résultat exact");
    }

    private sealed class BrokenCleanupJournal : ITechnicalJournal
    {
        public void Trace(string message) { }
        public void Info(string message) { }
        public void Warning(string message) => throw new IOException("Synthetic journal failure");
        public void Error(string message, Exception exception) { }
    }
}
