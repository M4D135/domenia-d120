using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Domenia.Core.Queries.Ldap;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Core.Queries;

/// <summary>What one evaluation may need besides the record: the directory links (in-chain rule) and the instant.</summary>
public sealed record QueryEvaluationContext(ILdapChain? Chain, DateTimeOffset Now);

/// <summary>One line of « Pourquoi ce résultat ? »: condition, value, verdict, availability and date of the source.</summary>
public sealed record QueryExplanationRow(string Condition, int Depth, string Value, string Verdict, string VerdictKey, string State, DateTimeOffset? ObservedAt, string Section);

/// <summary>Typed form row of one parameter (Domenia 1 Get-DomeniaQueryParameterRows).</summary>
public sealed record QueryParameterRow(string Name, string Label, string Field, string FieldName, QueryFieldKind Kind, string Unit, QueryValue Value, string ValueLabel, string Hint,
    ImmutableArray<QueryChoice> Choices, decimal? Minimum, decimal? Maximum);

/// <summary>
/// Compiled recipe: parameters resolved, values typed, tree checked. Evaluates records with three-valued logic (Kleene):
/// AND is FALSE as soon as one part is FALSE, OR is TRUE as soon as one part is TRUE, NOT keeps Unknown.
/// </summary>
public sealed class CompiledQuery
{
    private readonly Predicate main;
    private readonly Predicate? refinements;
    private readonly FrozenSet<string>? identities;
    private readonly ImmutableArray<string> clocks;

    internal CompiledQuery(QueryRecipe recipe, QueryRecipe normalized, QueryRecipe resolved, ImmutableSortedDictionary<string, QueryValue> effective, Predicate main, Predicate? refinements,
        FrozenSet<string>? identities, ImmutableArray<string> requested, ImmutableArray<string> clocks)
    {
        Recipe = recipe;
        Normalized = normalized;
        Resolved = resolved;
        EffectiveParameters = effective;
        this.main = main;
        this.refinements = refinements;
        this.identities = identities;
        RequestedFields = requested;
        this.clocks = clocks;
        Fingerprint = QueryRecipeJson.Fingerprint(normalized, effective.Count > 0 ? effective : null);
    }

    /// <summary>The recipe as received.</summary>
    public QueryRecipe Recipe { get; }

    /// <summary>The recipe with typed values (numbers with units converted, Oui/Non read): the form to keep.</summary>
    public QueryRecipe Normalized { get; }

    /// <summary>The recipe with every parameter replaced by its value: the form evaluated.</summary>
    public QueryRecipe Resolved { get; }

    public ImmutableSortedDictionary<string, QueryValue> EffectiveParameters { get; }

    public QueryTarget Target => Recipe.Target;

    public string Fingerprint { get; }

    /// <summary>Informations the recipe reads (conditions, segment, tree, distribution, collections).</summary>
    public ImmutableArray<string> RequestedFields { get; }

    /// <summary>Distinct clocks of the requested informations.</summary>
    public ImmutableArray<string> Clocks => clocks;

    /// <summary>True when the record belongs to the population: frozen selection, probe segment, refinements (segment ET).</summary>
    public bool InPopulation(QueryRecord record, QueryEvaluationContext context)
    {
        ArgumentNullException.ThrowIfNull(record);
        if (identities is not null && !identities.Contains(record.Id))
        {
            return false;
        }
        if (Resolved.ProbeSelection is { } segment && !SegmentMatches(segment, record))
        {
            return false;
        }
        return refinements is null || refinements.Evaluate(record, context) == MatchState.Match;
    }

    /// <summary>Verdict of the record: conditions and tree, then the coherence window of the source dates.</summary>
    public MatchState Evaluate(QueryRecord record, QueryEvaluationContext context)
    {
        ArgumentNullException.ThrowIfNull(record);
        var verdict = main.Evaluate(record, context);
        return Resolved.CoherenceHours is decimal hours && !Coherent(record, hours, out _) ? MatchState.Unknown : verdict;
    }

    /// <summary>Dates of the record within the window; <paramref name="reason"/> says why not.</summary>
    public bool Coherent(QueryRecord record, decimal hours, out string reason)
    {
        ArgumentNullException.ThrowIfNull(record);
        DateTimeOffset? earliest = null;
        DateTimeOffset? latest = null;
        foreach (var clock in clocks)
        {
            if (!record.Clocks.TryGetValue(clock, out var at))
            {
                reason = "Une date source manque";
                return false;
            }
            earliest = earliest is null || at < earliest ? at : earliest;
            latest = latest is null || at > latest ? at : latest;
        }
        if (earliest is DateTimeOffset e && latest is DateTimeOffset l && (decimal)(l - e).TotalHours > hours)
        {
            reason = "Mesures prises à des périodes différentes";
            return false;
        }
        reason = "Dates compatibles";
        return true;
    }

