using System.Security.Cryptography;
using Domenia.Core;

namespace Domenia.App;

internal sealed record UpdateOffer(string Source, string Location, UpdateAsset Asset, string CatalogSha256);

/// <summary>Gesture-driven read-only acquisition from a distribution folder or a local ZIP, with no network client.
/// The mode guard runs before all real I/O, including local archives.</summary>
internal sealed class PackageUpdateSources : IDisposable
{
    private readonly AppMode mode;
    private readonly bool light;
    private readonly SemaphoreSlim gate = new(1, 1);

    internal PackageUpdateSources(AppMode mode, bool light = false)
    {
        this.mode = mode;
        this.light = light;
    }

    private void RequireRealMode()
    {
        if (mode != AppMode.Directory) { throw new InvalidOperationException("La démonstration utilise un catalogue fictif ; aucun accès à une source réelle n’est autorisé."); }
    }

    internal async Task<UpdateOffer?> FolderAsync(string folder, string installed, CancellationToken token)
    {
        RequireRealMode(); await gate.WaitAsync(token).ConfigureAwait(false);
        try { return await Task.Run(() => ReadFolder(folder, installed, null, token), token).ConfigureAwait(false); }
        finally { gate.Release(); }
    }

    internal async Task<UpdateOffer> LocalZipAsync(string path, CancellationToken token)
    {
        RequireRealMode(); await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                var name = Path.GetFileName(path); var folder = Path.GetDirectoryName(path) ?? throw new InvalidDataException("Dossier du ZIP absent.");
                if (PackageUpdateCatalog.VersionOfProd(name, light) is null) { throw new InvalidDataException("Sélectionnez un ZIP stable Windows-x64 de la variante installée."); }
                return ReadFolder(folder, "0.0.0", name, token) ?? throw new InvalidDataException("Archive absente de SHA256SUMS.txt placé à côté du ZIP.");
            }, token).ConfigureAwait(false);
        }
        finally { gate.Release(); }
    }

    private UpdateOffer? ReadFolder(string folder, string installed, string? selected, CancellationToken token)
    {
        var root = QualifiedFolder(folder);
        using var pin = new PackageLifecycleFiles(); pin.Pin(root);
        var bytes = LocalBytes(Path.Combine(root, PackageUpdateCatalog.ChecksumsName), PackageUpdateCatalog.MaximumCatalogBytes, token);
        var checksums = PackageUpdateCatalog.Checksums(bytes);
        var candidates = PackageUpdateCatalog.FromChecksums(checksums, light);
        var chosen = selected is null ? PackageUpdateCatalog.Latest(candidates, installed, light: light) : candidates.SingleOrDefault(c => c.Name == selected);
        if (chosen is null) { return null; }
        var path = Path.Combine(root, chosen.Name); PackageLifecycleFiles.Check(path);
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length is <= 0 or > PackageUpdateCatalog.MaximumArchiveBytes) { throw new InvalidDataException("Archive annoncée vide ou trop volumineuse."); }
        token.ThrowIfCancellationRequested();
        return new(selected is null ? "folder" : "local", root, chosen with { Size = file.Length }, Hash(bytes));
    }

    internal async Task<PreparedUpdate> PrepareAsync(UpdateOffer offer, string privateParent, CancellationToken token)
    {
        RequireRealMode(); await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (offer.Source is not ("folder" or "local") || PackageUpdateCatalog.VersionOfProd(offer.Asset.Name, light) != offer.Asset.Version
                || !PackageUpdateCatalog.Hash(offer.Asset.Sha256) || offer.Asset.Size is null or <= 0 or > PackageUpdateCatalog.MaximumArchiveBytes)
            { throw new InvalidDataException("Offre de mise à jour incomplète ; recommencez la recherche."); }
            // Every preparation is a new private tree. At most four retained attempts; no blind cleanup of evidence.
            var root = PackageLifecycleFiles.Root(privateParent);
            using var pins = new PackageLifecycleFiles(); pins.PrivateDirectory(root);
            if (Directory.EnumerateFileSystemEntries(root).Take(4).Count() >= 4)
            { throw new IOException("Quatre préparations sont conservées. Consultez et retirez explicitement les anciennes avant de recommencer."); }
            var attempt = Path.Combine(root, Guid.NewGuid().ToString("N")); pins.PrivateDirectory(attempt);
            var zipPath = Path.Combine(attempt, offer.Asset.Name);
            await using (var output = new FileStream(zipPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 65536, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                var sourceRoot = QualifiedFolder(offer.Location); pins.Pin(sourceRoot);
                var sums = LocalBytes(Path.Combine(sourceRoot, PackageUpdateCatalog.ChecksumsName), PackageUpdateCatalog.MaximumCatalogBytes, token);
                if (Hash(sums) != offer.CatalogSha256) { throw new InvalidDataException("Le catalogue a changé depuis l’aperçu ; relancez la recherche."); }
                var sourcePath = Path.Combine(sourceRoot, offer.Asset.Name); PackageLifecycleFiles.Check(sourcePath);
                await using var source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
                if (source.Length != offer.Asset.Size) { throw new InvalidDataException("Le ZIP a changé de taille depuis l’aperçu."); }
                await Copy(source, output, digest, offer.Asset.Size.Value, token).ConfigureAwait(false);
                if (!Convert.ToHexStringLower(digest.GetHashAndReset()).Equals(offer.Asset.Sha256, StringComparison.OrdinalIgnoreCase))
                { throw new InvalidDataException("SHA-256 de la copie invalide ; les binaires installés restent intacts."); }
                output.Flush(true);
            }
            return await Task.Run(() => PackageUpdateArchive.Prepare(zipPath, offer.Asset.Sha256, offer.Asset.Version,
                Path.Combine(attempt, "package"), token, light), token).ConfigureAwait(false);
        }
        finally { gate.Release(); }
    }

    private static async Task Copy(Stream source, FileStream target, IncrementalHash hash, long expected, CancellationToken token)
    {
        var buffer = new byte[65536]; long copied = 0;
        while (true)
        {
            var count = await source.ReadAsync(buffer, token).ConfigureAwait(false); if (count == 0) { break; }
            if (copied + count > expected) { throw new InvalidDataException("Archive reçue plus grande que celle annoncée."); }
            await target.WriteAsync(buffer.AsMemory(0, count), token).ConfigureAwait(false); hash.AppendData(buffer, 0, count); copied += count;
        }
        if (copied != expected) { throw new InvalidDataException("Archive reçue incomplète ; réessayez explicitement."); }
    }

    private static byte[] LocalBytes(string path, int maximum, CancellationToken token)
    {
        PackageLifecycleFiles.Check(path); using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length is <= 0 || stream.Length > maximum) { throw new InvalidDataException("Catalogue local hors limites."); }
        var bytes = new byte[(int)stream.Length]; stream.ReadExactly(bytes); token.ThrowIfCancellationRequested(); return bytes;
    }

    internal static string QualifiedFolder(string folder)
    {
        if (string.IsNullOrWhiteSpace(folder) || folder.Length > 512 || !Path.IsPathFullyQualified(folder)
            || folder.StartsWith("\\\\?", StringComparison.Ordinal) || folder.StartsWith("\\\\.", StringComparison.Ordinal))
        { throw new InvalidDataException("Choisissez un dossier local ou UNC absolu ordinaire."); }
        var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
        if (!string.Equals(full, Path.TrimEndingDirectorySeparator(folder), StringComparison.OrdinalIgnoreCase)) { throw new InvalidDataException("Chemin ambigu refusé."); }
        var relative = full.StartsWith("\\\\", StringComparison.Ordinal) ? full[2..] : full.Length >= 3 && char.IsAsciiLetter(full[0]) && full[1..3] == ":\\" ? full[3..] : "";
        if (!PackageIntegrity.ValidRelativePath(relative.Replace('\\', '/')) || (full.StartsWith("\\\\", StringComparison.Ordinal) && relative.Split('\\').Length < 2))
        { throw new InvalidDataException("Dossier de diffusion non canonique."); }
        return full;
    }

    private static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    public void Dispose() => gate.Dispose();
}
