namespace Domenia.E2E.Report;

/// <summary>Verdict codes of the JSON report (French labels in the HTML report).</summary>
internal static class Verdicts
{
    public const string Passed = "passed";
    public const string Failed = "failed";
    public const string Skipped = "skipped";
    public const string Invalid = "invalid";
    public const string NotRun = "notRun";

    public static string Label(string code) => code switch
    {
        Passed => "réussi",
        Failed => "échoué",
        Skipped => "ignoré",
        Invalid => "invalide",
        NotRun => "non exécutée",
        _ => code,
    };

    public static string StepLabel(string code) => code switch
    {
        Passed => "réussie",
        Failed => "échouée",
        NotRun => "non exécutée",
        _ => Label(code),
    };
}

/// <summary>report.json: format « domenia.e2e.report », version 1 (docs/E2E.md § 6).</summary>
internal sealed class RunReport
{
    public string Format { get; init; } = "domenia.e2e.report";

    public int Version { get; init; } = 1;

    public DateTimeOffset StartedAt { get; init; }

    public long DurationMs { get; set; }

    public string Mode { get; init; } = "simulation";

    public string Filter { get; init; } = "";

    public string Exe { get; init; } = "";

    public string Machine { get; init; } = "";

    public string? DomeniaVersion { get; set; }

    public string? WebView2 { get; set; }

    public RunSummary Summary { get; } = new();

    public List<ScenarioResult> Scenarios { get; } = [];
}

internal sealed class RunSummary
{
    public int Passed { get; set; }

    public int Failed { get; set; }

    public int Skipped { get; set; }

    public int Invalid { get; set; }
}

internal sealed class ScenarioResult
{
    public string Id { get; init; } = "";

    public string File { get; init; } = "";

    public string Name { get; set; } = "";

    public string? Description { get; set; }

    public string Verdict { get; set; } = Verdicts.NotRun;

    public long DurationMs { get; set; }

    public long StartupMs { get; set; }

    /// <summary>Closing of the window, end of the process and release of the DevTools port (profile free again).</summary>
    public long CloseMs { get; set; }

    public string? Error { get; set; }

    public int? ExitCode { get; set; }

    public List<StepResult> Steps { get; } = [];

    public List<ConsoleEntry> ConsoleErrors { get; } = [];

    public List<ConsoleEntry> ConsoleWarnings { get; } = [];

    public List<string> Journal { get; } = [];
}

internal sealed class StepResult
{
    public int Index { get; init; }

    public string Action { get; init; } = "";

    public string Title { get; init; } = "";

    public string Verdict { get; set; } = Verdicts.NotRun;

    public long DurationMs { get; set; }

    public string? Error { get; set; }

    /// <summary>Relative to the report folder (shots/&lt;écran&gt;/&lt;nom&gt;/NN-…png).</summary>
    public string? Screenshot { get; set; }
}

/// <summary>A message of the page console (console.error, uncaught exception, browser log such as a CSP refusal).</summary>
internal sealed record ConsoleEntry(int Step, string Level, string Source, string Text);
