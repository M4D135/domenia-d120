using System.Diagnostics;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class RuntimeResourceTests
{
    [Test]
    public static async Task Release_by_owner_type_and_id_attempts_every_stop_but_never_removes_held_resources()
    {
        var registry = new RuntimeResourceRegistry(); var called = 0;
        using var failing = registry.Register("first", RuntimeResourceKind.ReadTimer, () => throw new InvalidOperationException("private"));
        using var valid = registry.Register("first", RuntimeResourceKind.ReadTimer, () => { Interlocked.Increment(ref called); return Task.CompletedTask; });
        using var foreign = registry.Register("other", RuntimeResourceKind.ReadTimer, () => { Interlocked.Add(ref called, 10); return Task.CompletedTask; });
        using var process = registry.Register("first", RuntimeResourceKind.NativeProcess, () => { Interlocked.Add(ref called, 100); return Task.CompletedTask; });
        await registry.RequestReleaseAsync("first", RuntimeResourceKind.ReadTimer);
        Check.Equal(1, called, "la seconde fermeture est tentée malgré la première faute");
        var held = registry.Snapshot();
        Check.Equal(4, held.Held, "une demande ne prouve aucune libération réelle");
        Check.Equal(2, held.StopRequested, "filtres de type et propriétaire respectés");
        Check.Equal(1L, held.ReleaseFailures, "échec compté une fois");
        Check.Equal("InvalidOperationException", held.Failures.Single().ErrorType, "aucun texte libre privé");
        await registry.RequestReleaseAsync(id: process!.Id);
        Check.Equal(101, called, "libération par identifiant exact");
        await registry.RequestReleaseAsync("first");
        Check.Equal(101, called, "aucune boucle de rejeu automatique");
        valid!.Dispose(); failing!.Dispose(); process.Dispose(); foreign!.Dispose();
        Check.Equal(0, registry.Snapshot().Held, "seul le détenteur retire ses ressources à la vraie fin");
    }

    [Test]
    public static async Task The_registry_and_failure_ring_are_bounded_without_disposing_untracked_work()
    {
        var registry = new RuntimeResourceRegistry(); var held = new List<IDisposable>();
        for (var i = 0; i < RuntimeResourceRegistry.MaximumResources; i++)
            held.Add(registry.Register("read", RuntimeResourceKind.Worker) ?? throw new TestFailureException("capacité attendue"));
        Check.Null(registry.Register("read", RuntimeResourceKind.Worker), "débordement explicite sans faux jeton");
        Check.Equal(1L, registry.Snapshot().Untracked, "ressource hors registre annoncée");
        Check.Equal(RuntimeResourceRegistry.MaximumResources, registry.Snapshot().Held, "registre borné");
        foreach (var resource in held) resource.Dispose();
        for (var i = 0; i < 40; i++)
        {
            using var resource = registry.Register("read", RuntimeResourceKind.NativeSession, () => throw new IOException("private"));
            await registry.RequestReleaseAsync(id: resource!.Id);
        }
        Check.Equal(40L, registry.Snapshot().ReleaseFailures, "toutes les fautes comptées");
        Check.Equal(32, registry.Snapshot().Failures.Length, "détails bornés indépendamment du cumul");
        Check.Equal(0, registry.Snapshot().Held, "seule la libération réelle retire les entrées");
    }

    [Test]
    public static Task Real_native_child_stop_keeps_its_session_and_physical_place_until_owner_disposal() => RunInNewProcessAsync("child");

    private static async Task CheckChildAsync()
    {
        var activity = new OperationActivity(TimeProvider.System, new RecordingJournal(), false);
        using var observed = OperationsMeasurements.Enter(activity);
        using var request = activity.BeginRequest("test.read") ?? throw new TestFailureException("contexte de requête");
        using var ownedRequest = OperationRequests.Enter(request);
        var baseline = PhysicalWorkBudget.Snapshot().Outstanding;
        Check.Equal(0, baseline, "processus neuf sans travail physique préalable");
        using var task = activity.Begin("test.read", TaskKind.NetworkRead, default);
        using var client = new NativeReadClient(new("PC-TEST", InventoryTransport.Dcom, 60000, true, null, false, false), null, task.Token,
            adaptive: new AdaptiveReadBudget(TimeProvider.System));
        var query = new NativeReadRequest(NativeReadKind.Query, 20000)
        { Category = "Fixture", Namespace = @"root\cimv2", Query = "SELECT Name FROM Win32_ComputerSystem", MaxItems = 1 };
        Check.Equal(SourceStatus.Skipped, (await client.ReadAsync(query)).Reading!.Status, "vrai enfant, lecture désactivée sans réseau");
        Check.Equal(2, activity.Resources.Snapshot().Held, "session et processus réellement créés");
        using var child = Process.GetProcessById(client.ProcessId!.Value);
        activity.Stop(task.Id);
        Check.True(task.Token.IsCancellationRequested, "arrêt utilisateur réellement transmis");
        await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
        Check.Equal(baseline + 1, PhysicalWorkBudget.Snapshot().Outstanding, "sortie seule ne libère ni compte ni place de la session");
        Check.Equal(2, activity.Resources.Snapshot().Held, "ressources encore détenues jusqu’à Dispose du propriétaire");
        client.Dispose();
        Check.Equal(baseline, PhysicalWorkBudget.Snapshot().Outstanding, "bail physique rendu après nettoyage réel");
        Check.Equal(0, activity.Resources.Snapshot().Held, "registre vidé par les vrais détenteurs");
        task.Complete(TaskOutcome.Stopped, null, 0);
    }

    [Test]
    public static Task A_timer_stop_keeps_the_worker_registered_and_reserved_until_its_actual_return() => RunInNewProcessAsync("timer");

    private static async Task CheckTimerAsync()
    {
        var activity = new OperationActivity(TimeProvider.System, new RecordingJournal(), false);
        using var measured = OperationsMeasurements.Enter(activity);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var released = new ManualResetEventSlim();
        var baseline = PhysicalWorkBudget.Snapshot().Outstanding;
        Check.Equal(0, baseline, "processus neuf sans travail physique préalable");
        var work = await WmiReadWorkers.StartAsync("PC-TEST", null, _ =>
        {
            using var progress = new NativeReadProgress(TimeProvider.System, TimeSpan.FromSeconds(30), false, default);
            entered.TrySetResult(); released.Wait(); return progress.Token.IsCancellationRequested;
        }, default, new AdaptiveReadBudget(TimeProvider.System));
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await activity.Resources.RequestReleaseAsync(kind: RuntimeResourceKind.ReadTimer);
            Check.False(work.IsCompleted, "arrêt demandé sans inventer une fin native");
            Check.Equal(baseline + 1, PhysicalWorkBudget.Snapshot().Outstanding, "worker encore compté");
            Check.Equal(2, activity.Resources.Snapshot().Held, "minuterie et worker conservés");
        }
        finally { released.Set(); }
        Check.True(await work.WaitAsync(TimeSpan.FromSeconds(5)), "la demande d’arrêt a atteint le vrai jeton");
        Check.Equal(0, activity.Resources.Snapshot().Held, "registre libéré au retour physique");
        Check.Equal(baseline, PhysicalWorkBudget.Snapshot().Outstanding, "pas de fuite de place");
    }

    internal const string FixtureArgument = "--runtime-resource-fixture";

    // These assertions concern the process-wide physical budget. A late cleanup from an unrelated test
    // must not change their baseline; a fresh process preserves strict 0 -> 1 -> 0 without resetting any quota.
    private static async Task RunInNewProcessAsync(string scenario)
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Exécutable de test absent.");
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = AppContext.BaseDirectory,
            RedirectStandardOutput = true, RedirectStandardError = true,
        };
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            start.ArgumentList.Add(typeof(RuntimeResourceTests).Assembly.Location);
        start.ArgumentList.Add(FixtureArgument); start.ArgumentList.Add(scenario);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Processus de test non démarré.");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var output = process.StandardOutput.ReadToEndAsync(deadline.Token);
        var errors = process.StandardError.ReadToEndAsync(deadline.Token);
        try
        {
            await process.WaitForExitAsync(deadline.Token);
            var result = await output; var error = await errors;
            Check.Equal(0, process.ExitCode, "ressources isolées « " + scenario + " » : " + result + error);
            Check.Equal("runtime-resource:" + scenario + ":ok", result.Trim(), "scénario effectivement exécuté");
        }
        finally
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
            }
        }
    }

    internal static async Task<int> RunFixtureAsync(string[] args)
    {
        if (args.Length != 2 || args[0] != FixtureArgument || args[1] is not ("child" or "timer")) return 2;
        try
        {
            if (args[1] == "child") await CheckChildAsync(); else await CheckTimerAsync();
            Console.WriteLine("runtime-resource:" + args[1] + ":ok");
            return 0;
        }
        catch (Exception failure)
        {
            Console.Error.WriteLine(failure.GetType().Name + ": " + failure.Message);
            return 1;
        }
    }

}
