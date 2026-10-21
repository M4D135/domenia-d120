using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.Text;
using Domenia.E2E.Report;
using Domenia.E2E.Runner;
using Domenia.E2E.Scenarios;

namespace Domenia.E2E;

/// <summary>
/// Domenia.E2E.exe (docs/E2E.md):
///   run --exe &lt;Domenia.exe&gt; --scenarios &lt;dossier&gt; [--filter motif] [--mode simulation|annuaire] [--out dossier]
///   self-test
/// Exit codes: 0 every scenario passed (ignored ones aside), 1 at least one failed or invalid, 2 usage or environment error.
/// </summary>
internal static class Program
{
    private const int Success = 0;
    private const int Failures = 1;
    private const int UsageError = 2;

    private const string Usage = """
        Usage :
          Domenia.E2E.exe run --exe <Domenia.exe> --scenarios <dossier> [--filter motif] [--mode simulation|annuaire] [--out dossier]
          Domenia.E2E.exe self-test
        """;

    private static async Task<int> Main(string[] args)
    {
        try
        {
            Console.OutputEncoding = new UTF8Encoding(false);
        }
        catch (IOException)
        {
            // No console (redirected output keeps its own encoding).
        }
        if (args.Length > 0 && args[0] == "self-test")
        {
            return SelfTests.Run();
        }
        var command = args.Length > 0 && !args[0].StartsWith("--", StringComparison.Ordinal) ? args[0] : "run";
        if (command != "run")
        {
            Console.Error.WriteLine(Usage);
            return UsageError;
        }
        if (!TryParse(args.SkipWhile(a => a == "run").ToArray(), out var options, out var error))
        {
            Console.Error.WriteLine("Domenia.E2E : " + error);
            Console.Error.WriteLine(Usage);
            return UsageError;
        }
        using var cancel = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            cancel.Cancel();
        };
        try
        {
            return await RunAsync(options, cancel.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("Domenia.E2E : exécution interrompue.");
            return UsageError;
        }
    }

