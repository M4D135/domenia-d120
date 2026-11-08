using System.Text.Json;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>
/// The live analysis of the bar (page, text.js) and the plan of the engine (SearchText.Plan) read the same vectors
/// (tests/vectors/search-text.json): validity and kind must agree, so the page never explains what the engine does not do.
/// </summary>
internal static class SearchTextVectorsTests
{
    private static string VectorsPath()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "tests", "vectors", "search-text.json");
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }
        throw new FileNotFoundException("tests/vectors/search-text.json introuvable au-dessus du dossier des tests.");
    }

    [Test]
    public static async Task The_engine_plan_agrees_with_the_vectors_of_the_page()
    {
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(VectorsPath()));
        var vectors = document.RootElement.GetProperty("vectors").EnumerateArray().ToList();
        Check.True(vectors.Count >= 20, "vecteurs partagés");
        foreach (var vector in vectors)
        {
            var text = vector.GetProperty("text").GetString()!;
            var match = vector.GetProperty("match").GetString() == "contains" ? SearchMatchMode.Contains : SearchMatchMode.Prefix;
            var plan = SearchText.Plan(text, SearchTypeFilter.All, match);
            var kind = !plan.Valid ? "invalid" : plan.Kind switch
            {
                SearchPlanKind.Default => "default",
                SearchPlanKind.Syntax => "syntax",
                SearchPlanKind.Address => "address",
                SearchPlanKind.Identifier => "identifier",
                SearchPlanKind.Contains => "contains",
                _ => plan.Kind.ToString(),
            };
            Check.Equal(vector.GetProperty("valid").GetBoolean(), plan.Valid, "validité de " + FrenchText.Quote(text));
            Check.Equal(vector.GetProperty("kind").GetString(), kind, "genre de " + FrenchText.Quote(text));
        }
    }

    [Test]
    public static void A_simple_search_is_one_plain_word()
    {
        Check.True(SearchText.IsSimple(SearchText.Plan("martin", SearchTypeFilter.All, SearchMatchMode.Prefix)), "un mot");
        Check.False(SearchText.IsSimple(SearchText.Plan("camille ber", SearchTypeFilter.All, SearchMatchMode.Prefix)), "deux mots");
        Check.False(SearchText.IsSimple(SearchText.Plan("*bernard", SearchTypeFilter.All, SearchMatchMode.Prefix)), "joker");
        Check.False(SearchText.IsSimple(SearchText.Plan("utilisateur: martin", SearchTypeFilter.All, SearchMatchMode.Prefix)), "jeton");
        Check.False(SearchText.IsSimple(SearchText.Plan("10.10.1.20", SearchTypeFilter.All, SearchMatchMode.Prefix)), "adresse");
    }
}
