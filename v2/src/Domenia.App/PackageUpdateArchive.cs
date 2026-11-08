using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace Domenia.App;

internal sealed record PreparedUpdate(string Directory, string Version, string ManifestSha256, string ArchiveSha256, long Bytes,
    string SourceCommit, string ExecutableSha256);

/// <summary>Inspect before extracting, then verify the exact private copy. Never executes an archive entry.</summary>
internal static class PackageUpdateArchive
{
    internal const int MaximumEntries = 8192;
    internal const long MaximumExpandedBytes = 8L * 1024 * 1024 * 1024;
    internal const long MaximumEntryBytes = 2L * 1024 * 1024 * 1024;
    internal const long MaximumRatio = 500;
    internal const string ReleaseName = "package-release.json";

    internal static IReadOnlyDictionary<string, ZipArchiveEntry> Inspect(ZipArchive archive)
    {
        if (archive.Entries.Count is < 12 or > MaximumEntries) { throw new InvalidDataException("Nombre d’entrées ZIP hors limites."); }
        var all = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var files = new Dictionary<string, ZipArchiveEntry>(StringComparer.OrdinalIgnoreCase);
        var directories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long bytes = 0;
        foreach (var entry in archive.Entries)
        {
            var directory = entry.FullName.EndsWith('/');
            var name = directory ? entry.FullName[..^1] : entry.FullName;
            var unixType = (entry.ExternalAttributes >> 16) & 0xF000;
            if (!PackageIntegrity.ValidRelativePath(name) || name.Split('/').Length > 32 || !all.Add(name)
                || (entry.ExternalAttributes & (int)FileAttributes.ReparsePoint) != 0
                || unixType is not (0 or 0x8000 or 0x4000) || (unixType == 0x4000 && !directory)
                || (unixType == 0x8000 && directory))
            { throw new InvalidDataException("ZIP : chemin, doublon Windows ou lien interdit."); }
            if (directory)
            {
                if (entry.Length != 0) { throw new InvalidDataException("Répertoire ZIP contenant des octets."); }
                directories.Add(name); continue;
            }
            if ((entry.ExternalAttributes & (int)FileAttributes.Directory) != 0 || entry.Length < 0 || entry.Length > MaximumEntryBytes
                || entry.Length > MaximumExpandedBytes - bytes || entry.CompressedLength < 0 || entry.CompressedLength > PackageUpdateCatalog.MaximumArchiveBytes
                || (entry.Length > 0 && (entry.CompressedLength == 0 || entry.Length > entry.CompressedLength * MaximumRatio)))
            { throw new InvalidDataException("ZIP : taille ou ratio de décompression excessif."); }
            bytes += entry.Length; files.Add(name, entry);
        }
        foreach (var name in all)
        {
            for (var slash = name.LastIndexOf('/'); slash >= 0; slash = name.LastIndexOf('/', slash - 1))
            {
                var parent = name[..slash];
                if (files.ContainsKey(parent)) { throw new InvalidDataException("Un fichier ZIP masque un répertoire."); }
                directories.Add(parent);
                if (slash == 0) { break; }
            }
        }
        var wad = files.ContainsKey("wad/" + PackageIntegrity.ManifestName);
        var manifestName = PackageLayout.Relative(wad, PackageIntegrity.ManifestName);
        var releaseName = PackageLayout.Relative(wad, ReleaseName);
        var lockName = PackageLayout.Relative(wad, ".lifecycle.lock");
        if (wad && files.Keys.Any(name => name != "Domenia.exe" && !name.StartsWith("wad/", StringComparison.Ordinal)))
        { throw new InvalidDataException("La racine PROD doit contenir uniquement Domenia.exe et wad."); }
        if (!files.ContainsKey(manifestName) || !files.ContainsKey(releaseName) || !files.ContainsKey("Domenia.exe")
            || !files.TryGetValue(lockName, out var lifecycle) || lifecycle.Length != 0)
        { throw new InvalidDataException("Pack incomplet ou placé dans un dossier supplémentaire ; Domenia.exe doit être à la racine."); }
        // Empty directories are irrelevant and may never conceal unlisted private content.
        if (directories.Any(d => !files.Keys.Any(f => f.StartsWith(d + "/", StringComparison.OrdinalIgnoreCase))))
        { throw new InvalidDataException("Répertoire vide hors inventaire du pack."); }
        return files;
    }

