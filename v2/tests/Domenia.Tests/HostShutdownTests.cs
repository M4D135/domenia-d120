using System.Collections.Immutable;
using System.Diagnostics;
using Domenia.Ad;
using Domenia.App;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class HostShutdownTests
{
    internal const string FixtureArgument = "--host-shutdown-fixture";

    [Test]
    public static async Task Real_SQLite_and_physical_ownership_survive_the_host_deadline_and_progress_reopens_locally()
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Hôte de test absent.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            WorkingDirectory = AppContext.BaseDirectory, RedirectStandardOutput = true, RedirectStandardError = true };
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(typeof(HostShutdownTests).Assembly.Location);
        start.ArgumentList.Add(FixtureArgument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Processus de test absent.");
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var output = process.StandardOutput.ReadToEndAsync(limit.Token); var errors = process.StandardError.ReadToEndAsync(limit.Token);
        try
        {
            await process.WaitForExitAsync(limit.Token);
            Check.Equal(0, process.ExitCode, "fermeture réelle isolée : " + await output + await errors);
            Check.Equal("host-shutdown:ok", (await output).Trim(), "scénario natif réellement exécuté");
        }
        finally
        {
            if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); }
        }
    }

    internal static async Task<int> RunFixtureAsync(string[] args)
    {
        if (args.Length != 1 || args[0] != FixtureArgument) return 2;
        try { await NativeCloseAsync(); Console.WriteLine("host-shutdown:ok"); return 0; }
        catch (Exception error) { Console.Error.WriteLine(error.GetType().Name + ": " + error.Message); return 1; }
    }

    private static async Task NativeCloseAsync()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var db = new DomeniaDatabase(folder.File("close.db"), Fixtures.Root, clock);
        await db.InitializeAsync(CancellationToken.None);
        var pc = Fixtures.Computer("PC1");
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Postes, "Postes", true), "DC1", CancellationToken.None);
        using (var sql = new SqliteDatabase(db.Path, false)) sql.Script("CREATE TABLE close_proof(id INTEGER PRIMARY KEY,value INTEGER); INSERT INTO close_proof VALUES(1,7);");
        using var connection = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", clock, connection: connection, localStore: new SqliteDirectoryCache(db));
        using var reader = new AdOperationsReader(source);
        ImmutableArray<SurveyTarget> targets = [new(pc.ObjectGuid.ToString("D"), "PC1", "CN=PC1," + Fixtures.Postes, null),
            new(Fixtures.IdOf("pc2").ToString("D"), "PC2", "CN=PC2," + Fixtures.Postes, null)];
        var run = Guid.NewGuid().ToString("D");
        await reader.BeginCollectionAsync(run, new(Fixtures.Postes, "Postes", true), SurveyMode.Ping, targets, CancellationToken.None);
        await reader.ProgressCollectionAsync(run, [pc.ObjectGuid], 0, CancellationToken.None);
        using var cancellation = new CancellationTokenSource();
        using var release = new ManualResetEventSlim();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var native = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Cim);
        var writer = Task.Run(async () =>
        {
            using (PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Storage))
            using (var sql = new SqliteDatabase(db.Path, false))
            {
                sql.Begin(); sql.Execute("UPDATE close_proof SET value=9 WHERE id=1;"); entered.SetResult();
                if (!release.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("Libération du vrai écrivain absente.");
                sql.Commit();
            }
            await reader.FinishCollectionAsync(run, true, CancellationToken.None);
        });
        Task? completion = null; var released = false; var diagnostics = new List<Exception>();
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            completion = HostShutdown.FinishAsync(async () => { await cancellation.CancelAsync(); stopped.SetResult(); }, [writer], PhysicalWorkBudget.WaitForIdleAsync,
                () => Task.CompletedTask, () => released = true, diagnostics.Add);
            await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var budget = new HostShutdown(TimeSpan.FromMilliseconds(40));
            Check.False(budget.Wait(completion, diagnostics.Add), "l’attente de l’hôte expire même si le travail ignore l’annulation");
            Check.True(cancellation.IsCancellationRequested, "arrêt demandé avant la vidange");
            Check.Equal(2, PhysicalWorkBudget.Snapshot().Outstanding, "les deux travailleurs gardent leur admission réelle");
            Check.False(released, "aucun service libéré sous le travail SQLite ou natif");
            Check.False(budget.Wait(completion, diagnostics.Add), "une seconde attente réutilise le même budget épuisé");
            native.Dispose();
            Check.False(released, "la fin du natif ne prétend pas que le commit est terminé");
        }
        finally { native.Dispose(); release.Set(); }
        await writer.WaitAsync(TimeSpan.FromSeconds(5));
        if (completion is not null) await completion.WaitAsync(TimeSpan.FromSeconds(5));
        Check.True(released, "libération uniquement après commit et fin physique");
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "budget rendu uniquement par les propriétaires");
        Check.Equal(0, diagnostics.Count, "aucun échec masqué");
        using (var coldSql = new SqliteDatabase(db.Path, true))
        {
            Check.Equal(9L, (long)coldSql.Scalar("SELECT value FROM close_proof WHERE id=1;")!, "transaction réellement validée après le délai");
        }
        var cold = new DomeniaDatabase(db.Path, Fixtures.Root, clock);
        Check.Equal(1, (await cold.ReadDirectoryAsync(CancellationToken.None))!.Computers.Length, "dernier cache AD conservé, aucune purge");
        using var coldSource = new AdDirectorySource("test.local", () => @"TEST\adm", clock, connection: new AdBoundaryTests.RecordingAdConnection(), localStore: new SqliteDirectoryCache(cold));
        using var fresh = new AdOperationsReader(coldSource);
        var history = await fresh.RunsAsync(CancellationToken.None);
        Check.True(history.Offer is { Resumable: true, Remaining: 1 }, "offre durable relue à froid ; seulement le poste non traité");
        Check.Equal(OperationsCollectionStatus.Cancelled, history.Rows.Single(row => row.Family == OperationsCollectionFamily.Presence).Status, "interruption visible, aucune réussite inventée");
        Check.Equal(0, connection.Calls, "aucune sonde ni relecture réseau de fermeture");
    }

    [Test]
    public static async Task Slow_receipt_read_is_fenced_immediately_and_cannot_reclose_a_cancelled_attempt()
    {
        var store = new BlockOnceReceiptStore();
        var (context, circuit, executor, _) = WriteCircuitTests.FakeCircuit(store); using var owned = context;
        var planned = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        store.Block = 1;
        var close = circuit.PrepareCloseAsync(CancellationToken.None);
        try
        {
            await store.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check.False(await HostShutdown.WaitAsync(close, TimeSpan.FromMilliseconds(30), _ => { }), "lecture non coopérative bornée pour l’hôte");
            var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None), "envoi clôturé avant le retour du disque");
            Check.Equal("write.closing", refusal.Code, "pas d’écriture pendant l’incertitude");
            circuit.CancelClose();
            Check.True(ReferenceEquals(close, circuit.PrepareCloseAsync(CancellationToken.None)), "nouvelle tentative partage la lecture encore active et referme les envois");
            circuit.CancelClose();
            await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None);
        }
        finally { store.Release.TrySetResult(); }
        await close.WaitAsync(TimeSpan.FromSeconds(5));
        _ = await circuit.PlanAsync(FakeWriteExecutor.Draft(), CancellationToken.None);
        Check.Equal(1, executor.Executes, "la lecture tardive n’a ni rejoué ni refermé les envois");
    }

    [Test]
    public static async Task Statistics_ignoring_cancellation_do_not_extend_the_deadline_or_release_early()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var disposed = false;
        var work = HostShutdown.FinishAsync(() => Task.CompletedTask, [], () => Task.CompletedTask,
            () => { entered.SetResult(); return release.Task; }, () => disposed = true, _ => { });
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        try
        {
            var budget = new HostShutdown(TimeSpan.FromMilliseconds(20));
            Check.False(budget.Wait(work, _ => { }), "statistiques bornées même sans coopération");
            Check.False(disposed, "contexte toujours détenu par l’enregistrement");
        }
        finally { release.TrySetResult(); }
        await work.WaitAsync(TimeSpan.FromSeconds(5));
        Check.True(disposed, "libération après retour réel");
    }

    [Test]
    public static async Task Real_bridge_cancellation_callback_never_blocks_the_host_or_releases_its_handler_early()
    {
        using var lifetime = new CancellationTokenSource();
        using var release = new ManualResetEventSlim();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelling = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var definition = new OperationDefinition("host.wait", OperationClass.LocalRead, async (_, _, token) =>
        {
            using var callback = token.Register(() =>
            {
                cancelling.TrySetResult();
                if (!release.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("Libération du callback absente.");
            });
            entered.TrySetResult();
            await finish.Task;
            return null;
        }, "Lecture locale retenue pour qualifier la fermeture.");
        using var dispatcher = new BridgeDispatcher(new OperationRegistry([definition]), _ => { });
        var handler = dispatcher.HandleAsync("{\"id\":\"close\",\"op\":\"host.wait\",\"args\":{}}", lifetime.Token);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var released = false;
        var work = HostShutdown.FinishAsync(() => Task.WhenAll(Task.Run(dispatcher.Dispose), lifetime.CancelAsync()), [handler],
            () => Task.CompletedTask, () => Task.CompletedTask, () => released = true, _ => { });
        try
        {
            await cancelling.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var budget = new HostShutdown(TimeSpan.FromMilliseconds(20));
            Check.False(budget.Wait(work, _ => { }), "callback natif non coopératif ne bloque pas l’attente de l’hôte");
            Check.True(lifetime.IsCancellationRequested, "annulation générale lancée indépendamment de la libération du pont");
            Check.False(released || handler.IsCompleted, "fin de délai ne libère ni le gestionnaire ni ses services");
        }
        finally { release.Set(); finish.TrySetResult(); }
        await work.WaitAsync(TimeSpan.FromSeconds(5));
        Check.True(released && handler.IsCompleted, "fin réelle observée avant libération");
    }

    private sealed class BlockOnceReceiptStore : IReceiptStore
    {
        private readonly MemoryReceiptStore inner = new();
        public int Block;
        public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Persistent => false;
        public Task AppendAsync(WriteReceipt receipt, CancellationToken token) => inner.AppendAsync(receipt, token);
        public Task<ReceiptLog> ReadAllAsync(CancellationToken token)
        {
            if (Interlocked.Exchange(ref Block, 0) != 0) { Entered.TrySetResult(); Release.Task.GetAwaiter().GetResult(); }
            return inner.ReadAllAsync(CancellationToken.None);
        }
    }
}
