using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Domenia.E2E.Cdp;
using Domenia.E2E.Driver;
using Domenia.E2E.Report;
using Domenia.E2E.Scenarios;

namespace Domenia.E2E.Runner;

/// <summary>Options of a run (command line of Domenia.E2E.exe).</summary>
internal sealed record RunOptions(string Exe, string ScenariosRoot, string? Filter, RunMode Mode, string Output);

/// <summary>A step that did not reach its goal, in French (shown in the report and the console).</summary>
internal sealed class StepFailure(string message) : Exception(message)
{
}

/// <summary>
/// Runs one scenario in a fresh Domenia process: start, mode check, start screen ready, each step with its screenshot,
/// console and journal collected, window closed. A failed step stops the scenario; the following steps are « non
/// exécutées ».
/// </summary>
internal sealed partial class ScenarioRunner(RunOptions options, RunReport report)
{
    /// <summary>Lets the interface answer an action (animation, toast) before its screenshot.</summary>
    private const int SettleMs = 300;

    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(100);
    private static readonly TimeSpan ReadyLimit = TimeSpan.FromSeconds(30);

    public async Task<ScenarioResult> RunAsync(Scenario scenario, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scenario);
        var result = new ScenarioResult { Id = scenario.Id, File = Relative(scenario.File), Name = scenario.Name, Description = scenario.Description };
        var clock = Stopwatch.StartNew();
        var shots = Path.Combine(options.Output, "shots", scenario.Id.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(shots);
        var journal = JournalTail.FromNow();
        AppSession? session = null;
        var failed = false;
        try
        {
            session = await AppSession.StartAsync(options.Exe, options.Mode, journal, cancellationToken).ConfigureAwait(false);
            report.WebView2 ??= session.BrowserVersion;
            await PrepareAsync(session, scenario, cancellationToken).ConfigureAwait(false);
            result.StartupMs = clock.ElapsedMilliseconds;
            var start = new StepResult
            {
                Index = 0,
                Action = "start",
                Title = $"Démarrage : écran « {scenario.StartScreen} » prêt",
                Verdict = Verdicts.Passed,
                DurationMs = result.StartupMs,
            };
            start.Screenshot = await ShotAsync(session, shots, 0, "depart", null, cancellationToken).ConfigureAwait(false);
            result.Steps.Add(start);
            Console.WriteLine($"  [0/{scenario.Steps.Count}] Démarrage : réussi ({result.StartupMs} ms)");
            foreach (var step in scenario.Steps)
            {
                var stepResult = new StepResult { Index = step.Index, Action = Name(step.Action), Title = step.Describe() };
                result.Steps.Add(stepResult);
                if (failed)
                {
                    continue;
                }
                session.CurrentStep = step.Index;
                var stepClock = Stopwatch.StartNew();
                TargetInfo? clip = null;
                try
                {
                    clip = await ExecuteAsync(session, step, cancellationToken).ConfigureAwait(false);
                    stepResult.Verdict = Verdicts.Passed;
                }
                catch (Exception ex) when (ex is StepFailure or PageScriptException or CdpException)
                {
                    stepResult.Verdict = Verdicts.Failed;
                    stepResult.Error = ex.Message;
                    result.Error = $"Étape {step.Index} ({stepResult.Title}) : {ex.Message}";
                    failed = true;
                }
                stepResult.DurationMs = stepClock.ElapsedMilliseconds;
                if (!failed && session.Exited)
                {
                    stepResult.Verdict = Verdicts.Failed;
                    stepResult.Error = $"Domenia s’est fermé pendant l’étape (code {session.ExitCode}).";
                    result.Error = $"Étape {step.Index} : {stepResult.Error}";
                    failed = true;
                }
                Console.WriteLine($"  [{step.Index}/{scenario.Steps.Count}] {stepResult.Title} : {Verdicts.StepLabel(stepResult.Verdict)} ({stepResult.DurationMs} ms){(stepResult.Error is null ? "" : " — " + stepResult.Error)}");
                if (!session.Exited)
                {
                    var name = step.Action == StepAction.Shot ? step.Name! : Name(step.Action);
                    stepResult.Screenshot = await ShotAsync(session, shots, step.Index, name, step.Action == StepAction.Shot ? clip : null, cancellationToken).ConfigureAwait(false);
                }
            }
            result.Verdict = failed ? Verdicts.Failed : Verdicts.Passed;
        }
        catch (Exception ex) when (ex is SessionException or CdpException or PageScriptException or IOException or System.ComponentModel.Win32Exception)
        {
            result.Verdict = Verdicts.Failed;
            result.Error = ex is System.ComponentModel.Win32Exception ? $"Domenia n’a pas pu être lancé ({ex.Message})." : ex.Message;
            Console.WriteLine("  Démarrage en échec : " + result.Error);
        }
        finally
        {
            if (session is not null)
            {
                var closing = Stopwatch.StartNew();
                result.ExitCode = await session.CloseAsync().ConfigureAwait(false);
                result.CloseMs = closing.ElapsedMilliseconds;
                foreach (var entry in session.ConsoleSnapshot())
                {
                    (entry.Level == "error" ? result.ConsoleErrors : result.ConsoleWarnings).Add(entry);
                }
                await session.DisposeAsync().ConfigureAwait(false);
            }
            result.Journal.AddRange(journal.Lines().Take(400));
            report.DomeniaVersion ??= VersionOf(result.Journal);
        }
        if (result.Verdict == Verdicts.Passed && result.ConsoleErrors.Count > 0 && !scenario.AllowConsoleErrors)
        {
            result.Verdict = Verdicts.Failed;
            result.Error = $"{result.ConsoleErrors.Count} erreur(s) dans la console de la page (voir la liste ; « allowConsoleErrors » les admet).";
        }
        if (result.Verdict == Verdicts.Passed && result.ExitCode is int code && code != 0)
        {
            result.Verdict = Verdicts.Failed;
            result.Error = $"Domenia s’est terminé avec le code {code} (erreur imprévue : voir le journal technique).";
        }
        result.DurationMs = clock.ElapsedMilliseconds;
        return result;
    }

