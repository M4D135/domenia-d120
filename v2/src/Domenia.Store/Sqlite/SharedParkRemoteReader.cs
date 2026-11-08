using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// One explicitly requested read of the shared TSV: the qualified canonical path is bound to Exists/SHA/bytes/rows, the bytes and
/// rows being those of <see cref="SharedParkFile.ReadFile"/> (bounded, strict UTF-8), never a duplicated payload. An empty present
/// file stays distinct from an absent one through <see cref="Exists"/>, although both carry the SHA of empty bytes.
/// </summary>
internal sealed record SharedParkRemoteRead(string Path, bool Exists, byte[] Bytes, string Sha256, ImmutableArray<SharedParkLine> Rows);

/// <summary>
/// Explicit read of the shared survey, reusable by the future read action: a pure lexical validation, then a read run off the UI
/// thread. Nothing is read from configuration, no share, lock, file, folder or identity is ever created, and no GUID or domain is
/// invented: the caller supplies the TSV path, the active local base, the protected configuration files and the protected
/// directories (Backups among them). The before/after re-qualifications of the file and of every parent are read guards only:
/// never a lock, never a CAS proof, never an atomic protection against every replacement. The re-read under lock, the physical
/// identity control, the double CAS and the qualification before any write stay mandatory in the publication lot. This lot
/// publishes nothing.
/// </summary>
internal static class SharedParkRemoteReader
{
    /// <summary>Bounded protection lists: beyond this, the request is refused rather than partially honoured.</summary>
    internal const int MaxProtectedEntries = 64;