    /// <summary>« Pourquoi ce résultat ? » (Domenia 1 Get-DomeniaQueryExplanation): every condition with its value and verdict.</summary>
    public ImmutableArray<QueryExplanationRow> Explain(QueryRecord record, QueryEvaluationContext context)
    {
        ArgumentNullException.ThrowIfNull(record);
        var rows = ImmutableArray.CreateBuilder<QueryExplanationRow>();
        var index = 0;
        foreach (var clause in Resolved.Clauses)
        {
            index++;
            rows.Add(ClauseRow(clause, index.ToString(CultureInfo.InvariantCulture) + ". ", 0, record, context, "condition"));
        }
        index = 0;
        foreach (var clause in Resolved.Refinements)
        {
            index++;
            rows.Add(ClauseRow(clause, "Segment ET · " + index.ToString(CultureInfo.InvariantCulture) + ". ", 0, record, context, "segment"));
        }
        if (Resolved.Expression is { } tree)
        {
            Explain(tree, 0, null, record, context, rows);
        }
        if (Resolved.ProbeSelection is { } segment)
        {
            var field = QueryCatalog.Find(Target, QueryCatalog.ProbePrefix + segment.Key);
            var inSegment = SegmentMatches(segment, record);
            rows.Add(new QueryExplanationRow("Segment de sonde · " + QueryAnalysis.SegmentLabel(segment, Target), 0,
                QueryFormat.Raw(record.Value(QueryCatalog.ProbePrefix + segment.Key), field), inSegment ? "Vrai" : "Faux", inSegment ? "match" : "noMatch",
                record.State(QueryCatalog.ProbePrefix + segment.Key), record.Clocks.TryGetValue("probe:" + segment.Key, out var at) ? at : null, "segment"));
        }
        if (Resolved.ObjectIds is { } selection)
        {
            var kept = identities?.Contains(record.Id) == true;
            rows.Add(new QueryExplanationRow("Sélection figée de " + FrenchText.Count(selection.Length, "GUID", "GUID"), 0, record.Id, kept ? "Vrai" : "Faux", kept ? "match" : "noMatch", "Calcul local", null, "segment"));
        }
        if (Resolved.CoherenceHours is decimal hours)
        {
            var ok = Coherent(record, hours, out var reason);
            rows.Add(new QueryExplanationRow("Écart des dates sources ≤ " + QueryFormat.Hours(hours), 0, reason, ok ? "Vrai" : "Inconnu", ok ? "match" : "unknown", "Cohérence temporelle", null, "coherence"));
        }
        return rows.ToImmutable();
    }

    private void Explain(QueryNode node, int depth, string? collection, QueryRecord record, QueryEvaluationContext context, ImmutableArray<QueryExplanationRow>.Builder rows)
    {
        if (node.Kind == QueryNodeKind.Clause && node.Clause is { } clause)
        {
            if (collection is null)
            {
                rows.Add(ClauseRow(clause, "", depth, record, context, "tree"));
            }
            return;
        }
        var predicate = QueryEngine.BuildNode(node, Target, Resolved.ReadDefinition, collection);
        var verdict = predicate.Evaluate(record, context);
        var label = QueryAnalysis.NodeLabel(node, Target, Resolved.ReadDefinition);
        string value;
        string state;
        DateTimeOffset? at = null;
        if (node.Kind == QueryNodeKind.Collection && node.CollectionField is { } field)
        {
            var probe = field.StartsWith(QueryCatalog.ProbePrefix, StringComparison.Ordinal) ? field[QueryCatalog.ProbePrefix.Length..] : field;
            if (record.Collections.TryGetValue(probe, out var instances))
            {
                value = FrenchText.Count(instances.Instances.Length, "instance mémorisée", "instances mémorisées");
                state = instances.Complete ? "Collecte complète" : "Collecte partielle";
            }
            else
            {
                value = "Non lu";
                state = record.Quality.GetValueOrDefault(field) ?? "Non lu";
            }
            at = record.Clocks.TryGetValue("probe:" + probe, out var date) ? date : null;
        }
        else
        {
            value = "Verdicts des sous-conditions";
            state = "Calcul local";
        }
        rows.Add(new QueryExplanationRow(label, depth, value, QueryTexts.Verdict(verdict), QueryTexts.VerdictKey(verdict), state, at, "tree"));
        if (node.Kind == QueryNodeKind.Collection)
        {
            return;
        }
        foreach (var child in node.Children)
        {
            Explain(child, depth + 1, collection, record, context, rows);
        }
    }

    private QueryExplanationRow ClauseRow(QueryClause clause, string prefix, int depth, QueryRecord record, QueryEvaluationContext context, string section)
    {
        var predicate = QueryEngine.BuildClause(clause, Target, Resolved.ReadDefinition, null);
        var verdict = predicate.Evaluate(record, context);
        var field = QueryCatalog.Find(Target, clause.Field, Resolved.ReadDefinition);
        string value;
        string state;
        DateTimeOffset? at = null;
        if (field is not null && field.Source == QuerySource.Ldap)
        {
            var reason = clause.Field == QueryCatalog.LdapFilterField ? null : LdapEvaluator.UndefinedReason(LdapFilter.Item(LdapFilterKind.Present, field.LdapAttribute ?? "", ""), record.Entry);
            var attribute = field.LdapAttribute is { } name ? LdapSchema.Find(name) : null;
            if (attribute is not null && record.Entry.Get(attribute, out var values) == LdapPresence.Present)
            {
                value = string.Join(" ; ", values.Take(5)) + (values.Count > 5 ? " ; …" : "");
                state = "Disponible";
            }
            else
            {
                value = reason ?? (attribute is null ? "Évalué sur la copie locale" : "Attribut absent");
                state = reason is null ? "Calcul local" : "Non lu";
            }
            at = record.Clocks.TryGetValue("ad", out var ad) ? ad : null;
        }
        else if (field is not null && QueryLdap.AbsentIsFalse(field) && !record.Values.ContainsKey(clause.Field))
        {
            value = "Attribut vide dans l’annuaire";
            state = "Disponible · attribut absent";
            at = record.Clocks.TryGetValue("ad", out var ad) ? ad : null;
        }
        else
        {
            value = record.Values.TryGetValue(clause.Field, out var raw) ? QueryFormat.Raw(raw, field) : record.State(clause.Field);
            state = record.State(clause.Field);
            if (field is not null && record.Clocks.TryGetValue(field.Clock, out var date))
            {
                at = date;
            }
        }
        return new QueryExplanationRow(prefix + QueryFormat.Clause(clause, Target, Resolved.ReadDefinition), depth, value, QueryTexts.Verdict(verdict), QueryTexts.VerdictKey(verdict), state, at, section);
    }

