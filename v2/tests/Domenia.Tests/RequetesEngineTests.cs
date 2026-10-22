using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Ldap;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Tests;

/// <summary>
/// Pure rules of the query workshop (« Atelier de requêtes »): RFC 4515 filters, three-valued evaluation, recipes and their
/// Domenia 1 compatible JSON, recipe ↔ LDAP translation, closed WQL grammar, delivered templates. No bridge, no directory.
/// </summary>
internal static class RequetesEngineTests
{
    /// <summary>Hand-made LDAP entry: present values, attributes known to be absent, attributes Domenia does not read.</summary>
    private sealed class Entry(string dn, Dictionary<string, string[]> values) : ILdapEntry
    {
        public string DistinguishedName => dn;

        public LdapPresence Get(LdapAttribute attribute, out IReadOnlyList<string> found)
        {
            if (values.TryGetValue(attribute.Name, out var list))
            {
                found = list;
                return LdapPresence.Present;
            }
            found = [];
            return attribute.ReadByDomenia ? LdapPresence.Absent : LdapPresence.NotRead;
        }
    }

    private static Entry Computer(params (string Name, string Value)[] values) =>
        new("CN=PC-1,OU=Postes,DC=test,DC=local", values.GroupBy(v => v.Name, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.Select(x => x.Value).ToArray(), StringComparer.OrdinalIgnoreCase));

    private static MatchState Eval(string filter, Entry entry) => LdapEvaluator.Evaluate(LdapFilterText.Parse(filter), entry);

    private static QueryRecipe Recipe(params QueryClause[] clauses) => QueryRecipe.Empty(QueryTarget.Computer) with { Name = "Essai", Clauses = [.. clauses] };

    private static QueryClause C(string field, QueryOperator op, QueryValue value) => new(field, op, value);

    private static QueryRecord Record(string name, bool? active, decimal? disk, DateTimeOffset? adAt = null, DateTimeOffset? inventoryAt = null)
    {
        var record = new QueryRecord(Fixtures.IdOf(name).ToString("D"), QueryTarget.Computer, name, "CN=" + name + ",OU=Postes,DC=test,DC=local", Computer(("cn", name)));
        if (active is bool a)
        {
            record.Values["active"] = a;
        }
        if (disk is decimal d)
        {
            record.Values["diskFreePercent"] = d;
        }
        if (adAt is DateTimeOffset at)
        {
            record.Clocks["ad"] = at;
        }
        if (inventoryAt is DateTimeOffset it)
        {
            record.Clocks["inventory"] = it;
        }
        return record;
    }

    private static readonly QueryEvaluationContext Now = new(null, TestClock.Reference);

    // ---------- RFC 4515 filters ----------

    [Test]
    public static void Filters_are_parsed_and_written_back_identically()
    {
        const string text = "(&(objectCategory=computer)(operatingSystem=*Windows 11*)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))";
        var filter = LdapFilterText.Parse(text);
        Check.Equal(LdapFilterKind.And, filter.Kind, "racine ET");
        Check.Equal(3, filter.Children.Length, "trois enfants");
        Check.Equal(text, LdapFilterText.Format(filter), "écriture canonique identique");
        Check.Contains("\n", LdapFilterText.Pretty(filter), "forme indentée sur plusieurs lignes");
    }

    [Test]
    public static void A_malformed_filter_says_where_it_stops()
    {
        var error = Check.Throws<LdapFilterException>(() => LdapFilterText.Parse("(&(cn=PC-1)(description=a"), "parenthèse manquante");
        Check.True(error.Position > 0, "position de l’erreur donnée : " + error.Position);
        Check.Throws<LdapFilterException>(() => LdapFilterText.Parse("cn=PC-1)"), "filtre sans parenthèse ouvrante");
        Check.Throws<LdapFilterException>(() => LdapFilterText.Parse("(cn=\\4)"), "échappement incomplet");
    }

    [Test]
    public static void Assertion_values_are_escaped_as_RFC_4515_says()
    {
        Check.Equal("a\\2ab\\28c\\29\\5c", LdapFilterText.Escape("a*b(c)\\"), "caractères réservés échappés");
        var filter = LdapFilterText.Parse("(description=" + LdapFilterText.Escape("50 % (kiosque)*") + ")");
        Check.Equal(MatchState.Match, LdapEvaluator.Evaluate(filter, Computer(("description", "50 % (kiosque)*"))), "valeur littérale retrouvée");
    }

    // ---------- Three-valued evaluation ----------

