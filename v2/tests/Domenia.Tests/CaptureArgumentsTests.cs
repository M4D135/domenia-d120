using System.Reflection;
using System.Text.RegularExpressions;
using Domenia.App.Capture;

namespace Domenia.Tests;

// The capture types of Domenia.App (a WinForms executable the tests cannot reference) are compiled into this project
// from their source files (Domenia.Tests.csproj): the code tested is the code shipped.
internal static class CaptureArgumentsTests
{
    private static readonly Regex SafeName = new("^[a-z0-9-]+$", RegexOptions.CultureInvariant);

    private static CaptureArguments Parse(params string[] arguments) => CaptureArguments.Parse(arguments);

    [Test]
    public static void Without_capture_options_the_command_line_is_untouched()
    {
        var parsed = Parse("--simulation", "autre");
        Check.False(parsed.Requested, "aucune capture");
        Check.Null(parsed.Error, "aucune erreur");
        Check.True(parsed.Remaining.SequenceEqual(["--simulation", "autre"]), "arguments rendus à l’identique");
        Check.Equal(0, parsed.Routes.Length, "aucun écran");
    }

    [Test]
    public static void Routes_and_themes_are_taken_out_and_checked()
    {
        var parsed = Parse("--simulation", "--CAPTURE", @"C:\x", "--capture-routes", "accueil,rechercher?q=a,b,parametres", "--Capture-Themes", "light,dark,light");
        Check.Null(parsed.Error, "options admises");
        Check.Equal(@"C:\x", parsed.Folder, "dossier");
        Check.True(parsed.Remaining.SequenceEqual(["--simulation"]), "options et valeurs retirées : " + string.Join(" ", parsed.Remaining));
        string[] routes = [.. parsed.Routes.Select(r => r.Value)];
        Check.True(routes.SequenceEqual(["accueil", "rechercher?q=a,b", "parametres"]), "virgule de requête gardée : " + string.Join(" | ", routes));
        Check.Equal("rechercher", parsed.Routes[1].Name, "nom de l’écran attendu dans data-ready");
        Check.True(parsed.Themes.SequenceEqual([CaptureTheme.Light, CaptureTheme.Dark]), "thèmes dans l’ordre donné, sans doublon");
        var defaultTheme = Parse("--capture", @"C:\x", "--capture-routes", "accueil");
        Check.True(defaultTheme.Themes.SequenceEqual([CaptureTheme.Dark]), "thème sombre par défaut");
        var split = Parse("--capture", @"C:\x", "--capture-routes", "rechercher?q=a,poste,accueil");
        Check.True(split.Routes.Select(r => r.Value).SequenceEqual(["rechercher?q=a", "poste", "accueil"]), "une virgule suivie d’un nom d’écran sépare les écrans");
    }

    [Test]
    public static void Invalid_values_refuse_the_run()
    {
        foreach (var routes in new[] { "Accueil", "a", "accueil,", "accueil rechercher", "accueil?q=<script>", "accueil?q='x'", "../accueil", "accueil\n", "1accueil",
            string.Join(",", Enumerable.Range(0, 13).Select(i => "ecran" + i.ToString(System.Globalization.CultureInfo.InvariantCulture))) })
        {
            var parsed = Parse("--capture", @"C:\x", "--capture-routes", routes);
            Check.Equal(CaptureTexts.RoutesInvalid, parsed.Error, "écrans refusés : " + routes[..Math.Min(routes.Length, 30)]);
            Check.Equal(0, parsed.Routes.Length, "rien n’est gardé");
        }
        foreach (var themes in new[] { "blue", "dark,", "Dark", "dark light", "system" })
        {
            Check.Equal(CaptureTexts.ThemesInvalid, Parse("--capture", @"C:\x", "--capture-routes", "accueil", "--capture-themes", themes).Error, "thèmes refusés : " + themes);
        }
        Check.Equal(CaptureTexts.ThemesWithoutRoutes, Parse("--capture", @"C:\x", "--capture-themes", "dark").Error, "thèmes sans écrans");
        var noFolder = Parse("--simulation", "--capture-routes", "accueil");
        Check.True(noFolder.Requested, "demande de capture reconnue");
        Check.Equal(CaptureTexts.FolderMissing, noFolder.Error, "dossier obligatoire");
        Check.Equal(CaptureTexts.RoutesMissing, Parse("--capture", @"C:\x", "--capture-routes", "--simulation").Error, "écrans oubliés");
        Check.Equal(CaptureTexts.ThemesMissing, Parse("--capture", @"C:\x", "--capture-routes", "accueil", "--capture-themes").Error, "thèmes oubliés");
        Check.Equal(CaptureTexts.Repeated("--capture-routes"), Parse("--capture", @"C:\x", "--capture-routes", "accueil", "--capture-routes", "poste").Error, "option répétée");
        Check.Equal(CaptureTexts.OptionRepeated, Parse("--capture", @"C:\x", "--capture", @"C:\y").Error, "--capture répétée");
        Check.True(Parse("--capture=C:\\x").Remaining.SequenceEqual(["--capture=C:\\x"]), "forme « = » non reconnue");
    }

