using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Tests;

/// <summary>
/// Architecture rules of the interface checked on the sources (Domenia 1 TRV-060 and TRV-009, TRV-063 improvements): no native
/// window or modal loop, no dynamic code, the help catalogue generated as a whole, the WCAG contrast of the colour pairs the
/// interface really paints (tokens.css, every theme, no accepted debt: Domenia 1 refused a palette that failed), the edges of
/// the chart series, motion in transform and opacity only, the rules of the screen sheet scoped to its screen, and no trace
/// of WAPT (abandoned on David’s decision of 22 October 2026, PST-001).
/// </summary>
internal static partial class ShellStaticChecksTests
{
    /// <summary>Properties a transition or a keyframe of the shell may animate (compositor only).</summary>
    private static readonly string[] AnimatedProperties = ["transform", "opacity", "filter", "translate", "scale", "rotate"];

    private static string V2Root()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "web", "index.html")) && Directory.Exists(Path.Combine(dir.FullName, "src")))
            {
                return dir.FullName;
            }
            dir = dir.Parent;
        }
        throw new TestFailureException("Dossier v2 introuvable depuis " + AppContext.BaseDirectory + " (web/index.html et src/ attendus).");
    }

    private static string Relative(string root, string path) => Path.GetRelativePath(root, path).Replace('\\', '/');

    [Test]
    public static void Web_code_opens_no_native_window_and_runs_no_dynamic_code()
    {
        var root = V2Root();
        var problems = new List<string>();
        foreach (var file in Directory.EnumerateFiles(Path.Combine(root, "web", "js"), "*.js", SearchOption.AllDirectories))
        {
            var lines = File.ReadAllLines(file);
            for (var i = 0; i < lines.Length; i++)
            {
                var line = lines[i];
                var trimmed = line.TrimStart();
                if (trimmed.StartsWith("//", StringComparison.Ordinal) || trimmed.StartsWith('*'))
                {
                    continue;
                }
                if (ForbiddenWeb().Match(line) is { Success: true } m)
                {
                    problems.Add(Relative(root, file) + ":" + (i + 1).ToString(CultureInfo.InvariantCulture) + " " + m.Value.Trim());
                }
            }
        }
        Check.True(problems.Count == 0, "fenêtres natives ou code dynamique : " + string.Join(" | ", problems));
    }

    [Test]
    public static void Native_dialogs_stay_in_their_allowed_places()
    {
        var root = V2Root();
        var allowed = new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            // A failure before the window exists has no page to show it.
            ["src/Domenia.App/Program.cs"] = ["MessageBox"],
            // The one window of the application.
            ["src/Domenia.App/MainForm.cs"] = [": Form"],
            // Secure windows of the host: a secret is typed or shown there, never in the page (OPERATIONS.md § 1.2).
            ["src/Domenia.App/Poste/SecretWindowForm.cs"] = [": Form"],
            ["src/Domenia.App/Secrets/PasswordWindow.cs"] = [": Form"],
            ["src/Domenia.App/Secrets/CredentialWindow.cs"] = [": Form"],
            ["src/Domenia.App/Secrets/NativeSecretDialog.cs"] = [": Form", ".ShowDialog("],
            // Closing unresolved native operations requires the operator's explicit choice before the host is disposed.
            ["src/Domenia.App/MainForm.Closing.cs"] = ["MessageBox"],
            // « Enregistrer sous » of the exports of the Poste screen (poste.export.save: the file chosen by the operator).
            ["src/Domenia.App/Poste/PosteHostServices.cs"] = ["SaveFileDialog", ".ShowDialog("],
        };
        var problems = new List<string>();
        foreach (var file in Directory.EnumerateFiles(Path.Combine(root, "src"), "*.cs", SearchOption.AllDirectories))
        {
            var rel = Relative(root, file);
            if (rel.Contains("/obj/", StringComparison.Ordinal) || rel.Contains("/bin/", StringComparison.Ordinal))
            {
                continue;
            }
            var text = File.ReadAllText(file);
            foreach (Match m in ForbiddenNative().Matches(text))
            {
                var token = m.Value.Trim();
                if (allowed.TryGetValue(rel, out var tokens) && tokens.Any(t => token.StartsWith(t, StringComparison.Ordinal)))
                {
                    continue;
                }
                problems.Add(rel + " " + token);
            }
        }
        Check.True(problems.Count == 0, "dialogues natifs hors liste : " + string.Join(" | ", problems));
    }

    [Test]
    public static void Help_catalogue_is_generated_whole_and_consistent()
    {
        var root = V2Root();
        var text = File.ReadAllText(Path.Combine(root, "web", "js", "shell", "help-catalog.js"));
        Check.Contains("Generated by v2/tools/gen_help.py", text, "fichier généré");
        var source = SourceCount().Match(text);
        Check.True(source.Success, "HELP_SOURCE.count présent");
        var declared = int.Parse(source.Groups[1].Value, CultureInfo.InvariantCulture);
        Check.Equal(820, declared, "sujets de la source");
        var names = TopicName().Matches(text).Select(m => m.Groups[1].Value).ToList();
        Check.Equal(declared, names.Count, "sujets générés");
        Check.Equal(names.Count, names.Distinct(StringComparer.Ordinal).Count(), "noms uniques");
        Check.False(SpaceColon().IsMatch(text), "deux-points toujours précédés d’une espace insécable");
    }

    [Test]
    public static void Painted_colour_pairs_meet_wcag_on_every_theme()
    {
        var root = V2Root();
        var css = File.ReadAllText(Path.Combine(root, "web", "css", "tokens.css"));
        var js = File.ReadAllText(Path.Combine(root, "web", "js", "shell", "contrast.js"));
        var pairs = PairLine().Matches(js).Select(m => (Label: m.Groups[1].Value, Fg: m.Groups[2].Value, Bg: m.Groups[3].Value, Kind: m.Groups[4].Value)).ToList();
        Check.Equal(29, pairs.Count, "paires de contrast.js");
        var light = Tokens(Block(css, ":root {"));
        var themes = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal)
        {
            ["clair"] = light,
            ["sombre"] = Merge(light, Tokens(Block(css, ":root[data-theme=\"dark\"] {"))),
            ["contraste"] = Merge(light, Tokens(Block(css, ":root[data-theme=\"contrast\"] {"))),
        };
        var failures = new List<(string Theme, string Pair)>();
        var report = new List<string>();
        foreach (var (theme, tokens) in themes)
        {
            var card = Parse(tokens["--bg-elevated"]) ?? throw new TestFailureException("--bg-elevated illisible (" + theme + ")");
            foreach (var (label, fgToken, bgToken, kind) in pairs)
            {
                var fg = tokens.TryGetValue(fgToken, out var f) ? Parse(f) : null;
                var bg = tokens.TryGetValue(bgToken, out var b) ? Parse(b) : null;
                if (fg is null || bg is null)
                {
                    failures.Add((theme, label));
                    report.Add(theme + " · " + label + " : couleur absente");
                    continue;
                }
                var back = bg.Value.A < 1 ? Over(bg.Value, card) : bg.Value;
                var front = fg.Value.A < 1 ? Over(fg.Value, back) : fg.Value;
                var ratio = Ratio(front, back);
                if (ratio < (kind == "text" ? 4.5 : 3.0))
                {
                    failures.Add((theme, label));
                    report.Add(theme + " · " + label + " : " + ratio.ToString("0.00", CultureInfo.InvariantCulture));
                }
            }
        }
        Check.True(failures.Count == 0, "contraste insuffisant : " + string.Join(" | ", report));
    }

    [Test]
    public static void Chart_series_have_an_edge_of_three_to_one_on_the_light_card()
    {
        var root = V2Root();
        var tokens = File.ReadAllText(Path.Combine(root, "web", "css", "tokens.css"));
        var shell = File.ReadAllText(Path.Combine(root, "web", "css", "shell.css"));
        var card = Parse(Tokens(Block(tokens, ":root {"))["--bg-elevated"]) ?? throw new TestFailureException("--bg-elevated illisible");
        var light = Tokens(Block(tokens, ":root {"));
        var problems = new List<string>();
        for (var i = 1; i <= 8; i++)
        {
            var name = "--c" + i.ToString(CultureInfo.InvariantCulture) + "-edge";
            var m = Regex.Match(shell, Regex.Escape(name) + @"\s*:\s*(#[0-9a-fA-F]{6})");
            if (!m.Success || Parse(m.Groups[1].Value) is not { } edge)
            {
                problems.Add(name + " absent");
                continue;
            }
            var ratio = Ratio(edge, card);
            if (ratio < 3.0)
            {
                problems.Add(name + " " + ratio.ToString("0.00", CultureInfo.InvariantCulture));
            }
            if (light.TryGetValue("--c" + i.ToString(CultureInfo.InvariantCulture), out var fill) && Parse(fill) is { } pastel && Ratio(edge, pastel) < 1.5)
            {
                problems.Add(name + " trop proche de sa série");
            }
        }
        Check.True(problems.Count == 0, "bords des séries : " + string.Join(" | ", problems));
    }

    [Test]
    public static void Shell_motion_uses_transform_and_opacity_only()
    {
        var root = V2Root();
        var problems = new List<string>();
        foreach (var rel in new[] { "web/css/shell.css", "web/css/pages/shell.css", "web/css/layout.css" })
        {
            var css = BlockComment().Replace(File.ReadAllText(Path.Combine(root, rel)), "");
            foreach (Match m in Transition().Matches(css))
            {
                foreach (var item in m.Groups[1].Value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                {
                    var property = item.Split(' ', StringSplitOptions.RemoveEmptyEntries)[0];
                    if (property != "none" && !AnimatedProperties.Contains(property, StringComparer.Ordinal))
                    {
                        problems.Add(rel + " transition " + property);
                    }
                }
            }
            foreach (Match m in Keyframes().Matches(css))
            {
                var body = BlockAt(css, m.Index + m.Length - 1);
                foreach (Match d in Declaration().Matches(body))
                {
                    if (!AnimatedProperties.Contains(d.Groups[1].Value, StringComparer.Ordinal))
                    {
                        problems.Add(rel + " @keyframes " + m.Groups[1].Value + " " + d.Groups[1].Value);
                    }
                }
            }
        }
        Check.True(problems.Count == 0, "animations hors transform, opacity et filter : " + string.Join(" | ", problems));
    }

    [Test]
    public static void Rules_of_the_screen_sheet_are_scoped_to_the_screen()
    {
        var root = V2Root();
        var css = BlockComment().Replace(File.ReadAllText(Path.Combine(root, "web", "css", "pages", "shell.css")), "");
        var problems = new List<string>();
        foreach (Match m in RuleSelector().Matches(css))
        {
            var selector = m.Groups[1].Value.Trim();
            if (selector.StartsWith('@') || selector.Length == 0 || Regex.IsMatch(selector, @"^(from|to|\d+%)"))
            {
                continue;
            }
            foreach (var part in selector.Split(',', StringSplitOptions.TrimEntries))
            {
                if (!part.StartsWith(".main[data-page=\"shell\"]", StringComparison.Ordinal))
                {
                    problems.Add(part);
                }
            }
        }
        Check.True(problems.Count == 0, "règles hors de l’écran : " + string.Join(" | ", problems.Take(10)));
    }

    [Test]
    public static void No_trace_of_wapt_in_the_code_of_domenia_2()
    {
        var root = V2Root();
        var problems = new List<string>();
        foreach (var file in Directory.EnumerateFiles(Path.Combine(root, "src"), "*.cs", SearchOption.AllDirectories)
                     .Concat(Directory.EnumerateFiles(Path.Combine(root, "web"), "*.*", SearchOption.AllDirectories)))
        {
            var rel = Relative(root, file);
            if (rel.Contains("/obj/", StringComparison.Ordinal) || rel.Contains("/bin/", StringComparison.Ordinal) || rel.EndsWith("parite.js", StringComparison.Ordinal))
            {
                continue;
            }
            if (File.ReadAllText(file).Contains("wapt", StringComparison.OrdinalIgnoreCase))
            {
                problems.Add(rel);
            }
        }
        Check.True(problems.Count == 0, "WAPT abandonné (PST-001) : " + string.Join(" | ", problems));
    }

    [Test]
    public static void No_inline_style_nor_script_in_the_markup_of_the_shell()
    {
        var root = V2Root();
        var problems = new List<string>();
        var files = Directory.EnumerateFiles(Path.Combine(root, "web", "js", "shell"), "*.js")
            .Concat(Directory.EnumerateFiles(Path.Combine(root, "web", "js", "pages", "shell"), "*.js"))
            .Append(Path.Combine(root, "web", "js", "app.js"))
            .Append(Path.Combine(root, "web", "js", "palette.js"))
            .Append(Path.Combine(root, "web", "js", "pages", "shell.js"));
        foreach (var file in files)
        {
            var text = File.ReadAllText(file);
            foreach (Match m in InlineMarkup().Matches(text))
            {
                problems.Add(Relative(root, file) + " " + m.Value.Trim());
            }
        }
        Check.True(problems.Count == 0, "style ou script en ligne : " + string.Join(" | ", problems.Take(10)));
    }

    // ---------- Helpers of the contrast check ----------

    private static readonly char[] ColourSeparators = [' ', ',', '/'];

    private readonly record struct Rgba(double R, double G, double B, double A);

    private static string Block(string css, string selector)
    {
        var start = css.IndexOf(selector, StringComparison.Ordinal);
        if (start < 0)
        {
            throw new TestFailureException("Bloc absent de tokens.css : " + selector);
        }
        var open = css.IndexOf('{', start);
        var depth = 0;
        for (var i = open; i < css.Length; i++)
        {
            if (css[i] == '{')
            {
                depth++;
            }
            else if (css[i] == '}' && --depth == 0)
            {
                return css[(open + 1)..i];
            }
        }
        throw new TestFailureException("Bloc non fermé : " + selector);
    }

    /// <summary>Body of the block whose opening brace is at <paramref name="open"/>.</summary>
    private static string BlockAt(string css, int open)
    {
        var depth = 0;
        for (var i = open; i < css.Length; i++)
        {
            if (css[i] == '{')
            {
                depth++;
            }
            else if (css[i] == '}' && --depth == 0)
            {
                return css[(open + 1)..i];
            }
        }
        return css[(open + 1)..];
    }

    private static Dictionary<string, string> Tokens(string block) =>
        TokenLine().Matches(block).GroupBy(m => m.Groups[1].Value, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Last().Groups[2].Value.Trim(), StringComparer.Ordinal);

    private static Dictionary<string, string> Merge(Dictionary<string, string> basis, Dictionary<string, string> overrides)
    {
        var merged = new Dictionary<string, string>(basis, StringComparer.Ordinal);
        foreach (var (k, v) in overrides)
        {
            merged[k] = v;
        }
        return merged;
    }

    private static Rgba? Parse(string value)
    {
        var v = value.Trim().ToLowerInvariant();
        var hex = HexColour().Match(v);
        if (hex.Success)
        {
            var h = hex.Groups[1].Value;
            if (h.Length == 3)
            {
                h = string.Concat(h.Select(c => new string(c, 2)));
            }
            double Channel(int at) => int.Parse(h.AsSpan(at, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            return new Rgba(Channel(0), Channel(2), Channel(4), h.Length == 8 ? Channel(6) / 255 : 1);
        }
        var rgb = RgbColour().Match(v);
        if (rgb.Success)
        {
            var parts = rgb.Groups[1].Value.Split(ColourSeparators, StringSplitOptions.RemoveEmptyEntries)
                .Select(p => double.Parse(p, CultureInfo.InvariantCulture)).ToArray();
            return parts.Length >= 3 ? new Rgba(parts[0], parts[1], parts[2], parts.Length > 3 ? parts[3] : 1) : null;
        }
        return null;
    }

    private static Rgba Over(Rgba front, Rgba back) =>
        new(front.R * front.A + back.R * (1 - front.A), front.G * front.A + back.G * (1 - front.A), front.B * front.A + back.B * (1 - front.A), 1);

    private static double Luminance(Rgba c)
    {
        static double Lin(double v)
        {
            var x = v / 255;
            return x <= 0.04045 ? x / 12.92 : Math.Pow((x + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * Lin(c.R) + 0.7152 * Lin(c.G) + 0.0722 * Lin(c.B);
    }

    private static double Ratio(Rgba a, Rgba b)
    {
        var (l1, l2) = (Luminance(a), Luminance(b));
        return (Math.Max(l1, l2) + 0.05) / (Math.Min(l1, l2) + 0.05);
    }

    [GeneratedRegex(@"(?<![\w.$])window\.(open|alert|confirm|prompt)\s*\(|(?<![\w.$])(?<!async\s)(?<!function\s)(alert|confirm|prompt)\s*\((?![^)]*\)\s*\{)|\.showModal\s*\(|(?<![\w.$])eval\s*\(|new\s+Function\s*\(|document\.write(ln)?\s*\(|setTimeout\s*\(\s*['""`]|setInterval\s*\(\s*['""`]")]
    private static partial Regex ForbiddenWeb();

    [GeneratedRegex(@"\bMessageBox\b|\.ShowDialog\s*\(|:\s*Form\b|\bnew\s+Form\s*\(|\b(OpenFileDialog|SaveFileDialog|FolderBrowserDialog|PrintDialog|ColorDialog|FontDialog)\b|\bCredUIPromptForWindowsCredentials\b")]
    private static partial Regex ForbiddenNative();

    [GeneratedRegex(@"HELP_SOURCE\s*=\s*Object\.freeze\(\{[^}]*count:\s*(\d+)")]
    private static partial Regex SourceCount();

    [GeneratedRegex(@"^\s*\[""([^""]+)"", ""(?:[^""\\]|\\.)*"", ""(?:[^""\\]|\\.)*"", ""(button|input|secret|choice|status|tab|list|zone)"", ""[a-z]+""\],?$", RegexOptions.Multiline)]
    private static partial Regex TopicName();

    [GeneratedRegex(@"\w :")]
    private static partial Regex SpaceColon();

    [GeneratedRegex(@"\['([^']+)', '(--[a-z0-9-]+)', '(--[a-z0-9-]+)', '(text|large|graphic)'\]")]
    private static partial Regex PairLine();

    [GeneratedRegex(@"(--[a-z0-9-]+)\s*:\s*([^;]+);")]
    private static partial Regex TokenLine();

    [GeneratedRegex(@"^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$")]
    private static partial Regex HexColour();

    [GeneratedRegex(@"^rgba?\(([^)]+)\)$")]
    private static partial Regex RgbColour();

    [GeneratedRegex(@"/\*.*?\*/", RegexOptions.Singleline)]
    private static partial Regex BlockComment();

    [GeneratedRegex(@"transition\s*:\s*([^;}]+)")]
    private static partial Regex Transition();

    [GeneratedRegex(@"@keyframes\s+([\w-]+)\s*\{")]
    private static partial Regex Keyframes();

    [GeneratedRegex(@"([a-z-]+)\s*:")]
    private static partial Regex Declaration();

    [GeneratedRegex(@"(?:^|})\s*([^{}@]+)\{", RegexOptions.Multiline)]
    private static partial Regex RuleSelector();

    // An attribute style="…" or an event handler on…="…" written in markup, or a <script> element.
    [GeneratedRegex(@"\sstyle=""|\son[a-z]+=""|<script\b")]
    private static partial Regex InlineMarkup();
}
