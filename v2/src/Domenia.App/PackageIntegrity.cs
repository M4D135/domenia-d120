using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Bridge;

namespace Domenia.App;

internal sealed record PackageComponent(string Path, long Length, string Sha256);

/// <summary>Local consistency check of a published pack; hashes are not a publisher signature.</summary>
internal sealed partial class PackageIntegrity : IDisposable
{
    internal const string LightType = "PROD-LIGHT";
    internal bool IsLight { get; private set; }
    internal const string ManifestName = "package-manifest.json";
    internal string ManifestRelativePath { get; private set; } = ManifestName;
    internal const int MaximumFiles = 4096;
    private const long MaximumManifest = 2 * 1024 * 1024;
    private static readonly string[] Required = ["Domenia.exe", "Domenia.deps.json", "Domenia.runtimeconfig.json",
        .. RuntimeLibraryPlan.RequiredFiles, "web/index.html", "runtime/webview2/msedgewebview2.exe"];
    private readonly List<FileStream> held = [];
    private readonly List<IDisposable> optionalTools = [];
    public int FilesChecked { get; private set; }
    public bool Packaged { get; private set; }
    internal long BytesHashed { get; private set; }
    internal long HashReads { get; private set; }
    internal string? ManifestHash { get; private set; }
    internal IReadOnlyList<PackageComponent> Components { get; private set; } = [];
    /// <summary>Socle WebView2 engine the operator extracted beside this PROD-LIGHT pack, verified byte for byte.</summary>
    internal SocleWebView? Socle { get; private set; }
    private readonly SocleWebView? socleIndex;

    private PackageIntegrity(SocleWebView? socleIndex = null) => this.socleIndex = socleIndex;

    /// <summary>Hold the lifecycle lock and the checked runtime files against replacement until shutdown.</summary>
    public static PackageIntegrity Open(string directory, bool manifestRequired, CancellationToken cancellationToken = default, Action<int, int>? progress = null)
    {
        var lease = new PackageIntegrity();
        try { lease.Verify(Path.GetFullPath(directory), manifestRequired, cancellationToken: cancellationToken, progress: progress); return lease; }
        catch { lease.Dispose(); throw; }
    }

    // Tests only: a small index stands in for the pinned 257-file Socle engine.
    internal static PackageIntegrity OpenWithSocle(string directory, SocleWebView socle)
    {
        var lease = new PackageIntegrity(socle);
        try { lease.Verify(Path.GetFullPath(directory), true); return lease; }
        catch { lease.Dispose(); throw; }
    }

    // Only the lifecycle owner may validate installed bytes while it holds the exclusive lock and a pending marker.
    // Startup always uses Open above and has no bypass flag.
    internal static PackageIntegrity OpenForLifecycle(string directory, FileStream exclusiveLock)
    {
        var root = Path.GetFullPath(directory);
        if (!exclusiveLock.CanRead || !exclusiveLock.CanWrite || !string.Equals(Path.GetFullPath(exclusiveLock.Name), PackageLayout.At(root, ".lifecycle.lock"), StringComparison.OrdinalIgnoreCase))
        { throw Invalid("Propriétaire du verrou de livraison invalide."); }
        var lease = new PackageIntegrity();
        try { lease.Verify(root, true, exclusiveLock); return lease; }
        catch { lease.Dispose(); throw; }
    }

    // Reachable only after the closed helper channel authenticated its real parent. The transaction and
    // one-use attempt are qualified again here; normal startup never takes this path.
    internal static PackageIntegrity OpenForHealth(string directory, PackageHealthRequest request)
    {
        var root = Path.GetFullPath(directory);
        PackageLifecycle.ValidateHealthStartup(root, request);
        var lease = new PackageIntegrity();
        try
        {
            lease.Verify(root, true, healthStartup: true);
            if (lease.ManifestHash != request.ManifestSha256) { throw Invalid("Paquet de santé différent de la transaction."); }
            return lease;
        }
        catch { lease.Dispose(); throw; }
    }