    [Test]
    public static void File_names_are_safe_and_distinct()
    {
        var routes = CaptureRoute.ParseList("rechercher?q=dupont,rechercher?q=Dupont,rechercher?q=%C3%A9t%C3%A9,accueil", out var error);
        Check.Null(error, "écrans admis");
        string[] stems = [.. routes.Select(r => r.FileStem)];
        Check.True(stems.All(SafeName.IsMatch), "noms sûrs : " + string.Join(", ", stems));
        Check.Equal(stems.Length, stems.Distinct(StringComparer.Ordinal).Count(), "deux requêtes, deux noms");
        Check.True(stems[0].StartsWith("rechercher-q-dupont-", StringComparison.Ordinal), "partie lisible : " + stems[0]);
        Check.Equal("accueil", stems[3], "écran sans requête : son nom");
        Check.True(stems.All(s => s.Length <= 31 + 1 + 40 + 1 + 6), "longueur bornée");
    }

    [Test]
    public static void Plan_adds_one_image_per_screen_and_theme_with_optional_middle_and_bottom_variants()
    {
        var plain = CapturePlan.For([], []);
        Check.True(ReferenceEquals(CapturePlan.Default, plain), "séquence par défaut seule");
        Check.Equal(8, plain.Steps.Length, "huit étapes par défaut");
        var routes = CaptureRoute.ParseList("accueil,rechercher", out _);
        var plan = CapturePlan.For(routes, [CaptureTheme.Dark, CaptureTheme.Contrast]);
        Check.Equal(8 + (2 * 2 * 3), plan.Steps.Length, "8 + écrans × thèmes × 3");
        Check.True(plan.Steps.Take(8).Select(s => s.Name).SequenceEqual(CaptureSequence.Steps.Select(s => s.Name)), "séquence par défaut d’abord");
        string[] extra = [.. plan.Steps.Skip(8).Select(s => s.Name)];
        Check.True(extra.SequenceEqual(["ecran-accueil-sombre", "ecran-accueil-sombre-milieu", "ecran-accueil-sombre-bas",
            "ecran-accueil-contraste", "ecran-accueil-contraste-milieu", "ecran-accueil-contraste-bas",
            "ecran-rechercher-sombre", "ecran-rechercher-sombre-milieu", "ecran-rechercher-sombre-bas",
            "ecran-rechercher-contraste", "ecran-rechercher-contraste-milieu", "ecran-rechercher-contraste-bas"]), "noms : " + string.Join(", ", extra));
        Check.Equal(plan.Steps.Length, plan.Steps.Select(s => s.Name).Distinct(StringComparer.Ordinal).Count(), "noms uniques");
        Check.True(plan.Steps.All(s => SafeName.IsMatch(s.Name)), "noms de fichiers sûrs");
        Check.True(plan.Steps.Where(s => s.Name.EndsWith("-bas", StringComparison.Ordinal) && s.Name.StartsWith("ecran-", StringComparison.Ordinal)).All(s => s.SkipWhen == CaptureSequence.NotScrollable), "variante « bas » facultative");
        Check.True(plan.Steps.Where(s => s.Name.EndsWith("-milieu", StringComparison.Ordinal) && s.Name.StartsWith("ecran-", StringComparison.Ordinal)).All(s => s.SkipWhen == CaptureSequence.NoMiddle), "variante « milieu » facultative");
        Check.True(plan.Steps.Where(s => !s.Name.StartsWith("ecran-", StringComparison.Ordinal) || !(s.Name.EndsWith("-bas", StringComparison.Ordinal) || s.Name.EndsWith("-milieu", StringComparison.Ordinal))).All(s => s.SkipWhen is null), "les autres images sont obligatoires");
        Check.True(plan.Steps.All(s => s.Actions.All(a => !string.IsNullOrEmpty(a.Condition))), "chaque geste a sa condition");
        Check.True(plan.Watchdog > plain.Watchdog, "garde-fou proportionnel au nombre d’étapes");
        Check.Equal(CaptureSequence.StartupLimit + (CaptureSequence.StepLimit * 20) + TimeSpan.FromSeconds(30), plan.Watchdog, "garde-fou");
    }