    private bool SegmentMatches(QueryProbeSegment segment, QueryRecord record)
    {
        var field = QueryCatalog.ProbePrefix + segment.Key;
        if (!record.Values.TryGetValue(field, out var value))
        {
            return false;
        }
        var probe = QueryProbeCatalog.Find(segment.Key);
        switch (segment.Mode)
        {
            case "Equal":
                if (probe?.Numeric == true)
                {
                    return value is decimal d && QueryProbeCatalog.Number(segment.Value) is decimal expected && d == expected;
                }
                return string.Equals(QueryProbeCatalog.Invariant(value), segment.Value, StringComparison.OrdinalIgnoreCase);
            case "Range":
                return value is decimal n && (segment.Low is not decimal low || n >= low) && (segment.High is not decimal high || n < high);
            case "Other":
                var text = QueryProbeCatalog.Invariant(value);
                return !segment.Excluded.Any(x => string.Equals(x, text, StringComparison.OrdinalIgnoreCase));
            default:
                return false;
        }
    }
}

/// <summary>Validation of a draft for the editor: errors (blocking), warnings, and the compiled query when valid.</summary>
public sealed record QueryValidation(bool Valid, ImmutableArray<string> Errors, ImmutableArray<string> Warnings, CompiledQuery? Compiled);

/// <summary>Compiles, validates and evaluates recipes. Pure: no clock, no culture, no I/O.</summary>
public static partial class QueryEngine
{
    [GeneratedRegex("^[A-Za-z][A-Za-z0-9_]{0,63}$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex ParameterName();

    /// <summary>Compiles a recipe; <see cref="QueryDefinitionException"/> with the first French reason otherwise.</summary>
    public static CompiledQuery Compile(QueryRecipe recipe)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        QueryRecipeJson.CheckFormat(recipe.Format, "Domenia.Query", 3, "requête");
        if (!QueryFormat.CleanText(recipe.Name, QueryLimits.MaxNameLength) || !QueryRecipeJson.IdPattern().IsMatch(recipe.Id ?? ""))
        {
            throw Invalid("nom (1 à 120 caractères, sans caractère de contrôle) ou identifiant de requête invalide.");
        }
        if (!Enum.IsDefined(recipe.Target) || !Enum.IsDefined(recipe.Junction))
        {
            throw Invalid("choisissez « Toutes les conditions » ou « Au moins une condition ».");
        }
        var read = recipe.ReadDefinition;
        if (read is not null)
        {
            if (recipe.Target != QueryTarget.Computer)
            {
                throw Invalid("un SELECT WMI mémorisé ne vaut que pour les postes.");
            }
            WqlRules.CheckReadDefinition(read);
        }
        var target = recipe.Target;
        // Typed values first (units, Oui/Non), parameters next: the normalized recipe keeps its parameter references.
        var clauses = recipe.Clauses.IsDefault ? [] : recipe.Clauses.Select(c => Normalize(c, target, read, null)).ToImmutableArray();
        var refinements = recipe.Refinements.IsDefault ? [] : recipe.Refinements.Select(c => Normalize(c, target, read, null)).ToImmutableArray();
        var expression = recipe.Expression is null ? null : NormalizeNode(recipe.Expression, target, read, 0, null, new int[1]);
        var parameters = recipe.Parameters.IsDefault ? [] : recipe.Parameters;
        if (recipe.GroupBy is { Length: > 0 } groupBy)
        {
            var field = QueryCatalog.Find(target, groupBy, read);
            if (field is null || field.Source == QuerySource.Instance || groupBy == QueryCatalog.LdapFilterField)
            {
                throw Invalid("champ de répartition inconnu.");
            }
        }
        var count = clauses.Length + refinements.Length + QueryRecipeWalk.TreeClauses(expression).Count();
        if (count > QueryLimits.MaxConditions)
        {
            throw Invalid("une requête accepte 64 conditions au maximum.");
        }
        if (recipe.CoherenceHours is decimal hours && (hours <= 0 || hours > QueryLimits.MaxCoherenceHours))
        {
            throw Invalid("fenêtre de cohérence invalide (plus de 0 et au plus 8 760 heures).");
        }
        FrozenSet<string>? identities = null;
        if (recipe.ObjectIds is { } ids)
        {
            if (ids.Length > QueryLimits.MaxObjectIds)
            {
                throw Invalid("la sélection accepte au plus 20 000 GUID.");
            }
            var set = new HashSet<string>(StringComparer.Ordinal);
            foreach (var id in ids)
            {
                if (!Guid.TryParse((id ?? "").Trim().Trim('{', '}'), out var guid) || guid == Guid.Empty)
                {
                    throw Invalid("GUID invalide dans la sélection d’objets.");
                }
                set.Add(guid.ToString("D"));
            }
            identities = set.ToFrozenSet(StringComparer.Ordinal);
        }
        if (recipe.ProbeSelection is { } segment)
        {
            CheckSegment(segment, target);
        }
        var normalized = recipe with
        {
            Clauses = clauses,
            Refinements = refinements,
            Expression = expression,
            Parameters = parameters,
            GroupBy = string.IsNullOrEmpty(recipe.GroupBy) ? null : recipe.GroupBy,
        };
        var (resolved, effective) = ResolveParameters(normalized);
        var json = QueryRecipeJson.Write(normalized);
        if (Encoding.UTF8.GetByteCount(json) > QueryLimits.MaxDefinitionBytes)
        {
            throw Invalid("une définition de requête accepte au plus 64 Kio.");
        }
        var main = BuildMain(resolved);
        var refined = resolved.Refinements.Length == 0 ? null : new GroupPredicate(QueryNodeKind.All, [.. resolved.Refinements.Select(c => BuildClause(c, target, read, null))]);
        var requested = RequestedFields(resolved);
        var clocks = requested.Select(f => QueryCatalog.Find(target, f, read)?.Clock).OfType<string>().Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToImmutableArray();
        return new CompiledQuery(recipe, normalized, resolved, effective, main, refined, identities, requested, clocks);
    }

    /// <summary>Validation for the editor: never throws for a bad draft.</summary>
    public static QueryValidation Validate(QueryRecipe recipe)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        try
        {
            var compiled = Compile(recipe);
            return new QueryValidation(true, [], Warnings(compiled), compiled);
        }
        catch (QueryDefinitionException ex)
        {
            return new QueryValidation(false, [ex.Message], [], null);
        }
    }

