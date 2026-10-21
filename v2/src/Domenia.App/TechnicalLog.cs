using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace Domenia.App;

/// <summary>
/// Technical journal in the user data folder (%LOCALAPPDATA%\Domenia\logs). Never receives page input, secrets or bulk
/// data; a failure to write is traced to the debugger output, never thrown. Without a data folder, lines go to the
/// debugger output only.
/// </summary>
internal static class TechnicalLog
{
    private static readonly Lock Gate = new();

    public static string? FilePath { get; } = AppPaths.UserData is string folder ? Path.Combine(folder, "logs", "domenia.log") : null;

    public static void Info(string message) => Write("INFO", message);

    public static void Warning(string message) => Write("ATTENTION", message);

    public static void Error(string message, Exception exception) => Write("ERREUR", message + Environment.NewLine + exception);

    private static void Write(string level, string message)
    {
        var line = DateTimeOffset.UtcNow.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture) + " [" + level + "] " + message + Environment.NewLine;
        if (FilePath is null)
        {
            Trace.Write("Domenia (no data folder, journal not written): " + line);
            return;
        }
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                File.AppendAllText(FilePath, line, Encoding.UTF8);
            }
        }
        catch (IOException ex)
        {
            Trace.WriteLine("Domenia: technical journal not written: " + ex.Message);
        }
        catch (UnauthorizedAccessException ex)
        {
            Trace.WriteLine("Domenia: technical journal not written: " + ex.Message);
        }
    }
}
