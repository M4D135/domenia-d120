using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.App;

/// <summary>Local automation exits before application composition. No AppPaths, journal, profile, AD source or transport.</summary>
internal static partial class AutomationHostCommand
{
    private const int MaxOutputBytes = 64 * 1024 * 1024;
    private static readonly JsonSerializerOptions OutputJson = new() { WriteIndented = true };

    internal static int Run(IReadOnlyList<string> args, Func<IDisposable?> verifyPackage)
    {
        try
        {
            if (!Console.IsOutputRedirected) _ = AttachConsole(-1);
            using var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false), bufferSize: -1, leaveOpen: true);
            using var error = new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false), bufferSize: -1, leaveOpen: true);
            return Run(args, output, error, Environment.GetEnvironmentVariable(ModeResolver.SimulationVariable),
                ReadDemoConfiguration, TimeProvider.System, verifyPackage);
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException) { return 5; }
    }

    internal static int Run(IReadOnlyList<string> args, TextWriter output, TextWriter error, string? simulationSetting,
        Func<bool> demoConfiguration, TimeProvider clock, Func<IDisposable?> verifyPackage)
    {
        var invocation = AutomationCommandLine.Parse(args);
        if (!invocation.Valid) return Refuse(output, invocation.Error ?? "Commande refusée.", invocation.ExitCode);
        var request = invocation.Request!;
#pragma warning disable CA1031 // Closed unattended boundary: even malformed local bytes produce an exit code, never a dialog/profile.
        try
        {
            var simulation = simulationSetting?.Trim();
            if ((request.Command != "version" || invocation.OutputPath is not null) && (simulation == "1" || simulation != "0" && demoConfiguration()))
                return Refuse(output, "Lecture de base réelle refusée en démonstration ; aucun chemin de base ni de sortie ouvert.", 4);
            using var package = verifyPackage();
            if (package is null) return Refuse(output, "Contrôle préalable du paquet refusé ; aucune base ouverte.", 4);
            string? destination;
            try { destination = invocation.OutputPath is { } path ? Destination(path, request.Format) : null; }
            catch (Exception failure) when (failure is IOException or InvalidDataException or ArgumentException or UnauthorizedAccessException or NotSupportedException)
            { return Refuse(output, "Destination locale refusée : fichier nouveau .json/.csv dans un dossier existant, sans lien ni partage.", 5); }
            AutomationAnswer answer;
            if (request.Command == "version")
            {
                answer = new(request, new JsonObject { ["Application"] = ProductInfo.Name, ["Version"] = ProductInfo.Version,
                    ["LectureSeule"] = true, ["Base"] = null }, new JsonArray(JsonSerializer.SerializeToNode(ShellAutomation.Contract)), false,
                    [], ["Cette commande ne lit aucune base ni aucun profil."], clock.GetUtcNow());
            }
            else
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                try
                {
                    answer = DomeniaDatabase.ReadAutomationAsync(invocation.DatabasePath!, request, invocation.Family, clock, timeout.Token)
                        .GetAwaiter().GetResult();
                }
                catch (Exception failure)
                {
                    return Refuse(output, failure is OperationCanceledException
                        ? "Délai de lecture locale atteint ; aucune réponse partielle ni fichier de sortie produit."
                        : "Base locale absente, occupée, incohérente ou hors limites. Utilisez une base .db locale fermée, sans WAL/journal actif ; aucune migration ni création effectuée.", 3);
                }
            }
            var text = answer.Text();
            if (Encoding.UTF8.GetByteCount(text) > MaxOutputBytes)
                return Refuse(output, "Réponse supérieure à 64 Mio ; réduisez le périmètre ou la limite. Aucun fichier écrit.", 3);
            try
            {
                if (destination is null)
                {
                    if (request.Format == "Csv") output.Write('\uFEFF');
                    output.WriteLine(text); output.Flush();
                    if (answer.Truncated && request.Format == "Csv")
                    { error.WriteLine("Résultat CSV partiel : limite de " + request.Limit + " lignes atteinte."); error.Flush(); }
                }
                else
                {
                    var encoding = new UTF8Encoding(request.Format == "Csv");
                    var payload = encoding.GetPreamble().Concat(encoding.GetBytes(text)).ToArray();
                    var hash = Save(destination, request.Format, payload);
                    output.WriteLine(JsonSerializer.Serialize(new { Contract = ShellAutomation.ContractName, Command = request.Command,
                        Output = destination, Sha256 = hash, Count = answer.Items.Count, answer.Truncated, answer.GeneratedUtc, answer.Notes }, OutputJson));
                    output.Flush();
                }
                return 0;
            }
            catch (Exception failure) when (failure is IOException or InvalidDataException or ArgumentException or UnauthorizedAccessException or NotSupportedException)
            { return Refuse(error, "Sortie non écrite entièrement. Une destination finalisée reste complète ; aucun fichier existant n’a été remplacé.", 5); }
        }
        catch (Exception)
        { return Refuse(output, "Commande locale refusée avant production d’une réponse ; aucun profil ni accès réseau.", 3); }