    /// <summary>Informations a recipe reads (Domenia 1 Get-DomeniaQueryRequestedFields), sorted.</summary>
    public static ImmutableArray<string> RequestedFields(QueryRecipe recipe)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        var ids = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var clause in QueryRecipeWalk.Clauses(recipe))
        {
            if (clause.Field.Length > 0)
            {
                ids.Add(clause.Field);
            }
        }
        if (recipe.GroupBy is { Length: > 0 } group)
        {
            ids.Add(group);
        }
        if (recipe.ProbeSelection is { } segment)
        {
            ids.Add(QueryCatalog.ProbePrefix + segment.Key);
        }
        foreach (var (node, _, _) in QueryRecipeWalk.Nodes(recipe.Expression))
        {
            if (node.Kind == QueryNodeKind.Collection && node.CollectionField is { Length: > 0 } field)
            {
                ids.Add(field);
            }
        }
        return [.. ids];
    }

    /// <summary>Typed form rows of the parameters, with their current values.</summary>
    public static ImmutableArray<QueryParameterRow> ParameterRows(QueryRecipe recipe)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        var rows = ImmutableArray.CreateBuilder<QueryParameterRow>();
        foreach (var definition in recipe.Parameters.IsDefault ? [] : recipe.Parameters)
        {
            var field = QueryCatalog.Find(recipe.Target, definition.Field, recipe.ReadDefinition);
            var value = recipe.ParameterValues is { } values && values.TryGetValue(definition.Name, out var given) ? given : definition.Default;
            var kind = field?.Kind ?? QueryFieldKind.Text;
            var unit = field?.Unit ?? "";
            string hint;
            if (kind == QueryFieldKind.Number)
            {
                hint = "Nombre" + (unit.Length > 0 && unit is not ("Nombre" or "Nombre / tranche" or "Valeur brute du fournisseur") ? " en " + (unit == "Jours" ? "jours" : unit) + " (unités usuelles acceptées)" : "");
                if (definition.Minimum is decimal min && definition.Maximum is decimal max)
                {
                    hint += ", de " + QueryFormat.Value(QueryValue.FromNumber(min), field) + " à " + QueryFormat.Value(QueryValue.FromNumber(max), field);
                }
                else if (definition.Minimum is decimal low)
                {
                    hint += ", au moins " + QueryFormat.Value(QueryValue.FromNumber(low), field);
                }
                else if (definition.Maximum is decimal high)
                {
                    hint += ", au plus " + QueryFormat.Value(QueryValue.FromNumber(high), field);
                }
            }
            else if (kind == QueryFieldKind.Boolean)
            {
                hint = "Oui ou Non";
            }
            else
            {
                hint = field is not null && field.Choices.Length > 0 ? "Choix parmi " + FrenchText.Count(field.Choices.Length, "valeur connue", "valeurs connues") : "Texte littéral, 4 096 caractères au plus";
            }
            rows.Add(new QueryParameterRow(definition.Name, string.IsNullOrEmpty(definition.Label) ? definition.Name : definition.Label, definition.Field, field?.Name ?? definition.Field, kind, unit,
                value, QueryFormat.Value(value, field, bare: true), hint, field?.Choices ?? [], definition.Minimum, definition.Maximum));
        }
        return rows.ToImmutable();
    }

    /// <summary>Typed value of one parameter (Domenia 1 ConvertTo-DomeniaQueryParameterValue): never evaluated as code.</summary>
    public static QueryValue ParameterValue(QueryParameter definition, QueryField field, QueryValue value)
    {
        ArgumentNullException.ThrowIfNull(definition);
        ArgumentNullException.ThrowIfNull(field);
        var label = string.IsNullOrEmpty(definition.Label) ? definition.Name : definition.Label;
        if (value.IsNone || value.Kind == QueryValueKind.Parameter || (value.Kind == QueryValueKind.Text && string.IsNullOrWhiteSpace(value.Text)))
        {
            throw new QueryDefinitionException("Renseignez le paramètre " + label + ".");
        }
        switch (field.Kind)
        {
            case QueryFieldKind.Number:
                var number = value.Kind == QueryValueKind.Number ? value.Number : QueryFormat.ParseNumber(value.Invariant, field);
                if (definition.Minimum is decimal min && number < min)
                {
                    throw new QueryDefinitionException(label + FrenchText.Colon + "valeur attendue supérieure ou égale à " + QueryFormat.Value(QueryValue.FromNumber(min), field) + ".");
                }
                if (definition.Maximum is decimal max && number > max)
                {
                    throw new QueryDefinitionException(label + FrenchText.Colon + "valeur attendue inférieure ou égale à " + QueryFormat.Value(QueryValue.FromNumber(max), field) + ".");
                }
                return QueryValue.FromNumber(number);
            case QueryFieldKind.Boolean:
                return ReadBoolean(value) is bool flag ? QueryValue.FromBoolean(flag) : throw new QueryDefinitionException("Le paramètre " + label + " attend Oui ou Non.");
            default:
                var text = value.Invariant;
                return text.Length > QueryLimits.MaxTextValue
                    ? throw new QueryDefinitionException("Le paramètre " + label + " attend un texte de 4 096 caractères maximum.")
                    : QueryValue.FromText(text);
        }
    }

    internal static QueryDefinitionException Invalid(string reason) => new(QueryTexts.InvalidMessage(reason));

    private static bool? ReadBoolean(QueryValue value) => value.Kind switch
    {
        QueryValueKind.Boolean => value.Flag,
        QueryValueKind.Number => value.Number == 1m ? true : value.Number == 0m ? false : null,
        QueryValueKind.Text => (value.Text ?? "").Trim().ToLowerInvariant() switch
        {
            "true" or "vrai" or "oui" or "1" => true,
            "false" or "faux" or "non" or "0" => false,
            _ => null,
        },
        _ => null,
    };

    private static ImmutableArray<string> Warnings(CompiledQuery compiled)
    {
        var warnings = new List<string>();
        var recipe = compiled.Resolved;
        if (recipe.Clauses.Length == 0 && recipe.Expression is null && recipe.Refinements.Length == 0 && recipe.ObjectIds is null && recipe.ProbeSelection is null)
        {
            var (_, many) = QueryTexts.Noun(recipe.Target);
            warnings.Add("Aucune condition : tous les " + many + " du périmètre correspondent.");
        }
        foreach (var clause in QueryRecipeWalk.Clauses(recipe))
        {
            if (clause.Field.StartsWith(QueryCatalog.LdapPrefix, StringComparison.Ordinal) && LdapSchema.Find(clause.Field[QueryCatalog.LdapPrefix.Length..]) is { ReadByDomenia: false } attribute)
            {
                warnings.Add("L’attribut « " + attribute.Name + " » n’est pas conservé par Domenia : en local, sa condition reste inconnue ; le contrôleur l’évaluera en mode annuaire.");
            }
        }
        var sources = compiled.Clocks.Where(c => c != "ad").ToList();
        if (sources.Count > 1 && recipe.CoherenceHours is null)
        {
            warnings.Add("Les informations viennent de " + FrenchText.Count(compiled.Clocks.Length, "source datée", "sources datées") + " séparément : « Vérifier les informations disponibles » propose une fenêtre commune.");
        }
        if (recipe.Junction == QueryJunction.Any && recipe.Clauses.Length > 1 && recipe.Clauses.Any(c => c.Operator == QueryOperator.NotEqual))
        {
            warnings.Add("Combinaison OU avec « est différent de » : vérifiez que la requête ne retient pas presque tout le périmètre.");
        }
        return [.. warnings.Distinct(StringComparer.Ordinal)];
    }

    private static QueryClause Normalize(QueryClause clause, QueryTarget target, WmiReadDefinition? read, string? collection)
    {
        var field = QueryCatalog.Find(target, clause.Field, read) ?? throw Invalid("information inconnue (" + Clip(clause.Field) + ").");
        if (field.Source == QuerySource.Instance)
        {
            if (collection is null)
            {
                throw Invalid("une propriété d’instance doit être utilisée dans un groupe de collection.");
            }
            if (!clause.Field.StartsWith(QueryCatalog.InstancePrefix + collection + ":", StringComparison.Ordinal))
            {
                throw Invalid("les conditions d’une collection doivent viser les propriétés de la même instance.");
            }
        }
        if (!field.Operators.Contains(clause.Operator))
        {
            throw Invalid("opérateur « " + QueryTexts.OperatorLabel(clause.Operator) + " » non admis pour « " + field.Name + " ».");
        }
        if (clause.Operator is QueryOperator.IsMissing or QueryOperator.IsPresent)
        {
            return clause with { Value = QueryValue.None };
        }
        var value = clause.Value;
        if (value.Kind == QueryValueKind.Parameter)
        {
            return clause;
        }
        if (value.IsNone)
        {
            throw Invalid("valeur manquante pour « " + field.Name + " ».");
        }
        if (field.Id == QueryCatalog.LdapFilterField)
        {
            var text = value.Invariant;
            try
            {
                var filter = LdapFilterText.Parse(text);
                return clause with { Value = QueryValue.FromText(LdapFilterText.Format(filter)) };
            }
            catch (LdapFilterException ex)
            {
                throw Invalid("filtre LDAP refusé : " + ex.Message);
            }
        }
        switch (field.Kind)
        {
            case QueryFieldKind.Number:
                return clause with { Value = value.Kind == QueryValueKind.Number ? value : QueryValue.FromNumber(QueryFormat.ParseNumber(value.Invariant, field)) };
            case QueryFieldKind.Boolean:
                return clause with { Value = ReadBoolean(value) is bool flag ? QueryValue.FromBoolean(flag) : throw Invalid("« " + field.Name + " » attend Oui ou Non.") };
            default:
                var literal = value.Invariant;
                if (literal.Length > QueryLimits.MaxTextValue)
                {
                    throw Invalid("texte limité à 4 096 caractères.");
                }
                if (literal.Length == 0 && clause.Operator is QueryOperator.Contains or QueryOperator.StartsWith or QueryOperator.EndsWith)
                {
                    throw Invalid("saisissez le texte cherché pour « " + field.Name + " ».");
                }
                return clause with { Value = QueryValue.FromText(literal) };
        }
    }

    private static QueryNode NormalizeNode(QueryNode node, QueryTarget target, WmiReadDefinition? read, int depth, string? collection, int[] budget)
    {
        if (depth > QueryLimits.MaxTreeDepth)
        {
            throw Invalid("arbre de conditions limité à 8 niveaux.");
        }
        if (++budget[0] > QueryLimits.MaxTreeNodes)
        {
            throw Invalid("arbre de requête limité à 256 éléments.");
        }
        var children = node.Children.IsDefault ? [] : node.Children;
        switch (node.Kind)
        {
            case QueryNodeKind.Clause:
                return node.Clause is { } clause
                    ? QueryNode.Leaf(Normalize(clause, target, read, collection))
                    : throw Invalid("condition imbriquée absente.");
            case QueryNodeKind.All:
            case QueryNodeKind.Any:
                return QueryNode.Group(node.Kind, children.Select(c => NormalizeNode(c, target, read, depth + 1, collection, budget)));
            case QueryNodeKind.Not:
                if (children.Length != 1)
                {
                    throw Invalid("un groupe NON contient exactement un élément.");
                }
                return QueryNode.Group(QueryNodeKind.Not, [NormalizeNode(children[0], target, read, depth + 1, collection, budget)]);
            case QueryNodeKind.Collection:
                if (collection is not null)
                {
                    throw Invalid("les collections imbriquées ne sont pas prises en charge.");
                }
                if (target != QueryTarget.Computer || node.CollectionField is not { } field || !field.StartsWith(QueryCatalog.ProbePrefix, StringComparison.Ordinal)
                    || QueryProbeCatalog.Find(field[QueryCatalog.ProbePrefix.Length..]) is null || node.Quantifier is not CollectionQuantifier quantifier || !Enum.IsDefined(quantifier))
                {
                    throw Invalid("source ou quantificateur de collection invalide.");
                }
                if (children.Length != 1)
                {
                    throw Invalid("un groupe de collection contient exactement un élément.");
                }
                var probe = field[QueryCatalog.ProbePrefix.Length..];
                return QueryNode.Collection(field, quantifier, NormalizeNode(children[0], target, read, depth + 1, probe, budget));
            default:
                throw Invalid("type de groupe de conditions inconnu.");
        }
    }

    private static void CheckSegment(QueryProbeSegment segment, QueryTarget target)
    {
        var probe = target == QueryTarget.Computer ? QueryProbeCatalog.Find(segment.Key) : null;
        if (probe is null || segment.Mode is not ("Equal" or "Range" or "Other"))
        {
            throw Invalid("segment de sonde inconnu.");
        }
        switch (segment.Mode)
        {
            case "Range":
                if (!probe.Numeric || (segment.Low is decimal low && segment.High is decimal high && low >= high) || (segment.Low is null && segment.High is null))
                {
                    throw Invalid("bornes de segment invalides.");
                }
                break;
            case "Equal":
                if (segment.Value is null || segment.Value.Length > QueryLimits.MaxTextValue || (probe.Numeric && QueryProbeCatalog.Number(segment.Value) is null))
                {
                    throw Invalid("valeur de segment invalide.");
                }
                break;
            default:
                if (segment.Excluded.IsDefaultOrEmpty || segment.Excluded.Length > 64)
                {
                    throw Invalid("catégories du segment invalides.");
                }
                break;
        }
    }

    private static (QueryRecipe Resolved, ImmutableSortedDictionary<string, QueryValue> Effective) ResolveParameters(QueryRecipe recipe)
    {
        var definitions = recipe.Parameters;
        if (definitions.Length > QueryLimits.MaxParameters)
        {
            throw Invalid("une recette accepte au maximum 32 paramètres.");
        }
        var effective = ImmutableSortedDictionary.CreateBuilder<string, QueryValue>(StringComparer.Ordinal);
        var resolved = new Dictionary<string, (string Field, QueryValue Value)>(StringComparer.Ordinal);
        foreach (var definition in definitions)
        {
            if (!ParameterName().IsMatch(definition.Name ?? "") || resolved.ContainsKey(definition.Name!))
            {
                throw Invalid("définition de paramètre invalide ou dupliquée.");
            }
            var field = QueryCatalog.Find(recipe.Target, definition.Field, recipe.ReadDefinition) ?? throw Invalid("définition de paramètre invalide ou dupliquée.");
            if (definition.Label is not null && !QueryFormat.CleanText(definition.Label, 80, allowEmpty: true))
            {
                throw Invalid("libellé de paramètre invalide (80 caractères, sans caractère de contrôle).");
            }
            if ((definition.Minimum is not null || definition.Maximum is not null) && field.Kind != QueryFieldKind.Number)
            {
                throw Invalid("seule une information numérique accepte des bornes.");
            }
            if (definition.Minimum is decimal min && definition.Maximum is decimal max && min > max)
            {
                throw Invalid("la borne minimale du paramètre dépasse sa borne maximale.");
            }
            var given = recipe.ParameterValues is { } values && values.TryGetValue(definition.Name!, out var v) ? v : definition.Default;
            var typed = ParameterValue(definition, field, given);
            resolved[definition.Name!] = (definition.Field, typed);
            effective[definition.Name!] = typed;
        }
        if (recipe.ParameterValues is { } extra && extra.Keys.Any(k => !resolved.ContainsKey(k)))
        {
            throw Invalid("valeur pour un paramètre inconnu.");
        }
        QueryClause Substitute(QueryClause clause)
        {
            if (clause.Value.Kind != QueryValueKind.Parameter)
            {
                return clause;
            }
            if (!resolved.TryGetValue(clause.Value.Text ?? "", out var entry) || !string.Equals(entry.Field, clause.Field, StringComparison.Ordinal))
            {
                throw Invalid("le paramètre doit appartenir au même champ que sa condition.");
            }
            return clause with { Value = entry.Value };
        }
        QueryNode SubstituteNode(QueryNode node) => node.Kind == QueryNodeKind.Clause && node.Clause is { } clause
            ? QueryNode.Leaf(Substitute(clause))
            : node with { Children = [.. node.Children.Select(SubstituteNode)] };
        var copy = recipe with
        {
            Clauses = [.. recipe.Clauses.Select(Substitute)],
            Refinements = [.. recipe.Refinements.Select(Substitute)],
            Expression = recipe.Expression is null ? null : SubstituteNode(recipe.Expression),
            Parameters = [],
            ParameterValues = null,
        };
        return (copy, effective.ToImmutable());
    }

    private static string Clip(string text) => text.Length <= 60 && !text.Any(char.IsControl) ? text : text[..Math.Min(60, text.Length)] + "…";

    private static Predicate BuildMain(QueryRecipe recipe)
    {
        var parts = new List<Predicate>();
        if (recipe.Clauses.Length > 0)
        {
            var clauses = recipe.Clauses.Select(c => BuildClause(c, recipe.Target, recipe.ReadDefinition, null)).ToImmutableArray();
            parts.Add(new GroupPredicate(recipe.Junction == QueryJunction.Any ? QueryNodeKind.Any : QueryNodeKind.All, clauses));
        }
        if (recipe.Expression is { } tree)
        {
            parts.Add(BuildNode(tree, recipe.Target, recipe.ReadDefinition, null));
        }
        // The advanced tree is combined in AND with the simple criteria (Domenia 1).
        return parts.Count == 1 ? parts[0] : new GroupPredicate(QueryNodeKind.All, [.. parts]);
    }

    internal static Predicate BuildNode(QueryNode node, QueryTarget target, WmiReadDefinition? read, string? collection) => node.Kind switch
    {
        QueryNodeKind.Clause => BuildClause(node.Clause!, target, read, collection),
        QueryNodeKind.Not => new NotPredicate(BuildNode(node.Children[0], target, read, collection)),
        QueryNodeKind.Collection => new CollectionPredicate(node.CollectionField![QueryCatalog.ProbePrefix.Length..], node.Quantifier ?? CollectionQuantifier.Any,
            BuildNode(node.Children[0], target, read, node.CollectionField[QueryCatalog.ProbePrefix.Length..])),
        _ => new GroupPredicate(node.Kind, [.. node.Children.Select(c => BuildNode(c, target, read, collection))]),
    };

    internal static Predicate BuildClause(QueryClause clause, QueryTarget target, WmiReadDefinition? read, string? collection)
    {
        var field = QueryCatalog.Find(target, clause.Field, read);
        if (field is null)
        {
            return new ConstantPredicate(MatchState.Unknown);
        }
        if (field.Source == QuerySource.Ldap)
        {
            var filter = clause.Field == QueryCatalog.LdapFilterField
                ? LdapFilterText.Parse(clause.Value.Text ?? "")
                : QueryLdap.ClauseFilter(clause, field.LdapAttribute!);
            return new LdapPredicate(filter);
        }
        return new ClausePredicate(clause, field, collection is not null, collection is null && QueryLdap.AbsentIsFalse(field));
    }
}

