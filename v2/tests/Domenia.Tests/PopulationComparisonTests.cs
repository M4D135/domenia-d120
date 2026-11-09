using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using QueryProbeReading = Domenia.Core.Queries.ProbeReading;

namespace Domenia.Tests;

internal static class PopulationComparisonTests
{
    private static FleetFigures Figures() => new(100, 80, 20, 0, 30, 0, 0, 0, null,
        100, 0, 80, 100, 100, "population-a", "assessed-a", "coverage-a", "policy-a", 1);

    private static FleetSnapshot Snapshot(string label, DateTimeOffset at, FleetFigures figures) =>
        new(label, "daily", label, DateOnly.FromDateTime(at.UtcDateTime), at, figures);

    private static FleetComparison Compare(FleetFigures before, FleetFigures after) => FleetAnalysis.Compare(
        Snapshot("Avant", Fixtures.Now.AddDays(-1), before), Snapshot("Après", Fixtures.Now, after));

    [Test]
    public static void Missing_descriptions_on_either_or_both_sides_are_never_presumed_identical()
    {
        var known = Figures();
        foreach (var (missing, factor) in new[]
        {
            (known with { PopulationHash = "" }, "Périmètre"),
            (known with { AssessedHash = "" }, "Couverture"),
            (known with { CoverageHash = "" }, "Couverture"),
            (known with { PolicyHash = "" }, "Règles"),
        })
        {
            foreach (var (before, after) in new[] { (missing, known), (known, missing), (missing, missing) })
            {
                var result = Compare(before, after);
                Check.False(result.Comparable, factor + " absent : aucune identité présumée");
                Check.Equal("Limitée", result.Category, "compteurs identiques sans description suffisante");
                Check.Equal("Inconnu", result.Factors.Single(f => f.Factor == factor).Status, "dimension manquante nommée");
                Check.Contains("Ne pas lire la variation du score", result.Summary, "limite visible");
            }
        }
        var empty = known with { PopulationHash = "", CoverageHash = "", PolicyHash = "" };
        Check.Equal(6, Compare(empty, empty).Limits.Length, "chaque empreinte absente des deux relevés est signalée");
    }

    [Test]
    public static void Equal_counts_with_different_members_are_a_population_change()
    {
        var before = Figures();
        var result = Compare(before, before with { PopulationHash = "population-b" });
        Check.False(result.Comparable, "même nombre ne signifie pas mêmes postes");
        Check.Equal("Périmètre", result.Category, "cause nommée");
        var factor = result.Factors.Single(f => f.Factor == "Périmètre");
        Check.Equal("Modifié", factor.Status, "composition différente");
        Check.Contains("même nombre, composition différente", factor.Text, "explication visible");
        Check.Equal("0", result.Rows.Single(r => r.Measure == "Comptes activés").Delta, "compteur effectivement égal");
    }

    [Test]
    public static void Coverage_rules_and_mixed_changes_are_named_separately()
    {
        var before = Figures();
        foreach (var (after, category) in new[]
        {
            (before with { AssessedHash = "assessed-b" }, "Couverture"),
            (before with { CoverageHash = "coverage-b" }, "Couverture"),
            (before with { PolicyHash = "policy-b" }, "Règles"),
            (before with { PopulationHash = "population-b", CoverageHash = "coverage-b" }, "Mixte"),
        })
        {
            var result = Compare(before, after);
            Check.False(result.Comparable, "variation non attribuée au seul état observé");
            Check.Equal(category, result.Category, "cause distincte");
        }
        var mixed = Compare(before, before with { PopulationHash = "population-b", CoverageHash = "coverage-b" });
        Check.Contains("périmètre", mixed.Summary, "première cause");
        Check.Contains("couverture", mixed.Summary, "seconde cause");
        var incompatible = Compare(before, before with { FormatVersion = 2 });
        Check.False(incompatible.Comparable, "formats de règles incompatibles");
        Check.Equal("Inconnu", incompatible.Factors.Single(f => f.Factor == "Règles").Status, "règles non présumées identiques");
    }

