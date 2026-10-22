using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.App;

/// <summary>
/// « Ouvrir le journal » of the home page (Domenia 1, BtnDashOpenLog, ACC-019): the last lines of the technical journal, read
/// by the host that owns it (%LOCALAPPDATA%\Domenia\logs\domenia.log) and shown in the page instead of opening another program.
/// LocalRead, bounded (256 Kio, 200 lines); the journal never holds page input nor secrets by design. Public for the composition.
/// </summary>
public sealed class AccueilJournalOperations : IOperationModule
{
    public const int MaxBytes = 256 * 1024;
    public const int MaxLines = 200;

    public string Screen => "accueil";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return
        [
            new OperationDefinition("accueil.log.tail", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                return await TailAsync(TechnicalLog.FilePath, cancellationToken).ConfigureAwait(false);
            }, "Dernières lignes du journal technique de Domenia (lecture locale, bornée)."),
        ];
    }

    /// <summary>Last lines of a journal file; a line that continues the previous one (exception detail) is appended to it.</summary>
    public static async Task<LogTail> TailAsync(string? path, CancellationToken cancellationToken)
    {
        const string Display = @"%LOCALAPPDATA%\Domenia\logs\domenia.log";
        if (path is null || !File.Exists(path))
        {
            return new LogTail(Display, false, [], false, "Aucun journal technique pour l’instant : il est créé au premier événement.");
        }
        byte[] buffer;
        bool truncated;
        await using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
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

    public sealed record LogLine(DateTimeOffset At, string Level, string Text);

    public sealed record LogTail(string Path, bool Available, ImmutableArray<LogLine> Lines, bool Truncated, string Summary);
}
