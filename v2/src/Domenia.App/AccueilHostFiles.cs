using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using Domenia.Core;

namespace Domenia.App;

/// <summary>
/// Files of the host read for the home page, without WinForms nor WebView2 (compiled into the tests from this very file): the last
/// lines of the technical journal (« Ouvrir le journal », ACC-019; 256 Kio and 200 lines at most, a line that continues the
/// previous one is appended to it) and the free space of the volume of the data folder (ACC-001).
/// </summary>
public static class AccueilHostFiles
{
    public const int MaxBytes = 256 * 1024;
    public const int MaxLines = 200;

    /// <summary>Free space of the volume that holds <paramref name="folder"/> (null: no data folder, not measured).</summary>
    public static long? FreeBytes(string? folder)
    {
        if (string.IsNullOrEmpty(folder) || Path.GetPathRoot(folder) is not { Length: > 0 } root)
        {
            return null;
        }
        return new DriveInfo(root).AvailableFreeSpace;
    }

    /// <summary>Last lines of a journal file; a line that continues the previous one (exception detail) is appended to it.</summary>
    /// <remarks>
    /// A journal locked or unreadable for now (antivirus, rotation, rights) gives a clear sentence instead of an error, and
    /// <paramref name="trace"/> receives the kind of the error only (never a line of the file).
    /// </remarks>
    public static async Task<LogTail> TailAsync(string? path, CancellationToken cancellationToken, Action<string>? trace = null)
    {
        const string Display = @"%LOCALAPPDATA%\Domenia\logs\domenia.log";
        if (path is null || !File.Exists(path))
        {
            return new LogTail(Display, false, [], false, "Aucun journal technique pour l’instant : il est créé au premier événement.");
        }
        byte[] buffer;
        bool truncated;
        try
        {
            await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            truncated = stream.Length > MaxBytes;
            if (truncated)
            {
                stream.Seek(-MaxBytes, SeekOrigin.End);
            }
            buffer = new byte[(int)Math.Min(stream.Length, MaxBytes)];
            var read = 0;
            while (read < buffer.Length)
            {
                var n = await stream.ReadAsync(buffer.AsMemory(read), cancellationToken).ConfigureAwait(false);
                if (n == 0)
                {
                    break;
                }
                read += n;
            }
            Array.Resize(ref buffer, read);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            trace?.Invoke("accueil.log.tail : journal technique illisible pour l’instant (" + ex.GetType().Name + ").");
            return new LogTail(Display, false, [], false, "Journal technique illisible pour l’instant (fichier verrouillé ou accès refusé)" + FrenchText.Colon + "réessayez dans un instant.");
        }
        var text = Encoding.UTF8.GetString(buffer);
        var raw = text.Split('\n');
        var lines = new List<LogLine>();
        foreach (var line in raw.Skip(truncated ? 1 : 0))
        {
            var clean = line.TrimEnd('\r');
            if (clean.Length == 0)
            {
                continue;
            }
            if (clean.Length > 21 && clean[4] == '-' && clean[10] == 'T' && clean[19] == 'Z'
                && DateTimeOffset.TryParse(clean[..20], CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var at))
            {
                var rest = clean[21..];
                var level = "INFO";
                if (rest.StartsWith('[') && rest.IndexOf(']', StringComparison.Ordinal) is var close and > 0)
                {
                    level = rest[1..close];
                    rest = rest[(close + 1)..].TrimStart();
                }
                lines.Add(new LogLine(at, level, rest.Length > 2000 ? rest[..2000] + "…" : rest));
            }
            else if (lines.Count > 0 && lines[^1].Text.Length < 4000)
            {
                lines[^1] = lines[^1] with { Text = lines[^1].Text + "\n" + clean };
            }
        }
        var tail = lines.TakeLast(MaxLines).Reverse().ToImmutableArray();
        return new LogTail(Display, true, tail, truncated || lines.Count > MaxLines,
            FleetLine(tail.Length, lines.Count));
    }

    private static string FleetLine(int shown, int total) =>
        FrenchText.Count(shown, "ligne affichée", "lignes affichées") + (total > shown ? " sur " + FrenchText.Integer(total) + " lues" : "") + ", la plus récente d’abord.";

    /// <summary>One line of the technical journal: date, level and text (continuation lines included).</summary>
    public sealed record LogLine(DateTimeOffset At, string Level, string Text);

    /// <summary>Result of accueil.log.tail.</summary>
    public sealed record LogTail(string Path, bool Available, ImmutableArray<LogLine> Lines, bool Truncated, string Summary);
}