    internal static PreparedUpdate Prepare(string localArchive, string expectedSha256, string expectedVersion,
        string destination, CancellationToken cancellationToken, bool light = false)
    {
        if (!PackageUpdateCatalog.Hash(expectedSha256)) { throw new InvalidDataException("Empreinte du ZIP requise."); }
        _ = PackageUpdateCatalog.StableVersion(expectedVersion);
        var target = PackageLifecycleFiles.Root(destination);
        using var paths = new PackageLifecycleFiles();
        paths.Pin(Path.GetDirectoryName(target)!);
        if (PackageLifecycleFiles.Exists(target)) { throw new IOException("Le dossier de préparation existe déjà ; il est conservé."); }
        using var input = new FileStream(localArchive, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan);
        if (input.Length is <= 0 or > PackageUpdateCatalog.MaximumArchiveBytes) { throw new InvalidDataException("Taille du ZIP hors limites."); }
        cancellationToken.ThrowIfCancellationRequested();
        var archiveSha = Convert.ToHexStringLower(SHA256.HashData(input));
        if (!archiveSha.Equals(expectedSha256, StringComparison.OrdinalIgnoreCase)) { throw new InvalidDataException("Le SHA-256 de la copie locale diffère de la publication."); }
        input.Position = 0;
        using var zip = new ZipArchive(input, ZipArchiveMode.Read, leaveOpen: true);
        var entries = Inspect(zip);
        var wad = entries.ContainsKey("wad/" + PackageIntegrity.ManifestName);
        var manifestName = PackageLayout.Relative(wad, PackageIntegrity.ManifestName);
        var releaseName = PackageLayout.Relative(wad, ReleaseName);
        var lockName = PackageLayout.Relative(wad, ".lifecycle.lock");
        using var manifestBytes = ReadSmall(entries[manifestName], 2 * 1024 * 1024, cancellationToken);
        var manifestHash = Convert.ToHexStringLower(SHA256.HashData(manifestBytes)); manifestBytes.Position = 0;
        var components = PackageIntegrity.ReadManifest(manifestBytes, out var declaredLight);
        if (declaredLight != light) throw new InvalidDataException("Variante du manifeste différente de la mise à jour sélectionnée.");
        var declared = components.ToDictionary(c => c.Path, StringComparer.OrdinalIgnoreCase);
        if (entries.Count != declared.Count + 2 || entries.Keys.Any(name => name != manifestName && name != lockName && !declared.ContainsKey(name))
            || declared.Any(c => !entries.TryGetValue(c.Key, out var entry) || entry.Length != c.Value.Length))
        { throw new InvalidDataException("L’inventaire du pack ne couvre pas exactement les fichiers du ZIP."); }
        using var releaseBytes = ReadSmall(entries[releaseName], 16384, cancellationToken);
        using var releaseJson = JsonDocument.Parse(releaseBytes);
        ValidateRelease(releaseJson.RootElement, expectedVersion, declared, light);
        var release = releaseJson.RootElement;
        var sourceCommit = release.GetProperty("sourceCommit").GetString()!;
        var executableHash = release.GetProperty("executableSha256").GetString()!;
        // No filesystem mutation before the entire central-directory/manifest/metadata contract has passed.
        paths.PrivateDirectory(target);
        long expanded = 0;
        foreach (var pair in entries.OrderBy(p => p.Key, StringComparer.Ordinal))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var output = PackageLifecycleFiles.At(target, pair.Key);
            var parent = Path.GetDirectoryName(output)!;
            MakeParents(paths, target, parent);
            using var stream = pair.Value.Open();
            using var file = new FileStream(output, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 65536, FileOptions.WriteThrough);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[65536]; long count = 0;
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var read = stream.Read(buffer);
                if (read == 0) { break; }
                if (count + read > pair.Value.Length || expanded + read > MaximumExpandedBytes)
                { throw new InvalidDataException("L’entrée décompressée dépasse sa taille annoncée."); }
                file.Write(buffer, 0, read); hash.AppendData(buffer, 0, read); count += read; expanded += read;
            }
            var actual = Convert.ToHexStringLower(hash.GetHashAndReset());
            var expected = pair.Key == manifestName ? manifestHash
                : pair.Key == lockName ? Convert.ToHexStringLower(SHA256.HashData(Array.Empty<byte>())) : declared[pair.Key].Sha256;
            if (count != pair.Value.Length || !actual.Equals(expected, StringComparison.OrdinalIgnoreCase))
            { throw new InvalidDataException("Composant du ZIP altéré : " + pair.Key + ". Copie conservée, aucune installation."); }
            file.Flush(true);
        }
        cancellationToken.ThrowIfCancellationRequested();
        using var verified = PackageIntegrity.Open(target, manifestRequired: true);
        if (verified.ManifestHash != manifestHash) { throw new InvalidDataException("La préparation a changé pendant sa vérification."); }
        return new(target, expectedVersion, manifestHash, archiveSha, input.Length, sourceCommit, executableHash);
    }

    internal static void ValidateRelease(JsonElement release, string version, IReadOnlyDictionary<string, PackageComponent> components, bool light = false)
    {
        PackageUpdateCatalog.Unique(release);
        string[] fields = ["version", "build", "dataSchemaVersion", "dataSchemaRevision", "project", "architecture", "packageType", "sourceCommit", "executableSha256", "dependencies"];
        if (release.ValueKind != JsonValueKind.Object || release.EnumerateObject().Count() != fields.Length
            || release.EnumerateObject().Any(p => !fields.Contains(p.Name, StringComparer.Ordinal)))
        { throw new InvalidDataException("Métadonnées de pack incomplètes ou inconnues."); }
        var build = release.GetProperty("build").GetString() ?? "";
        var commit = release.GetProperty("sourceCommit").GetString() ?? "";
        var exe = release.GetProperty("executableSha256").GetString();
        if (release.GetProperty("project").GetString() != "Domenia" || release.GetProperty("version").GetString() != version
            || release.GetProperty("architecture").GetString() != "win-x64" || release.GetProperty("packageType").GetString() != (light ? PackageIntegrity.LightType : "PROD")
            || !build.StartsWith(version + "+", StringComparison.Ordinal) || !PackageUpdateCatalog.Hash(build[(version.Length + 1)..])
            || commit.Length != 40 || !commit.All(Uri.IsHexDigit) || !PackageUpdateCatalog.Hash(exe)
            || !components.TryGetValue("Domenia.exe", out var executable) || !string.Equals(executable.Sha256, exe, StringComparison.OrdinalIgnoreCase)
            || !release.GetProperty("dataSchemaVersion").TryGetInt32(out var schema) || schema is < 1 or > 1000000
            || !release.GetProperty("dataSchemaRevision").TryGetInt32(out var revision) || revision is < 0 or > 1000000)
        { throw new InvalidDataException("Pack PROD incompatible, provenance absente ou identité différente de l’inventaire."); }
        var dependencies = release.GetProperty("dependencies");
        if (dependencies.ValueKind != JsonValueKind.Object || dependencies.EnumerateObject().Count() != 2
            || dependencies.EnumerateObject().Any(p => p.Name is not (".NET" or "WebView2") || p.Value.ValueKind != JsonValueKind.String
                || p.Value.GetString() is not { Length: > 0 and <= 100 } value || value.Any(char.IsControl)))
        { throw new InvalidDataException("Versions .NET et WebView2 requises dans le pack."); }
        if (light != (dependencies.GetProperty("WebView2").GetString() == "Evergreen"))
            throw new InvalidDataException("Dépendance WebView2 incompatible avec la variante sélectionnée.");
    }

    private static MemoryStream ReadSmall(ZipArchiveEntry entry, int maximum, CancellationToken token)
    {
        if (entry.Length is <= 0 || entry.Length > maximum) { throw new InvalidDataException("Document du pack hors limites."); }
        using var stream = entry.Open(); var output = new MemoryStream((int)entry.Length);
        var buffer = new byte[16384];
        try
        {
            while (true)
            {
                token.ThrowIfCancellationRequested(); var count = stream.Read(buffer); if (count == 0) { break; }
                if (output.Length + count > entry.Length) { throw new InvalidDataException("Document ZIP tronqué ou plus grand qu’annoncé."); }
                output.Write(buffer, 0, count);
            }
            if (output.Length != entry.Length) { throw new InvalidDataException("Document ZIP incomplet."); }
            output.Position = 0; return output;
        }
        catch { output.Dispose(); throw; }
    }

    private static void MakeParents(PackageLifecycleFiles paths, string root, string parent)
    {
        if (parent == root) { return; }
        MakeParents(paths, root, Path.GetDirectoryName(parent)!); paths.MakeDirectory(parent);
    }
}