/// <summary>Compiled predicate (internal tree: conditions, groups, collections, LDAP items).</summary>
internal abstract class Predicate
{
    public abstract MatchState Evaluate(QueryRecord record, QueryEvaluationContext context);

    /// <summary>Evaluation on one instance of a collection (properties of the same instance).</summary>
    public virtual MatchState EvaluateInstance(ProbeInstance instance, QueryEvaluationContext context) => MatchState.Unknown;
}

internal sealed class ConstantPredicate(MatchState state) : Predicate
{
    public override MatchState Evaluate(QueryRecord record, QueryEvaluationContext context) => state;

    public override MatchState EvaluateInstance(ProbeInstance instance, QueryEvaluationContext context) => state;
}

internal sealed class GroupPredicate(QueryNodeKind kind, ImmutableArray<Predicate> children) : Predicate
{
    public override MatchState Evaluate(QueryRecord record, QueryEvaluationContext context) => Combine(c => c.Evaluate(record, context));

    public override MatchState EvaluateInstance(ProbeInstance instance, QueryEvaluationContext context) => Combine(c => c.EvaluateInstance(instance, context));

    private MatchState Combine(Func<Predicate, MatchState> evaluate)
    {
        var unknown = false;
        var any = kind == QueryNodeKind.Any;
        foreach (var child in children)
        {
            var state = evaluate(child);
            if (any && state == MatchState.Match)
            {
                return MatchState.Match;
            }
            if (!any && state == MatchState.NoMatch)
            {
                return MatchState.NoMatch;
            }
            unknown |= state == MatchState.Unknown;
        }
        if (unknown)
        {
            return MatchState.Unknown;
        }
        return any ? MatchState.NoMatch : MatchState.Match;
    }
}