    [Test]
    public static void Absent_attributes_are_false_and_unread_ones_stay_undefined()
    {
        var entry = Computer(("operatingSystem", "Windows 11 Entreprise"), ("userAccountControl", "4096"));
        Check.Equal(MatchState.Match, Eval("(operatingSystem=*windows 11*)", entry), "sous-chaîne insensible à la casse");
        Check.Equal(MatchState.NoMatch, Eval("(description=*)", entry), "attribut lu et absent : FAUX");
        Check.Equal(MatchState.Unknown, Eval("(info=*)", entry), "attribut non lu par Domenia : indéfini");
        Check.Equal(MatchState.Unknown, Eval("(!(info=*))", entry), "NON d’un indéfini reste indéfini");
        Check.Equal(MatchState.Unknown, Eval("(attributInconnu=1)", entry), "attribut hors schéma : indéfini");
        Check.Equal(MatchState.Match, Eval("(|(info=*)(operatingSystem=*))", entry), "OU : un VRAI suffit");
        Check.Equal(MatchState.NoMatch, Eval("(&(info=*)(description=*))", entry), "ET : un FAUX suffit");
        Check.Equal(MatchState.Unknown, Eval("(&(info=*)(operatingSystem=*))", entry), "ET : indéfini et VRAI");
    }

    [Test]
    public static void Bitwise_rules_read_the_account_flags()
    {
        var disabled = Computer(("userAccountControl", "4098"));
        var enabled = Computer(("userAccountControl", "4096"));
        Check.Equal(MatchState.Match, Eval("(userAccountControl:1.2.840.113556.1.4.803:=2)", disabled), "ET binaire : désactivé");
        Check.Equal(MatchState.NoMatch, Eval("(userAccountControl:1.2.840.113556.1.4.803:=2)", enabled), "ET binaire : actif");
        Check.Equal(MatchState.Match, Eval("(userAccountControl:1.2.840.113556.1.4.804:=6)", disabled), "OU binaire");
        Check.Equal(MatchState.Unknown, Eval("(userAccountControl:1.2.3.4:=2)", disabled), "règle inconnue : indéfini");
        Check.Equal(MatchState.Unknown, Eval("(userAccountControl>=douze)", disabled), "valeur d’assertion invalide : indéfini");
    }

    // ---------- Recipes and their JSON ----------

    [Test]
    public static void Domenia_1_recipes_are_read_and_written_back_compatibly()
    {
        const string d1 = """{"Format":"Domenia.Query/1","Id":"abc","Name":"Actifs","Junction":"All","Clauses":[{"Field":"active","Operator":"Equal","Value":true}],"GroupBy":""}""";
        var recipe = QueryRecipeJson.Read(d1);
        Check.Equal(QueryTarget.Computer, recipe.Target, "cible par défaut : postes");
        Check.Equal(1, recipe.Clauses.Length, "une condition");
        Check.Null(recipe.GroupBy, "répartition vide lue comme absente");
        var written = QueryRecipeJson.Write(recipe);
        Check.Contains("\"Clauses\"", written, "écriture en PascalCase");
        Check.False(written.Contains("\"Target\"", StringComparison.Ordinal), "cible omise pour les postes (lisible par Domenia 1)");
        var camel = QueryRecipeJson.Read("""{"format":"Domenia.Query/1","id":"abc","name":"Actifs","junction":"all","clauses":[{"field":"active","operator":"equal","value":true}]}""");
        Check.Equal(QueryRecipeJson.Fingerprint(recipe), QueryRecipeJson.Fingerprint(camel), "même empreinte quelle que soit la casse");
    }

    [Test]
    public static void Unknown_properties_and_newer_formats_are_refused()
    {
        Check.Throws<QueryDefinitionException>(() => QueryRecipeJson.Read("""{"Format":"Domenia.Query/1","Name":"x","Script":"rm"}"""), "propriété inconnue");
        Check.Throws<QueryDefinitionException>(() => QueryRecipeJson.Read("""{"Format":"Domenia.Query/9","Name":"x"}"""), "format plus récent");
        Check.Throws<QueryDefinitionException>(() => QueryRecipeJson.Read("[]"), "pas un objet");
        Check.Throws<QueryDefinitionException>(() => QueryRecipeJson.Read("{"), "JSON illisible");
    }

    // ---------- Engine ----------