    [Test]
    public static void Chronological_order_and_observed_changes_keep_the_correct_labels_and_deltas()
    {
        var before = Figures();
        var after = before with { Healthy = 85, Problems = 15, Score = 85 };
        var stable = Compare(before, before);
        Check.True(stable.Comparable, "descriptions complètes identiques");
        Check.Equal("Stable", stable.Category, "état inchangé");
        var result = FleetAnalysis.Compare(Snapshot("Après", Fixtures.Now, after),
            Snapshot("Avant", Fixtures.Now.AddDays(-1), before));
        Check.True(result.Swapped, "ordre corrigé");
        Check.True(result.Comparable, "seul état observé changé");
        Check.Equal("Réel", result.Category, "variation à périmètre, couverture et règles constants");
        Check.Equal("Avant", result.BeforeLabel, "ancien relevé");
        Check.Equal("Après", result.AfterLabel, "nouveau relevé");
        Check.Equal("+5", result.Rows.Single(r => r.Measure == "Score").Delta, "sens chronologique");
    }

    [Test]
    public static void A_score_becoming_available_or_missing_is_not_a_stable_or_improved_fleet()
    {
        var measured = Figures();
        var partial = measured with { Score = null };
        foreach (var (before, after) in new[] { (partial, measured), (measured, partial) })
        {
            var result = Compare(before, after);
            Check.False(result.Comparable, "score absent : aucune conclusion sur le gain ou la perte");
            Check.Equal("Limitée", result.Category, "disponibilité différente du score");
            Check.Equal("Inconnu", result.Factors.Single(f => f.Factor == "Couverture").Status, "couverture limitée");
            Check.Equal("Non comparable", result.Rows.Single(r => r.Measure == "Score").Delta, "score absent jamais zéro");
            Check.True(result.Limits.Any(l => l.Contains("score", StringComparison.Ordinal)), "raison explicite");
        }
    }

    [Test]
    public static void Different_numeric_scores_are_never_described_as_unchanged()
    {
        var before = Figures();
        var result = Compare(before, before with { Score = 81 });
        Check.Equal("Modifié", result.Factors.Single(f => f.Factor == "État observé").Status, "score différent nommé");
        Check.Equal("Réel", result.Category, "pas de résumé stable contradictoire");
    }

    [Test]
    public static void Query_population_describes_domain_scope_depth_types_criteria_and_snapshot()
    {
        var directory = Fixtures.Snapshot(computers: [Fixtures.Computer("POPULATION-1")]);
        var dataset = new QueryDataset(directory, new(null, []), ImmutableDictionary<Guid, ImmutableArray<QueryProbeReading>>.Empty,
            ImmutableDictionary<Guid, ConsoleReading>.Empty, ImmutableDictionary<Guid, char>.Empty,
            ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>>.Empty, 42, "Instantané local de test", true);
        var workshop = new QueryWorkshop(new MemoryPreferenceStore(), TestClock.Fixed());
        foreach (var scope in new ScopeSelection?[] { null, new(Fixtures.Postes, "Postes", false), new(Fixtures.Postes, "Postes", true) })
        {
            foreach (var target in new[] { QueryTarget.Computer, QueryTarget.User })
            {
                var query = QueryEngine.Compile(QueryRecipe.Empty(target) with { Name = "Population décrite" });
                var records = QueryRecordBuilder.Build(dataset, target, scope, Fixtures.Now);
                var evaluation = workshop.Evaluate(query, records, dataset, scope, Fixtures.Now, "example.local");
                var description = evaluation.Description;
                Check.Equal("example.local", description.Domain, "domaine");
                Check.Equal(scope?.Dn ?? directory.Domain.RootDn, description.ScopeDn, "périmètre");
                Check.Equal(scope?.Label ?? "example.local", description.ScopeLabel, "libellé de périmètre");
                Check.Equal(scope?.Subtree ?? true, description.Subtree, "profondeur");
                Check.Equal(target, description.Target, "type d’objet");
                Check.Equal(target == QueryTarget.Computer ? "Comptes ordinateurs" : "Comptes utilisateurs", description.TargetLabel, "type lisible");
                Check.Equal(query.Recipe.Name, description.RecipeName, "critères nommés");
                Check.Equal(query.Fingerprint, description.Fingerprint, "critères figés par empreinte");
                Check.Equal(42L, description.DatasetVersion, "version de l’instantané");
                Check.Equal(Fixtures.Now, description.EvaluatedAt, "date de calcul");
                Check.Equal(dataset.SourceLabel, description.Source, "source");
                Check.Contains(query.Fingerprint[..12], description.Text, "empreinte visible");
                Check.Contains("UTC", description.Text, "date située");
                Check.Contains(scope is null ? "tout le domaine example.local" : scope.Subtree ? "et ses sous-OU" : "sans sous-OU", description.Text, "portée explicite");
                Check.Equal(description, workshop.RequireEvaluation(evaluation.Id).Description, "pages et exports retrouvent la même description figée");
            }
        }
    }
}