    /// <summary>Mode actually chosen by Domenia, page preferences, fresh load of the start screen.</summary>
    private async Task PrepareAsync(AppSession session, Scenario scenario, CancellationToken cancellationToken)
    {
        var expected = options.Mode == RunMode.Simulation ? "Simulation" : "Directory";
        var startLine = await PollAsync(() =>
        {
            var line = session.Journal.Lines().LastOrDefault(l => l.Contains("Démarrage de Domenia", StringComparison.Ordinal));
            return Task.FromResult((line is not null, line));
        }, TimeSpan.FromSeconds(15), cancellationToken).ConfigureAwait(false);
        if (startLine.Value is not string line)
        {
            throw new SessionException("Ligne de démarrage absente du journal technique : mode de Domenia inconnu.");
        }
        var mode = StartPattern().Match(line);
        if (!mode.Success || mode.Groups["mode"].Value != expected)
        {
            throw new SessionException($"Domenia a démarré en mode {(mode.Success ? mode.Groups["mode"].Value : "inconnu")} au lieu de {expected} (--mode {(options.Mode == RunMode.Simulation ? "simulation" : "annuaire")}).");
        }
        if (scenario.Theme is not null || scenario.Motion is not null)
        {
            var prefs = new JsonObject();
            if (scenario.Theme is not null)
            {
                prefs["theme"] = scenario.Theme;
            }
            if (scenario.Motion is not null)
            {
                prefs["motion"] = scenario.Motion;
            }
            await session.Page.AddStartupScriptAsync(PageScripts.Call(PageScripts.PresetPreferences, prefs), cancellationToken).ConfigureAwait(false);
        }
        var before = await session.Page.ProbeAsync(new JsonObject(), cancellationToken).ConfigureAwait(false);
        var origin = Number(before, "origin");
        await session.Page.CallAsync(PageScripts.Go, JsonValue.Create(scenario.Start), cancellationToken).ConfigureAwait(false);
        await session.Page.ReloadAsync(cancellationToken).ConfigureAwait(false);
        var ready = await PollAsync(async () =>
        {
            var probe = await session.Page.ProbeAsync(new JsonObject(), cancellationToken).ConfigureAwait(false);
            var done = Number(probe, "origin") != origin && Bool(probe, "complete") && Str(probe, "ready") == scenario.StartScreen;
            return (done, Str(probe, "ready"));
        }, ReadyLimit, cancellationToken).ConfigureAwait(false);
        if (!ready.Done)
        {
            throw new SessionException($"L’écran de départ « {scenario.StartScreen} » n’est jamais devenu prêt (data-ready : {ready.Value ?? "absent"}) en {(int)ReadyLimit.TotalSeconds} s.");
        }
    }