    private static readonly char[] InvalidComponentChars = ['<', '>', '"', '|', '?', '*', ':'];
    private static readonly string[] ReservedDeviceNames = ["CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        "COM\u00B9", "COM\u00B2", "COM\u00B3", "LPT\u00B9", "LPT\u00B2", "LPT\u00B3"];

    /// <summary>
    /// Pure lexical validation, no file or network access at all (an UNC included, which is never opened): the base rules of
    /// <see cref="SharedParkFile.PathValue"/> reinforced against Windows ambiguities. Only an ordinary absolute local file or an
    /// explicit UNC share passes; relative, device, extension-prefixed, alternate-data-stream, root-only, empty, dot/dotdot,
    /// trailing-space-or-dot, forbidden-character and DOS-reserved components are refused as given, never silently normalized to
    /// become acceptable. The same ambiguity rules apply to the UNC server and share names. The TSV can never target the active
    /// base, its lock/-wal/-shm/-journal sidecars, a protected
    /// configuration file, or a protected directory and its descendants (compared OrdinalIgnoreCase with a correct directory
    /// boundary, so a like-prefixed neighbor stays allowed).
    /// </summary>
    internal static string Validate(string path, string databasePath, ImmutableArray<string> configFiles, ImmutableArray<string> protectedDirectories, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(path);
        ArgumentNullException.ThrowIfNull(databasePath);
        var database = Qualified(databasePath, "Base locale active", allowRoot: false);
        var configs = QualifiedList(configFiles, "Fichier de configuration protégé", allowRoot: false, token);
        var protectedDirs = QualifiedList(protectedDirectories, "Répertoire protégé", allowRoot: true, token);
        var canonical = SharedParkFile.PathValue(path);
        Qualified(path, "Relevé partagé", allowRoot: false);
        if (string.Equals(canonical, database, StringComparison.OrdinalIgnoreCase)) { throw new InvalidDataException("Le relevé partagé ne peut pas viser la base locale active ; aucune lecture engagée."); }
        foreach (var sidecar in Sidecars(database))
        {
            token.ThrowIfCancellationRequested();
            if (string.Equals(canonical, sidecar, StringComparison.OrdinalIgnoreCase))
            { throw new InvalidDataException("Le relevé partagé ne peut pas viser un fichier de verrou ni un sidecar -wal, -shm ou -journal de la base active ; aucune lecture engagée."); }
        }
        foreach (var config in configs)
        {
            token.ThrowIfCancellationRequested();
            if (string.Equals(canonical, config, StringComparison.OrdinalIgnoreCase)) { throw new InvalidDataException("Le relevé partagé ne peut pas viser un fichier de configuration protégé ; aucune lecture engagée."); }
        }
        foreach (var directory in protectedDirs)
        {
            token.ThrowIfCancellationRequested();
            if (IsSelfOrDescendant(canonical, directory)) { throw new InvalidDataException("Le relevé partagé ne peut pas viser un répertoire protégé ni l’un de ses descendants ; aucune lecture engagée."); }
        }
        token.ThrowIfCancellationRequested();
        return canonical;
    }

    /// <summary>
    /// Explicitly requested read, run off the UI thread: the token is verified before the operations, after the read and
    /// immediately before the return; the attributes of the file and of each of its parents up to the root or the share are
    /// qualified before and after the read.
    /// Reparse points, junctions, links, a target that is a folder and a missing, inaccessible or non-directory parent refuse
    /// everything; no access or network error is ever converted into an absence. Only the terminal file really absent under
    /// qualified existing parents reads as Exists=false, and nothing is ever created on the way.
    /// </summary>
    internal static Task<SharedParkRemoteRead> ReadAsync(string path, string databasePath, ImmutableArray<string> configFiles, ImmutableArray<string> protectedDirectories, DateTimeOffset now, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(path);
        ArgumentNullException.ThrowIfNull(databasePath);
        if (now <= DateTimeOffset.UnixEpoch) { throw new InvalidDataException("Horloge de lecture absente ou sentinelle ; aucune date de relevé n’est comparée à un zéro."); }
        return Task.Run(() =>
        {
            token.ThrowIfCancellationRequested();
            var canonical = Validate(path, databasePath, configFiles, protectedDirectories, token);
            QualifyTree(canonical, token);
            var read = SharedParkFile.ReadFile(canonical, now, token);
            token.ThrowIfCancellationRequested();
            QualifyTree(canonical, token);
            token.ThrowIfCancellationRequested();
            return new SharedParkRemoteRead(canonical, read.Exists, read.Bytes, read.Sha256, read.Rows);
        }, token);
    }

    /// <summary>Strict lexical qualification of one path identity, no access at all: absolute local (drive root) or explicit UNC (server and share), ordinary components only.</summary>
    private static string Qualified(string path, string label, bool allowRoot)
    {
        if (path is null) { throw new InvalidDataException(label + " : une protection absente n’est pas ignorée."); }
        if (path.Length is 0 or > 1024 || path.Any(char.IsControl)
            || path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal))
        { throw new InvalidDataException(label + " : chemin absolu ordinaire attendu (1 024 caractères au plus, sans préfixe d’étendue ni caractère de contrôle)."); }
        var normalized = path.Replace('/', '\\');
        string root;
        string remainder;
        if (normalized.StartsWith(@"\\", StringComparison.Ordinal))
        {
            var tail = normalized.AsSpan(2);
            if (tail.IsEmpty || tail[0] == '\\') { throw new InvalidDataException(label + " : partage UNC ambigu ; le chemin doit désigner explicitement le serveur et le partage."); }
            var serverEnd = tail.IndexOf('\\');
            if (serverEnd < 0) { throw new InvalidDataException(label + " : partage UNC sans partage ; le serveur seul n’est pas une origine de fichier."); }
            var server = tail[..serverEnd].ToString();
            QualifiedComponent(server, label, "nom de serveur");
            var shareTail = tail[(serverEnd + 1)..];
            var shareEnd = shareTail.IndexOf('\\');
            var share = (shareEnd < 0 ? shareTail : shareTail[..shareEnd]).ToString();
            QualifiedComponent(share, label, "nom de partage");
            root = @"\\" + server + "\\" + share;
            remainder = shareEnd < 0 ? string.Empty : shareTail[(shareEnd + 1)..].ToString();
        }
        else if (normalized.Length >= 3 && char.IsAsciiLetter(normalized[0]) && normalized[1] == ':' && normalized[2] == '\\')
        {
            root = normalized[..3];
            remainder = normalized[3..];
        }
        else { throw new InvalidDataException(label + " : chemin absolu local ou partage UNC explicite attendu ; rien n’est complété en silence."); }
        if (remainder.Length == 0)
        {
            if (allowRoot) { return System.IO.Path.GetFullPath(normalized); }
            throw new InvalidDataException(label + " : la racine ou le partage seul n’est pas un fichier ordinaire.");
        }
        foreach (var component in remainder.Split('\\')) { QualifiedComponent(component, label, "composant de chemin"); }
        return System.IO.Path.GetFullPath(normalized);
    }