    [Test]
    public static void A_missing_measure_never_decides_a_verdict()
    {
        var compiled = QueryEngine.Compile(Recipe(C("active", QueryOperator.Equal, QueryValue.FromBoolean(true)), C("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(10))));
        Check.Equal(MatchState.Match, compiled.Evaluate(Record("A", true, 5), Now), "actif et 5 % libres");
        Check.Equal(MatchState.Unknown, compiled.Evaluate(Record("B", true, null), Now), "mesure absente : inconnu, jamais faux");
        Check.Equal(MatchState.NoMatch, compiled.Evaluate(Record("C", false, null), Now), "un critère faux suffit en ET");
        Check.Equal(MatchState.NoMatch, compiled.Evaluate(Record("D", true, 40), Now), "40 % libres");
        var any = QueryEngine.Compile(Recipe(C("active", QueryOperator.Equal, QueryValue.FromBoolean(false)), C("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(10))) with { Junction = QueryJunction.Any });
        Check.Equal(MatchState.Unknown, any.Evaluate(Record("E", true, null), Now), "OU : faux et inconnu restent inconnus");
        Check.Equal(MatchState.Match, any.Evaluate(Record("F", false, null), Now), "OU : un vrai suffit");
    }

    [Test]
    public static void Is_missing_is_decisive_and_coherence_turns_far_apart_dates_unknown()
    {
        var missing = QueryEngine.Compile(Recipe(C("diskFreePercent", QueryOperator.IsMissing, QueryValue.None)));
        Check.Equal(MatchState.Match, missing.Evaluate(Record("A", true, null), Now), "valeur absente");
        Check.Equal(MatchState.NoMatch, missing.Evaluate(Record("B", true, 12), Now), "valeur présente");
        var window = QueryEngine.Compile(Recipe(C("active", QueryOperator.Equal, QueryValue.FromBoolean(true)), C("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(10))) with { CoherenceHours = 24 });
        var now = TestClock.Reference;
        Check.Equal(MatchState.Match, window.Evaluate(Record("C", true, 5, now, now.AddHours(-3)), Now), "dates à trois heures d’écart");
        Check.Equal(MatchState.Unknown, window.Evaluate(Record("D", true, 5, now, now.AddHours(-48)), Now), "dates à 48 heures d’écart");
        Check.Equal(MatchState.Unknown, window.Evaluate(Record("E", true, 5, now, null), Now), "date d’inventaire absente");
    }

    [Test]
    public static void Validation_reports_unknown_informations_and_bad_values_in_French()
    {
        var unknown = QueryEngine.Validate(Recipe(C("informationInconnue", QueryOperator.Equal, QueryValue.FromText("x"))));
        Check.False(unknown.Valid, "information inconnue refusée");
        Check.True(unknown.Errors.Length > 0, "erreur expliquée");
        var text = QueryEngine.Validate(Recipe(C("diskFreePercent", QueryOperator.Less, QueryValue.FromText("beaucoup"))));
        Check.False(text.Valid, "texte sur une information numérique");
        var ok = QueryEngine.Validate(Recipe(C("ramGB", QueryOperator.Less, QueryValue.FromText("8192 Mo"))));
        Check.True(ok.Valid, "unités converties : " + string.Join(" ; ", ok.Errors));
        Check.Equal(8m, ok.Compiled!.Normalized.Clauses[0].Value.Number, "8192 Mo = 8 Go");
    }

    [Test]
    public static void Parameters_are_resolved_and_change_the_fingerprint()
    {
        var template = QueryTemplates.Find("template.param.diskfree") ?? throw new TestFailureException("modèle paramétré absent");
        var compiled = QueryEngine.Compile(template.Recipe);
        Check.Equal(10m, compiled.Resolved.Clauses[0].Value.Number, "valeur par défaut 10 %");
        var changed = QueryEngine.Compile(template.Recipe with { ParameterValues = ImmutableSortedDictionary.CreateRange(StringComparer.Ordinal, [new KeyValuePair<string, QueryValue>("Seuil", QueryValue.FromNumber(20))]) });
        Check.Equal(20m, changed.Resolved.Clauses[0].Value.Number, "valeur choisie 20 %");
        Check.True(compiled.Fingerprint != changed.Fingerprint, "l’empreinte suit la valeur effective");
        Check.Equal(MatchState.Match, changed.Evaluate(Record("A", true, 15), Now), "15 % sous le seuil de 20 %");
    }

    // ---------- Recipe ↔ LDAP ----------

    [Test]
    public static void Directory_conditions_translate_exactly_and_local_ones_stay_residual()
    {
        var exact = QueryLdap.Translate(QueryEngine.Compile(Recipe(C("os", QueryOperator.Contains, QueryValue.FromText("Windows 11")))).Resolved, TestClock.Reference);
        Check.True(exact.Exact, "condition AD seule : traduction exacte");
        Check.Contains("operatingSystem=*Windows 11*", exact.Filter, "sous-chaîne LDAP");
        Check.Contains("objectCategory=computer", exact.Filter, "classe de la cible");
        var mixed = QueryLdap.Translate(QueryEngine.Compile(Recipe(C("os", QueryOperator.Contains, QueryValue.FromText("Windows 11")), C("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(10)))).Resolved, TestClock.Reference);
        Check.False(mixed.Exact, "condition relevée : traduction partielle");
        Check.True(mixed.Residual.Length == 1, "une condition évaluée localement");
        Check.Contains("operatingSystem=*Windows 11*", mixed.PreFilter, "le préfiltre garde la partie annuaire");
    }

    [Test]
    public static void A_typed_filter_becomes_conditions_or_a_located_error()
    {
        var reading = QueryLdap.Read("(&(objectCategory=person)(objectClass=user)(department=Comptabilité))", QueryRecipe.Empty(QueryTarget.Computer));
        Check.True(reading.Valid, "filtre accepté : " + reading.Error);
        Check.Equal(QueryTarget.User, reading.Recipe!.Target, "cible déduite de objectCategory et objectClass");
        var bad = QueryLdap.Read("(&(department=Comptabilité)", QueryRecipe.Empty(QueryTarget.User));
        Check.False(bad.Valid, "filtre incomplet refusé");
        Check.True(bad.Position is > 0, "position donnée");
    }

    // ---------- WQL ----------

    [Test]
    public static void The_WQL_grammar_is_closed_and_secrets_are_refused()
    {
        var select = WqlRules.Parse("SELECT Name, FreeSpace FROM Win32_LogicalDisk WHERE DriveType = 3 AND Name LIKE 'C%'");
        Check.Equal("Win32_LogicalDisk", select.ClassName, "classe lue");
        Check.Throws<QueryDefinitionException>(() => WqlRules.Parse("SELECT * FROM Win32_Process"), "SELECT * refusé");
        Check.Throws<QueryDefinitionException>(() => WqlRules.Parse("SELECT Name FROM Win32_Process; DELETE"), "suite de commande refusée");
        Check.Throws<QueryDefinitionException>(() => WqlRules.Parse("ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='C:'}"), "requête hors SELECT refusée");
        Check.True(WqlRules.IsSecret("Password"), "propriété de secret reconnue");
        Check.Throws<QueryDefinitionException>(() => WqlRules.CheckNamespace("\\\\serveur\\root\\cimv2"), "espace de noms distant refusé");
    }

    [Test]
    public static void Only_a_tested_SELECT_becomes_a_read_definition_with_a_stable_key()
    {
        var first = WqlRules.NewReadDefinition("root\\cimv2", "SELECT Name, State FROM Win32_Service WHERE StartMode = 'Auto'", 100);
        var second = WqlRules.NewReadDefinition("ROOT\\CIMV2", "select  Name ,State from Win32_Service where StartMode = 'Auto'", 100);
        Check.Equal(first.RequestKey, second.RequestKey, "même clé pour la même requête canonique");
        var plan = WqlRules.Plan("root\\cimv2", "SELECT Name FROM Win32_Service", 100, null, null, null, null, null);
        Check.True(plan.Valid, "SELECT valide");
        Check.False(plan.Ready, "jamais exécuté sur un poste : pas prêt pour une recette");
    }

    // ---------- Templates ----------

    [Test]
    public static void Every_delivered_template_compiles_and_has_a_unique_identifier()
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var template in QueryTemplates.All)
        {
            Check.True(ids.Add(template.Recipe.Id), "identifiant unique : " + template.Recipe.Id);
            Check.True(template.Recipe.Id.StartsWith(QueryTemplates.Prefix, StringComparison.Ordinal), "préfixe des modèles : " + template.Recipe.Id);
            var validation = QueryEngine.Validate(template.Recipe);
            Check.True(validation.Valid, "modèle valide : " + template.Recipe.Id + " " + string.Join(" ; ", validation.Errors));
            var json = QueryRecipeJson.Write(validation.Compiled!.Normalized);
            Check.Equal(validation.Compiled.Fingerprint, QueryEngine.Compile(QueryRecipeJson.Read(json)).Fingerprint, "relu à l’identique : " + template.Recipe.Id);
        }
        Check.True(ids.Count > 150, "plus de modèles que Domenia 1 : " + ids.Count);
        Check.True(QueryTemplates.All.Any(t => t.Recipe.Target == QueryTarget.User) && QueryTemplates.All.Any(t => t.Recipe.Target == QueryTarget.Group), "modèles comptes et groupes");
    }

    [Test]
    public static void The_probe_catalog_keeps_the_111_probes_of_Domenia_1()
    {
        Check.Equal(111, QueryProbeCatalog.All.Length, "sondes");
        Check.True(QueryProbeCatalog.All.Select(p => p.Id).Distinct(StringComparer.Ordinal).Count() == 111, "identifiants uniques");
        Check.NotNull(QueryProbeCatalog.Find("soft.servicedetails"), "liste détaillée des services");
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(QueryCatalog.Fields(QueryTarget.Computer).Select(f => f.Id)));
        Check.True(document.RootElement.GetArrayLength() >= 140, "informations des postes : " + document.RootElement.GetArrayLength());
    }
}
