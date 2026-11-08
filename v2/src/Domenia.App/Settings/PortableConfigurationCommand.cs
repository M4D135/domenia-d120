using System.Text;
using System.Text.Json;
using Domenia.Store;

namespace Domenia.App;

internal static class PortableConfigurationCommand
{
    internal static bool TryRun(string[] args, out int code)
    {
        code = 2;
        if (!args.Any(a => a.StartsWith("--check-settings-seed", StringComparison.OrdinalIgnoreCase))) return false;
        try
        {
            if (args.Length != 2 || !args[0].Equals("--check-settings-seed", StringComparison.OrdinalIgnoreCase)
                || PortableConfigurationFile.Read(args[1], CancellationToken.None) is null)
                throw new InvalidDataException();
            code = 0;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or JsonException or InvalidOperationException or NotSupportedException)
        {
            // Fixed refusal only: validation/parser errors must never expose the selected configuration's contents.
            try
            {
                using var output = new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false), leaveOpen: true);
                output.WriteLine("Configuration distribuable refusée : fichier local absent, inaccessible, invalide ou hors limites.");
            }
            catch (IOException) { /* Exit code remains the refusal; never initialize the application journal here. */ }
        }
        return true;
    }
}