internal sealed class NotPredicate(Predicate child) : Predicate
{
    public override MatchState Evaluate(QueryRecord record, QueryEvaluationContext context) => LdapEvaluator.Negate(child.Evaluate(record, context));

    public override MatchState EvaluateInstance(ProbeInstance instance, QueryEvaluationContext context) => LdapEvaluator.Negate(child.EvaluateInstance(instance, context));
}

internal sealed class LdapPredicate(LdapFilter filter) : Predicate
{
    public override MatchState Evaluate(QueryRecord record, QueryEvaluationContext context) => LdapEvaluator.Evaluate(filter, record.Entry, context.Chain);
}

/// <summary>Quantified condition on the instances of one probe collection (Domenia 1 Collection: Any, All, None).</summary>
internal sealed class CollectionPredicate(string probe, CollectionQuantifier quantifier, Predicate child) : Predicate
{
    public override MatchState Evaluate(QueryRecord record, QueryEvaluationContext context)
    {
        if (!record.Collections.TryGetValue(probe, out var collection))
        {
            return MatchState.Unknown;
        }
        var unknown = !collection.Complete;
        foreach (var instance in collection.Instances)
        {
            var state = child.EvaluateInstance(instance, context);
            switch (quantifier)
            {
                case CollectionQuantifier.Any when state == MatchState.Match:
                    return MatchState.Match;
                case CollectionQuantifier.All when state == MatchState.NoMatch:
                case CollectionQuantifier.None when state == MatchState.Match:
                    return MatchState.NoMatch;
            }
            unknown |= state == MatchState.Unknown;
        }
        if (unknown)
        {
            return MatchState.Unknown;
        }
        return quantifier == CollectionQuantifier.Any ? MatchState.NoMatch : MatchState.Match;
    }
}