    private async Task<TargetInfo?> ExecuteAsync(AppSession session, Step step, CancellationToken cancellationToken)
    {
        var page = session.Page;
        var timeout = TimeSpan.FromMilliseconds(step.TimeoutMs);
        switch (step.Action)
        {
            case StepAction.Go:
                await page.CallAsync(PageScripts.Go, JsonValue.Create(step.Route), cancellationToken).ConfigureAwait(false);
                var screen = Step.ScreenOf(step.Route!);
                var ready = await PollAsync(async () =>
                {
                    var probe = await page.ProbeAsync(new JsonObject(), cancellationToken).ConfigureAwait(false);
                    return (Bool(probe, "complete") && Str(probe, "ready") == screen, Str(probe, "ready"));
                }, timeout, cancellationToken).ConfigureAwait(false);
                if (!ready.Done)
                {
                    throw new StepFailure($"écran « {screen} » jamais prêt (data-ready : {ready.Value ?? "absent"}).");
                }
                return null;
            case StepAction.Click:
                var target = await WaitTargetAsync(page, step.Locator(hit: true, enabled: true), timeout, cancellationToken).ConfigureAwait(false);
                await page.ClickAsync(target.X, target.Y, step.Button, step.ClickCount, cancellationToken).ConfigureAwait(false);
                await Task.Delay(SettleMs, cancellationToken).ConfigureAwait(false);
                return target;
            case StepAction.Hover:
                var hovered = await WaitTargetAsync(page, step.Locator(hit: true, enabled: false), timeout, cancellationToken).ConfigureAwait(false);
                await page.MoveAsync(hovered.X, hovered.Y, cancellationToken).ConfigureAwait(false);
                await Task.Delay(SettleMs, cancellationToken).ConfigureAwait(false);
                return hovered;
            case StepAction.Type:
                if (step.Selector is not null)
                {
                    var field = await WaitTargetAsync(page, step.Locator(hit: true, enabled: true), timeout, cancellationToken).ConfigureAwait(false);
                    await page.ClickAsync(field.X, field.Y, "left", 1, cancellationToken).ConfigureAwait(false);
                }
                if (step.Clear)
                {
                    await page.PressAsync(Keys.Parse("Control+A", out _)!, cancellationToken).ConfigureAwait(false);
                    await page.PressAsync(Keys.Parse("Backspace", out _)!, cancellationToken).ConfigureAwait(false);
                }
                if (step.Text!.Length > 0)
                {
                    await page.InsertTextAsync(step.Text, cancellationToken).ConfigureAwait(false);
                }
                await Task.Delay(SettleMs, cancellationToken).ConfigureAwait(false);
                return null;
            case StepAction.Press:
                for (var n = 0; n < step.Repeat; n++)
                {
                    await page.PressAsync(step.Key!, cancellationToken).ConfigureAwait(false);
                    await Task.Delay(40, cancellationToken).ConfigureAwait(false);
                }
                await Task.Delay(SettleMs, cancellationToken).ConfigureAwait(false);
                return null;
            case StepAction.Expect or StepAction.Wait:
                if (step.Ms is int ms)
                {
                    await Task.Delay(ms, cancellationToken).ConfigureAwait(false);
                    return null;
                }
                var spec = step.ProbeSpec();
                var outcome = await PollAsync(async () =>
                {
                    var probe = await page.ProbeAsync(spec, cancellationToken).ConfigureAwait(false);
                    var (ok, seen) = Evaluate(step, probe);
                    return (ok, seen);
                }, timeout, cancellationToken).ConfigureAwait(false);
                if (!outcome.Done)
                {
                    var head = step.Action == StepAction.Expect ? "vérification en échec" : "délai dépassé";
                    throw new StepFailure($"{head} après {step.TimeoutMs} ms ; constaté : {outcome.Value}.");
                }
                return null;
            case StepAction.Shot:
                return step.Selector is null && step.Within is null
                    ? null
                    : await WaitTargetAsync(page, step.Locator(hit: false, enabled: false), timeout, cancellationToken).ConfigureAwait(false);
            case StepAction.Scroll:
                var area = await WaitTargetAsync(page, step.Locator(hit: false, enabled: false, defaultSelector: ".main"), timeout, cancellationToken).ConfigureAwait(false);
                await page.WheelAsync(area.X, area.Y, step.DeltaY ?? 0, cancellationToken).ConfigureAwait(false);
                await Task.Delay(SettleMs * 2, cancellationToken).ConfigureAwait(false);
                return null;
            case StepAction.Journal:
                return await JournalAsync(session, step, timeout, cancellationToken).ConfigureAwait(false);
            default:
                throw new StepFailure($"action {step.Action} non prise en charge.");
        }
    }

