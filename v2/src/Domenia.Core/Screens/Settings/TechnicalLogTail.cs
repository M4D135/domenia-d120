using System.Collections.Immutable;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// Reading of the end of the technical journal (Domenia 1 Apply-DomeniaExperienceLogReading): one record per line
/// « 2026-10-22T08:15:02Z [ERREUR] texte », continuation lines (a stack) kept with their record, 5 000 records at most from the
/// end, a first partial line dropped when the reading started in the middle of the file, and the errors of the session
/// counted apart from those of earlier runs. Pure: the host reads the bytes, these rules only parse.
/// </summary>
public static partial class TechnicalLogTail
{
    /// <summary>Most of the journal read from its end.</summary>
    public const int TailBytes = 2 * 1024 * 1024;

    /// <summary>Most records returned.</summary>
    public const int MaxRecords = 5000;

    /// <summary>Most continuation lines kept with one record.</summary>
    public const int MaxContinuation = 40;

    [GeneratedRegex(@"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) \[([A-ZÉ]+)\] (.*)$", RegexOptions.CultureInvariant, matchTimeoutMilliseconds: 200)]
    private static partial Regex Record();

    /// <summary>
    /// Records of a text, oldest first. <paramref name="startsMidway"/>: the text starts in the middle of the file, its first
    /// line is partial and dropped. <paramref name="cut"/> tells when older records were left out (more than 5 000).
    /// </summary>
    public static ImmutableArray<LogLine> Parse(string text, bool startsMidway, out bool cut)
    {
        ArgumentNullException.ThrowIfNull(text);
        var records = new List<(DateTimeOffset? At, string Level, string Text, List<string> More)>();
        var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        for (var n = startsMidway ? 1 : 0; n < lines.Length; n++)
        {
            var line = lines[n];
            if (line.Length == 0)
            {
                continue;
            }
            Match match;
            try
            {
                match = Record().Match(line);
            }
            catch (RegexMatchTimeoutException)
            {
                match = Match.Empty;
            }
            if (match.Success)
            {
                var at = DateTimeOffset.TryParse(match.Groups[1].Value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed) ? parsed : (DateTimeOffset?)null;
                records.Add((at, match.Groups[2].Value, match.Groups[3].Value, []));
            }
            else if (records.Count > 0)
            {
                if (records[^1].More.Count < MaxContinuation)
                {
                    records[^1].More.Add(line.TrimEnd());
                }
            }
            else
            {
                records.Add((null, "INFO", line.TrimEnd(), []));
            }
        }
        cut = records.Count > MaxRecords;
        return [.. records.Skip(Math.Max(0, records.Count - MaxRecords)).Select(r => new LogLine(r.At, r.Level, r.Text, [.. r.More]))];
    }

    /// <summary>Errors and warnings of the records written since <paramref name="since"/> (the start of this run).</summary>
    public static (int Errors, int Warnings) Since(IEnumerable<LogLine> lines, DateTimeOffset since)
    {
        ArgumentNullException.ThrowIfNull(lines);
        var errors = 0;
        var warnings = 0;
        // The journal writes UTC at the second: a record of the second the process started belongs to this run.
        var from = WritePlans.TruncateToSecond(since);
        foreach (var line in lines)
        {
            if (line.At is not DateTimeOffset at || at < from)
            {
                continue;
            }
            if (line.Level == "ERREUR")
            {
                errors++;
            }
            else if (line.Level == "ATTENTION")
            {
                warnings++;
            }
        }
        return (errors, warnings);
    }
}

/// <summary>
/// The closed set of local folders that « Ouvrir l’emplacement » may show (settings.folder.open), and the refusals that come
/// before any path is resolved: never during a capture or an E2E run, never an unknown name, never the local base while it
/// has no file (fictitious base of the simulation, directory mode of this version). Pure.
/// </summary>
public static class SettingsFolders
{
    public static ImmutableArray<string> Known { get; } = ["app", "data", "logs", "preferences", "receipts", "profile", "base"];

    /// <summary>True for a name whose target is a file (selected in the Explorer), false for a folder.</summary>
    public static bool IsFile(string folder) => folder is "preferences" or "receipts";

    /// <summary>The refusal (code and message) of a request, or null when the path may be resolved.</summary>
    public static (string Code, string Message)? Refusal(string folder, bool unattended, bool simulation)
    {
        ArgumentNullException.ThrowIfNull(folder);
        if (unattended)
        {
            return ("settings.folderUnavailable", "Capture ou scénario E2E en cours" + FrenchText.Colon + "l’Explorateur n’est pas ouvert.");
        }
        if (!Known.Contains(folder))
        {
            return (DomeniaErrors.ArgumentsInvalid, FrenchText.Quote("folder") + " doit être app, data, logs, preferences, receipts, profile ou base.");
        }
        if (folder == "base")
        {
            return ("settings.folderUnavailable", simulation
                ? "Base de démonstration" + FrenchText.Colon + "aucun fichier sur le disque à montrer."
                : "Aucune base locale pour ce domaine pour l’instant" + FrenchText.Colon + "rien à montrer.");
        }
        return null;
    }
}
