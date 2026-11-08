using System.Collections.Immutable;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Domenia.Core.Queries;

public sealed record QuerySourcePin(string Path, string Sha256);
public sealed record QueryImplementationManifest(string Format, string Implementation, string Assembly, bool RuntimeDownload,
    string UpstreamRepository, string HistoricalCommit, string ReviewedCommit, string UpstreamSource, string UpstreamBlob,
    bool UpstreamAssemblyLoaded, string Relationship, string SourceEncoding, ImmutableArray<string> Contracts, ImmutableArray<QuerySourcePin> Sources);
public sealed record QueryImplementationIdentity(QueryImplementationManifest Manifest, string Version, Guid ModuleId, string? BuildIdentity);

/// <summary>Contract lineage, not a claim that the historical .NET Framework library is shipped or executed by V2.</summary>
public static class QueryImplementationProvenance
{
    public static QueryImplementationIdentity Read()
    {
        var assembly = typeof(QueryEngine).Assembly;
        using var stream = assembly.GetManifestResourceStream("Domenia.QueryImplementation.json")
            ?? throw new InvalidDataException("Manifeste de provenance du moteur de requêtes absent.");
        if (stream.Length > 65536) throw new InvalidDataException("Manifeste de provenance hors limites.");
        var manifest = JsonSerializer.Deserialize<QueryImplementationManifest>(stream, new JsonSerializerOptions
        { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, MaxDepth = 8 })
            ?? throw new InvalidDataException("Manifeste de provenance vide.");
        if (manifest.Format != "Domenia.QueryImplementation/1" || manifest.Implementation != "internal-v2"
            || manifest.Assembly != assembly.GetName().Name || manifest.Assembly != "Domenia.Core" || manifest.RuntimeDownload || manifest.UpstreamAssemblyLoaded
            || manifest.UpstreamRepository != "https://github.com/M4D135/m4d-admin-common"
            || manifest.HistoricalCommit != "5ad02712e5c0eea6975b6ccb2c3e4343f93cc18b"
            || manifest.ReviewedCommit != "a050525abb46696d6b1516b18cccc2b837908a09"
            || manifest.UpstreamBlob != "6b5e244c55c5eb301f15597403244bb104fc227e" || manifest.UpstreamSource != "src/Query/QueryEngine.cs"
            || manifest.Relationship != "historical-contract-lineage" || manifest.SourceEncoding != "utf8-lf"
            || !manifest.Contracts.SequenceEqual(new[] { "Domenia.Query/1", "Domenia.Query/2", "Domenia.Query/3", "Domenia.Query/4", "Kleene-three-valued" })
            || manifest.Sources.IsDefaultOrEmpty || manifest.Sources.Length > 32
            || manifest.Sources.Any(p => !p.Path.StartsWith("src/Domenia.Core/Screens/Requetes/", StringComparison.Ordinal) || p.Path.Contains("..", StringComparison.Ordinal)
                || !p.Path.EndsWith(".cs", StringComparison.Ordinal) || p.Sha256 is not { Length: 64 } || !p.Sha256.All(char.IsAsciiHexDigitLower))
            || manifest.Sources.Select(p => p.Path).Distinct(StringComparer.Ordinal).Count() != manifest.Sources.Length)
            throw new InvalidDataException("Provenance du moteur incohérente avec l’implémentation interne chargée.");
        return new(manifest, assembly.GetName().Version?.ToString() ?? "inconnue", assembly.ManifestModule.ModuleVersionId,
            assembly.GetCustomAttributes<AssemblyMetadataAttribute>().SingleOrDefault(a => a.Key == "DomeniaBuildIdentity")?.Value);
    }

    public static void Validate() => _ = Read();
}
