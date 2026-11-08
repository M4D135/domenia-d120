using System.Security.Cryptography;
using System.Text;
using Domenia.Bridge;
using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class QueryImplementationProvenanceTests
{
    [Test]
    public static void Loaded_query_engine_declares_internal_implementation_and_pins_the_real_contract_lineage()
    {
        var identity = QueryImplementationProvenance.Read();
        Check.Equal("internal-v2", identity.Manifest.Implementation, "aucune DLL historique prétendue chargée");
        Check.False(identity.Manifest.RuntimeDownload || identity.Manifest.UpstreamAssemblyLoaded, "aucun téléchargement ni assemblage commun à l’exécution");
        Check.Equal(typeof(QueryEngine).Assembly.ManifestModule.ModuleVersionId, identity.ModuleId, "moteur réellement chargé");
        Check.Equal(typeof(QueryEngine).Assembly.GetName().Version!.ToString(), identity.Version, "version du produit réel, pas une version amont inventée");
        Check.True(RuntimeLibraryPlan.RequiredFiles.Contains("Domenia.Core.dll"), "le même assemblage est exigé par l’intégrité du pack");
        Check.False(typeof(QueryEngine).Assembly.GetReferencedAssemblies().Any(a => a.Name?.StartsWith("M4D.Admin.Common", StringComparison.Ordinal) == true), "pas de dépendance historique dissimulée");
        Check.Equal(QueryEngine.Compile(QueryRecipe.Empty(QueryTarget.Computer, "lineage")).Fingerprint,
            QueryEngine.Compile(QueryRecipeJson.Read(QueryRecipeJson.Write(QueryRecipe.Empty(QueryTarget.Computer, "lineage")))).Fingerprint,
            "le codec déclaré est réellement utilisé par le moteur");
    }

    [Test]
    public static void Source_pins_match_the_checked_in_engine_and_codec_with_explicit_LF_normalization()
    {
        var roots = new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory };
        string? root = null;
        foreach (var start in roots)
            for (DirectoryInfo? current = new(start); current is not null; current = current.Parent)
            {
                var candidate = Path.Combine(current.FullName, "v2");
                if (Directory.Exists(Path.Combine(candidate, "src", "Domenia.Core"))) { root = candidate; break; }
                if (Directory.Exists(Path.Combine(current.FullName, "src", "Domenia.Core"))) { root = current.FullName; break; }
            }
        if (root is null) throw new TestFailureException("Sources de qualification introuvables pour vérifier les empreintes du manifeste.");
        var identity = QueryImplementationProvenance.Read();
        Check.Equal("utf8-lf", identity.Manifest.SourceEncoding, "normalisation explicite identique sur Git et Windows");
        foreach (var pin in identity.Manifest.Sources)
        {
            var source = File.ReadAllText(Path.Combine(root, pin.Path.Replace('/', Path.DirectorySeparatorChar))).Replace("\r\n", "\n", StringComparison.Ordinal);
            Check.Equal(pin.Sha256, Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(source))), "source épinglé : " + pin.Path);
        }
        var actual = Directory.GetFiles(Path.Combine(root, "src", "Domenia.Core", "Screens", "Requetes"), "QueryEngine*.cs")
            .Concat(Directory.GetFiles(Path.Combine(root, "src", "Domenia.Core", "Screens", "Requetes"), "QueryRecipeJson*.cs"))
            .Select(p => Path.GetRelativePath(root, p).Replace('\\', '/')).ToHashSet(StringComparer.Ordinal);
        Check.True(actual.SetEquals(identity.Manifest.Sources.Select(p => p.Path)), "toutes les parties compilées du moteur et du codec sont déclarées");
    }
}
