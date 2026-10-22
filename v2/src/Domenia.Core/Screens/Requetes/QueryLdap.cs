using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Core.Queries;

/// <summary>
/// LDAP form of a recipe. <see cref="Filter"/> is the natural filter of the conditions the directory can evaluate (the
/// text editor shows it); when some conditions are computed locally (readings, probes, dashboard rules), <see cref="Exact"/>
/// is false and they are listed in <see cref="Residual"/>. <see cref="PreFilter"/> is the filter the controller receives in
/// directory mode: a superset of every object whose verdict may be « match » or « unknown », re-evaluated locally after.
/// </summary>
public sealed record LdapTranslation(string Filter, string Pretty, bool Exact, string PreFilter, ImmutableArray<string> Residual, ImmutableArray<string> Notes);

/// <summary>Result of reading an LDAP text typed in the editor: the recipe conditions, or the refusal and its position.</summary>
public sealed record LdapReading(bool Valid, string? Error, int? Position, QueryRecipe? Recipe, string? Pretty, ImmutableArray<string> Warnings);

/// <summary>Translation between recipes and LDAP filters (both directions). Pure.</summary>
public static class QueryLdap
{
    private const string Uac = "userAccountControl";

    /// <summary>Base filter of a target: the class of the objects read.</summary>
    public static LdapFilter TargetFilter(QueryTarget target) => target switch
    {
        QueryTarget.User => LdapFilter.And([LdapFilter.Item(LdapFilterKind.Equality, "objectCategory", "person"), LdapFilter.Item(LdapFilterKind.Equality, "objectClass", "user")]),
        QueryTarget.Group => LdapFilter.Item(LdapFilterKind.Equality, "objectCategory", "group"),
        _ => LdapFilter.Item(LdapFilterKind.Equality, "objectCategory", "computer"),
    };

    /// <summary>Filter of one raw LDAP attribute condition (« ldap:department contient Commercial »).</summary>
    public static LdapFilter ClauseFilter(QueryClause clause, string attribute)
    {
        ArgumentNullException.ThrowIfNull(clause);
        ArgumentNullException.ThrowIfNull(attribute);
        var text = clause.Value.Kind == QueryValueKind.None ? "" : clause.Value.Invariant;
        return clause.Operator switch
        {
            QueryOperator.Equal => LdapFilter.Item(LdapFilterKind.Equality, attribute, text),
            QueryOperator.NotEqual => LdapFilter.Not(LdapFilter.Item(LdapFilterKind.Equality, attribute, text)),
            QueryOperator.Contains => LdapFilter.Substring(attribute, null, [text], null),
            QueryOperator.StartsWith => LdapFilter.Substring(attribute, text, [], null),
            QueryOperator.EndsWith => LdapFilter.Substring(attribute, null, [], text),
            QueryOperator.GreaterOrEqual => LdapFilter.Item(LdapFilterKind.GreaterOrEqual, attribute, text),
            QueryOperator.LessOrEqual => LdapFilter.Item(LdapFilterKind.LessOrEqual, attribute, text),
            QueryOperator.Greater => LdapFilter.And([LdapFilter.Item(LdapFilterKind.GreaterOrEqual, attribute, text), LdapFilter.Not(LdapFilter.Item(LdapFilterKind.Equality, attribute, text))]),
            QueryOperator.Less => LdapFilter.And([LdapFilter.Item(LdapFilterKind.LessOrEqual, attribute, text), LdapFilter.Not(LdapFilter.Item(LdapFilterKind.Equality, attribute, text))]),
            QueryOperator.IsPresent => LdapFilter.Present(attribute),
            _ => LdapFilter.Not(LdapFilter.Present(attribute)),
        };
    }

    // One clause translated: the exact filter (null when computed locally) and its superset for the directory (null = no constraint).
    // Definite: the local verdict equals the LDAP verdict for every object, absent attribute included (an information whose
    // absence stays « unknown » locally is not definite: under a negation its exact filter would select other objects).
    private sealed record Part(LdapFilter? Exact, LdapFilter? Upper, LdapFilter? Lower, bool Residual, bool Definite = true);

    /// <summary>
    /// True when an information is the plain copy of a text attribute kept by Domenia (name, operatingSystem, description…):
    /// an absent value is then an empty attribute, a known fact, evaluated like LDAP (the item is FALSE, its negation TRUE),
    /// never a missing measure. Readings, probes and computed informations keep « unknown » for a missing value.
    /// </summary>
    public static bool AbsentIsFalse(QueryField field)
    {
        ArgumentNullException.ThrowIfNull(field);
        return field.Source == QuerySource.Ad && field.Kind == QueryFieldKind.Text && field.LdapAttribute is { } name && !name.Contains(',', StringComparison.Ordinal)
            && LdapSchema.Find(name) is { ReadByDomenia: true, Syntax: LdapSyntax.CaseIgnore or LdapSyntax.Dn };
    }

