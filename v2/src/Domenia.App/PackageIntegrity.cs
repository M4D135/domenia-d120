using System.Security.Cryptography;
using System.Text.Json;

namespace Domenia.App;

/// <summary>Local consistency check of a published pack; hashes are not a publisher signature.</summary>
internal sealed class PackageIntegrity : IDisposable
{
    internal const string ManifestName = "package-manifest.json";
    private const int MaximumFiles = 4096;
    private const long MaximumManifest = 2 * 1024 * 1024;
    private static readonly string[] Required = ["Domenia.exe", "Domenia.dll", "Domenia.deps.json", "Domenia.runtimeconfig.json",
        "Domenia.Core.dll", "Domenia.Ad.dll", "Domenia.Store.dll", "Domenia.Inventory.dll", "Domenia.Engine.dll",
        "Domenia.Bridge.dll", "Domenia.Simulation.dll", "web/index.html", "runtime/webview2/msedgewebview2.exe"];
    private readonly List<FileStream> held = [];
    public int FilesChecked { get; private set; }
    public bool Packaged { get; private set; }

    private PackageIntegrity() { }

    /// <summary>Hold the lifecycle lock and the checked runtime files against replacement until shutdown.</summary>
    public static PackageIntegrity Open(string directory, bool manifestRequired)
    {
        var lease = new PackageIntegrity();
        try { lease.Verify(Path.GetFullPath(directory), manifestRequired); return lease; }
        catch { lease.Dispose(); throw; }
    }

    private void Verify(string root, bool manifestRequired)
    {
        CheckPath(root);
        RefusePendingUpdate(root);
        var manifestPath = Path.Combine(root, ManifestName);
        if (!File.Exists(manifestPath))
        {
            if (manifestRequired) { throw Invalid("Manifeste du paquet absent. Réextrayez le paquet complet dans un nouveau dossier."); }
            return;
        }
        // The publisher creates the lock; startup never creates files in the installation directory.
        Hold(Path.Combine(root, ".lifecycle.lock"));
        RefusePendingUpdate(root);
        var manifest = Hold(manifestPath);
        if (manifest.Length is <= 0 or > MaximumManifest) { throw Invalid("Taille du manifeste invalide."); }
        using var document = JsonDocument.Parse(manifest, new JsonDocumentOptions { MaxDepth = 8 });
        var value = document.RootElement;
        Fields(value, ["format", "files"]);
        if (value.GetProperty("format").ValueKind != JsonValueKind.Number || value.GetProperty("format").GetInt32() != 1)
        { throw Invalid("Version du manifeste non prise en charge."); }
        var files = value.GetProperty("files");
        if (files.ValueKind != JsonValueKind.Array || files.GetArrayLength() is < 10 or > MaximumFiles)
        { throw Invalid("Nombre de composants du paquet invalide."); }
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in files.EnumerateArray())
        {
            Fields(file, ["path", "length", "sha256"]);
            var name = file.GetProperty("path").GetString();
            var expected = file.GetProperty("sha256").GetString();
            if (!ValidRelativePath(name) || !names.Add(name!) || IsMutable(name!) || name == ManifestName)
            { throw Invalid("Chemin de composant invalide ou répété dans le manifeste."); }
            if (expected is null || expected.Length != 64 || !expected.All(Uri.IsHexDigit) ||
                !file.GetProperty("length").TryGetInt64(out var length) || length < 0)
            { throw Invalid("Empreinte ou taille de composant invalide dans le manifeste."); }
            var stream = Hold(Path.Combine(root, name!.Replace('/', Path.DirectorySeparatorChar)));
            var actual = Convert.ToHexString(SHA256.HashData(stream));
            if (stream.Length != length || !string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
            {
                throw Invalid($"Composant modifié ou versions mélangées : {name}. Taille attendue {length}, lue {stream.Length} ; SHA-256 attendu {expected}, lu {actual}.");
            }
            FilesChecked++;
        }
        if (Required.Any(name => !names.Contains(name))) { throw Invalid("Manifeste incomplet : un composant indispensable manque."); }
        // A stale JS module, native DLL or WebView resource outside the manifest must not be loaded later.
        var visited = 0;
        InspectTree(root, root, names, ref visited);
        RefusePendingUpdate(root);
        Packaged = true;
    }

