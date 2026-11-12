using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;

namespace Domenia.App;

internal sealed record DefaultsPackageResult(bool Simulated, string? File, string? Sha256, string? Backup, string Message);

/// <summary>
/// Writes the default configuration in place, beside the running code (same model as GLPI Pilot): one file in wad,
/// outside the manifest. The binaries, the manifest and the official ZIP with its checksums are never edited, so the
/// folder stays a verified published pack and an update keeps the file. A previous file is backed up first.
/// </summary>
internal static class PackageDefaults
{
    internal const string SeedName = PackageIntegrity.DefaultsName;
    private const long MaximumPrevious = 16 * 1024 * 1024;

    internal static async Task<DefaultsPackageResult> WriteAsync(string source, string text, Func<byte[], CancellationToken, Task<string?>> backup, CancellationToken token)
    {
        _ = PortableConfiguration.Read(text);
        var seed = new UTF8Encoding(false, true).GetBytes(text);
        var root = PackageLifecycleFiles.Root(source);
        token.ThrowIfCancellationRequested();
        using var paths = new PackageLifecycleFiles();
        string relative, target;
        byte[]? previous = null;
        using (var pack = PackageIntegrity.Open(root, manifestRequired: true, token))
        {
            relative = PackageLayout.Relative(root, SeedName);
            var components = pack.Components.ToDictionary(c => c.Path, StringComparer.OrdinalIgnoreCase);
            var releaseName = PackageLayout.Relative(root, PackageUpdateArchive.ReleaseName);
            if (!components.TryGetValue(releaseName, out var release) || release.Length is <= 0 or > 16384)
            { throw new InvalidDataException("Cette action exige un pack PROD publié complet."); }
            using (var metadata = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(root, release.Path))))
            {
                var version = metadata.RootElement.GetProperty("version").GetString() ?? "";
                _ = PackageUpdateCatalog.StableVersion(version);
                PackageUpdateArchive.ValidateRelease(metadata.RootElement, version, components, pack.IsLight);
            }
            if (components.ContainsKey(relative))
            {
                throw new InvalidDataException("La configuration par défaut de ce pack fait partie de son manifeste (copie préparée avant 2.1.6) : "
                    + "elle ne peut pas être remplacée sur place. Extrayez le ZIP officiel dans un nouveau dossier, puis définissez-y la configuration par défaut.");
            }
            target = PackageLifecycleFiles.At(root, relative);
            paths.Pin(Path.GetDirectoryName(target)!);
            if (PackageLifecycleFiles.Exists(target))
            {
                PackageLifecycleFiles.Check(target);
                if (new FileInfo(target).Length > MaximumPrevious) { throw new InvalidDataException("Configuration par défaut existante trop volumineuse ; fichier conservé sans remplacement."); }
                previous = File.ReadAllBytes(target);
            }
        }
        if (previous is not null && SameConfiguration(previous, seed))
        {
            return new(false, target, Hash(previous), null, $"Cette configuration par défaut est déjà en place ({relative}) ; aucun fichier modifié.");
        }
        token.ThrowIfCancellationRequested();
        string? saved = null;
        if (previous is not null)
        {
            saved = await backup(previous, token).ConfigureAwait(false)
                ?? throw new IOException("Sauvegarde de la configuration par défaut existante impossible ; fichier conservé sans remplacement.");
        }
        token.ThrowIfCancellationRequested();
        // Same directory, then one rename: a reader sees the old or the new file, never a partial one.
        var temporary = target + ".domenia-" + Guid.NewGuid().ToString("N") + ".part";
        try
        {
            PackageLifecycleFiles.WriteNew(temporary, seed);
            if (previous is not null && PackageLifecycleFiles.Measure(root, relative) != new PackageComponent(relative, previous.Length, Hash(previous)))
            { throw new IOException("Configuration par défaut modifiée pendant l’écriture ; fichier conservé sans remplacement."); }
            if (previous is null && PackageLifecycleFiles.Exists(target)) { throw new IOException("Configuration par défaut apparue pendant l’écriture ; fichier conservé sans remplacement."); }
            File.Move(temporary, target, overwrite: previous is not null);
        }
        catch (UnauthorizedAccessException ex)
        {
            throw new UnauthorizedAccessException("Dossier du logiciel en lecture seule pour cette session : aucune configuration écrite. "
                + "Réglez Domenia dans un dossier extrait accessible en écriture, puis diffusez ce dossier.", ex);
        }
        finally { if (PackageLifecycleFiles.Exists(temporary)) { File.Delete(temporary); } }
        if (PackageLifecycleFiles.Measure(root, relative) != new PackageComponent(relative, seed.Length, Hash(seed)))
        { throw new IOException("Configuration par défaut relue différente de l’aperçu."); }
        // The file is written: no cancellation from here. The next start must accept this folder exactly as it is now.
        PackageIntegrity.Open(root, manifestRequired: true, CancellationToken.None).Dispose();
        return new(false, target, Hash(seed), saved,
            $"Configuration par défaut écrite dans {relative}. Ce dossier est prêt à diffuser ; le ZIP officiel, son manifeste et ses binaires restent inchangés. "
            + "Les nouveaux profils l’importeront automatiquement ; les profils existants pourront remplacer ou conserver leurs réglages."
            + (saved is null ? "" : $" L’ancienne configuration est sauvegardée dans vos exports : {saved}."));
    }

    // Each export carries its own time (exportedAt, to the second): the same choices written again are the same
    // configuration, so the file in place, its checksum and the decisions recorded for it are kept.
    private static bool SameConfiguration(byte[] previous, byte[] seed)
    {
        if (previous.AsSpan().SequenceEqual(seed)) { return true; }
        try
        {
            if (JsonNode.Parse(previous) is not JsonObject before || JsonNode.Parse(seed) is not JsonObject after) { return false; }
            before.Remove("exportedAt"); after.Remove("exportedAt");
            return JsonNode.DeepEquals(before, after);
        }
        catch (JsonException) { return false; }
    }

    private static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
}