    private static async Task<TargetInfo?> JournalAsync(AppSession session, Step step, TimeSpan timeout, CancellationToken cancellationToken)
    {
        bool Matches(string line)
        {
            try
            {
                return step.Pattern?.IsMatch(line) ?? line.Contains(step.Contains!, StringComparison.Ordinal);
            }
            catch (RegexMatchTimeoutException)
            {
                throw new StepFailure("expression régulière trop lente sur le journal.");
            }
        }
        if (step.Absent)
        {
            // Point-in-time check: what the journal holds when the step runs.
            var found = session.Journal.Lines().FirstOrDefault(Matches);
            return found is null ? null : throw new StepFailure($"ligne présente dans le journal : {Clip(found)}");
        }
        var hit = await PollAsync(() =>
        {
            var line = session.Journal.Lines().FirstOrDefault(Matches);
            return Task.FromResult((line is not null, line));
        }, timeout, cancellationToken).ConfigureAwait(false);
        return hit.Done ? null : throw new StepFailure($"aucune ligne correspondante dans le journal technique après {step.TimeoutMs} ms.");
    }

    /// <summary>Waits until the element is ready for the action; on timeout, says why in French.</summary>
    private static async Task<TargetInfo> WaitTargetAsync(PageDriver page, JsonObject locator, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var outcome = await PollAsync(async () =>
        {
            var info = await page.TargetAsync(locator, cancellationToken).ConfigureAwait(false);
            return (info.Ok, info);
        }, timeout, cancellationToken).ConfigureAwait(false);
        if (outcome.Done)
        {
            return outcome.Value;
        }
        var info = outcome.Value;
        var what = Locate(locator);
        throw new StepFailure(info.State switch
        {
            "scope" => $"zone {locator["within"]} introuvable ou masquée.",
            "missing" => $"aucun élément visible pour {what}.",
            "ambiguous" => $"{info.Count} éléments visibles pour {what} : précisez « within » ou « nth » ({string.Join(" ; ", info.Sample)}).",
            "nth" => $"seulement {info.Count} élément(s) pour {what}.",
            "moving" => $"élément toujours en mouvement : {info.What}.",
            "offscreen" => $"élément hors de la fenêtre : {info.What}.",
            "disabled" => $"élément désactivé : {info.What}.",
            "covered" => $"élément recouvert par {info.By} : {info.What}.",
            _ => $"élément non disponible ({info.State}).",
        });
    }

    private static string Locate(JsonObject locator)
    {
        var text = locator["text"]?.GetValue<string>();
        var selector = locator["selector"]?.GetValue<string>();
        return text is not null ? $"« {text} »" + (selector is null ? "" : $" ({selector})") : selector ?? "?";
    }

