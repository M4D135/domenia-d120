using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class QueryFormatWordingTests
{
    [Test]
    public static void Ordered_comparisons_on_a_coded_choice_quote_the_choice()
    {
        var bucket = new QueryClause("logonBucket", QueryOperator.GreaterOrEqual, QueryValue.FromNumber(3));
        Check.Equal("Tranche de connexion AD est au moins « 90 à 179 jours »", QueryFormat.Clause(bucket, QueryTarget.User), "au moins dans la tranche");
        var upTo = bucket with { Operator = QueryOperator.LessOrEqual, Value = QueryValue.FromNumber(4) };
        Check.Equal("Tranche de connexion AD est au plus « 180 jours et plus »", QueryFormat.Clause(upTo, QueryTarget.User), "au plus dans la tranche");
        var equal = bucket with { Operator = QueryOperator.Equal };
        Check.Equal("Tranche de connexion AD est égal à 90 à 179 jours", QueryFormat.Clause(equal, QueryTarget.User), "égalité inchangée");
        var days = new QueryClause("logonDays", QueryOperator.GreaterOrEqual, QueryValue.FromNumber(90));
        Check.Equal("Jours depuis la connexion AD (approximatif) est supérieur ou égal à 90 j", QueryFormat.Clause(days, QueryTarget.User), "nombre sans tranche inchangé");
    }

    [Test]
    public static void Parameter_references_read_as_the_value_of_a_named_parameter()
    {
        Check.Equal("la valeur du paramètre « Seuil »", QueryFormat.Value(QueryValue.FromParameter("Seuil"), null), "article et guillemets");
    }

    [Test]
    public static void Observed_day_counts_are_truncated_but_typed_values_stay_exact()
    {
        var days = QueryCatalog.Find(QueryTarget.User, "logonDays")!;
        Check.Equal("3,3 j", QueryFormat.Raw(3.3817m, days), "une décimale sous 10 jours");
        Check.Equal("11 j", QueryFormat.Raw(11.8989m, days), "jours entiers écoulés au-delà, comme la grille");
        Check.Equal("89 j", QueryFormat.Raw(89.6m, days), "jamais arrondi au seuil supérieur");
        Check.Equal("0,1 j", QueryFormat.Raw(0.1476m, days), "fraction de jour lisible");
        Check.Equal("3,3817 j", QueryFormat.Value(QueryValue.FromNumber(3.3817m), days), "valeur saisie exacte");
    }

    [Test]
    public static void Canonical_select_reads_without_the_space_before_commas_outside_literals()
    {
        Check.Equal("SELECT DeviceID, FreeSpace FROM Win32_LogicalDisk", QueryFormat.Wql("SELECT DeviceID , FreeSpace FROM Win32_LogicalDisk"), "virgule collée");
        Check.Equal("SELECT Name, Caption FROM Win32_Service WHERE Caption LIKE '% ,%'", QueryFormat.Wql("SELECT Name , Caption FROM Win32_Service WHERE Caption LIKE '% ,%'"), "littéral intact");
    }
}