    /// <summary>LDAP form of a recipe whose parameters are resolved, with dates converted at <paramref name="now"/>.</summary>
    public static LdapTranslation Translate(QueryRecipe resolved, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(resolved);
        var residual = new List<string>();
        var notes = new SortedSet<string>(StringComparer.Ordinal);
        var parts = new List<Part>();
        if (resolved.Clauses.Length > 0)
        {
            var items = resolved.Clauses.Select(c => Clause(c, resolved, now, residual, notes)).ToList();
            parts.Add(Combine(resolved.Junction == QueryJunction.Any ? LdapFilterKind.Or : LdapFilterKind.And, items));
        }
        if (resolved.Expression is { } tree)
        {
            parts.Add(Node(tree, resolved, now, residual, notes));
        }
        foreach (var refinement in resolved.Refinements)
        {
            parts.Add(Clause(refinement, resolved, now, residual, notes));
        }
        if (resolved.ObjectIds is { } ids)
        {
            residual.Add("Sélection figée de " + FrenchText.Count(ids.Length, "GUID", "GUID") + " (évaluée localement)");
            parts.Add(new Part(null, null, null, true));
        }
        if (resolved.ProbeSelection is { } segment)
        {
            residual.Add("Segment de sonde · " + QueryAnalysis.SegmentLabel(segment, resolved.Target));
            parts.Add(new Part(null, null, null, true));
        }
        var whole = parts.Count == 0 ? new Part(null, null, null, false) : parts.Count == 1 ? parts[0] : Combine(LdapFilterKind.And, parts);
        var target = TargetFilter(resolved.Target);
        var display = whole.Exact is { } exact ? LdapFilter.And([target, exact]) : Natural(resolved, now, residual.Count > 0) is { } natural ? LdapFilter.And([target, natural]) : target;
        var upper = whole.Upper is { } u ? LdapFilter.And([target, u]) : target;
        var allExact = whole.Exact is not null && residual.Count == 0 || parts.Count == 0;
        if (resolved.CoherenceHours is not null)
        {
            notes.Add("La fenêtre de cohérence des dates s’applique localement, après la lecture.");
        }
        display = Flatten(display);
        return new LdapTranslation(LdapFilterText.Format(display), LdapFilterText.Pretty(display), allExact, LdapFilterText.Format(Flatten(upper)), [.. residual.Distinct(StringComparer.Ordinal)], [.. notes]);
    }

    /// <summary>Natural filter of the conditions the directory can evaluate, when the whole recipe cannot be written in LDAP.</summary>
    private static LdapFilter? Natural(QueryRecipe resolved, DateTimeOffset now, bool hasResidual)
    {
        _ = hasResidual;
        var scratch = new List<string>();
        var notes = new SortedSet<string>(StringComparer.Ordinal);
        var kept = new List<LdapFilter>();
        if (resolved.Junction == QueryJunction.All)
        {
            kept.AddRange(resolved.Clauses.Select(c => Clause(c, resolved, now, scratch, notes).Exact).OfType<LdapFilter>());
        }
        else if (resolved.Clauses.Length > 0)
        {
            var any = resolved.Clauses.Select(c => Clause(c, resolved, now, scratch, notes)).ToList();
            if (any.All(p => p.Exact is not null))
            {
                kept.Add(LdapFilter.Or(any.Select(p => p.Exact!)));
            }
        }
        if (resolved.Expression is { } tree && Node(tree, resolved, now, scratch, notes).Exact is { } exact)
        {
            kept.Add(exact);
        }
        kept.AddRange(resolved.Refinements.Select(c => Clause(c, resolved, now, scratch, notes).Exact).OfType<LdapFilter>());
        return kept.Count switch
        {
            0 => null,
            1 => kept[0],
            _ => LdapFilter.And(kept),
        };
    }

    private static Part Combine(LdapFilterKind kind, IReadOnlyList<Part> parts)
    {
        var exact = parts.All(p => p.Exact is not null) ? Group(kind, parts.Select(p => p.Exact!)) : null;
        LdapFilter? upper;
        LdapFilter? lower;
        if (kind == LdapFilterKind.And)
        {
            var uppers = parts.Select(p => p.Upper).OfType<LdapFilter>().ToList();
            upper = uppers.Count == 0 ? null : Group(kind, uppers);
            lower = parts.Any(p => p.Lower is null) ? null : Group(kind, parts.Select(p => p.Lower!));
        }
        else
        {
            upper = parts.Any(p => p.Upper is null) ? null : Group(kind, parts.Select(p => p.Upper!));
            var lowers = parts.Select(p => p.Lower).OfType<LdapFilter>().ToList();
            lower = lowers.Count == 0 ? null : Group(kind, lowers);
        }
        return new Part(exact, upper, lower, parts.Any(p => p.Residual), parts.All(p => p.Definite));
    }

    private static LdapFilter Group(LdapFilterKind kind, IEnumerable<LdapFilter> items)
    {
        var list = items.ToList();
        return list.Count == 1 ? list[0] : kind == LdapFilterKind.Or ? LdapFilter.Or(list) : LdapFilter.And(list);
    }

