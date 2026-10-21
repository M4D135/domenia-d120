using System.Globalization;
using System.Net;
using System.Reflection;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Domenia.E2E.Report;

/// <summary>
/// report.json (data) and report.html with report.css (no script, no inline style, no external resource; every text
/// escaped). Both are written again after each scenario, so a run stopped midway still leaves a readable report.
/// </summary>
internal static class ReportWriter
{
    private const string Nb = " ";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static void Write(RunReport report, string folder)
    {
        ArgumentNullException.ThrowIfNull(report);
        Directory.CreateDirectory(folder);
        WriteAtomically(Path.Combine(folder, "report.json"), JsonSerializer.Serialize(report, JsonOptions));
        WriteAtomically(Path.Combine(folder, "report.css"), Stylesheet());
        WriteAtomically(Path.Combine(folder, "report.html"), Html(report));
    }

    public static string Stylesheet()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Domenia.E2E.report.css")
            ?? throw new InvalidOperationException("Feuille de style du rapport absente de l’assemblage.");
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    /// <summary>The HTML report; public for the self-tests (escaping).</summary>
    public static string Html(RunReport report)
    {
        ArgumentNullException.ThrowIfNull(report);
        var s = report.Summary;
        var total = s.Passed + s.Failed + s.Skipped + s.Invalid;
        var ok = s.Failed == 0 && s.Invalid == 0 && s.Passed > 0;
        var h = new StringBuilder(16 * 1024);
        h.Append("<!doctype html>\n<html lang=\"fr\">\n<head>\n<meta charset=\"utf-8\">\n");
        h.Append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'self' file:; img-src 'self' file: data:; base-uri 'none'; form-action 'none'\">\n");
        h.Append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"color-scheme\" content=\"light dark\">\n");
        h.Append("<title>Rapport E2E · Domenia</title>\n<link rel=\"stylesheet\" href=\"report.css\">\n</head>\n<body>\n");
        h.Append("<header class=\"hero ").Append(ok ? "is-ok" : s.Failed + s.Invalid > 0 ? "is-fail" : "is-idle").Append("\">\n");
        h.Append("<div class=\"hero-text\"><p class=\"kicker\">Domenia 2 · harnais de bout en bout</p>");
        h.Append("<h1>").Append(ok ? "Tous les scénarios ont réussi" : s.Failed + s.Invalid > 0 ? "Des scénarios ont échoué" : "Aucun scénario exécuté").Append("</h1>");
        h.Append("<p class=\"meta\">").Append(E(Date(report.StartedAt))).Append(" · mode ").Append(E(report.Mode))
            .Append(" · ").Append(E(Duration(report.DurationMs))).Append(report.Filter.Length > 0 ? " · filtre " + E(Quote(report.Filter)) : "").Append("</p></div>\n");
        h.Append("<dl class=\"counters\">");
        Counter(h, "ok", s.Passed, "réussi", "réussis");
        Counter(h, "fail", s.Failed, "échoué", "échoués");
        Counter(h, "skip", s.Skipped, "ignoré", "ignorés");
        Counter(h, "invalid", s.Invalid, "invalide", "invalides");
        h.Append("</dl>\n</header>\n<main>\n");
        h.Append("<section class=\"facts\" aria-label=\"Contexte de l’exécution\"><dl>");
        Fact(h, "Scénarios", total.ToString(CultureInfo.InvariantCulture));
        Fact(h, "Domenia", report.DomeniaVersion ?? "inconnue");
        Fact(h, "Moteur WebView2", report.WebView2 ?? "inconnu");
        Fact(h, "Machine", report.Machine);
        Fact(h, "Exécutable", report.Exe);
        h.Append("</dl></section>\n");
        h.Append("<nav class=\"toc\" aria-label=\"Scénarios\"><ol>");
        foreach (var scenario in report.Scenarios)
        {
            h.Append("<li><a class=\"v-").Append(Css(scenario.Verdict)).Append("\" href=\"#").Append(E(Anchor(scenario.Id))).Append("\"><span class=\"dot\" aria-hidden=\"true\"></span>")
                .Append(E(scenario.Name.Length > 0 ? scenario.Name : scenario.Id)).Append("<span class=\"toc-v\">").Append(E(Verdicts.Label(scenario.Verdict))).Append("</span></a></li>");
        }
        h.Append("</ol></nav>\n");
        foreach (var scenario in report.Scenarios)
        {
            ScenarioSection(h, scenario);
        }
        h.Append("</main>\n<footer><p>Rapport produit par Domenia.E2E · format ").Append(E(report.Format)).Append(" version ").Append(report.Version.ToString(CultureInfo.InvariantCulture))
            .Append(" · données détaillées dans <a href=\"report.json\">report.json</a></p></footer>\n</body>\n</html>\n");
        return h.ToString();
    }

    private static void ScenarioSection(StringBuilder h, ScenarioResult scenario)
    {
        h.Append("<section class=\"scenario v-").Append(Css(scenario.Verdict)).Append("\" id=\"").Append(E(Anchor(scenario.Id))).Append("\">\n<header class=\"sc-head\">");
        h.Append("<div><p class=\"sc-id\">").Append(E(scenario.Id)).Append(" · ").Append(E(scenario.File)).Append("</p><h2>").Append(E(scenario.Name.Length > 0 ? scenario.Name : scenario.Id)).Append("</h2>");
        if (scenario.Description is not null)
        {
            h.Append("<p class=\"sc-desc\">").Append(E(scenario.Description)).Append("</p>");
        }
        h.Append("</div><div class=\"sc-side\"><span class=\"pill v-").Append(Css(scenario.Verdict)).Append("\">").Append(E(Verdicts.Label(scenario.Verdict))).Append("</span>");
        h.Append("<span class=\"sc-time\">").Append(E(Duration(scenario.DurationMs))).Append(scenario.StartupMs > 0 ? " · démarrage " + E(Duration(scenario.StartupMs)) : "")
            .Append(scenario.CloseMs > 0 ? " · fermeture " + E(Duration(scenario.CloseMs)) : "")
            .Append(scenario.ExitCode is int code ? " · code de sortie " + code.ToString(CultureInfo.InvariantCulture) : "").Append("</span></div></header>\n");
        if (scenario.Error is not null)
        {
            h.Append("<p class=\"sc-error\" role=\"alert\">").Append(E(scenario.Error)).Append("</p>\n");
        }
        if (scenario.Steps.Count > 0)
        {
            h.Append("<ol class=\"steps\">\n");
            foreach (var step in scenario.Steps)
            {
                h.Append("<li class=\"step v-").Append(Css(step.Verdict)).Append("\">");
                if (step.Screenshot is not null)
                {
                    h.Append("<a class=\"shot\" href=\"").Append(E(step.Screenshot)).Append("\"><img src=\"").Append(E(step.Screenshot)).Append("\" alt=\"Capture après l’étape ")
                        .Append(step.Index.ToString(CultureInfo.InvariantCulture)).Append("\" loading=\"lazy\"></a>");
                }
                else
                {
                    h.Append("<span class=\"shot none\">").Append(step.Verdict == Verdicts.NotRun ? "Étape non exécutée" : "Pas de capture").Append("</span>");
                }
                h.Append("<div class=\"step-body\"><p class=\"step-top\"><span class=\"num\">").Append(step.Index.ToString(CultureInfo.InvariantCulture)).Append("</span>")
                    .Append("<span class=\"act\">").Append(E(step.Action)).Append("</span><span class=\"pill sm v-").Append(Css(step.Verdict)).Append("\">")
                    .Append(E(Verdicts.StepLabel(step.Verdict))).Append("</span></p><p class=\"step-title\">").Append(E(step.Title)).Append("</p>");
                if (step.Verdict != Verdicts.NotRun)
                {
                    h.Append("<p class=\"step-time\">").Append(E(Duration(step.DurationMs))).Append("</p>");
                }
                if (step.Error is not null)
                {
                    h.Append("<p class=\"step-error\">").Append(E(step.Error)).Append("</p>");
                }
                h.Append("</div></li>\n");
            }
            h.Append("</ol>\n");
        }
        ConsoleList(h, "Erreurs de la console", scenario.ConsoleErrors, "Aucune erreur dans la console de la page.", open: scenario.ConsoleErrors.Count > 0);
        ConsoleList(h, "Avertissements de la console", scenario.ConsoleWarnings, "Aucun avertissement.", open: false);
        h.Append("<details class=\"journal\"><summary>Journal technique pendant le scénario <span class=\"count\">")
            .Append(scenario.Journal.Count.ToString(CultureInfo.InvariantCulture)).Append(" ligne(s)</span></summary>");
        h.Append(scenario.Journal.Count == 0 ? "<p class=\"empty\">Aucune ligne.</p>" : "<pre>" + E(string.Join("\n", scenario.Journal)) + "</pre>").Append("</details>\n");
        h.Append("</section>\n");
    }

    private static void ConsoleList(StringBuilder h, string title, List<ConsoleEntry> entries, string empty, bool open)
    {
        h.Append("<details class=\"console\"").Append(open ? " open" : "").Append("><summary>").Append(E(title)).Append(" <span class=\"count\">")
            .Append(entries.Count.ToString(CultureInfo.InvariantCulture)).Append("</span></summary>");
        if (entries.Count == 0)
        {
            h.Append("<p class=\"empty\">").Append(E(empty)).Append("</p>");
        }
        else
        {
            h.Append("<ul>");
            foreach (var entry in entries)
            {
                h.Append("<li><span class=\"c-step\">étape ").Append(entry.Step.ToString(CultureInfo.InvariantCulture)).Append("</span><span class=\"c-src\">")
                    .Append(E(entry.Source)).Append("</span><code>").Append(E(entry.Text)).Append("</code></li>");
            }
            h.Append("</ul>");
        }
        h.Append("</details>\n");
    }

    private static void Counter(StringBuilder h, string css, int value, string one, string many) =>
        h.Append("<div class=\"counter c-").Append(css).Append("\"><dt>").Append(value <= 1 ? one : many).Append("</dt><dd>")
            .Append(value.ToString(CultureInfo.InvariantCulture)).Append("</dd></div>");

    private static void Fact(StringBuilder h, string name, string value) =>
        h.Append("<div><dt>").Append(E(name)).Append("</dt><dd>").Append(E(value)).Append("</dd></div>");

    /// <summary>HTML text and attribute escaping (&lt; &gt; &amp; " ').</summary>
    public static string E(string? text) => WebUtility.HtmlEncode(text ?? "");

    private static string Css(string verdict) => verdict switch
    {
        Verdicts.Passed => "ok",
        Verdicts.Failed => "fail",
        Verdicts.Skipped => "skip",
        Verdicts.Invalid => "invalid",
        _ => "notrun",
    };

    private static string Anchor(string id) => "sc-" + id.Replace('/', '-');

    private static string Quote(string text) => "«" + Nb + text + Nb + "»";

    /// <summary>« 1,8 s », « 640 ms », « 2 min 05 s ».</summary>
    public static string Duration(long ms)
    {
        var fr = CultureInfo.GetCultureInfo("fr-FR");
        if (ms < 1000)
        {
            return ms.ToString(CultureInfo.InvariantCulture) + Nb + "ms";
        }
        if (ms < 60_000)
        {
            return (ms / 1000.0).ToString("0.0", fr) + Nb + "s";
        }
        var span = TimeSpan.FromMilliseconds(ms);
        return ((int)span.TotalMinutes).ToString(CultureInfo.InvariantCulture) + Nb + "min" + Nb + span.Seconds.ToString("00", CultureInfo.InvariantCulture) + Nb + "s";
    }

    private static string Date(DateTimeOffset at)
    {
        var local = at.ToLocalTime();
        return local.ToString("d MMMM yyyy", CultureInfo.GetCultureInfo("fr-FR")) + " à " + local.ToString("HH' h 'mm", CultureInfo.InvariantCulture);
    }

    private static void WriteAtomically(string path, string text)
    {
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, text, new UTF8Encoding(false));
        File.Move(temporary, path, overwrite: true);
    }
}