    private void Verify(string root, bool manifestRequired, FileStream? exclusiveLock = null, bool healthStartup = false, CancellationToken cancellationToken = default, Action<int, int>? progress = null)
    {
        cancellationToken.ThrowIfCancellationRequested();
        CheckPath(root);
        if (exclusiveLock is null && !healthStartup) { RefusePendingUpdate(root); }
        ManifestRelativePath = PackageLayout.Relative(root, ManifestName);
        var manifestPath = Path.Combine(root, ManifestRelativePath);
        if (!File.Exists(manifestPath))
        {
            if (manifestRequired) { throw Invalid("Manifeste du paquet absent. Réextrayez le paquet complet dans un nouveau dossier."); }
            return;
        }
        // The publisher creates the lock; startup never creates files in the installation directory.
        if (exclusiveLock is null && !healthStartup) { Hold(PackageLayout.At(root, ".lifecycle.lock")); RefusePendingUpdate(root); }
        var manifest = Hold(manifestPath);
        if (manifest.Length is <= 0 or > MaximumManifest) { throw Invalid("Taille du manifeste invalide."); }
        ManifestHash = Convert.ToHexStringLower(SHA256.HashData(manifest)); manifest.Position = 0;
        Components = ReadManifest(manifest, out var light);
        IsLight = light;
        if (ManifestRelativePath.StartsWith("wad/", StringComparison.Ordinal) != Components.Any(c => c.Path == "wad/Domenia.dll"))
        { throw Invalid("Emplacement du manifeste différent de la disposition déclarée."); }
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        // A PROD-LIGHT pack never lists the Socle engine; once extracted into wad it is admitted only as the exact pinned index.
        var socle = IsLight && Directory.Exists(PackageLayout.At(root, SocleWebView.Folder)) ? socleIndex ?? SocleWebView.Pinned : null;
        var total = Components.Count + (socle?.Files.Count ?? 0);
        // One shared buffer: retaining file handles must not retain a separate 64 KiB read buffer per component.
        var hashBuffer = new byte[1024 * 1024];
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        void Admit(string name, PackageComponent expected, string changed)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var stream = Hold(Path.Combine(root, name.Replace('/', Path.DirectorySeparatorChar)));
            int read;
            while ((read = stream.Read(hashBuffer)) != 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
                hasher.AppendData(hashBuffer, 0, read); BytesHashed += read; HashReads++;
            }
            var actual = Convert.ToHexString(hasher.GetHashAndReset());
            if (stream.Length != expected.Length || !string.Equals(actual, expected.Sha256, StringComparison.OrdinalIgnoreCase))
            { throw Invalid($"{changed} : {name}. Taille attendue {expected.Length}, lue {stream.Length} ; SHA-256 attendu {expected.Sha256}, lu {actual}."); }
            FilesChecked++;
            progress?.Invoke(FilesChecked, total);
        }
        foreach (var component in Components)
        {
            names.Add(component.Path);
            Admit(component.Path, component, "Composant modifié ou versions mélangées");
        }
        if (socle is not null)
        {
            foreach (var file in socle.Files)
            {
                var name = PackageLayout.Relative(root, file.Path);
                if (!names.Add(name)) { throw Invalid("Le manifeste du pack recouvre le moteur WebView2 du Socle."); }
                if (!File.Exists(Path.Combine(root, name.Replace('/', Path.DirectorySeparatorChar))))
                { throw Invalid($"Pack WebView2 du Socle incomplet : {name} absent. Réextrayez {SocleWebView.Archive} dans le dossier wad, sans rien renommer."); }
                Admit(name, file, "Pack WebView2 du Socle modifié ou d’une autre version");
            }
            Socle = socle;
        }
        cancellationToken.ThrowIfCancellationRequested();
        // A stale JS module, native DLL or WebView resource outside the manifest must not be loaded later.
        var visited = 0;
        InspectTree(root, root, names, ref visited, allowPending: exclusiveLock is not null || healthStartup);
        if (exclusiveLock is null && !healthStartup) { RefusePendingUpdate(root); }
        cancellationToken.ThrowIfCancellationRequested();
        VerifyReleaseContract(root, required: IsLight);
        var release = PackageLifecycle.Release(root, Components);
        if (IsLight != (release?.PackageType == LightType) || IsLight != (release?.Dependencies?.GetValueOrDefault("WebView2") == "Evergreen"))
            throw Invalid("Déclaration du moteur WebView2 incompatible avec le manifeste du paquet.");
        if (IsLight)
        {
            var version = release?.Dependencies?.GetValueOrDefault(".NET");
            if (!Version.TryParse(version, out var net) || net.Major != 10 || net.Minor != 0 || net.Build < 0 || net.Revision != -1 || net.ToString() != version
                || new[] { $"host/fxr/{version}/hostfxr.dll", $"shared/Microsoft.NETCore.App/{version}/coreclr.dll",
                    $"shared/Microsoft.NETCore.App/{version}/System.Private.CoreLib.dll",
                    $"shared/Microsoft.WindowsDesktop.App/{version}/System.Windows.Forms.dll" }
                    .Any(p => !names.Contains("wad/runtime/dotnet/" + p)))
                throw Invalid("Runtime .NET privé de PROD-LIGHT absent ou incohérent.");
        }
        Packaged = true;
    }

    internal static IReadOnlyList<PackageComponent> ReadManifest(Stream manifest) => ReadManifest(manifest, out _);

    internal static IReadOnlyList<PackageComponent> ReadManifest(Stream manifest, out bool light)
    {
        if (manifest.Length is <= 0 or > MaximumManifest) { throw Invalid("Taille du manifeste invalide."); }
        using var document = JsonDocument.Parse(manifest, new JsonDocumentOptions { MaxDepth = 8 });
        var value = document.RootElement;
        if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty("format", out var field) || field.ValueKind != JsonValueKind.Number
            || !field.TryGetInt32(out var format) || format is not (1 or 2)) throw Invalid("Version du manifeste non prise en charge.");
        light = format == 2;
        Fields(value, light ? ["format", "packageType", "files"] : ["format", "files"]);
        if (light && (value.GetProperty("packageType").ValueKind != JsonValueKind.String || value.GetProperty("packageType").GetString() != LightType))
            throw Invalid("Seul un manifeste PROD-LIGHT explicite peut utiliser WebView2 préinstallé.");
        var files = value.GetProperty("files");
        if (files.ValueKind != JsonValueKind.Array || files.GetArrayLength() is < 10 or > MaximumFiles)
        { throw Invalid("Nombre de composants du paquet invalide."); }
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<PackageComponent>();
        long bytes = 0;
        foreach (var file in files.EnumerateArray())
        {
            Fields(file, ["path", "length", "sha256"]);
            var name = file.GetProperty("path").GetString();
            var expected = file.GetProperty("sha256").GetString();
            if (!ValidRelativePath(name) || !names.Add(name!) || IsMutable(name!) || IsData(name!) || name!.Equals(ManifestName, StringComparison.OrdinalIgnoreCase)
                || name.Equals("wad/" + ManifestName, StringComparison.OrdinalIgnoreCase))
            { throw Invalid("Chemin de composant invalide ou répété dans le manifeste."); }
            if (expected is null || expected.Length != 64 || !expected.All(Uri.IsHexDigit) ||
                !file.GetProperty("length").TryGetInt64(out var length) || length < 0)
            { throw Invalid("Empreinte ou taille de composant invalide dans le manifeste."); }
            const long maximumBytes = 8L * 1024 * 1024 * 1024;
            if (length > maximumBytes - bytes) { throw Invalid("Paquet supérieur au plafond de 8 Gio."); }
            bytes += length;
            result.Add(new(name!, length, expected.ToLowerInvariant()));
        }
        var wad = names.Contains("wad/Domenia.dll");
        if (light && (!wad || names.Contains("wad/runtime/webview2") || names.Any(n => n.StartsWith("wad/runtime/webview2/", StringComparison.OrdinalIgnoreCase)
                || n.EndsWith("/msedgewebview2.exe", StringComparison.OrdinalIgnoreCase) || n.EndsWith("/msedge.dll", StringComparison.OrdinalIgnoreCase))
                || new[] { "runtime/dotnet/dotnet.exe", ContractName, PackageUpdateArchive.ReleaseName }
                    .Any(n => !names.Contains(PackageLayout.Relative(wad, n)))))
            throw Invalid("Inventaire PROD-LIGHT incomplet ou moteur WebView2 fixe présent.");
        var required = light ? Required.Where(name => name != "runtime/webview2/msedgewebview2.exe") : Required;
        if (required.Any(name => !names.Contains(name == "Domenia.exe" ? name : PackageLayout.Relative(wad, name)))
            || wad && names.Any(name => name != "Domenia.exe" && !name.StartsWith("wad/", StringComparison.Ordinal)))
        { throw Invalid("Manifeste incomplet ou dispositions mélangées : un composant indispensable manque."); }
        return result.AsReadOnly();
    }

    private void InspectTree(string root, string current, HashSet<string> names, ref int visited, int depth = 0, bool allowPending = false)
    {
        if (depth > 32) { throw Invalid("Arborescence du paquet trop profonde."); }
        CheckPath(current);
        foreach (var path in Directory.EnumerateFileSystemEntries(current))
        {
            if (++visited > MaximumFiles * 2) { throw Invalid("Trop de composants dans le paquet."); }
            CheckPath(path);
            if (depth == 0 && ManifestRelativePath.StartsWith("wad/", StringComparison.Ordinal)
                && Path.GetFileName(path) is not ("Domenia.exe" or "wad"))
            { throw Invalid("Le pack doit contenir uniquement Domenia.exe et le dossier wad à sa racine."); }
            if ((File.GetAttributes(path) & FileAttributes.Directory) != 0) { InspectTree(root, path, names, ref visited, depth + 1, allowPending); continue; }
            var name = Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');
            if (!names.Contains(name) && Domenia.Inventory.RemoteReadTools.IsOptionalPackageComponent(name))
            {
                // Optional D1 deployment layout; never accept an executable merely because of its name.
                // Keep the approved bytes pinned for the whole application lifetime, just like manifested code.
                optionalTools.Add(Domenia.Inventory.RemoteReadTools.PinOptionalPackageComponent(root, name, CancellationToken.None));
                FilesChecked++;
                continue;
            }
            if (!IsMutable(name) && !name.Equals(ManifestRelativePath, StringComparison.OrdinalIgnoreCase) && !names.Contains(name)
                && !(allowPending && name == PackageLayout.Relative(root, ".update.pending")))
            {
                throw Invalid(Socle is not null && name.StartsWith(PackageLayout.Relative(root, SocleWebView.Folder) + "/", StringComparison.OrdinalIgnoreCase)
                    ? $"Fichier étranger au pack WebView2 du Socle : {name}. Réextrayez {SocleWebView.Archive} dans un dossier wad/runtime/webview2 vide."
                    : $"Composant hors manifeste : {name}. Réextrayez le paquet complet dans un nouveau dossier.");
            }
        }
    }

    private FileStream Hold(string path)
    {
        CheckPath(path);
        var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.SequentialScan);
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
        foreach (var relative in new[] { ".update.pending", "Support/.update.pending", "wad/.update.pending", "wad/Support/.update.pending" })
        {
            var path = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
            if (File.Exists(path) || Directory.Exists(path))
            { throw Invalid(PendingRecoveryHint.Describe(root, path)); }
        }
    }

    private static bool IsMutable(string name) => name.Equals(".lifecycle.lock", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("Domenia.config.json", StringComparison.OrdinalIgnoreCase) || name.Equals("wad/.lifecycle.lock", StringComparison.OrdinalIgnoreCase)
        || name.Equals("wad/Domenia.config.json", StringComparison.OrdinalIgnoreCase);

    private static bool IsData(string name) => name.Equals("data", StringComparison.OrdinalIgnoreCase)
        || name.StartsWith("data/", StringComparison.OrdinalIgnoreCase) || name.Equals("wad/data", StringComparison.OrdinalIgnoreCase)
        || name.StartsWith("wad/data/", StringComparison.OrdinalIgnoreCase);

    internal static bool ValidRelativePath(string? name)
    {
        if (string.IsNullOrEmpty(name) || name.Length > 512 || name.Any(c => char.IsControl(c) || c is '\\' or ':' or '<' or '>' or '"' or '|' or '?' or '*')) { return false; }
        foreach (var part in name.Split('/'))
        {
            if (part is "" or "." or ".." || part.EndsWith(' ') || part.EndsWith('.')) { return false; }
            var stem = part.Split('.')[0];
            if (stem.Equals("CON", StringComparison.OrdinalIgnoreCase) || stem.Equals("PRN", StringComparison.OrdinalIgnoreCase) ||
                stem.Equals("AUX", StringComparison.OrdinalIgnoreCase) || stem.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
                (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.OrdinalIgnoreCase) || stem.StartsWith("LPT", StringComparison.OrdinalIgnoreCase))
                    && (stem[3] is >= '1' and <= '9' or '\u00B9' or '\u00B2' or '\u00B3'))) { return false; }
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
        foreach (var tool in optionalTools) { tool.Dispose(); }
        optionalTools.Clear();
        foreach (var stream in held) { stream.Dispose(); }
        held.Clear();
    }
}