    /// <summary>The same ambiguity rules for every name of the path, the UNC server and share included: never empty, never
    /// dot/dotdot, no trailing space or dot, no forbidden character, no DOS-reserved device name (COM/LPT with superscripts too,
    /// the U+00B9/U+00B2/U+00B3 forms Windows reserves; the U+2081/U+2082/U+2083 subscripts stay ordinary characters).</summary>
    private static void QualifiedComponent(string name, string label, string what)
    {
        if (name.Length == 0) { throw new InvalidDataException(label + " : " + what + " vide ; rien n’est complété en silence."); }
        if (name is "." or "..") { throw new InvalidDataException(label + " : « " + name + " » n’est pas un " + what + " ordinaire ; rien n’est normalisé en silence pour devenir acceptable."); }
        if (name.EndsWith('.') || name.EndsWith(' ')) { throw new InvalidDataException(label + " : espace ou point final sur le " + what + " ; la valeur ambiguë n’est pas normalisée pour devenir acceptable."); }
        if (name.IndexOfAny(InvalidComponentChars) >= 0) { throw new InvalidDataException(label + " : caractère interdit dans le " + what + "."); }
        var dot = name.IndexOf('.');
        if (ReservedDeviceNames.Contains(dot < 0 ? name : name[..dot], StringComparer.OrdinalIgnoreCase))
        { throw new InvalidDataException(label + " : « " + name + " » porte un nom de périphérique DOS réservé."); }
    }

    private static ImmutableArray<string> QualifiedList(ImmutableArray<string> values, string label, bool allowRoot, CancellationToken token)
    {
        if (values.IsDefault) { throw new InvalidDataException(label + " : tableau absent ; les protections ne sont pas ignorées."); }
        if (values.Length > MaxProtectedEntries) { throw new InvalidDataException(label + " : plus de " + MaxProtectedEntries + " entrées ; liste de protections hors limites."); }
        var list = ImmutableArray.CreateBuilder<string>(values.Length);
        foreach (var value in values)
        {
            token.ThrowIfCancellationRequested();
            list.Add(Qualified(value, label, allowRoot));
        }
        return list.ToImmutable();
    }

    private static IEnumerable<string> Sidecars(string database)
    {
        yield return database + ".lock";
        yield return database + "-wal";
        yield return database + "-shm";
        yield return database + "-journal";
    }

    /// <summary>Directory boundary done right: the directory itself and its descendants, never a like-prefixed neighbor.</summary>
    private static bool IsSelfOrDescendant(string candidate, string directory)
    {
        if (string.Equals(candidate, directory, StringComparison.OrdinalIgnoreCase)) { return true; }
        var prefix = directory.EndsWith('\\') ? directory : directory + '\\';
        return candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>File then every parent up to the root or the share (never above the share), attributes read by real access
    /// through <see cref="File.GetAttributes"/> — never an existence helper, never the sentinel value a <see cref="FileSystemInfo"/>
    /// returns for a missing entry. The token is verified once more before the terminal access.</summary>
    private static void QualifyTree(string file, CancellationToken token)
    {
        var directory = System.IO.Path.GetDirectoryName(file)!;
        var rootTrimmed = System.IO.Path.GetPathRoot(directory)!.TrimEnd('\\');
        for (var current = directory; ; current = System.IO.Path.GetDirectoryName(current)!)
        {
            token.ThrowIfCancellationRequested();
            QualifyDirectory(current);
            if (string.Equals(current.TrimEnd('\\'), rootTrimmed, StringComparison.OrdinalIgnoreCase)) { break; }
        }
        token.ThrowIfCancellationRequested();
        QualifyTerminal(file);
    }

    private static void QualifyDirectory(string directory)
    {
        FileAttributes attributes;
        try { attributes = File.GetAttributes(directory); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { throw new InvalidDataException("Parent du relevé partagé absent ou inaccessible : « " + directory + " » ; une erreur d’accès n’est jamais convertie en absence.", ex); }
        if ((attributes & FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("Parent du relevé partagé est un point d’analyse, une jonction ou un lien : « " + directory + " » ; la lecture explicite s’arrête là."); }
        if ((attributes & FileAttributes.Directory) == 0) { throw new InvalidDataException("Parent du relevé partagé n’est pas un répertoire : « " + directory + " » ; aucune lecture engagée."); }
    }

    private static void QualifyTerminal(string file)
    {
        FileAttributes attributes;
        try { attributes = File.GetAttributes(file); }
        catch (FileNotFoundException) { return; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { throw new InvalidDataException("Relevé partagé inaccessible : « " + file + " » ; une erreur d’accès ou de réseau n’est jamais convertie en absence.", ex); }
        if ((attributes & FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("Le relevé partagé est un point d’analyse, une jonction ou un lien ; la lecture explicite s’arrête là."); }
        if ((attributes & FileAttributes.Directory) != 0) { throw new InvalidDataException("La cible du relevé partagé est un dossier ; aucun dossier n’est lu comme un relevé."); }
    }
}
