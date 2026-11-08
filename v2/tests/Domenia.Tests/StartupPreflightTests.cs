using System.Diagnostics;
using System.Text.Json;
using Domenia.App;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

internal static class StartupPreflightTests
{
    [Test]
    public static Task Embedded_diagnostic_exercises_engine_and_demo_without_keeping_physical_work() => RunInNewProcessAsync("clean");

    private static async Task CheckCleanProcessAsync()
    {
        var result = await StartupPreflight.DiagnoseAsync([typeof(SessionOperations).Assembly], CancellationToken.None);
        Check.True(result.Passed, "tous les invariants de l’autotest local sont confirmés : " + result.Error
            + string.Join(", ", result.Checks.Where(c => !c.Passed).Select(c => c.Name)));
        Check.True(result.Modules is { Modules: > 20 }, "modules réels chargés, pas un catalogue inventé");
        Check.True(result.Checks.Any(c => c.Name == "scheduler.promotion" && c.Passed), "promotion après libération réelle d’un bail");
        Check.True(result.Checks.Any(c => c.Name == "scheduler.cancel-before-send" && c.Passed), "annulation réelle de l’admission");
        Check.True(result.Checks.Any(c => c.Name == "simulation.reserved-domain" && c.Passed), "fournisseur simulé réel");
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "aucune réservation restante");
    }

    [Test]
    public static Task Missing_modules_and_cancelled_diagnostic_never_report_success() => RunInNewProcessAsync("cancelled");

    private static async Task CheckCancelledProcessAsync()
    {
        var missing = await StartupPreflight.DiagnoseAsync([], CancellationToken.None);
        Check.False(missing.Passed, "aucun succès sur un ensemble vide"); Check.NotNull(missing.Error, "raison fermée");
        using var stop = new CancellationTokenSource(); stop.Cancel();
        var cancelled = await StartupPreflight.DiagnoseAsync([typeof(SessionOperations).Assembly], stop.Token);
        Check.False(cancelled.Passed, "pas de réussite après annulation");
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "aucune réservation prise pour une commande annulée");
    }

    [Test]
    public static Task Diagnostic_refuses_active_physical_work_without_releasing_its_owners_place() => RunInNewProcessAsync("occupied");

    private static async Task CheckOccupiedProcessAsync()
    {
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "processus neuf avant le bail témoin");
        using (PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Other))
        {
            var refused = await StartupPreflight.DiagnoseAsync([typeof(SessionOperations).Assembly], CancellationToken.None);
            Check.False(refused.Passed, "l’autotest ne peut pas qualifier un processus déjà composé");
            Check.Equal(nameof(InvalidOperationException), refused.Error, "refus explicite du processus occupé");
            Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "le bail tiers demeure réellement détenu");
        }
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "seul le propriétaire a rendu sa place");
        await CheckCleanProcessAsync();
    }

    internal const string FixtureArgument = "--startup-preflight-fixture";

    // StartupPreflight is intentionally a pre-composition diagnostic. Other tests compose full simulated bridges,
    // whose local startup notices may still be running. Use the real executable boundary, never reset their budgets
    // or wait an arbitrary duration and pretend the shared test process has never been composed.
    private static async Task RunInNewProcessAsync(string scenario)
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Exécutable de test absent.");
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = AppContext.BaseDirectory,
            RedirectStandardOutput = true, RedirectStandardError = true,
        };
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            start.ArgumentList.Add(typeof(StartupPreflightTests).Assembly.Location);
        start.ArgumentList.Add(FixtureArgument); start.ArgumentList.Add(scenario);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Processus de diagnostic non démarré.");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var output = process.StandardOutput.ReadToEndAsync(deadline.Token);
        var errors = process.StandardError.ReadToEndAsync(deadline.Token);
        try
        {
            await process.WaitForExitAsync(deadline.Token);
            var result = await output; var error = await errors;
            Check.Equal(0, process.ExitCode, "diagnostic isolé « " + scenario + " » : " + result + error);
            Check.Equal("startup-preflight:" + scenario + ":ok", result.Trim(), "scénario effectivement exécuté");
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
        if (args.Length != 2 || args[0] != FixtureArgument || args[1] is not ("clean" or "cancelled" or "occupied")) return 2;
        try
        {
            switch (args[1])
            {
                case "clean": await CheckCleanProcessAsync(); break;
                case "cancelled": await CheckCancelledProcessAsync(); break;
                case "occupied": await CheckOccupiedProcessAsync(); break;
            }
            Console.WriteLine("startup-preflight:" + args[1] + ":ok");
            return 0;
        }
        catch (Exception failure)
        {
            Console.Error.WriteLine(failure.GetType().Name + ": " + failure.Message);
            return 1;
        }
    }

    [Test]
    public static void Selftest_arguments_reject_mixed_live_commands_and_result_overwrite()
    {
        foreach (var args in new[] { new[] { "--selftest", "--server", "dc.test.local" }, new[] { "--selftest", "--simulation" },
            new[] { "--selftest", "--selftest-output", "relative.json" }, new[] { "--selftest", "--selftest-output", @"\\server\share\result.json" } })
            Check.Throws<ArgumentException>(() => StartupPreflight.Parse(args), "combinaison ou sortie non locale refusée");
        Check.Null(StartupPreflight.Parse(["-MegADSelfTest"]), "alias historique explicite");
        var folder = Path.Combine(Path.GetTempPath(), "domenia-selftest-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
        try
        {
            var path = Path.Combine(folder, "result.json");
            Check.Equal(path, StartupPreflight.Parse(["--selftest", "--selftest-output", path]), "chemin local absolu neuf");
            var result = new StartupSelfTestResult("Domenia.SelfTest/1", "fixture", false, null, [], "InvalidDataException", 0);
            StartupPreflight.Save(path, result);
            var bytes = File.ReadAllBytes(path);
            using var saved = JsonDocument.Parse(bytes);
            Check.False(saved.RootElement.GetProperty("Passed").GetBoolean(), "échec enregistré sans succès fabriqué");
            Check.Throws<IOException>(() => StartupPreflight.Save(path, result with { Passed = true }), "aucun remplacement silencieux");
            Check.True(bytes.SequenceEqual(File.ReadAllBytes(path)), "preuve initiale intacte");
        }
        finally { Directory.Delete(folder, recursive: true); }
    }

    [Test]
    public static void Startup_measurements_use_one_clock_are_bounded_and_ignore_a_failed_sink()
    {
        var clock = new MonotonicClock(); var trace = new StartupMeasurements(clock, _ => throw new IOException("fixture"));
        using (trace.Measure(StartupPhase.Integrity)) clock.Advance(TimeSpan.FromMilliseconds(25));
        using (trace.Measure(StartupPhase.Assemblies)) clock.Advance(TimeSpan.FromMilliseconds(10));
        Check.Equal(35d, trace.Snapshot[1].ProcessMilliseconds, "origine commune");
        Check.Equal(10d, trace.Snapshot[1].DurationMilliseconds, "durée de l’étape");
        var scope = trace.Measure(StartupPhase.Readers); scope.Dispose(); scope.Dispose();
        Check.Equal(3, trace.Snapshot.Count, "Dispose idempotent");
        for (var i = 0; i < 40; i++) using (trace.Measure(StartupPhase.Modules)) { }
        Check.Equal(32, trace.Snapshot.Count, "borne ferme, erreur de journal ignorée");
    }
    private sealed class MonotonicClock : TimeProvider
    {
        private long ticks;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => ticks;
        public override DateTimeOffset GetUtcNow() => TestClock.Reference.AddTicks(ticks);
        internal void Advance(TimeSpan elapsed) => ticks += elapsed.Ticks;
    }

}
