using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class RemoteTaskPhysicalBudgetTests
{
    private sealed class BlockedCleanup(RemoteTaskReadPlan plan) : IRemoteTaskReadBackend
    {
        internal readonly ManualResetEventSlim Cleaning = new(false), Release = new(false), Disposed = new(false);
        internal int Starts;
        public void Preflight(CancellationToken token) => token.ThrowIfCancellationRequested();
        public void PrepareCleanup(RemoteTaskReadCompletion? previous, CancellationToken token) => token.ThrowIfCancellationRequested();
        public void Start(CancellationToken token) { token.ThrowIfCancellationRequested(); Starts++; }
        public string? ReadResult() => RemoteTaskReadTests.Json(plan);
        public bool Finished => true;
        public RemoteTaskReadCleanup Cleanup(Action? recordStopped = null)
        {
            Cleaning.Set();
            if (!Release.Wait(TimeSpan.FromSeconds(10))) { throw new IOException("Fixture cleanup barrier timed out."); }
            recordStopped?.Invoke();
            return new(true, true, "Nettoyé.");
        }
        public void Dispose() => Disposed.Set();
    }

    [Test]
    public static async Task Remote_task_cancelled_wait_keeps_physical_admission_and_credential_through_cleanup()
    {
        using var folder = new TemporaryFolder();
        var (db, plan) = await RemoteTaskReadTests.Open(folder);
        using (var password = new System.Security.SecureString())
        using (var stop = new CancellationTokenSource())
        {
            foreach (var c in Guid.NewGuid().ToString("N")) { password.AppendChar(c); }
            password.MakeReadOnly();
            using var credential = new RemoteProbeCredential("TEST\\operator", password.Copy(), false);
            var backend = new BlockedCleanup(plan);
            var runner = new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend };
            var work = runner.RunAsync(plan, new SqliteDirectoryCache(db), credential, _ => Task.FromResult(true), stop.Token);
            credential.Dispose(); // Only the worker-owned copy may survive the cancelled wait.
            try
            {
                Check.True(backend.Cleaning.Wait(TimeSpan.FromSeconds(5)), "nettoyage natif effectivement engagé");
                stop.Cancel();
                var result = await work.WaitAsync(TimeSpan.FromSeconds(5));
                Check.True(result.WorkerPending, "fin d’attente distincte du nettoyage");
                Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "worker de nettoyage encore compté");
                Check.Equal(1, RemoteTaskReadRunner.ActiveReads, "réservation de poste encore détenue");
                Check.True(SecureCredentialCopies.Contains(password), "compte conservé pendant le nettoyage");
            }
            finally
            {
                backend.Release.Set();
                await work.WaitAsync(TimeSpan.FromSeconds(5));
                Check.True(backend.Disposed.Wait(TimeSpan.FromSeconds(5)), "backend fermé");
                for (var i = 0; i < 100 && (RemoteTaskReadRunner.ActiveReads != 0 || PhysicalWorkBudget.Snapshot().Outstanding != 0); i++) { await Task.Delay(10); }
                backend.Cleaning.Dispose(); backend.Release.Dispose(); backend.Disposed.Dispose();
            }
            Check.Equal(0, RemoteTaskReadRunner.ActiveReads, "réservation rendue après nettoyage");
            Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "bail physique finalement rendu");
            Check.Equal(1, backend.Starts, "aucun rejeu");
            Check.False(SecureCredentialCopies.Contains(password), "copie du worker effacée avant restitution");
        }
    }

    [Test]
    public static async Task Remote_task_physical_refusal_precedes_journal_and_backend_for_read_and_recovery()
    {
        using var folder = new TemporaryFolder(); var (db, plan) = await RemoteTaskReadTests.Open(folder);
        {
            var leases = Enumerable.Range(0, PhysicalWorkBudget.ReadLimit)
                .Select(_ => PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Network, PhysicalWorkPriority.Selection)).ToArray();
            var backends = 0;
            var runner = new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => { backends++; throw new InvalidOperationException(); } };
            var journal = new SqliteDirectoryCache(db);
            try
            {
                var read = await Check.ThrowsAsync<DomeniaOperationException>(() => runner.RunAsync(plan, journal, null, _ => Task.FromResult(true), default), "lecture refusée avant envoi");
                var cleanup = await Check.ThrowsAsync<DomeniaOperationException>(() => runner.RecoverCleanupAsync(plan, journal, null, _ => Task.FromResult(true), default), "nettoyage refusé avant envoi");
                Check.Equal("operation.physicalBusy", read.Code, "cause exacte de lecture");
                Check.Equal("operation.physicalBusy", cleanup.Code, "cause exacte de nettoyage");
                Check.True(await journal.ReadTaskReadAsync(plan.Id, default) is null, "aucune intention créée par un refus physique");
                Check.Equal(0, backends, "aucun backend construit");
                Check.Equal(0, RemoteTaskReadRunner.ActiveReads, "réservation locale restituée");
            }
            finally { foreach (var lease in leases) { lease.Dispose(); } }
        }
    }
}