    private static Part Node(QueryNode node, QueryRecipe recipe, DateTimeOffset now, List<string> residual, SortedSet<string> notes)
    {
        switch (node.Kind)
        {
            case QueryNodeKind.Clause:
                return Clause(node.Clause!, recipe, now, residual, notes);
            case QueryNodeKind.Not:
                var child = Node(node.Children[0], recipe, now, residual, notes);
                // Upper of NOT x = objects where x is not surely TRUE; lower = objects where x is surely FALSE. The exact filter of
                // NOT x is kept only when x is definite: otherwise an object locally « unknown » would be TRUE for the controller.
                var exactNot = child.Exact is { } e && child.Definite ? LdapFilter.Not(e) : null;
                if (child.Exact is not null && !child.Definite)
                {
                    residual.Add("Groupe NON évalué localement : une information absente y reste inconnue, alors que le contrôleur la compterait vraie");
                }
                return new Part(exactNot, child.Lower is { } l ? LdapFilter.Not(l) : null, child.Upper is { } u ? LdapFilter.Not(u) : null, child.Residual || exactNot is null && child.Exact is not null, child.Definite);
            case QueryNodeKind.Collection:
                residual.Add(QueryAnalysis.NodeLabel(node, recipe.Target, recipe.ReadDefinition));
                return new Part(null, null, null, true);
            default:
                if (node.Children.Length == 0)
                {
                    return node.Kind == QueryNodeKind.Any
                        ? new Part(LdapFilter.Or([]), LdapFilter.Or([]), LdapFilter.Or([]), false)
                        : new Part(LdapFilter.And([]), null, LdapFilter.And([]), false);
                }
                return Combine(node.Kind == QueryNodeKind.Any ? LdapFilterKind.Or : LdapFilterKind.And, [.. node.Children.Select(c => Node(c, recipe, now, residual, notes))]);
        }
    }

    private static Part Exact(LdapFilter filter, string? presence = null, bool definite = true) =>
        new(filter, presence is null ? filter : LdapFilter.Or([filter, LdapFilter.Not(LdapFilter.Present(presence))]), filter, false, definite);

    private static Part Local(QueryClause clause, QueryRecipe recipe, List<string> residual, LdapFilter? upper = null)
    {
        residual.Add(QueryFormat.Clause(clause, recipe.Target, recipe.ReadDefinition));
        return new Part(null, upper, null, true);
    }

    private static LdapFilter Bit(string attribute, long mask) => LdapFilter.Extensible(attribute, LdapSchema.BitAnd, mask.ToString(CultureInfo.InvariantCulture));

    private static LdapFilter Ge(string attribute, long value) => LdapFilter.Item(LdapFilterKind.GreaterOrEqual, attribute, value.ToString(CultureInfo.InvariantCulture));

    private static LdapFilter Le(string attribute, long value) => LdapFilter.Item(LdapFilterKind.LessOrEqual, attribute, value.ToString(CultureInfo.InvariantCulture));

    private static LdapFilter Eq(string attribute, string value) => LdapFilter.Item(LdapFilterKind.Equality, attribute, value);

    private static Part Clause(QueryClause clause, QueryRecipe recipe, DateTimeOffset now, List<string> residual, SortedSet<string> notes)
    {
        var part = ClauseCore(clause, recipe, now, residual, notes);
        // « est différent de » is a negation: on an information that stays unknown when absent, the LDAP filter would also
        // select the objects without the attribute. Evaluated locally, never claimed exact.
        if (!part.Definite && part.Exact is not null && clause.Operator == QueryOperator.NotEqual)
        {
            residual.Add(QueryFormat.Clause(clause, recipe.Target, recipe.ReadDefinition));
            return part with { Exact = null, Residual = true };
        }
        return part;
    }