/// <summary>
/// One typed condition on a record value (or on an instance property inside a collection). <paramref name="absentIsFalse"/>:
/// the information is the plain copy of a directory attribute kept by Domenia, so an absent value is an empty attribute, a
/// known fact (as in LDAP: the item is FALSE, its negation TRUE), never a missing measure.
/// </summary>
internal sealed class ClausePredicate(QueryClause clause, QueryField field, bool instance, bool absentIsFalse = false) : Predicate
{
    public override MatchState Evaluate(QueryRecord record, QueryEvaluationContext context)
    {
        if (instance)
        {
            return MatchState.Unknown;
        }
        var value = record.Values.TryGetValue(clause.Field, out var raw) ? raw : null;
        if (value is null && absentIsFalse && clause.Operator is not (QueryOperator.IsMissing or QueryOperator.IsPresent))
        {
            return clause.Operator == QueryOperator.NotEqual ? MatchState.Match : MatchState.NoMatch;
        }
        return Test(value);
    }

    public override MatchState EvaluateInstance(ProbeInstance item, QueryEvaluationContext context)
    {
        if (!instance || field.Property is not { } property)
        {
            return MatchState.Unknown;
        }
        if (item.Incomplete.Contains(property, StringComparer.OrdinalIgnoreCase))
        {
            return MatchState.Unknown;
        }
        var raw = item.Values.FirstOrDefault(p => string.Equals(p.Key, property, StringComparison.OrdinalIgnoreCase)).Value;
        return Test(Typed(raw));
    }

