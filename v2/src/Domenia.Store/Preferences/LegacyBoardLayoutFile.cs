using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>Explicit bounded local reads of the D1 preference locations. No database, backup, source rewrite or network access.</summary>
public static class LegacyBoardLayoutFile
{
    public const int MaxBytes = 4_194_304;

    public static LegacyBoardPreview Read(string appFolder, string userFolder, CancellationToken token, string? localApplicationData = null)
    {
        var (data, configuration) = Layout(appFolder, userFolder, token);
        var portable = Path.Combine(appFolder, "data");
        // Exact D1 Read-DomeniaPreference order, including original ADCC locations. SQLite contains observations, not these preferences.
        var paths = new List<string>
        {
            Path.Combine(data, "Preferences", "Domenia.settings.json"), Path.Combine(data, "Domenia.settings.json"),
            Path.Combine(appFolder, "Domenia.settings.json"), Path.Combine(data, "ADCC.settings.json"),
            Path.Combine(portable, "ADCC.settings.json"), Path.Combine(appFolder, "ADCC.settings.json"),
        };
        if (!string.IsNullOrWhiteSpace(localApplicationData)) paths.Add(Path.Combine(localApplicationData, "ADCC.settings.json"));
        return ReadCandidates(paths, token, configuration);
    }

    internal static (string Data, LegacyBoardConfiguration? Configuration) Layout(string appFolder, string userFolder, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var mode = "Compatible";
        LegacyBoardConfiguration? configuration = null;
        var configPath = Path.Combine(appFolder, "Domenia.config.json");
        if (ReadBounded(configPath, 1_048_576, token) is { } configBytes)
        {
            using var config = Parse(configBytes);
            configuration = new(configPath, Convert.ToHexStringLower(SHA256.HashData(configBytes)), config.RootElement.Clone());
            if (Property(config.RootElement, "LocalStore") is { } local)
            {
                if (Property(local, "Mode") is { } configured)
                {
                    if (configured.ValueKind != JsonValueKind.String) { throw new InvalidDataException("Mode LocalStore non textuel."); }
                    mode = configured.GetString()!;
                }
            }
        }
        if (!new[] { "Compatible", "Portable", "UserLocal" }.Contains(mode, StringComparer.OrdinalIgnoreCase))
        { throw new InvalidDataException("Mode de stockage D1 inconnu ; aucun emplacement deviné."); }
        var portable = Path.Combine(appFolder, "data");
        var usePortable = mode.Equals("Portable", StringComparison.OrdinalIgnoreCase);
        if (mode.Equals("Compatible", StringComparison.OrdinalIgnoreCase) && Qualify(portable, directory: true, token))
        {
            token.ThrowIfCancellationRequested();
            usePortable = Directory.EnumerateFileSystemEntries(portable).Any();
            if (!Qualify(portable, directory: true, token)) { throw new IOException("Le dossier de données a disparu pendant sa qualification."); }
        }
        var data = usePortable ? portable : Path.Combine(userFolder, "Data");
        return (data, configuration);
    }

    internal static LegacyBoardPreview ReadCandidates(IReadOnlyList<string> paths, CancellationToken token, LegacyBoardConfiguration? configuration = null)
    {
        if (paths.Count > 8) { throw new InvalidDataException("Trop d’emplacements de préférences historiques."); }
        var warnings = ImmutableArray.CreateBuilder<string>();
        foreach (var path in paths.Distinct(StringComparer.OrdinalIgnoreCase).SelectMany(p => new[] { p, p + ".bak" }))
        {
            token.ThrowIfCancellationRequested();
            var bytes = ReadBounded(path, MaxBytes, token);
            if (bytes is null) { continue; }
            try
            {
                using var document = Parse(bytes);
                var preview = LegacyBoardLayouts.Parse(document.RootElement, path, Convert.ToHexStringLower(SHA256.HashData(bytes)), configuration);
                token.ThrowIfCancellationRequested();
                return preview with { Warnings = warnings.ToImmutable() };
            }
            catch (Exception ex) when (ex is JsonException or DecoderFallbackException or InvalidDataException)
            {
                // As in Read-DomeniaPreference, malformed JSON may fall back to .bak. Access errors never select another file.
                warnings.Add("Document D1 incompatible conservé : " + path + ". Recherche du prochain emplacement historique.");
            }
        }
        token.ThrowIfCancellationRequested();
        if (configuration is not null)
        {
            var settings = JsonSerializer.SerializeToElement(new Dictionary<string, string>());
            var preview = LegacyBoardLayouts.Parse(settings, configuration.Path, configuration.Sha256, configuration)
                with { Warnings = warnings.ToImmutable(), SourceKind = "configuration" };
            token.ThrowIfCancellationRequested();
            return preview;
        }
        return new(null, null, [.. new[] { "Fleet", "Computer", "Software" }.Select(b =>
            new LegacyBoardProposal(b, null, "absent", "Aucune disposition D1 locale trouvée.", 0, [], null))], warnings.ToImmutable());
    }

