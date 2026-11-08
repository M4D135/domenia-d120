using Domenia.Core.Queries;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class QueryTemplateLibraryTests
{
    [Test]
    public static void Every_delivered_recipe_has_a_real_source_cost_and_valid_roundtrip()
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var template in QueryTemplates.All)
        {
            Check.True(ids.Add(template.Recipe.Id), "identifiant unique : " + template.Recipe.Id);
            var compiled = QueryEngine.Compile(template.Recipe);
            Check.Equal(compiled.Fingerprint, QueryEngine.Compile(QueryRecipeJson.Read(QueryRecipeJson.Write(compiled.Normalized))).Fingerprint, "recette sauvegardée identique : " + template.Recipe.Id);
            Check.Contains("Sources :", template.Description, "provenance annoncée : " + template.Recipe.Id);
            Check.Contains("Collecte :", template.Description, "mode de collecte annoncé : " + template.Recipe.Id);
            Check.Contains("Coût :", template.Description, "coût annoncé : " + template.Recipe.Id);
            Check.Contains("inconnues", template.Description, "absence de données explicitée : " + template.Recipe.Id);
            foreach (var field in compiled.RequestedFields)
            { Check.NotNull(compiled.FindField(field), "aucun champ inventé : " + field); }
        }
        Check.True(ids.Count >= 500, "bibliothèque de plusieurs centaines de recettes exploitables");
        Check.True(QueryTemplates.All.Where(t => t.Recipe.Id.StartsWith("template.ops.", StringComparison.Ordinal)).Count() >= 40, "questions opérationnelles ajoutées sans produit cartésien de seuils");
    }

    [Test]
    public static void Operational_models_use_admitted_projections_and_keep_instance_grouping_explicit()
    {
        var checkedProbes = new HashSet<string>(StringComparer.Ordinal);
        foreach (var template in QueryTemplates.All.Where(t => t.Recipe.Id.StartsWith("template.ops.", StringComparison.Ordinal)))
        {
            var compiled = QueryEngine.Compile(template.Recipe);
            foreach (var field in compiled.RequestedFields.Select(compiled.FindField).OfType<QueryField>())
            {
                if (field.ProbeId is not { } id || !checkedProbes.Add(id)) { continue; }
                var probe = QueryProbeCatalog.Find(id)!;
                Check.NotNull(probe, "sonde livrée existante : " + id);
                var select = QueryPersonalProbes.Select(probe, TestClock.Reference);
                Check.Equal(select.CanonicalQuery, WmiWorkstationReader.CheckWorkshopSelect(probe.Namespace, select, probe.Mode == "First" ? 1 : 500).CanonicalQuery,
                    "projection admise par le lecteur réel sans contact : " + id);
            }
            if (compiled.Resolved.GroupBy is { } group)
            { Check.True(compiled.FindField(group)!.Source != QuerySource.Instance, "aucune répartition sur un premier volume arbitraire"); }
        }
        Check.True(checkedProbes.Contains("sec.bitlockermethodc") && checkedProbes.Contains("sec.bitlockervolumes"), "les deux parcours BitLocker ont des lectures réelles distinctes");
        Check.True(checkedProbes.Contains("soft.installed") && checkedProbes.Contains("soft.servicedetails"), "applications et services réellement raccordés");
    }

    [Test]
    public static void BitLocker_ready_distribution_keeps_C_scope_and_service_parameters_are_correlated()
    {
        var distribution = QueryTemplates.Find("template.ops.bitlocker.methods.c")!;
        Check.NotNull(distribution, "modèle prêt à créer un widget de répartition");
        Check.Equal("probe:sec.bitlockermethodc", distribution.Recipe.GroupBy, "une valeur explicitement ciblée par poste");
        Check.Equal(0, distribution.Recipe.Clauses.Length, "aucun filtre Non chiffré implicite");
        var service = QueryEngine.Compile(QueryTemplates.Find("template.ops.services.named.state")!.Recipe);
        var expression = service.Resolved.Expression!;
        Check.Equal(QueryNodeKind.Collection, expression.Kind, "un seul contexte service");
        Check.Equal("probe:soft.servicedetails", expression.CollectionField, "collection de services exacte");
        Check.Equal(2, expression.Children.Single().Children.Length, "nom et état dans la même instance");
        Check.Equal(2, service.EffectiveParameters.Count, "paramètres guidés réellement résolus");
    }
}