    [Test]
    public static void Values_reach_scripts_only_as_json_arguments_of_constant_functions()
    {
        var script = CaptureScript.Call("(x) => x", "a'b\"c</script>\u2028é");
        Check.True(script.StartsWith("((x) => x)(\"", StringComparison.Ordinal), "fonction constante appliquée : " + script);
        Check.False(script.Contains('\'', StringComparison.Ordinal), "apostrophe encodée");
        Check.False(script.Contains("</script>", StringComparison.Ordinal), "chevrons encodés");
        Check.False(script.Contains('\u2028', StringComparison.Ordinal), "séparateur de ligne encodé");
        Check.Equal(1, script.Count(c => c == '"') / 2, "une seule chaîne littérale");
        var route = CaptureRoute.ParseList("rechercher?q=a%27b", out _)[0];
        var actions = CaptureSequence.RouteActions(route, CaptureTheme.Light);
        Check.True(actions.Any(a => a.Script is not null && a.Script.Contains("\"rechercher?q=a%27b\"", StringComparison.Ordinal)), "route passée en argument JSON");
        Check.True(actions.Any(a => a.Condition.Contains("\"rechercher\"", StringComparison.Ordinal)), "nom attendu passé en argument JSON");
        Check.True(actions.Any(a => a.Script is not null && a.Script.Contains("\"light\"", StringComparison.Ordinal)), "thème passé en argument JSON");
    }

    [Test]
    public static void Every_script_text_is_a_compile_time_constant()
    {
        var strings = typeof(CaptureSequence).GetFields(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static).Where(f => f.FieldType == typeof(string)).ToList();
        Check.True(strings.Count >= 20, "scripts trouvés : " + strings.Count.ToString(System.Globalization.CultureInfo.InvariantCulture));
        foreach (var field in strings)
        {
            Check.True(field.IsLiteral, "champ const : " + field.Name);
        }
        Check.True(CaptureSequence.Steps.Select(s => s.Name).SequenceEqual(["accueil-sombre", "accueil-clair", "accueil-contraste", "accueil-milieu", "accueil-bas", "palette", "page-a-porter", "menu-replie"]), "séquence par défaut inchangée");
    }

    [Test]
    public static void Route_pattern_is_the_one_of_the_contract()
    {
        Check.Equal(@"\A[a-z][a-z0-9-]{1,30}(\?[A-Za-z0-9=&%._,-]{0,200})?\z", CaptureRoute.Pattern, "expression stricte");
        var longest = "a" + new string('b', 30) + "?" + new string('c', 200);
        Check.Equal(1, CaptureRoute.ParseList(longest, out var error).Length, "bornes admises");
        Check.Null(error, "aucune erreur");
        _ = CaptureRoute.ParseList(longest + "c", out error);
        Check.Equal(CaptureTexts.RoutesInvalid, error, "requête trop longue");
    }
}