    private object? Typed(object? raw)
    {
        if (raw is null)
        {
            return null;
        }
        return field.Kind switch
        {
            QueryFieldKind.Number => raw is decimal d ? d : QueryProbeCatalog.Number(QueryProbeCatalog.Invariant(raw)),
            QueryFieldKind.Boolean => raw is bool b ? b : QueryProbeCatalog.Invariant(raw).ToUpperInvariant() switch
            {
                "TRUE" or "1" => true,
                "FALSE" or "0" => false,
                _ => null,
            },
            _ => QueryProbeCatalog.Invariant(raw),
        };
    }

    private MatchState Test(object? value)
    {
        switch (clause.Operator)
        {
            case QueryOperator.IsMissing:
                return value is null ? MatchState.Match : MatchState.NoMatch;
            case QueryOperator.IsPresent:
                return value is null ? MatchState.NoMatch : MatchState.Match;
        }
        if (value is null)
        {
            return MatchState.Unknown;
        }
        var expected = clause.Value;
        bool result;
        switch (field.Kind)
        {
            case QueryFieldKind.Number:
                if (value is not decimal number || expected.Kind != QueryValueKind.Number)
                {
                    return MatchState.Unknown;
                }
                result = clause.Operator switch
                {
                    QueryOperator.Equal => number == expected.Number,
                    QueryOperator.NotEqual => number != expected.Number,
                    QueryOperator.Greater => number > expected.Number,
                    QueryOperator.GreaterOrEqual => number >= expected.Number,
                    QueryOperator.Less => number < expected.Number,
                    QueryOperator.LessOrEqual => number <= expected.Number,
                    _ => false,
                };
                break;
            case QueryFieldKind.Boolean:
                if (value is not bool flag || expected.Kind != QueryValueKind.Boolean)
                {
                    return MatchState.Unknown;
                }
                result = clause.Operator == QueryOperator.NotEqual ? flag != expected.Flag : flag == expected.Flag;
                break;
            default:
                var text = value as string ?? QueryProbeCatalog.Invariant(value);
                var wanted = expected.Text ?? expected.Invariant;
                result = clause.Operator switch
                {
                    QueryOperator.Equal => string.Equals(text, wanted, StringComparison.OrdinalIgnoreCase),
                    QueryOperator.NotEqual => !string.Equals(text, wanted, StringComparison.OrdinalIgnoreCase),
                    QueryOperator.Contains => text.Contains(wanted, StringComparison.OrdinalIgnoreCase),
                    QueryOperator.StartsWith => text.StartsWith(wanted, StringComparison.OrdinalIgnoreCase),
                    QueryOperator.EndsWith => text.EndsWith(wanted, StringComparison.OrdinalIgnoreCase),
                    _ => false,
                };
                break;
        }
        return result ? MatchState.Match : MatchState.NoMatch;
    }
}