    private static Part ClauseCore(QueryClause clause, QueryRecipe recipe, DateTimeOffset now, List<string> residual, SortedSet<string> notes)
    {
        var field = QueryCatalog.Find(recipe.Target, clause.Field, recipe.ReadDefinition);
        if (field is null)
        {
            return Local(clause, recipe, residual);
        }
        if (field.Id == QueryCatalog.LdapFilterField)
        {
            var filter = LdapFilterText.Parse(clause.Value.Text ?? "");
            return Exact(filter);
        }
        if (field.Source == QuerySource.Ldap)
        {
            var attribute = LdapSchema.Find(field.LdapAttribute);
            if (attribute is { ReadByDomenia: false })
            {
                notes.Add("L’attribut « " + attribute.Name + " » n’est pas conservé localement : le contrôleur l’évalue en mode annuaire.");
            }
            var raw = ClauseFilter(clause, field.LdapAttribute!);
            return clause.Operator is QueryOperator.IsMissing or QueryOperator.IsPresent ? Exact(raw) : Exact(raw);
        }
        var op = clause.Operator;
        var value = clause.Value;
        switch (field.Id)
        {
            case "active":
                {
                    var disabled = Bit(Uac, AdValues.AccountDisabled);
                    if (op is QueryOperator.IsPresent)
                    {
                        return Exact(LdapFilter.Present(Uac));
                    }
                    if (op is QueryOperator.IsMissing)
                    {
                        return Exact(LdapFilter.Not(LdapFilter.Present(Uac)));
                    }
                    var wantActive = value.Flag ^ (op == QueryOperator.NotEqual);
                    return Exact(wantActive ? LdapFilter.Not(disabled) : disabled);
                }
            case "adminCount":
                {
                    if (op is QueryOperator.IsPresent or QueryOperator.IsMissing)
                    {
                        return op == QueryOperator.IsPresent ? Exact(LdapFilter.Present("adminCount")) : Exact(LdapFilter.Not(LdapFilter.Present("adminCount")));
                    }
                    var wanted = value.Flag ^ (op == QueryOperator.NotEqual);
                    return Exact(wanted ? Eq("adminCount", "1") : LdapFilter.Not(Eq("adminCount", "1")));
                }
            case "passwordNeverExpires":
            case "passwordNotRequired":
                {
                    var bit = Bit(Uac, field.Id == "passwordNeverExpires" ? AdValues.DontExpirePassword : AdValues.PasswordNotRequired);
                    if (op is QueryOperator.IsPresent or QueryOperator.IsMissing)
                    {
                        return op == QueryOperator.IsPresent ? Exact(LdapFilter.Present(Uac)) : Exact(LdapFilter.Not(LdapFilter.Present(Uac)));
                    }
                    var wanted = value.Flag ^ (op == QueryOperator.NotEqual);
                    return Exact(wanted ? bit : LdapFilter.Not(bit));
                }
            case "win10":
                {
                    if (op is QueryOperator.IsPresent or QueryOperator.IsMissing)
                    {
                        return Exact(op == QueryOperator.IsPresent ? LdapFilter.And([]) : LdapFilter.Or([]));
                    }
                    var win10 = LdapFilter.And([LdapFilter.Substring("operatingSystem", null, ["Windows 10"], null), LdapFilter.Not(LdapFilter.Substring("operatingSystem", null, ["LTSC"], null)),
                        LdapFilter.Not(LdapFilter.Substring("operatingSystem", null, ["LTSB"], null)), LdapFilter.Not(LdapFilter.Substring("operatingSystem", null, ["IoT"], null))]);
                    return Exact(value.Flag ^ (op == QueryOperator.NotEqual) ? win10 : LdapFilter.Not(win10));
                }
            case "osFamily" when op is QueryOperator.Equal or QueryOperator.NotEqual:
                {
                    var family = (value.Text ?? "") switch
                    {
                        "Serveurs" => LdapFilter.Substring("operatingSystem", null, ["Server"], null),
                        "Postes de travail" => LdapFilter.And([LdapFilter.Present("operatingSystem"), LdapFilter.Not(LdapFilter.Substring("operatingSystem", null, ["Server"], null))]),
                        "Système non renseigné" => LdapFilter.Not(LdapFilter.Present("operatingSystem")),
                        _ => null,
                    };
                    return family is null ? Local(clause, recipe, residual) : Exact(op == QueryOperator.Equal ? family : LdapFilter.Not(family));
                }
            case "logonDays":
                return Days(clause, recipe, "lastLogonTimestamp", now, residual, notes, fileTime: true);
            case "passwordAgeDays":
                return Days(clause, recipe, "pwdLastSet", now, residual, notes, fileTime: true, positive: true);
            case "createdDays":
                return Days(clause, recipe, "whenCreated", now, residual, notes, fileTime: false);
            case "createdRecent":
                {
                    if (op is QueryOperator.IsPresent or QueryOperator.IsMissing)
                    {
                        return Exact(op == QueryOperator.IsPresent ? LdapFilter.Present("whenCreated") : LdapFilter.Not(LdapFilter.Present("whenCreated")));
                    }
                    notes.Add(DateNote(now));
                    var recent = LdapFilter.Item(LdapFilterKind.GreaterOrEqual, "whenCreated", LdapEvaluator.FormatTime(now.AddDays(-30)));
                    return Exact(value.Flag ^ (op == QueryOperator.NotEqual) ? recent : LdapFilter.Not(recent));
                }
            case "passwordOld":
                {
                    if (op is QueryOperator.IsPresent or QueryOperator.IsMissing)
                    {
                        var set = LdapFilter.And([Ge("pwdLastSet", 1)]);
                        return Exact(op == QueryOperator.IsPresent ? set : LdapFilter.Not(set));
                    }
                    notes.Add(DateNote(now));
                    var limit = LdapEvaluator.FileTime(now.AddDays(-60));
                    var old = LdapFilter.And([Ge("pwdLastSet", 1), Le("pwdLastSet", limit - 1)]);
                    var recent = Ge("pwdLastSet", limit);
                    return new Part(value.Flag ^ (op == QueryOperator.NotEqual) ? old : recent, LdapFilter.Or([value.Flag ^ (op == QueryOperator.NotEqual) ? old : recent, LdapFilter.Not(Ge("pwdLastSet", 1))]), value.Flag ^ (op == QueryOperator.NotEqual) ? old : recent, false, false);
                }
            case "laps" when op is QueryOperator.Equal or QueryOperator.NotEqual:
                {
                    notes.Add(DateNote(now));
                    var nowFt = LdapEvaluator.FileTime(now);
                    const string windows = "msLAPS-PasswordExpirationTime";
                    const string legacy = "ms-Mcs-AdmPwdExpirationTime";
                    LdapFilter? code = (value.Text ?? "").ToUpperInvariant() switch
                    {
                        "O" => LdapFilter.Or([Ge(windows, nowFt + 1), Ge(legacy, nowFt + 1)]),
                        "E" => LdapFilter.Or([LdapFilter.And([LdapFilter.Present(windows), Le(windows, nowFt)]), LdapFilter.And([LdapFilter.Present(legacy), Le(legacy, nowFt)])]),
                        "N" => LdapFilter.And([LdapFilter.Not(LdapFilter.Present(windows)), LdapFilter.Not(LdapFilter.Present(legacy))]),
                        _ => null,
                    };
                    return code is null ? Local(clause, recipe, residual) : Exact(op == QueryOperator.Equal ? code : LdapFilter.Not(code));
                }
            case "scope" when op is QueryOperator.Equal or QueryOperator.NotEqual:
                {
                    long? mask = (value.Text ?? "") switch
                    {
                        "Global" => 2,
                        "Domaine local" => 4,
                        "Universel" => 8,
                        "Local intégré" => 1,
                        _ => null,
                    };
                    return mask is long m ? Exact(op == QueryOperator.Equal ? Bit("groupType", m) : LdapFilter.Not(Bit("groupType", m))) : Local(clause, recipe, residual);
                }
            case "groupKind" when op is QueryOperator.Equal or QueryOperator.NotEqual:
                {
                    var security = Bit("groupType", 2147483648L);
                    var wantSecurity = string.Equals(value.Text, "Sécurité", StringComparison.Ordinal) ^ (op == QueryOperator.NotEqual);
                    return Exact(wantSecurity ? security : LdapFilter.Not(security));
                }
            case "members":
                {
                    var none = op switch
                    {
                        QueryOperator.Equal when value.Number == 0 => true,
                        QueryOperator.LessOrEqual when value.Number < 1 => true,
                        QueryOperator.Less when value.Number <= 1 && value.Number > 0 => true,
                        _ => (bool?)null,
                    };
                    var some = op switch
                    {
                        QueryOperator.Greater when value.Number >= 0 && value.Number < 1 => true,
                        QueryOperator.GreaterOrEqual when value.Number > 0 && value.Number <= 1 => true,
                        QueryOperator.NotEqual when value.Number == 0 => true,
                        _ => (bool?)null,
                    };
                    if (none == true)
                    {
                        return Exact(LdapFilter.Not(LdapFilter.Present("member")));
                    }
                    if (some == true)
                    {
                        return Exact(LdapFilter.Present("member"));
                    }
                    return Local(clause, recipe, residual, op is QueryOperator.Greater or QueryOperator.GreaterOrEqual && value.Number > 0 ? LdapFilter.Present("member") : null);
                }
            case "empty":
                return Local(clause, recipe, residual, value.Flag ^ (op == QueryOperator.NotEqual) ? LdapFilter.Not(LdapFilter.Present("member")) : null);
            case "lockState" when op == QueryOperator.Equal && value.Text == "Verrouillé":
                notes.Add("lockoutTime seul ne prouve pas un verrouillage : la règle du contrôleur est vérifiée localement.");
                return Local(clause, recipe, residual, Ge("lockoutTime", 1));
            case "passwordState" when op == QueryOperator.Equal && value.Text == "À changer":
                return Exact(Eq("pwdLastSet", "0"));
            case "passwordState" when op == QueryOperator.Equal && value.Text == "N’expire jamais":
                return Local(clause, recipe, residual, Bit(Uac, AdValues.DontExpirePassword));
            case "badPwdCount":
                return Integer(clause, recipe, "badPwdCount", residual);
        }
        if (field.Source == QuerySource.Ad && field.LdapAttribute is { } name && !name.Contains(',', StringComparison.Ordinal) && LdapSchema.Find(name) is { } schema)
        {
            if (op is QueryOperator.IsPresent)
            {
                return Exact(LdapFilter.Present(schema.Name));
            }
            if (op is QueryOperator.IsMissing)
            {
                return Exact(LdapFilter.Not(LdapFilter.Present(schema.Name)));
            }
            if (schema.Syntax == LdapSyntax.Dn && op is not (QueryOperator.Equal or QueryOperator.NotEqual))
            {
                // Active Directory has no substring matching on distinguished names: evaluated locally.
                return Local(clause, recipe, residual, LdapFilter.Present(schema.Name));
            }
            if (field.Kind == QueryFieldKind.Text && schema.Syntax is LdapSyntax.CaseIgnore or LdapSyntax.Dn)
            {
                var filter = ClauseFilter(clause, schema.Name);
                return op == QueryOperator.NotEqual ? Exact(filter, schema.Name) : Exact(filter, schema.Name);
            }
        }
        return Local(clause, recipe, residual);
    }

