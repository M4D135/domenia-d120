using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;

namespace Domenia.App;

internal sealed record DefaultsPackageResult(bool Cancelled, bool Simulated, string? Directory, string? Archive, string? Sha256, string Message);

/// <summary>Creates a new distributable copy. The running installation, its manifest and operator data are never edited.</summary>
internal static class PackageDefaults
{
    internal const string SeedName = "Domenia.settings.seed.json";

    internal static DefaultsPackageResult Create(string source, string destinationParent, string? userData, string text, CancellationToken token)
    {
        _ = PortableConfiguration.Read(text);
        var seed = new UTF8Encoding(false, true).GetBytes(text);
        var root = PackageLifecycleFiles.Root(source);
        var parent = PackageLifecycleFiles.Root(destinationParent);
        if (Within(parent, root) || userData is not null && Within(parent, Path.GetFullPath(userData)))
        { throw new InvalidDataException("Choisissez un dossier de diffusion extérieur au logiciel et aux données de Domenia."); }
        token.ThrowIfCancellationRequested();
        using var paths = new PackageLifecycleFiles();
        paths.Pin(parent); paths.PinTree(root);
        using var original = PackageIntegrity.Open(root, manifestRequired: true);
        var seedName = PackageLayout.Relative(root, SeedName);
        var manifestName = original.ManifestRelativePath;
        var lockName = PackageLayout.Relative(root, ".lifecycle.lock");
        var releaseName = PackageLayout.Relative(root, PackageUpdateArchive.ReleaseName);
        var components = original.Components.ToDictionary(c => c.Path, StringComparer.OrdinalIgnoreCase);
        if (!components.TryGetValue(releaseName, out var release) || release.Length is <= 0 or > 16384)
        { throw new InvalidDataException("Cette action exige un pack PROD publié complet."); }
        using var metadata = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(root, release.Path)));
        var version = metadata.RootElement.GetProperty("version").GetString() ?? "";
        _ = PackageUpdateCatalog.StableVersion(version);
        PackageUpdateArchive.ValidateRelease(metadata.RootElement, version, components, original.IsLight);
        if (components.Values.Where(c => !c.Path.Equals(seedName, StringComparison.OrdinalIgnoreCase)).Sum(c => c.Length) + seed.Length > PackageLifecycleFiles.MaximumBytes)
        { throw new InvalidDataException("Pack avec configuration supérieur à 8 Gio."); }
        if (!components.ContainsKey(seedName) && components.Count == 4096)
        { throw new InvalidDataException("Le pack ne dispose plus d’une entrée pour sa configuration par défaut."); }
        var output = Path.Combine(parent, "Domenia-diffusion-" + Guid.NewGuid().ToString("N"));
        if (PackageLifecycleFiles.Exists(output)) { throw new IOException("Destination déjà présente ; aucune copie remplacée."); }
        paths.PrivateDirectory(output);
        try
        {
            var pack = Path.Combine(output, "Domenia"); paths.MakeDirectory(pack);
            var copied = new List<PackageComponent>();
            var contractName = PackageLayout.Relative(root, PackageIntegrity.ContractName);
            foreach (var component in components.Values.OrderBy(c => c.Path, StringComparer.Ordinal))
            {
                if (component.Path.Equals(seedName, StringComparison.OrdinalIgnoreCase) || component.Path == contractName) { continue; }
                paths.Copy(PackageLifecycleFiles.At(root, component.Path), PackageLifecycleFiles.At(pack, component.Path), component, token);
                copied.Add(component);
            }
            token.ThrowIfCancellationRequested();
            PackageLifecycleFiles.WriteNew(Path.Combine(pack, seedName), seed);
            copied.Add(new(seedName, seed.Length, Hash(seed)));
            if (original.Contract is not null)
            {
                var contract = JsonNode.Parse(File.ReadAllBytes(Path.Combine(root, contractName)))!.AsObject();
                contract["componentsFingerprint"] = PackageIntegrity.ComponentFingerprint(copied);
                var bytes = JsonSerializer.SerializeToUtf8Bytes(contract);
                PackageLifecycleFiles.WriteNew(Path.Combine(pack, contractName), bytes);
                copied.Add(new(contractName, bytes.Length, Hash(bytes)));
            }
            var files = copied.OrderBy(c => c.Path, StringComparer.Ordinal).Select(c => new { path = c.Path, length = c.Length, sha256 = c.Sha256 }).ToArray();
            var manifest = original.IsLight ? JsonSerializer.SerializeToUtf8Bytes(new { format = 2, packageType = PackageIntegrity.LightType, files })
                : JsonSerializer.SerializeToUtf8Bytes(new { format = 1, files });
            PackageLifecycleFiles.WriteNew(Path.Combine(pack, manifestName), manifest);
            PackageLifecycleFiles.WriteNew(Path.Combine(pack, lockName), []);
            using var verified = PackageIntegrity.Open(pack, manifestRequired: true);
            var archiveName = $"Domenia_{version}_{(original.IsLight ? PackageIntegrity.LightType : "PROD")}_Windows-x64.zip";
            var archive = Path.Combine(output, archiveName);
            WriteArchive(pack, archive, copied.Select(c => c.Path).Append(manifestName).Append(lockName), token);
            string archiveHash;
            using (var stream = new FileStream(archive, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan))
            {
                if (stream.Length is <= 0 or > PackageUpdateCatalog.MaximumArchiveBytes) { throw new InvalidDataException("Archive supérieure au plafond de diffusion."); }
                archiveHash = Convert.ToHexStringLower(SHA256.HashData(stream)); stream.Position = 0;
                using var zip = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen: true);
                var entries = PackageUpdateArchive.Inspect(zip);
                if (entries.Count != copied.Count + 2) { throw new InvalidDataException("Archive de diffusion incomplète."); }
                foreach (var component in copied.Append(new(manifestName, manifest.Length, Hash(manifest))).Append(new(lockName, 0, Hash([]))))
                {
                    token.ThrowIfCancellationRequested();
                    if (!entries.TryGetValue(component.Path, out var entry) || entry.Length != component.Length) { throw new InvalidDataException("Composant ZIP absent ou incomplet."); }
                    using var content = entry.Open();
                    if (Convert.ToHexStringLower(SHA256.HashData(content)) != component.Sha256) { throw new InvalidDataException("Composant ZIP différent de la copie contrôlée."); }
                }
            }
            token.ThrowIfCancellationRequested();
            PackageLifecycleFiles.WriteNew(Path.Combine(output, PackageUpdateCatalog.ChecksumsName), Encoding.UTF8.GetBytes(archiveHash + "  " + archiveName + "\n"));
            return new(false, false, output, archive, archiveHash,
                "Pack prêt à diffuser avec cette configuration par défaut. Le logiciel ouvert et vos réglages restent inchangés. Les nouveaux profils l’importeront automatiquement ; les profils existants pourront remplacer ou conserver leurs réglages.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException or JsonException or OperationCanceledException)
        {
            if (ex is OperationCanceledException) { throw; }
            throw new IOException("Pack de diffusion non terminé ; copie conservée dans " + output + ". Ne la diffusez pas. Le pack d’origine reste intact.", ex);
        }
    }

    private static bool Within(string path, string root) => string.Equals(Path.TrimEndingDirectorySeparator(path), Path.TrimEndingDirectorySeparator(root), StringComparison.OrdinalIgnoreCase)
        || path.StartsWith(Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    private static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    private static void WriteArchive(string root, string output, IEnumerable<string> names, CancellationToken token)
    {
        using var file = new FileStream(output, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 65536, FileOptions.WriteThrough);
        using (var zip = new ZipArchive(file, ZipArchiveMode.Create, leaveOpen: true))
        {
            var buffer = new byte[65536];
            foreach (var name in names.OrderBy(n => n, StringComparer.Ordinal))
            {
                token.ThrowIfCancellationRequested();
                var entry = zip.CreateEntry(name, CompressionLevel.Fastest);
                using var input = new FileStream(PackageLifecycleFiles.At(root, name), FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan);
                using var destination = entry.Open();
                int count;
                while ((count = input.Read(buffer)) != 0)
                {
                    token.ThrowIfCancellationRequested(); destination.Write(buffer, 0, count);
                    if (file.Length > PackageUpdateCatalog.MaximumArchiveBytes) { throw new InvalidDataException("Archive supérieure à 4 Gio."); }
                }
            }
        }
        file.Flush(true);
    }
}
