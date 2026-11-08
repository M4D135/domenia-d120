using System.Globalization;
using System.Text;

namespace Domenia.App;

/// <summary>BCL-only diagnostics before package admission; no WinForms, profile, application journal, timer or provider.</summary>
internal static class StartupBootstrap
{
    private const long Limit = 256 * 1024;
    private static readonly Lock Gate = new();
    internal static string? Begin(string build) => Write("Domenia-bootstrap.log", FirstLine(build));
    internal static string FirstLine(string build) => $"Amorçage : PID {Environment.ProcessId}; hôte Domenia.exe; version {Clean(build)}; "
        + $"runtime {Environment.Version}; processus {(Environment.Is64BitProcess ? "64" : "32")} bits; Windows {OperatingSystem.IsWindows()}.";
    internal static string? Failure(Exception error, string? reference = null) => Write("Domenia-startup-error.log", FailureText(error, reference));
    internal static string FailureText(Exception error, string? reference = null)
    {
        var code = reference is { Length: 36 } && reference.StartsWith("INC-", StringComparison.Ordinal)
            && reference.Skip(4).All(c => c is >= '0' and <= '9' or >= 'A' and <= 'F') ? reference + " · " : "";
        // Mask each untrusted component first so WriteAt's whole-line guard does not erase the incident reference.
        return code + "Démarrage refusé : " + Clean(error.GetType().Name) + " (0x"
            + error.HResult.ToString("X8", CultureInfo.InvariantCulture) + "). " + Clean(error.Message);
    }
    internal static string FailureLocation(string? path) => path is null ? "La trace de démarrage n’a pas pu être écrite."
        : "Trace de démarrage : " + path;

    // Before integrity we cannot load the product's masking service. Fail closed for any secret-shaped diagnostic;
    // command-line values, exception Data and stack traces are never passed here.
    internal static string Clean(string? text)
    {
        if (text is null) return "";
        if (text.Length > 8192) return "[détail trop long, non conservé]";
        foreach (var key in new[] { "password", "passwd", "pwd", "token", "secret", "credential", "authorization", "mot de passe", "bearer", "eyJ" })
            if (text.Contains(key, StringComparison.OrdinalIgnoreCase)) return "[détail masqué]";
        return string.Concat(text.Select(c => char.IsControl(c) ? ' ' : c));
    }

    private static string? Write(string name, string text)
    {
        // These roots never derive from the working directory, package, ROOT aliases or a caller-supplied path.
        try
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            foreach (var root in new[] { local, Path.GetTempPath() }.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                if (string.IsNullOrWhiteSpace(root) || !Path.IsPathFullyQualified(root)) continue;
                var result = WriteAt(Path.Combine(root, "Domenia", "logs"), name, text);
                if (result is not null) return result;
            }
        }
#pragma warning disable CA1031 // Destination discovery itself is best effort; never hide the original startup error.
        catch (Exception) { }
#pragma warning restore CA1031
        return null;
    }

    internal static string? WriteAt(string folder, string name, string text)
    {
        if (name is not ("Domenia-bootstrap.log" or "Domenia-startup-error.log")) return null;
        try
        {
            if (!Path.IsPathFullyQualified(folder) || folder.StartsWith(@"\\", StringComparison.Ordinal)) return null;
            var drive = new DriveInfo(Path.GetPathRoot(folder)!);
            if (drive.DriveType is not (DriveType.Fixed or DriveType.Removable or DriveType.Ram)) return null;
            lock (Gate)
            {
                Ordinary(folder); Directory.CreateDirectory(folder); Ordinary(folder);
                var path = Path.Combine(folder, name); Ordinary(path); Ordinary(path + ".1");
                var bytes = Encoding.UTF8.GetBytes(DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture) + " " + Clean(text) + "\r\n");
                if (File.Exists(path) && new FileInfo(path).Length + bytes.Length > Limit) File.Move(path, path + ".1", overwrite: true);
                using var file = new FileStream(path, FileMode.OpenOrCreate, FileAccess.Write, FileShare.Read);
                Ordinary(path);
                if (file.Length + bytes.Length > Limit) return null;
                file.Seek(0, SeekOrigin.End); file.Write(bytes); file.Flush(flushToDisk: true);
                return path;
            }
        }
#pragma warning disable CA1031 // Early diagnostics are observational, including destination discovery and disk failures.
        catch (Exception) { return null; }
#pragma warning restore CA1031
    }

    private static void Ordinary(string path)
    {
        for (var current = path; !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
            if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Destination de trace redirigée.");
    }
}