    private static string DateNote(DateTimeOffset now) =>
        "Dates converties au moment du calcul (" + now.UtcDateTime.ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture) + " UTC) : relancez pour les recalculer.";

    private static Part Integer(QueryClause clause, QueryRecipe recipe, string attribute, List<string> residual)
    {
        var op = clause.Operator;
        if (op is QueryOperator.IsPresent)
        {
            return Exact(LdapFilter.Present(attribute));
        }
        if (op is QueryOperator.IsMissing)
        {
            return Exact(LdapFilter.Not(LdapFilter.Present(attribute)));
        }
        var n = clause.Value.Number;
        var floor = (long)Math.Floor(n);
        var ceiling = (long)Math.Ceiling(n);
        LdapFilter? filter = op switch
        {
            QueryOperator.Equal => n == floor ? Eq(attribute, floor.ToString(CultureInfo.InvariantCulture)) : LdapFilter.Or([]),
            QueryOperator.NotEqual => n == floor ? LdapFilter.Not(Eq(attribute, floor.ToString(CultureInfo.InvariantCulture))) : LdapFilter.Present(attribute),
            QueryOperator.Greater => Ge(attribute, floor + 1),
            QueryOperator.GreaterOrEqual => Ge(attribute, ceiling),
            QueryOperator.Less => Le(attribute, ceiling - 1),
            QueryOperator.LessOrEqual => Le(attribute, floor),
            _ => null,
        };
        return filter is null ? Local(clause, recipe, residual) : Exact(filter, attribute, definite: false);
    }

    // Days since a date attribute (lastLogonTimestamp, pwdLastSet, whenCreated): « more than N days » is « before now − N days ».
    private static Part Days(QueryClause clause, QueryRecipe recipe, string attribute, DateTimeOffset now, List<string> residual, SortedSet<string> notes, bool fileTime, bool positive = false)
    {
        var op = clause.Operator;
        var set = positive ? Ge(attribute, 1) : LdapFilter.Present(attribute);
        if (op is QueryOperator.IsPresent)
        {
            return Exact(set);
        }
        if (op is QueryOperator.IsMissing)
        {
            return Exact(LdapFilter.Not(set));
        }
        if (op is QueryOperator.Equal or QueryOperator.NotEqual)
        {
            return Local(clause, recipe, residual, op == QueryOperator.Equal ? set : null);
        }
        notes.Add(DateNote(now));
        var limit = now - TimeSpan.FromDays((double)clause.Value.Number);
        string Text(DateTimeOffset at, long shift) => fileTime
            ? (LdapEvaluator.FileTime(at) + shift).ToString(CultureInfo.InvariantCulture)
            : LdapEvaluator.FormatTime(at.AddSeconds(shift));
        // More days = an older date.
        var filter = op switch
        {
            QueryOperator.Greater => LdapFilter.Item(LdapFilterKind.LessOrEqual, attribute, Text(limit, -1)),
            QueryOperator.GreaterOrEqual => LdapFilter.Item(LdapFilterKind.LessOrEqual, attribute, Text(limit, 0)),
            QueryOperator.Less => LdapFilter.Item(LdapFilterKind.GreaterOrEqual, attribute, Text(limit, 1)),
            _ => LdapFilter.Item(LdapFilterKind.GreaterOrEqual, attribute, Text(limit, 0)),
        };
        var exact = positive ? LdapFilter.And([set, filter]) : filter;
        return new Part(exact, LdapFilter.Or([exact, LdapFilter.Not(set)]), exact, false, false);
    }

    /// <summary>Removes nested groups of the same kind and single-child groups: « (&amp;(&amp;(a)(b))(c)) » becomes « (&amp;(a)(b)(c)) ».</summary>
    public static LdapFilter Flatten(LdapFilter filter)
    {
        ArgumentNullException.ThrowIfNull(filter);
        if (filter.Kind is not (LdapFilterKind.And or LdapFilterKind.Or or LdapFilterKind.Not))
        {
            return filter;
        }
        var children = filter.Children.Select(Flatten).ToList();
        if (filter.Kind == LdapFilterKind.Not)
        {
            return children[0].Kind == LdapFilterKind.Not ? children[0].Children[0] : LdapFilter.Not(children[0]);
        }
        var merged = new List<LdapFilter>();
        foreach (var child in children)
        {
            if (child.Kind == filter.Kind && child.Children.Length > 0)
            {
                merged.AddRange(child.Children);
            }
            else
            {
                merged.Add(child);
            }
        }
        if (merged.Count == 1)
        {
            return merged[0];
        }
        return filter.Kind == LdapFilterKind.And ? LdapFilter.And(merged) : LdapFilter.Or(merged);
    }

    /// <summary>
    /// Reads an LDAP text into recipe conditions: the class items set the target, known attributes become catalog
    /// conditions, other items raw LDAP conditions. The recipe keeps its name, identifier, distribution and settings.
    /// </summary>
    public static LdapReading Read(string text, QueryRecipe current)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(current);
        LdapFilter filter;
        try
        {
            filter = Flatten(LdapFilterText.Parse(text));
        }
        catch (LdapFilterException ex)
        {
            return new LdapReading(false, ex.Message, ex.Position, null, null, []);
        }
        var warnings = new List<string>();
        var target = current.Target;
        var items = filter.Kind == LdapFilterKind.And ? filter.Children.ToList() : [filter];
        var detected = DetectTarget(items);
        if (detected is QueryTarget found)
        {
            target = found;
        }
        var conditions = items.Where(i => !IsClassItem(i)).ToList();
        foreach (var item in Items(filter))
        {
            if (item.Attribute is { } attribute && LdapSchema.Find(attribute) is null)
            {
                warnings.Add("Attribut « " + attribute + " » inconnu du schéma de Domenia : sa condition restera inconnue en local.");
            }
            else if (item.Attribute is { } known && LdapSchema.Find(known) is { ReadByDomenia: false } notKept)
            {
                warnings.Add("Attribut « " + notKept.Name + " » non conservé par Domenia : évalué par le contrôleur en mode annuaire seulement.");
            }
        }
        var root = conditions.Count switch
        {
            0 => null,
            1 => Map(conditions[0], target, 0),
            _ => QueryNode.Group(QueryNodeKind.All, conditions.Select(c => Map(c, target, 1))),
        };
        var recipe = current with
        {
            Format = QueryRecipe.FormatV3,
            Target = target,
            Junction = QueryJunction.All,
            Clauses = [],
            Expression = null,
            GroupBy = target == current.Target ? current.GroupBy : null,
            ProbeSelection = target == QueryTarget.Computer ? current.ProbeSelection : null,
            ReadDefinition = target == QueryTarget.Computer ? current.ReadDefinition : null,
            Parameters = [],
            ParameterValues = null,
            Refinements = [],
        };
        if (root is not null)
        {
            if (root.Kind == QueryNodeKind.Clause)
            {
                recipe = recipe with { Clauses = [root.Clause!] };
            }
            else if (root.Kind is QueryNodeKind.All or QueryNodeKind.Any && root.Children.All(c => c.Kind == QueryNodeKind.Clause) && root.Children.Length <= QueryLimits.MaxConditions)
            {
                recipe = recipe with { Junction = root.Kind == QueryNodeKind.Any ? QueryJunction.Any : QueryJunction.All, Clauses = [.. root.Children.Select(c => c.Clause!)] };
            }
            else
            {
                recipe = recipe with { Expression = root.Kind is QueryNodeKind.All or QueryNodeKind.Any ? root : QueryNode.Group(QueryNodeKind.All, [root]) };
            }
        }
        if (current.Parameters.Length > 0)
        {
            warnings.Add("Les paramètres de la requête ont été retirés : le texte LDAP porte des valeurs fixes.");
        }
        if (detected is null && filter.Kind is not LdapFilterKind.And)
        {
            warnings.Add("Aucune classe d’objet dans le filtre : la cible « " + QueryTexts.TargetLabel(target) + " » est conservée.");
        }
        return new LdapReading(true, null, null, recipe, LdapFilterText.Pretty(filter), [.. warnings.Distinct(StringComparer.Ordinal)]);
    }

    private static IEnumerable<LdapFilter> Items(LdapFilter filter)
    {
        if (filter.Children.IsDefaultOrEmpty)
        {
            yield return filter;
            yield break;
        }
        foreach (var child in filter.Children)
        {
            foreach (var item in Items(child))
            {
                yield return item;
            }
        }
    }

    private static bool IsClassItem(LdapFilter item) =>
        item.Kind == LdapFilterKind.Equality && item.Attribute is { } a && (a.Equals("objectCategory", StringComparison.OrdinalIgnoreCase) || a.Equals("objectClass", StringComparison.OrdinalIgnoreCase))
        && item.Text.ToUpperInvariant() is "COMPUTER" or "PERSON" or "USER" or "GROUP";

    private static QueryTarget? DetectTarget(List<LdapFilter> items)
    {
        var classes = items.Where(IsClassItem).Select(i => i.Text.ToUpperInvariant()).ToHashSet(StringComparer.Ordinal);
        if (classes.Contains("COMPUTER"))
        {
            return QueryTarget.Computer;
        }
        if (classes.Contains("GROUP"))
        {
            return QueryTarget.Group;
        }
        return classes.Contains("PERSON") || classes.Contains("USER") ? QueryTarget.User : null;
    }

    private static QueryNode Raw(LdapFilter filter) =>
        QueryNode.Leaf(new QueryClause(QueryCatalog.LdapFilterField, QueryOperator.Equal, QueryValue.FromText(LdapFilterText.Format(filter))));

    private static QueryNode Map(LdapFilter filter, QueryTarget target, int depth)
    {
        if (depth >= QueryLimits.MaxTreeDepth - 1)
        {
            return Raw(filter);
        }
        switch (filter.Kind)
        {
            case LdapFilterKind.And:
            case LdapFilterKind.Or:
                return QueryNode.Group(filter.Kind == LdapFilterKind.And ? QueryNodeKind.All : QueryNodeKind.Any, filter.Children.Select(c => Map(c, target, depth + 1)));
            case LdapFilterKind.Not:
                var inner = filter.Children[0];
                if (Negated(inner, target) is { } negated)
                {
                    return negated;
                }
                return QueryNode.Group(QueryNodeKind.Not, [Map(inner, target, depth + 1)]);
        }
        return Positive(filter, target) ?? Raw(filter);
    }

    private static QueryNode Leaf(string field, QueryOperator op, QueryValue value) => QueryNode.Leaf(new QueryClause(field, op, value));

    private static bool IsBit(LdapFilter filter, string attribute, long mask) =>
        filter.Kind == LdapFilterKind.Extensible && filter.MatchingRule == LdapSchema.BitAnd && string.Equals(filter.Attribute, attribute, StringComparison.OrdinalIgnoreCase)
        && long.TryParse(filter.Text.Trim(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value) && value == mask;

    private static QueryNode? Negated(LdapFilter inner, QueryTarget target)
    {
        if (IsBit(inner, Uac, AdValues.AccountDisabled))
        {
            return Leaf("active", QueryOperator.Equal, QueryValue.FromBoolean(true));
        }
        if (inner.Kind == LdapFilterKind.Present && FieldFor(inner.Attribute, target) is { } absent)
        {
            return Leaf(absent.Id, QueryOperator.IsMissing, QueryValue.None);
        }
        if (inner.Kind == LdapFilterKind.Present && LdapSchema.Find(inner.Attribute) is { } attribute)
        {
            return Leaf(QueryCatalog.LdapPrefix + attribute.Name, QueryOperator.IsMissing, QueryValue.None);
        }
        if (inner.Kind == LdapFilterKind.Equality && FieldFor(inner.Attribute, target) is { Kind: QueryFieldKind.Text } different && AbsentIsFalse(different))
        {
            return Leaf(different.Id, QueryOperator.NotEqual, QueryValue.FromText(inner.Text));
        }
        if (inner.Kind == LdapFilterKind.Equality && LdapSchema.Find(inner.Attribute) is { } other)
        {
            return Leaf(QueryCatalog.LdapPrefix + other.Name, QueryOperator.NotEqual, QueryValue.FromText(inner.Text));
        }
        return null;
    }

    private static QueryNode? Positive(LdapFilter filter, QueryTarget target)
    {
        if (IsBit(filter, Uac, AdValues.AccountDisabled))
        {
            return Leaf("active", QueryOperator.Equal, QueryValue.FromBoolean(false));
        }
        if (target == QueryTarget.User && IsBit(filter, Uac, AdValues.DontExpirePassword))
        {
            return Leaf("passwordNeverExpires", QueryOperator.Equal, QueryValue.FromBoolean(true));
        }
        if (target == QueryTarget.Group && filter.Kind == LdapFilterKind.Extensible && string.Equals(filter.Attribute, "groupType", StringComparison.OrdinalIgnoreCase) && filter.MatchingRule == LdapSchema.BitAnd)
        {
            var label = filter.Text.Trim() switch
            {
                "2" => "Global",
                "4" => "Domaine local",
                "8" => "Universel",
                "1" => "Local intégré",
                _ => null,
            };
            if (label is not null)
            {
                return Leaf("scope", QueryOperator.Equal, QueryValue.FromText(label));
            }
            if (filter.Text.Trim() == "2147483648")
            {
                return Leaf("groupKind", QueryOperator.Equal, QueryValue.FromText("Sécurité"));
            }
        }
        if (target != QueryTarget.Computer && filter.Kind == LdapFilterKind.Equality && string.Equals(filter.Attribute, "adminCount", StringComparison.OrdinalIgnoreCase) && filter.Text.Trim() == "1")
        {
            return Leaf("adminCount", QueryOperator.Equal, QueryValue.FromBoolean(true));
        }
        // A catalog information is used only when its local verdict is the LDAP one, absent attribute included; otherwise the
        // raw attribute keeps the semantics of the typed filter (a number left unknown when absent would differ under a NOT).
        var field = FieldFor(filter.Attribute, target) is { } plain && AbsentIsFalse(plain) ? plain : null;
        var attribute = LdapSchema.Find(filter.Attribute);
        if (attribute is null)
        {
            return null;
        }
        var id = field?.Id ?? QueryCatalog.LdapPrefix + attribute.Name;
        switch (filter.Kind)
        {
            case LdapFilterKind.Present:
                return Leaf(id, QueryOperator.IsPresent, QueryValue.None);
            case LdapFilterKind.Equality:
                if (field is { Kind: QueryFieldKind.Number } && decimal.TryParse(filter.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number))
                {
                    return Leaf(id, QueryOperator.Equal, QueryValue.FromNumber(number));
                }
                return field is null or { Kind: QueryFieldKind.Text } ? Leaf(id, QueryOperator.Equal, QueryValue.FromText(filter.Text)) : null;
            case LdapFilterKind.Substring when field is null or { Kind: QueryFieldKind.Text }:
                if (filter.Initial is { } start && filter.Any.IsEmpty && filter.Final is null)
                {
                    return Leaf(id, QueryOperator.StartsWith, QueryValue.FromText(start));
                }
                if (filter.Initial is null && filter.Any.IsEmpty && filter.Final is { } end)
                {
                    return Leaf(id, QueryOperator.EndsWith, QueryValue.FromText(end));
                }
                if (filter.Initial is null && filter.Any.Length == 1 && filter.Final is null)
                {
                    return Leaf(id, QueryOperator.Contains, QueryValue.FromText(filter.Any[0]));
                }
                return null;
            case LdapFilterKind.GreaterOrEqual when field is null:
                return Leaf(id, QueryOperator.GreaterOrEqual, QueryValue.FromText(filter.Text));
            case LdapFilterKind.LessOrEqual when field is null:
                return Leaf(id, QueryOperator.LessOrEqual, QueryValue.FromText(filter.Text));
            case LdapFilterKind.GreaterOrEqual when field is { Kind: QueryFieldKind.Number } && decimal.TryParse(filter.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var low):
                return Leaf(id, QueryOperator.GreaterOrEqual, QueryValue.FromNumber(low));
            case LdapFilterKind.LessOrEqual when field is { Kind: QueryFieldKind.Number } && decimal.TryParse(filter.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var high):
                return Leaf(id, QueryOperator.LessOrEqual, QueryValue.FromNumber(high));
            default:
                return null;
        }
    }

    /// <summary>Catalog information of a target that is the plain copy of an LDAP attribute (name, operatingSystem…).</summary>
    private static QueryField? FieldFor(string? attribute, QueryTarget target)
    {
        if (attribute is null)
        {
            return null;
        }
        return QueryCatalog.Fields(target).FirstOrDefault(f => f.Source == QuerySource.Ad && f.Kind != QueryFieldKind.Boolean
            && string.Equals(f.LdapAttribute, attribute, StringComparison.OrdinalIgnoreCase) && f.Id is not ("laps" or "bitlocker"));
    }
}
