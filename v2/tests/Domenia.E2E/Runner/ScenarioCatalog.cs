using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.E2E.Runner;

/// <summary>A scenario file found under the scenarios folder: id « écran/nom » and full path.</summary>
internal sealed record ScenarioFile(string Id, string Screen, string Name, string Path);

/// <summary>
/// Scenario files <c>&lt;racine&gt;/&lt;écran&gt;/&lt;nom&gt;.json</c> (one level, lower-case names), filtered by a list of
/// patterns separated by commas: « accueil » (a screen or a file name), « accueil/* », « */choisir-* », « accueil/mesure-active ».
/// </summary>
internal static partial class ScenarioCatalog
{
    public static IReadOnlyList<ScenarioFile> Find(string root, string? filter)
    {
        var files = new List<ScenarioFile>();
        foreach (var folder in Directory.EnumerateDirectories(root).Order(StringComparer.Ordinal))
        {
            var screen = System.IO.Path.GetFileName(folder);
            if (!NamePattern().IsMatch(screen))
            {
                continue;
            }
            foreach (var path in Directory.EnumerateFiles(folder, "*.json").Order(StringComparer.Ordinal))
            {
                var name = System.IO.Path.GetFileNameWithoutExtension(path);
                if (NamePattern().IsMatch(name))
                {
                    files.Add(new ScenarioFile(screen + "/" + name, screen, name, path));
                }
            }
        }
        var patterns = Patterns(filter);
        return patterns.Count == 0 ? files : files.Where(f => patterns.Any(p => Matches(p, f))).ToList();
    }

    /// <summary>True when the filter is made of admitted characters only (letters, digits, « * ? _ . / , - »).</summary>
    public static bool IsValidFilter(string? filter) => filter is null || FilterPattern().IsMatch(filter);

    public static IReadOnlyList<string> Patterns(string? filter) =>
        string.IsNullOrWhiteSpace(filter) ? [] : [.. filter.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)];

    public static bool Matches(string pattern, ScenarioFile file)
    {
        ArgumentNullException.ThrowIfNull(file);
        var regex = Glob(pattern);
        if (regex.IsMatch(file.Id))
        {
            return true;
        }
        // Without « / », a pattern names a screen or a file.
        return !pattern.Contains('/', StringComparison.Ordinal) && (regex.IsMatch(file.Screen) || regex.IsMatch(file.Name));
    }

    private static Regex Glob(string pattern)
    {
        var builder = new StringBuilder("^");
        foreach (var c in pattern)
        {
            builder.Append(c switch
            {
                '*' => "[^/]*",
                '?' => "[^/]",
                _ => Regex.Escape(char.ToString(c)),
            });
        }
        builder.Append('$');
        return new Regex(builder.ToString(), RegexOptions.CultureInvariant | RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1));
    }

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{0,59}$", RegexOptions.CultureInvariant)]
    private static partial Regex NamePattern();

    [GeneratedRegex(@"^[A-Za-z0-9*?_./,-]{1,200}$", RegexOptions.CultureInvariant)]
    private static partial Regex FilterPattern();
}