    internal static bool TryParse(IReadOnlyList<string> args, [NotNullWhen(true)] out RunOptions? options, out string? error)
    {
        options = null;
        error = null;
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var n = 0; n < args.Count; n++)
        {
            var name = args[n];
            if (name is not ("--exe" or "--scenarios" or "--filter" or "--mode" or "--out"))
            {
                error = $"option inconnue : {name}";
                return false;
            }
            if (n + 1 >= args.Count || args[n + 1].StartsWith("--", StringComparison.Ordinal))
            {
                error = $"valeur manquante après {name}";
                return false;
            }
            if (!values.TryAdd(name, args[++n]))
            {
                error = $"option répétée : {name}";
                return false;
            }
        }
        if (!values.TryGetValue("--exe", out var exe) || !values.TryGetValue("--scenarios", out var scenarios))
        {
            error = "--exe et --scenarios sont obligatoires";
            return false;
        }
        var mode = values.GetValueOrDefault("--mode", "simulation") switch
        {
            "simulation" => RunMode.Simulation,
            "annuaire" => RunMode.Annuaire,
            _ => (RunMode?)null,
        };
        if (mode is null)
        {
            error = "--mode vaut simulation ou annuaire";
            return false;
        }
        var filter = values.GetValueOrDefault("--filter");
        if (!ScenarioCatalog.IsValidFilter(filter))
        {
            error = "--filter : lettres, chiffres et « * ? _ . / , - » seulement, 200 caractères au plus";
            return false;
        }
        var output = values.GetValueOrDefault("--out") ?? Path.Combine(Environment.CurrentDirectory, "e2e-report");
        options = new RunOptions(Path.GetFullPath(exe), Path.GetFullPath(scenarios), filter, mode.Value, Path.GetFullPath(output));
        return true;
    }

    private static async Task<int> RunAsync(RunOptions options, CancellationToken cancellationToken)
    {
        if (!File.Exists(options.Exe))
        {
            Console.Error.WriteLine($"Domenia.E2E : exécutable introuvable : {options.Exe}");
            return UsageError;
        }
        if (!Directory.Exists(options.ScenariosRoot))
        {
            Console.Error.WriteLine($"Domenia.E2E : dossier des scénarios introuvable : {options.ScenariosRoot}");
            return UsageError;
        }
        var files = ScenarioCatalog.Find(options.ScenariosRoot, options.Filter);
        if (files.Count == 0)
        {
            Console.Error.WriteLine($"Domenia.E2E : aucun scénario ne correspond à « {options.Filter ?? "*"} » dans {options.ScenariosRoot}.");
            return UsageError;
        }
        if (!PrepareOutput(options.Output, out var refusal))
        {
            Console.Error.WriteLine("Domenia.E2E : " + refusal);
            return UsageError;
        }
        var modeName = options.Mode == RunMode.Simulation ? "simulation" : "annuaire";
        var report = new RunReport
        {
            StartedAt = DateTimeOffset.UtcNow,
            Mode = modeName,
            Filter = options.Filter ?? "",
            Exe = options.Exe,
            Machine = Environment.MachineName,
        };
        var clock = Stopwatch.StartNew();
        var runner = new ScenarioRunner(options, report);
        Console.WriteLine($"Domenia.E2E : {files.Count} scénario(s), mode {modeName}, rapport dans {options.Output}");
        foreach (var file in files)
        {
            ScenarioResult result;
            Scenario scenario;
            try
            {
                scenario = ScenarioLoader.Load(file.Path, file.Id);
            }
            catch (Exception ex) when (ex is ScenarioException or IOException or UnauthorizedAccessException)
            {
                result = new ScenarioResult { Id = file.Id, File = file.Screen + "/" + Path.GetFileName(file.Path), Name = file.Id, Verdict = Verdicts.Invalid, Error = "Scénario invalide : " + ex.Message };
                Console.WriteLine($"✗ {file.Id} : {result.Error}");
                Add(report, result);
                continue;
            }
            if (!scenario.Modes.Contains(options.Mode))
            {
                result = new ScenarioResult { Id = file.Id, File = file.Screen + "/" + Path.GetFileName(file.Path), Name = scenario.Name, Description = scenario.Description, Verdict = Verdicts.Skipped, Error = $"Prévu pour le mode {string.Join(", ", scenario.Modes.Select(m => m == RunMode.Simulation ? "simulation" : "annuaire"))} seulement." };
                Console.WriteLine($"– {file.Id} : ignoré ({result.Error})");
                Add(report, result);
                continue;
            }
            Console.WriteLine($"▶ {file.Id} — {scenario.Name}");
            result = await runner.RunAsync(scenario, cancellationToken).ConfigureAwait(false);
            Console.WriteLine($"{(result.Verdict == Verdicts.Passed ? "✓" : "✗")} {file.Id} : {Verdicts.Label(result.Verdict)} en {ReportWriter.Duration(result.DurationMs)}{(result.Error is null ? "" : " — " + result.Error)}");
            Add(report, result);
            report.DurationMs = clock.ElapsedMilliseconds;
            ReportWriter.Write(report, options.Output);
        }
        report.DurationMs = clock.ElapsedMilliseconds;
        ReportWriter.Write(report, options.Output);
        var s = report.Summary;
        Console.WriteLine($"Bilan : {s.Passed} réussi(s), {s.Failed} échoué(s), {s.Skipped} ignoré(s), {s.Invalid} invalide(s) en {ReportWriter.Duration(report.DurationMs)}.");
        Console.WriteLine($"Rapport : {Path.Combine(options.Output, "report.html")}");
        return s.Failed + s.Invalid > 0 ? Failures : Success;
    }

    private static void Add(RunReport report, ScenarioResult result)
    {
        report.Scenarios.Add(result);
        switch (result.Verdict)
        {
            case Verdicts.Passed:
                report.Summary.Passed++;
                break;
            case Verdicts.Skipped:
                report.Summary.Skipped++;
                break;
            case Verdicts.Invalid:
                report.Summary.Invalid++;
                break;
            default:
                report.Summary.Failed++;
                break;
        }
    }

    /// <summary>A report.json of this harness (folders written before the marker existed).</summary>
    private static bool HoldsReport(string folder)
    {
        var path = Path.Combine(folder, "report.json");
        try
        {
            return File.Exists(path) && new FileInfo(path).Length < 64 * 1024 * 1024
                && File.ReadAllText(path).Contains("\"format\": \"domenia.e2e.report\"", StringComparison.Ordinal);
        }
        catch (IOException)
        {
            return false;
        }
    }

    /// <summary>Marks a folder as an E2E report folder: only such a folder (or an empty one) is ever cleaned.</summary>
    internal const string Marker = ".domenia-e2e";

    /// <summary>
    /// Removes the previous report of this folder, its own names only (report.*, shots), and only when the folder holds the
    /// marker of an earlier run or is empty: a folder given by mistake (a home folder, a drive root) is refused untouched.
    /// </summary>
    internal static bool PrepareOutput(string folder, out string? refusal)
    {
        refusal = null;
        if (Directory.Exists(folder) && !File.Exists(Path.Combine(folder, Marker)) && !HoldsReport(folder) && Directory.EnumerateFileSystemEntries(folder).Any())
        {
            refusal = $"le dossier de sortie {folder} n’est pas vide et ne contient pas de rapport E2E précédent ({Marker}) : choisissez un dossier vide ou dédié.";
            return false;
        }
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, Marker), "Dossier de rapport du harnais E2E de Domenia (docs/E2E.md).\n");
        foreach (var name in new[] { "report.json", "report.html", "report.css" })
        {
            var path = Path.Combine(folder, name);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        var shots = Path.Combine(folder, "shots");
        if (Directory.Exists(shots))
        {
            Directory.Delete(shots, recursive: true);
        }
        return true;
    }
}