    /// <summary>Import-only source lease. Runs after the D2 mutex wait; files cannot change during the atomic write.</summary>
    public static IDisposable HoldSources(LegacyBoardPreview preview, string board, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var proposal = preview.Boards.Single(p => p.Board == board);
        if (proposal.State != "ready" || preview.SourcePath is null || preview.SourceSha256 is null)
        { throw new InvalidDataException("Aucune source qualifiée à tenir pour cet import."); }
        var paths = new Dictionary<string, (string Sha, int Max)>(StringComparer.OrdinalIgnoreCase)
            { [preview.SourcePath] = (preview.SourceSha256, preview.SourceKind == "configuration" ? 1_048_576 : MaxBytes) };
        if (proposal.TeamSource is { } team)
        {
            if (paths.TryGetValue(team.Path, out var same) && same.Sha != team.Sha256)
            { throw new InvalidDataException("Empreintes contradictoires pour la même source D1."); }
            paths[team.Path] = (team.Sha256, 1_048_576);
        }
        var lease = new SourceLease();
        try
        {
            foreach (var (path, expected) in paths)
            {
                token.ThrowIfCancellationRequested();
                if (!Qualify(path, directory: false, token)) { throw new InvalidDataException("Source D1 disparue depuis l’aperçu."); }
                var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan);
                lease.Streams.Add(stream);
                if (!Qualify(path, directory: false, token)) { throw new InvalidDataException("Source D1 disparue pendant son ouverture."); }
                var length = stream.Length;
                if (length > expected.Max) { throw new InvalidDataException("Source D1 agrandie au-delà de sa borne."); }
                var bytes = new byte[checked((int)length)];
                stream.ReadExactly(bytes);
                token.ThrowIfCancellationRequested();
                if (stream.ReadByte() != -1 || Convert.ToHexStringLower(SHA256.HashData(bytes)) != expected.Sha)
                { throw new InvalidDataException("Source D1 modifiée depuis l’aperçu ; import non appliqué."); }
                if (!Qualify(path, directory: false, token)) { throw new InvalidDataException("Source D1 déplacée pendant sa qualification."); }
            }
            token.ThrowIfCancellationRequested();
            return lease;
        }
        catch { lease.Dispose(); throw; }
    }

    private sealed class SourceLease : IDisposable
    {
        public List<FileStream> Streams { get; } = [];
        public void Dispose() { foreach (var stream in Streams) { stream.Dispose(); } }
    }

    /// <summary>Real absence only; measured allocation, exact read and EOF, with local non-reparse paths checked before and after.</summary>
    internal static byte[]? ReadBounded(string path, int maxBytes, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (!Qualify(path, directory: false, token)) { token.ThrowIfCancellationRequested(); return null; }
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan);
        if (!Qualify(path, directory: false, token)) { throw new IOException("Fichier de préférences disparu pendant son ouverture."); }
        var length = file.Length;
        if (length > maxBytes) { throw new InvalidDataException("Fichier de préférences au-delà de la taille autorisée ; original conservé."); }
        var bytes = new byte[checked((int)length)];
        token.ThrowIfCancellationRequested();
        file.ReadExactly(bytes);
        token.ThrowIfCancellationRequested();
        if (file.ReadByte() != -1) { throw new InvalidDataException("Fichier de préférences agrandi pendant la lecture."); }
        if (!Qualify(path, directory: false, token)) { throw new IOException("Fichier de préférences disparu pendant sa lecture."); }
        token.ThrowIfCancellationRequested();
        return bytes;
    }

    internal static bool Qualify(string path, bool directory, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (path.Length is < 3 or > 1024 || !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\'
            || path.AsSpan(3).Contains(':') || path.Contains('/') || path.Any(char.IsControl))
        { throw new InvalidDataException("Un emplacement absolu local ordinaire est requis pour la migration D1."); }
        var full = Path.GetFullPath(path);
        var current = Path.GetPathRoot(full)!;
        if (new DriveInfo(current).DriveType == DriveType.Network) { throw new InvalidDataException("Migration D1 depuis un lecteur réseau refusée."); }
        var attributes = File.GetAttributes(current);
        if ((attributes & FileAttributes.ReparsePoint) != 0 || (attributes & FileAttributes.Directory) == 0)
        { throw new InvalidDataException("Racine de préférences redirigée ou non répertoire."); }
        var components = full[3..].TrimEnd('\\').Split('\\');
        for (var i = 0; i < components.Length; i++)
        {
            current = Path.Combine(current, components[i]);
            token.ThrowIfCancellationRequested();
            try { attributes = File.GetAttributes(current); }
            catch (FileNotFoundException) { token.ThrowIfCancellationRequested(); return false; }
            catch (DirectoryNotFoundException) { token.ThrowIfCancellationRequested(); return false; }
            if ((attributes & FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("Préférences ou ancêtre redirigés ; aucune migration."); }
            var mustBeDirectory = i < components.Length - 1 || directory;
            if (((attributes & FileAttributes.Directory) != 0) != mustBeDirectory)
            { throw new InvalidDataException("Type de fichier ou d’ancêtre des préférences incompatible."); }
        }
        token.ThrowIfCancellationRequested();
        return true;
    }

    private static JsonDocument Parse(byte[] bytes)
    {
        var offset = bytes.AsSpan().StartsWith(new byte[] { 0xEF, 0xBB, 0xBF }) ? 3 : 0;
        return JsonDocument.Parse(new UTF8Encoding(false, true).GetString(bytes, offset, bytes.Length - offset), new JsonDocumentOptions { MaxDepth = 32 });
    }

    private static JsonElement? Property(JsonElement value, string name)
    {
        if (value.ValueKind != JsonValueKind.Object) { throw new InvalidDataException("Objet de configuration D1 attendu."); }
        var found = value.EnumerateObject().Where(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase)).ToArray();
        if (found.Length > 1) { throw new InvalidDataException("Champ de configuration D1 dupliqué."); }
        return found.Length == 0 ? null : found[0].Value;
    }
}