#pragma warning restore CA1031
    }

    private static bool ReadDemoConfiguration()
    {
        var path = Path.Combine(AppContext.BaseDirectory, LegacyConfiguration.FileName);
        using var stream = OpenConfiguration(path);
        if (stream is null) return false;
        if (stream.Length > LegacyConfiguration.MaxBytes) throw new InvalidDataException("Configuration de démarrage hors limites.");
        var bytes = new byte[checked((int)stream.Length)]; stream.ReadExactly(bytes);
        var config = LegacyConfiguration.Parse(bytes);
        if (stream.ReadByte() != -1 || config.State == ConfigurationFileState.Invalid)
            throw new InvalidDataException("Configuration de démonstration non déterminable ; lecture réelle refusée.");
        return config.DemoProvider;
    }

    private static FileStream? OpenConfiguration(string path)
    {
        try { return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    private static string Destination(string path, string format)
    {
        if (!Path.IsPathFullyQualified(path) || path.StartsWith(@"\\", StringComparison.Ordinal) || path.AsSpan(2).Contains(':')
            || !ShellFileNames.IsSafe(Path.GetFileName(path), format == "Csv" ? "csv" : "json"))
            throw new InvalidDataException("Chemin local absolu et extension de sortie requis.");
        var target = Path.GetFullPath(path);
        if (FileDocumentStore.CheckLocalFolder(Path.GetDirectoryName(target)) is { } reason) throw new InvalidDataException(reason);
        if (File.Exists(target) || Directory.Exists(target)) throw new IOException("La destination existe déjà.");
        return target;
    }

    private static string Save(string target, string format, byte[] bytes)
    {
        _ = Destination(target, format);
        var temporary = Path.Combine(Path.GetDirectoryName(target)!, ".domenia-cli-" + Guid.NewGuid().ToString("N") + ".tmp");
        var created = false;
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                created = true; stream.Write(bytes); stream.Flush(flushToDisk: true); stream.Position = 0;
                var expected = SHA256.HashData(bytes);
                if (!SHA256.HashData(stream).AsSpan().SequenceEqual(expected)) throw new IOException("Relecture de la sortie différente.");
            }
            _ = Destination(target, format);
            File.Move(temporary, target, overwrite: false); created = false;
            return Convert.ToHexStringLower(SHA256.HashData(bytes));
        }
        finally
        {
            if (created)
            {
                // Remove only the temporary file this invocation created, never an existing destination.
                try { File.Delete(temporary); }
                catch (Exception failure) when (failure is IOException or UnauthorizedAccessException) { System.Diagnostics.Trace.WriteLine("Nettoyage temporaire CLI impossible."); }
            }
        }
    }

    private static int Refuse(TextWriter output, string message, int code)
    {
        try { output.WriteLine(JsonSerializer.Serialize(new { Contract = ShellAutomation.ContractName, ExitCode = code, Error = message })); output.Flush(); }
        catch (Exception failure) when (failure is IOException or ObjectDisposedException) { return 5; }
        return code;
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AttachConsole(int processId);
}