    /// <summary>Compares the facts reported by the page with what the step expects.</summary>
    internal static (bool Ok, string Seen) Evaluate(Step step, JsonElement probe)
    {
        var scope = Bool(probe, "scope");
        var count = probe.ValueKind == JsonValueKind.Object && probe.TryGetProperty("count", out var c) && c.TryGetInt32(out var n) ? n : 0;
        var sample = probe.ValueKind == JsonValueKind.Object && probe.TryGetProperty("sample", out var s) && s.ValueKind == JsonValueKind.Array
            ? string.Join(" ; ", s.EnumerateArray().Select(e => e.GetString()))
            : "";
        var seen = count == 0 ? "aucun élément visible" : $"{count} élément(s) visible(s)" + (sample.Length == 0 ? "" : $" ({sample})");
        if (step.Ready is not null)
        {
            var ready = Str(probe, "ready");
            return (Bool(probe, "complete") && ready == step.Ready, $"écran prêt : {ready ?? "aucun"}");
        }
        if (step.Contains is not null)
        {
            if (!scope)
            {
                return (step.Absent, $"zone {step.Within} introuvable ou masquée");
            }
            var has = Bool(probe, "contains");
            return (step.Absent ? !has : has, has ? "texte présent" : "texte absent");
        }
        if (!scope)
        {
            return (step.Absent || step.Count == 0, $"zone {step.Within} introuvable ou masquée");
        }
        if (step.Property is not null || step.Attribute is not null)
        {
            if (!Bool(probe, "hasValue"))
            {
                return (false, count <= 1 ? seen : seen + " : précisez « within » ou « nth »");
            }
            var value = probe.GetProperty("value");
            return (JsonEquals(value, step.Expected), "valeur " + value.GetRawText());
        }
        if (step.Count is int expected)
        {
            return (count == expected, seen);
        }
        return (step.Absent ? count == 0 : count >= 1, seen);
    }

    internal static bool JsonEquals(JsonElement actual, JsonElement expected) => (actual.ValueKind, expected.ValueKind) switch
    {
        (JsonValueKind.Number, JsonValueKind.Number) => actual.GetDouble().Equals(expected.GetDouble()),
        (JsonValueKind.String, JsonValueKind.String) => string.Equals(actual.GetString(), expected.GetString(), StringComparison.Ordinal),
        (JsonValueKind.True, JsonValueKind.True) or (JsonValueKind.False, JsonValueKind.False) or (JsonValueKind.Null, JsonValueKind.Null) => true,
        _ => false,
    };

    /// <summary>Screenshot after a step; a failure to take it is written in the console, never fatal.</summary>
    private async Task<string?> ShotAsync(AppSession session, string folder, int index, string name, TargetInfo? clip, CancellationToken cancellationToken)
    {
        try
        {
            var png = await session.Page.ScreenshotAsync(clip, cancellationToken).ConfigureAwait(false);
            var file = $"{index.ToString("00", CultureInfo.InvariantCulture)}-{name}.png";
            await File.WriteAllBytesAsync(Path.Combine(folder, file), png, cancellationToken).ConfigureAwait(false);
            return Path.GetRelativePath(options.Output, Path.Combine(folder, file)).Replace('\\', '/');
        }
        catch (Exception ex) when (ex is CdpException or IOException or FormatException)
        {
            Console.WriteLine($"  Capture de l’étape {index} impossible : {ex.Message}");
            return null;
        }
    }

    private static async Task<(bool Done, T Value)> PollAsync<T>(Func<Task<(bool Done, T Value)>> probe, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var started = Stopwatch.GetTimestamp();
        while (true)
        {
            var (done, value) = await probe().ConfigureAwait(false);
            if (done || Stopwatch.GetElapsedTime(started) >= timeout)
            {
                return (done, value);
            }
            await Task.Delay(PollInterval, cancellationToken).ConfigureAwait(false);
        }
    }

    private string Relative(string path)
    {
        var root = Path.GetDirectoryName(Path.GetFullPath(options.ScenariosRoot)) ?? options.ScenariosRoot;
        return Path.GetRelativePath(root, path).Replace('\\', '/');
    }

    private static string? VersionOf(IEnumerable<string> journal)
    {
        foreach (var line in journal)
        {
            var match = StartPattern().Match(line);
            if (match.Success)
            {
                return match.Groups["version"].Value;
            }
        }
        return null;
    }

    private static string Name(StepAction action) => action.ToString().ToLowerInvariant();

    private static string Clip(string text) => text.Length > 300 ? text[..300] + "…" : text;

    private static bool Bool(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    private static string? Str(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static double Number(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : double.NaN;

    /// <summary>« Démarrage de Domenia 2.0.0-dev : mode Simulation, raison Argument. » (Program.ResolveMode).</summary>
    [GeneratedRegex(@"Démarrage de Domenia (?<version>\S+) : mode (?<mode>[A-Za-z]+),", RegexOptions.CultureInvariant)]
    private static partial Regex StartPattern();
}
