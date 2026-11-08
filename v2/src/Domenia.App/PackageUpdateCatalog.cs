using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Domenia.App;

internal sealed record UpdateAsset(string Name, string Version, long? Size, string Sha256);

/// <summary>Closed, deterministic distribution contract. No filesystem, network, or installation.</summary>
internal static partial class PackageUpdateCatalog
{
    internal const string ChecksumsName = "SHA256SUMS.txt";
    internal const int MaximumCatalogBytes = 2 * 1024 * 1024;
    internal const long MaximumArchiveBytes = 4L * 1024 * 1024 * 1024;
    internal const string TrustNotice = "Les empreintes vérifient l’intégrité, pas une signature éditeur. Utilisez un partage dont les écritures sont administrées.";

    [GeneratedRegex(@"^Domenia_(0|[1-9][0-9]{0,7})\.(0|[1-9][0-9]{0,7})\.(0|[1-9][0-9]{0,7})_(PROD|PROD-LIGHT|DEV)_Windows-x64\.zip$", RegexOptions.CultureInvariant)]
    private static partial Regex PackName();

    internal static Version StableVersion(string text)
    {
        if (text.Length > 26 || text.Split('.').Length != 3 || text.Split('.').Any(p => p.Length == 0 || p.Length > 8
            || (p.Length > 1 && p[0] == '0') || !p.All(char.IsAsciiDigit)) || !Version.TryParse(text, out var version))
        { throw new InvalidDataException("Version stable majeure.mineure.correctif attendue."); }
        return version;
    }

    internal static string? VersionOfProd(string name, bool light = false)
    {
        var match = PackName().Match(name);
        return match.Success && match.Groups[4].Value == (light ? PackageIntegrity.LightType : "PROD")
            ? string.Join('.', match.Groups[1].Value, match.Groups[2].Value, match.Groups[3].Value) : null;
    }

    internal static bool Hash(string? hash) => hash is { Length: 64 } && hash.All(Uri.IsHexDigit);

    internal static IReadOnlyDictionary<string, string> Checksums(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length is 0 or > MaximumCatalogBytes) { throw new InvalidDataException("Liste d’empreintes hors limites."); }
        var text = new UTF8Encoding(false, true).GetString(bytes);
        if (text.StartsWith('\uFEFF')) { text = text[1..]; }
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.EndsWith('\r') ? raw[..^1] : raw;
            if (line.Length == 0) { continue; }
            if (line.Length is < 67 or > 300 || !Hash(line[..64]) || line[64] != ' ' || line[65] is not (' ' or '*'))
            { throw new InvalidDataException("Ligne SHA256SUMS invalide ; aucune empreinte devinée."); }
            var name = line[66..];
            if (!PackageIntegrity.ValidRelativePath(name) || name.Contains('/') || !result.TryAdd(name, line[..64].ToLowerInvariant()))
            { throw new InvalidDataException("Nom de fichier ambigu ou répété dans SHA256SUMS."); }
            if (result.Count > 512) { throw new InvalidDataException("Trop d’archives dans SHA256SUMS."); }
        }
        if (result.Count == 0) { throw new InvalidDataException("Aucune empreinte publiée."); }
        return result;
    }

    internal static UpdateAsset? Latest(IEnumerable<UpdateAsset> candidates, string installed, bool requireHash = true, bool light = false)
    {
        // Development builds may upgrade to the stable release with the same numeric version.
        var core = installed.Split('+')[0]; var prerelease = core.Contains('-');
        var current = StableVersion(core.Split('-')[0]);
        var values = candidates.Take(513).ToArray();
        if (values.Length > 512) { throw new InvalidDataException("Trop de versions candidates."); }
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var candidate in values)
        {
            if (VersionOfProd(candidate.Name, light) != candidate.Version || (requireHash && !Hash(candidate.Sha256))
                || candidate.Size is <= 0 or > MaximumArchiveBytes || !seen.Add(candidate.Version))
            { throw new InvalidDataException("Publication PROD incompatible ou ambiguë."); }
        }
        return values.Where(c => StableVersion(c.Version) > current || (prerelease && StableVersion(c.Version) == current))
            .OrderByDescending(c => StableVersion(c.Version)).FirstOrDefault();
    }

    internal static IReadOnlyList<UpdateAsset> FromChecksums(IReadOnlyDictionary<string, string> checksums, bool light = false)
        => checksums.Where(kv => VersionOfProd(kv.Key, light) is not null)
            .Select(kv => new UpdateAsset(kv.Key, VersionOfProd(kv.Key, light)!, null, kv.Value)).ToArray();

    internal static void Unique(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
            { if (!names.Add(property.Name)) { throw new InvalidDataException("Champ JSON répété."); } Unique(property.Value); }
        }
        else if (value.ValueKind == JsonValueKind.Array) { foreach (var child in value.EnumerateArray()) { Unique(child); } }
    }
}