    private static void InspectTree(string root, string current, HashSet<string> names, ref int visited, int depth = 0)
    {
        if (depth > 32) { throw Invalid("Arborescence du paquet trop profonde."); }
        CheckPath(current);
        foreach (var path in Directory.EnumerateFileSystemEntries(current))
        {
            if (++visited > MaximumFiles * 2) { throw Invalid("Trop de composants dans le paquet."); }
            CheckPath(path);
            if ((File.GetAttributes(path) & FileAttributes.Directory) != 0) { InspectTree(root, path, names, ref visited, depth + 1); continue; }
            var name = Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');
            if (!IsMutable(name) && !name.Equals(ManifestName, StringComparison.OrdinalIgnoreCase) && !names.Contains(name))
            { throw Invalid($"Composant hors manifeste : {name}. Réextrayez le paquet complet dans un nouveau dossier."); }
        }
    }

    private FileStream Hold(string path)
    {
        CheckPath(path);
        var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, FileOptions.SequentialScan);
        held.Add(stream);
        CheckPath(path);
        return stream;
    }

    private static void CheckPath(string path)
    {
        for (var current = Path.GetFullPath(path); !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
        {
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            { throw Invalid("Le dossier du logiciel contient un lien ou une redirection. Utilisez un dossier ordinaire."); }
        }
    }

    private static void RefusePendingUpdate(string root)
    {
        foreach (var relative in new[] { ".update.pending", "Support/.update.pending" })
        {
            var path = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
            if (File.Exists(path) || Directory.Exists(path))
            { throw Invalid("Une mise à jour interrompue est signalée. Conservez les sauvegardes et réextrayez un paquet vérifié dans un nouveau dossier avant de relancer Domenia."); }
        }
    }

    private static bool IsMutable(string name) => name.Equals(".lifecycle.lock", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("Domenia.config.json", StringComparison.OrdinalIgnoreCase);

    internal static bool ValidRelativePath(string? name)
    {
        if (string.IsNullOrEmpty(name) || name.Length > 512 || name.Any(c => char.IsControl(c) || c is '\\' or ':' or '<' or '>' or '"' or '|' or '?' or '*')) { return false; }
        foreach (var part in name.Split('/'))
        {
            if (part is "" or "." or ".." || part.EndsWith(' ') || part.EndsWith('.')) { return false; }
            var stem = part.Split('.')[0];
            if (stem.Equals("CON", StringComparison.OrdinalIgnoreCase) || stem.Equals("PRN", StringComparison.OrdinalIgnoreCase) ||
                stem.Equals("AUX", StringComparison.OrdinalIgnoreCase) || stem.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
                (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.OrdinalIgnoreCase) || stem.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) && stem[3] is >= '1' and <= '9')) { return false; }
        }
        return true;
    }

    private static void Fields(JsonElement value, string[] expected)
    {
        if (value.ValueKind != JsonValueKind.Object) { throw Invalid("Structure du manifeste invalide."); }
        var found = new HashSet<string>(StringComparer.Ordinal);
        foreach (var field in value.EnumerateObject())
        {
            if (!expected.Contains(field.Name, StringComparer.Ordinal) || !found.Add(field.Name)) { throw Invalid("Champs inconnus ou répétés dans le manifeste."); }
        }
        if (found.Count != expected.Length) { throw Invalid("Manifeste incomplet."); }
    }

    private static InvalidDataException Invalid(string message) => new(message);
    public void Dispose()
    {
        foreach (var stream in held) { stream.Dispose(); }
        held.Clear();
    }
}
