using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.App.E2e;
using Domenia.E2E.Cdp;
using Domenia.E2E.Driver;
using Domenia.E2E.Report;
using Domenia.E2E.Runner;
using Domenia.E2E.Scenarios;

namespace Domenia.E2E;

/// <summary>
/// Self-tests of the harness and of the E2E switch of Domenia.App (compiled from its source): no window, no process, no
/// network. Written with the code, run at the very end with the other suites (decision of 21/10):
/// <c>Domenia.E2E.exe self-test</c>.
/// </summary>
internal static class SelfTests
{
    private static int passed;
    private static int failed;

    public static int Run()
    {
        Test("E2E : sans option, rien n’est demandé et la ligne reste intacte", () =>
        {
            var r = E2eArguments.Parse(["--simulation", "x"], "1");
            Check(!r.Requested && !r.Enabled && r.Error is null, "aucune demande");
            Check(r.Remaining.SequenceEqual(["--simulation", "x"]), "arguments rendus");
            Check(r.BrowserArguments.Length == 0, "aucun argument de navigateur");
        });
        Test("E2E : option et variable ouvrent le port de la boucle locale", () =>
        {
            var r = E2eArguments.Parse(["--simulation", "--E2E-PORT", "9333"], "1");
            Check(r.Enabled && r.Port == 9333, "port retenu");
            Check(r.Remaining.SequenceEqual(["--simulation"]), "option retirée avant le choix du mode");
            Check(r.BrowserArguments == "--remote-debugging-port=9333 --remote-debugging-address=127.0.0.1", "arguments du navigateur");
        });
        Test("E2E : l’option seule est refusée (variable absente ou différente de 1)", () =>
        {
            foreach (var value in new string?[] { null, "", "0", "true", "yes", " 2 " })
            {
                var r = E2eArguments.Parse(["--e2e-port", "9333"], value);
                Check(r.Requested && !r.Enabled && r.Error == E2eTexts.VariableMissing, $"variable « {value} » refusée");
            }
            Check(E2eArguments.Parse(["--e2e-port", "9333"], " 1 ").Enabled, "espaces autour de 1 admis");
        });
        Test("E2E : la variable seule n’ouvre rien", () =>
        {
            var r = E2eArguments.Parse([], "1");
            Check(!r.Requested && !r.Enabled, "rien sans l’option");
        });
        Test("E2E : ports invalides, valeur oubliée, option répétée, forme « = »", () =>
        {
            foreach (var port in new[] { "80", "1023", "65536", "99999", "-9333", "+9333", "0x2405", "9 333", "９３３３", "09333a" })
            {
                Check(E2eArguments.Parse(["--e2e-port", port], "1").Error == E2eTexts.PortInvalid, $"port « {port} » refusé");
            }
            Check(E2eArguments.Parse(["--e2e-port", "1024"], "1").Enabled && E2eArguments.Parse(["--e2e-port", "65535"], "1").Enabled, "bornes admises");
            var missing = E2eArguments.Parse(["--e2e-port", "--simulation"], "1");
            Check(missing.Error == E2eTexts.PortMissing && missing.Remaining.SequenceEqual(["--simulation"]), "valeur oubliée, option suivante laissée en place");
            Check(E2eArguments.Parse(["--e2e-port"], "1").Error == E2eTexts.PortMissing, "valeur absente en fin de ligne");
            Check(E2eArguments.Parse(["--e2e-port", "9333", "--e2e-port", "9444"], "1").Error == E2eTexts.Repeated, "option répétée");
            var equals = E2eArguments.Parse(["--e2e-port=9333"], "1");
            Check(!equals.Requested && equals.Remaining.Count == 1, "forme « = » non reconnue (comptée parmi les arguments ignorés)");
        });
        Test("Garde des variables WebView2", () =>
        {
            Check(BrowserArgumentsGuard.VariablesToNeutralize("--remote-debugging-port=9222", null, e2e: false, debugBuild: false).SequenceEqual([BrowserArgumentsGuard.ArgumentsVariable]), "port de débogage neutralisé hors E2E");
            Check(BrowserArgumentsGuard.VariablesToNeutralize("--REMOTE-DEBUGGING-PIPE", null, false, true).Count == 1, "casse indifférente, même en Debug");
            Check(BrowserArgumentsGuard.VariablesToNeutralize("--do-not-de-elevate", null, false, false).Count == 0, "autres arguments conservés hors E2E");
            Check(BrowserArgumentsGuard.VariablesToNeutralize("--do-not-de-elevate", null, true, false).Count == 1, "tout argument neutralisé en E2E");
            Check(BrowserArgumentsGuard.VariablesToNeutralize(null, "pipe", false, false).SequenceEqual([BrowserArgumentsGuard.ScriptDebuggerVariable]), "canal de débogage de scripts neutralisé en Release");
            Check(BrowserArgumentsGuard.VariablesToNeutralize(null, "pipe", false, true).Count == 0, "canal de débogage de scripts gardé en Debug");
            Check(BrowserArgumentsGuard.VariablesToNeutralize("  ", "", false, false).Count == 0, "valeurs vides ignorées");
        });
        Test("Touches", () =>
        {
            var chord = Keys.Parse("Control+K", out _)!;
            Check(chord.ModifierMask == 2 && chord.Key.Code == "KeyK" && chord.Key.Text is null, "raccourci sans texte");
            Check(Keys.Parse("Enter", out _)!.Key.Text == "\r", "Entrée tape un retour");
            Check(Keys.Parse("Shift+a", out _)!.Key.Key == "A", "Maj donne la majuscule");
            Check(Keys.Parse("Alt+1", out _)!.Key.Code == "Digit1", "Alt 1 garde le code Digit1 (navigation)");
            Check(Keys.Parse("F12", out _)!.Key.VirtualKey == 123, "F12");
            foreach (var bad in new[] { "", "Control+", "Hyper+K", "Control+Control+K", "Entree", "ab" })
            {
                Check(Keys.Parse(bad, out var error) is null && error is not null, $"« {bad} » refusée");
            }
        });
        Test("Scénario valide : valeurs par défaut", () =>
        {
            var s = Load("""
                { "name": "Essai", "steps": [ { "do": "click", "text": "Choisir l’OU" }, { "do": "expect", "selector": ".ou-panel" } ] }
                """);
            Check(s.Start == "accueil" && s.Modes.SequenceEqual([RunMode.Simulation]) && !s.AllowConsoleErrors, "défauts du scénario");
            Check(s.Steps[0].TimeoutMs == ScenarioLoader.DefaultTimeoutMs && s.Steps[0].Button == "left" && s.Steps[0].ClickCount == 1, "défauts de l’étape");
            Check(s.Steps[0].Describe().Contains("Choisir l’OU", StringComparison.Ordinal), "description lisible");
        });
        Test("Scénarios refusés avec un message qui nomme l’étape et le champ", () =>
        {
            Refused("""{ "steps": [ { "do": "wait", "ms": 10 } ] }""", "name");
            Refused("""{ "name": "x", "steps": [] }""", "steps");
            Refused("""{ "name": "x", "steps": [ { "do": "fly" } ] }""", "inconnue");
            Refused("""{ "name": "x", "steps": [ { "do": "click" } ] }""", "étape 1");
            Refused("""{ "name": "x", "steps": [ { "do": "click", "text": "a", "ms": 3 } ] }""", "« ms » non admis");
            Refused("""{ "name": "x", "steps": [ { "do": "go", "route": "../etc" } ] }""", "route");
            Refused("""{ "name": "x", "steps": [ { "do": "press", "key": "Control+" } ] }""", "touche");
            Refused("""{ "name": "x", "steps": [ { "do": "wait", "ms": 10, "ready": "accueil" } ] }""", "une seule attente");
            Refused("""{ "name": "x", "steps": [ { "do": "expect", "text": "a", "property": "checked" } ] }""", "equals");
            Refused("""{ "name": "x", "steps": [ { "do": "expect", "contains": "a", "text": "b" } ] }""", "seul");
            Refused("""{ "name": "x", "steps": [ { "do": "expect", "text": "a", "absent": true, "count": 2 } ] }""", "absent");
            Refused("""{ "name": "x", "steps": [ { "do": "shot", "name": "Mauvais Nom" } ] }""", "name");
            Refused("""{ "name": "x", "steps": [ { "do": "journal", "pattern": "(" } ] }""", "pattern");
            Refused("""{ "name": "x", "steps": [ { "do": "click", "text": "a", "timeoutMs": 5 } ] }""", "timeoutMs");
            Refused("""{ "name": "x", "modes": ["prod"], "steps": [ { "do": "wait", "ms": 1 } ] }""", "mode");
            Refused("""{ "name": "x", "inconnu": 1, "steps": [ { "do": "wait", "ms": 1 } ] }""", "non admis");
        });
        Test("Filtre des scénarios", () =>
        {
            var file = new ScenarioFile("accueil/choisir-ou", "accueil", "choisir-ou", "x");
            Check(ScenarioCatalog.Matches("accueil", file) && ScenarioCatalog.Matches("accueil/*", file) && ScenarioCatalog.Matches("choisir-ou", file), "écran, joker, nom");
            Check(ScenarioCatalog.Matches("*/choisir-*", file) && !ScenarioCatalog.Matches("comptes/*", file) && !ScenarioCatalog.Matches("accueil/mesure-*", file), "jokers par segment");
            Check(ScenarioCatalog.IsValidFilter("accueil/*,comptes") && !ScenarioCatalog.IsValidFilter("a;rm") && !ScenarioCatalog.IsValidFilter("a b"), "caractères admis");
        });
        Test("Arguments des scripts : JSON sûr comme expression JavaScript", () =>
        {
            var call = PageScripts.Call("(x) => x", JsonValue.Create("</script>'\"+`&\u2028é"));
            Check(!call.Contains("</script>", StringComparison.Ordinal) && !call.Contains('\'', StringComparison.Ordinal) && !call.Contains('`', StringComparison.Ordinal)
                && !call.Contains('\u2028', StringComparison.Ordinal) && !call.Contains('é', StringComparison.Ordinal), "caractères sensibles échappés");
        });
        Test("Cibles DevTools : page de l’interface seulement, sur le même port de la boucle locale", () =>
        {
            const string json = """
                [ { "id": "a", "type": "page", "url": "https://domenia.local/index.html#/accueil", "webSocketDebuggerUrl": "ws://127.0.0.1:9333/devtools/page/a" },
                  { "id": "b", "type": "page", "url": "https://example.com/", "webSocketDebuggerUrl": "ws://127.0.0.1:9333/devtools/page/b" },
                  { "id": "c", "type": "service_worker", "url": "https://domenia.local/sw.js", "webSocketDebuggerUrl": "ws://127.0.0.1:9333/devtools/page/c" },
                  { "id": "d", "type": "page", "url": "https://domenia.local/", "webSocketDebuggerUrl": "ws://10.0.0.5:9333/devtools/page/d" },
                  { "id": "e", "type": "page", "url": "https://domenia.local/", "webSocketDebuggerUrl": "ws://127.0.0.1:9444/devtools/page/e" } ]
                """;
            var targets = DevToolsEndpoint.ParseTargets(json, 9333);
            Check(targets.Count == 1 && targets[0].Id == "a", "seule la page de l’interface est retenue");
            Check(DevToolsEndpoint.LoopbackOnly([new System.Net.IPEndPoint(System.Net.IPAddress.Loopback, 9333)]), "boucle locale admise");
            Check(!DevToolsEndpoint.LoopbackOnly([new System.Net.IPEndPoint(System.Net.IPAddress.Any, 9333)]), "0.0.0.0 refusé");
            Check(!DevToolsEndpoint.LoopbackOnly([]), "aucun écouteur : refusé");
        });
        Test("Icône demandée par le navigateur : avertissement, pas erreur", () =>
        {
            Check(AppSession.IsFavicon("https://domenia.local/favicon.ico"), "icône de l’interface");
            Check(!AppSession.IsFavicon("https://domenia.local/js/app.js") && !AppSession.IsFavicon("https://example.com/favicon.ico") && !AppSession.IsFavicon(null), "autres ressources");
        });
        Test("Évaluation des attentes", () =>
        {
            var step = Load("""{ "name": "x", "steps": [ { "do": "expect", "selector": "[data-toggle]", "property": "checked", "equals": false } ] }""").Steps[0];
            Check(ScenarioRunner.Evaluate(step, Json("""{ "scope": true, "count": 1, "hasValue": true, "value": false }""")).Ok, "propriété attendue");
            Check(!ScenarioRunner.Evaluate(step, Json("""{ "scope": true, "count": 2, "hasValue": false, "value": null }""")).Ok, "deux éléments : pas de valeur");
            var absent = Load("""{ "name": "x", "steps": [ { "do": "expect", "text": "a", "within": ".panel", "absent": true } ] }""").Steps[0];
            Check(ScenarioRunner.Evaluate(absent, Json("""{ "scope": false, "count": 0 }""")).Ok, "zone fermée : texte absent");
            Check(ScenarioRunner.JsonEquals(Json("1.0"), Json("1")) && !ScenarioRunner.JsonEquals(Json("\"1\""), Json("1")), "comparaison typée");
        });
        Test("Rapport HTML : textes échappés, aucun script ni style en ligne", () =>
        {
            var report = new RunReport { Mode = "simulation", Exe = "C:\\x\\Domenia.exe", Machine = "VM" };
            var scenario = new ScenarioResult { Id = "accueil/x", File = "e2e/accueil/x.json", Name = "<img src=x onerror=alert(1)>", Verdict = Verdicts.Failed, Error = "\"'&<>" };
            scenario.Steps.Add(new StepResult { Index = 1, Action = "click", Title = "<b>t</b>", Verdict = Verdicts.Failed, Error = "<script>" });
            scenario.ConsoleErrors.Add(new ConsoleEntry(1, "error", "console", "<svg onload=x>"));
            report.Scenarios.Add(scenario);
            report.Summary.Failed = 1;
            var html = ReportWriter.Html(report);
            Check(!html.Contains("<img src=x", StringComparison.Ordinal) && !html.Contains("<script", StringComparison.OrdinalIgnoreCase) && !html.Contains("<svg", StringComparison.Ordinal), "balisage de données échappé");
            Check(!System.Text.RegularExpressions.Regex.IsMatch(html, @"<[^>]*\sstyle\s*=", System.Text.RegularExpressions.RegexOptions.None, TimeSpan.FromSeconds(1)) && !System.Text.RegularExpressions.Regex.IsMatch(html, @"<[^>]*\son[a-z]+\s*=", System.Text.RegularExpressions.RegexOptions.None, TimeSpan.FromSeconds(1)), "aucun style ni gestionnaire en ligne");
            Check(ReportWriter.Stylesheet().Length > 1000, "feuille de style embarquée");
        });
        Test("Dossier de sortie : nettoyé seulement s’il est vide ou déjà un dossier de rapport", () =>
        {
            var folder = Path.Combine(Path.GetTempPath(), "domenia-e2e-selftest-" + Guid.NewGuid().ToString("N"));
            try
            {
                Directory.CreateDirectory(folder);
                File.WriteAllText(Path.Combine(folder, "notes.txt"), "à garder");
                Check(!Program.PrepareOutput(folder, out var refusal) && refusal is not null && File.Exists(Path.Combine(folder, "notes.txt")), "dossier étranger refusé intact");
                File.Delete(Path.Combine(folder, "notes.txt"));
                Check(Program.PrepareOutput(folder, out _) && File.Exists(Path.Combine(folder, Program.Marker)), "dossier vide admis et marqué");
                Directory.CreateDirectory(Path.Combine(folder, "shots", "a"));
                File.WriteAllText(Path.Combine(folder, "report.html"), "ancien");
                File.WriteAllText(Path.Combine(folder, "garde.txt"), "autre fichier");
                Check(Program.PrepareOutput(folder, out _) && !Directory.Exists(Path.Combine(folder, "shots")) && !File.Exists(Path.Combine(folder, "report.html")), "ancien rapport retiré");
                Check(File.Exists(Path.Combine(folder, "garde.txt")), "les autres fichiers restent");
            }
            finally
            {
                Directory.Delete(folder, recursive: true);
            }
        });
        Console.WriteLine($"Auto-tests : {passed} réussi(s), {failed} en échec.");
        return failed == 0 ? 0 : 1;
    }

    private static void Test(string name, Action body)
    {
        try
        {
            body();
            passed++;
            Console.WriteLine("OK     " + name);
        }
#pragma warning disable CA1031 // A failing self-test is reported, then the next one runs.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            failed++;
            Console.WriteLine($"ÉCHEC  {name} : {ex.Message}");
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static Scenario Load(string json)
    {
        var path = Path.Combine(Path.GetTempPath(), "domenia-e2e-selftest-" + Guid.NewGuid().ToString("N") + ".json");
        File.WriteAllText(path, json);
        try
        {
            return ScenarioLoader.Load(path, "essai/scenario");
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static void Refused(string json, string expectedPart)
    {
        try
        {
            Load(json);
        }
        catch (ScenarioException ex)
        {
            Check(ex.Message.Contains(expectedPart, StringComparison.Ordinal), $"message « {ex.Message} » sans « {expectedPart} »");
            return;
        }
        throw new InvalidOperationException($"scénario admis à tort : {json}");
    }

    private static JsonElement Json(string text)
    {
        using var document = JsonDocument.Parse(text);
        return document.RootElement.Clone();
    }
}
