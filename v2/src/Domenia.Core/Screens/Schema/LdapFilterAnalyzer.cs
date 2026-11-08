using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>One node of a parsed filter, with its place in the normalized text (start included, end excluded).</summary>
public sealed record LdapFilterNode(
    LdapFilterNodeKind Kind,
    ImmutableArray<LdapFilterNode> Children,
    string Attribute,
    string Value,
    string Rule,
    bool LeadingWildcard,
    int Start,
    int End,
    int ValueStart);

/// <summary>Result of parsing: never an exception (Domenia 1 ConvertFrom-DomeniaLdapFilter returns {Valid, Error, Root}).</summary>
public sealed record LdapFilterParse(bool Valid, string? Error, int? ErrorPosition, LdapFilterNode? Root, string Text, int Items);

/// <summary>
/// Local analysis of an LDAP filter (Domenia 1 point 29, Domenia-DirectorySchema.Model.ps1): RFC 4515 parser bounded to
/// 32 768 characters, 64 levels and 2 000 elements, index use from the schema read in this session, advice, and the draft
/// insertion of an attribute (SCH-005). Nothing here contacts a controller; nothing ever throws for a bad filter.
/// </summary>
public static partial class LdapFilterAnalyzer
{
    public const int MaxLength = 32768;
    public const int MaxDepth = 64;
    public const int MaxItems = 2000;

    /// <summary>Elements above which the tree of the analysis is not sent to the page.</summary>
    public const int MaxTreeItems = 300;

    [GeneratedRegex("^[A-Za-z][A-Za-z0-9-]*(;[A-Za-z0-9-]+)*$", RegexOptions.CultureInvariant)]
    private static partial Regex AttributePattern();

    [GeneratedRegex(@"^\d+(\.\d+)+$", RegexOptions.CultureInvariant)]
    private static partial Regex OidPattern();

    // ---------------------------------------------------------------- parsing

    /// <summary>Parses a filter; a filter typed without its outer parentheses is completed first.</summary>
    public static LdapFilterParse Parse(string? filter)
    {
        var text = (filter ?? "").Trim();
        if (text.Length == 0)
        {
            return new LdapFilterParse(false, "Filtre vide.", null, null, text, 0);
        }
        if (text.Length > MaxLength)
        {
            return new LdapFilterParse(false, "Filtre trop long" + FrenchText.Colon + FrenchText.Integer(MaxLength) + " caractères au plus.", null, null, "", 0);
        }
        if (!text.StartsWith('('))
        {
            text = "(" + text + ")";
        }
        var state = new ParseState(text);
        try
        {
            var root = ReadNode(state, 0);
            if (state.Pos != text.Length)
            {
                throw new FilterSyntaxException("Texte inattendu après le filtre, position " + Position(state.Pos) + ".", state.Pos);
            }
            return new LdapFilterParse(true, null, null, root, text, state.Items);
        }
        catch (FilterSyntaxException ex)
        {
            return new LdapFilterParse(false, ex.Message, ex.Position, null, text, state.Items);
        }
    }

    private static string Position(int index) => (index + 1).ToString(CultureInfo.InvariantCulture);

    private static LdapFilterNode ReadNode(ParseState state, int depth)
    {
        if (depth > MaxDepth)
        {
            throw new FilterSyntaxException("Filtre trop imbriqué" + FrenchText.Colon + "64 niveaux au plus.", state.Pos);
        }
        state.Items++;
        if (state.Items > MaxItems)
        {
            throw new FilterSyntaxException("Filtre trop long" + FrenchText.Colon + FrenchText.Integer(MaxItems) + " éléments au plus.", state.Pos);
        }
        var text = state.Text;
        if (state.Pos >= text.Length || text[state.Pos] != '(')
        {
            throw new FilterSyntaxException("Parenthèse ouvrante attendue, position " + Position(state.Pos) + ".", state.Pos);
        }
        var start = state.Pos;
        state.Pos++;
        if (state.Pos >= text.Length)
        {
            throw new FilterSyntaxException("Filtre incomplet.", state.Pos);
        }
        var op = text[state.Pos];
        if (op is '&' or '|' or '!')
        {
            state.Pos++;
            var children = ImmutableArray.CreateBuilder<LdapFilterNode>();
            while (state.Pos < text.Length && text[state.Pos] == '(')
            {
                children.Add(ReadNode(state, depth + 1));
            }
            if (state.Pos >= text.Length || text[state.Pos] != ')')
            {
                throw new FilterSyntaxException("Parenthèse fermante attendue, position " + Position(state.Pos) + ".", state.Pos);
            }
            state.Pos++;
            var kind = op switch { '&' => LdapFilterNodeKind.And, '|' => LdapFilterNodeKind.Or, _ => LdapFilterNodeKind.Not };
            if (kind == LdapFilterNodeKind.Not && children.Count != 1)
            {
                throw new FilterSyntaxException("Une négation (!) porte sur un seul filtre.", start + 1);
            }
            if (children.Count < 1)
            {
                throw new FilterSyntaxException("Un ET (&) ou un OU (|) sans filtre est vide.", start + 1);
            }
            return new LdapFilterNode(kind, children.ToImmutable(), "", "", "", false, start, state.Pos, -1);
        }
        // Values escape parentheses as \28 and \29: the first closing parenthesis ends the assertion.
        var end = text.IndexOf(')', state.Pos);
        if (end < 0)
        {
            throw new FilterSyntaxException("Parenthèse fermante manquante.", text.Length);
        }
        var itemStart = state.Pos;
        var item = text[itemStart..end];
        state.Pos = end + 1;
        var open = item.IndexOf('(', StringComparison.Ordinal);
        if (open >= 0)
        {
            throw new FilterSyntaxException("Parenthèse non échappée dans " + FrenchText.Quote(item) + FrenchText.Colon + "écrivez \\28 et \\29.", itemStart + open);
        }
        return ReadItem(item, start, state.Pos, itemStart);
    }

    /// <summary>One simple assertion (ConvertFrom-DomeniaLdapFilterItem).</summary>
    private static LdapFilterNode ReadItem(string item, int start, int end, int itemStart)
    {
        var equal = item.IndexOf('=', StringComparison.Ordinal);
        if (equal <= 0)
        {
            throw new FilterSyntaxException("Assertion sans opérateur" + FrenchText.Colon + FrenchText.Quote(item) + ".", itemStart);
        }
        var left = item[..equal];
        var value = item[(equal + 1)..];
        var kind = LdapFilterNodeKind.Equality;
        var rule = "";
        switch (left[^1])
        {
            case '~':
                kind = LdapFilterNodeKind.Approx;
                left = left[..^1];
                break;
            case '>':
                kind = LdapFilterNodeKind.GreaterOrEqual;
                left = left[..^1];
                break;
            case '<':
                kind = LdapFilterNodeKind.LessOrEqual;
                left = left[..^1];
                break;
            case ':':
                kind = LdapFilterNodeKind.Extensible;
                left = left[..^1];
                break;
            default:
                break;
        }
        var attribute = left;
        if (kind == LdapFilterNodeKind.Extensible)
        {
            var segments = left.Split(':');
            attribute = segments[0];
            rule = string.Join(":", segments.Skip(1).Where(s => s.Length > 0 && !string.Equals(s, "dn", StringComparison.OrdinalIgnoreCase)));
        }
        var attributeOk = AttributePattern().IsMatch(attribute) || OidPattern().IsMatch(attribute) || (kind == LdapFilterNodeKind.Extensible && attribute.Length == 0);
        if (!attributeOk)
        {
            throw new FilterSyntaxException("Nom d’attribut invalide" + FrenchText.Colon + FrenchText.Quote(attribute) + ".", itemStart);
        }
        if (kind == LdapFilterNodeKind.Equality)
        {
            if (value == "*")
            {
                kind = LdapFilterNodeKind.Presence;
            }
            else if (value.Contains('*', StringComparison.Ordinal))
            {
                kind = LdapFilterNodeKind.Substring;
            }
        }
        var name = attribute.Split(';')[0];
        return new LdapFilterNode(kind, [], name, value, rule, kind == LdapFilterNodeKind.Substring && value.StartsWith('*'), start, end, itemStart + equal + 1);
    }

    // ---------------------------------------------------------------- index use

    /// <summary>
    /// Yes: the controller can answer this node from an index; No: it reads every candidate object; Unknown: an attribute is
    /// missing from the schema read in this session, or the schema was not read (Get-DomeniaLdapNodeIndexUse).
    /// </summary>
    public static LdapIndexUse IndexUse(LdapFilterNode node, SchemaCatalog? catalog)
    {
        ArgumentNullException.ThrowIfNull(node);
        switch (node.Kind)
        {
            case LdapFilterNodeKind.Not:
            case LdapFilterNodeKind.Extensible:
                return LdapIndexUse.No;
            case LdapFilterNodeKind.And:
            {
                var uses = node.Children.Select(c => IndexUse(c, catalog)).ToList();
                if (uses.Contains(LdapIndexUse.Yes))
                {
                    return LdapIndexUse.Yes;
                }
                return uses.Contains(LdapIndexUse.Unknown) ? LdapIndexUse.Unknown : LdapIndexUse.No;
            }
            case LdapFilterNodeKind.Or:
            {
                var uses = node.Children.Select(c => IndexUse(c, catalog)).ToList();
                if (uses.Contains(LdapIndexUse.No))
                {
                    return LdapIndexUse.No;
                }
                return uses.Contains(LdapIndexUse.Unknown) ? LdapIndexUse.Unknown : LdapIndexUse.Yes;
            }
            default:
                break;
        }
        // Ambiguous name resolution searches the ANR attributes, which the directory indexes for that purpose.
        if (string.Equals(node.Attribute, "anr", StringComparison.OrdinalIgnoreCase) && node.Kind is LdapFilterNodeKind.Equality or LdapFilterNodeKind.Substring)
        {
            return LdapIndexUse.Yes;
        }
        // Every object carries objectClass and objectCategory: their presence (=*) selects the whole scope.
        if (node.Kind == LdapFilterNodeKind.Presence && IsClassAttribute(node.Attribute))
        {
            return LdapIndexUse.No;
        }
        var attribute = catalog?.FindAttribute(node.Attribute);
        if (attribute is null)
        {
            return LdapIndexUse.Unknown;
        }
        if (attribute.Constructed || !attribute.Indexed)
        {
            return LdapIndexUse.No;
        }
        if (node.Kind == LdapFilterNodeKind.Substring && node.LeadingWildcard)
        {
            return attribute.TupleIndexed ? LdapIndexUse.Yes : LdapIndexUse.No;
        }
        return LdapIndexUse.Yes;
    }

    private static bool IsClassAttribute(string name) =>
        string.Equals(name, "objectClass", StringComparison.OrdinalIgnoreCase) || string.Equals(name, "objectCategory", StringComparison.OrdinalIgnoreCase);

    /// <summary>Assertions of a filter with whether a negation covers them (Get-DomeniaLdapFilterLeaves).</summary>
    public static IEnumerable<(LdapFilterNode Node, bool Negated)> Leaves(LdapFilterNode? node, bool negated = false)
    {
        if (node is null)
        {
            yield break;
        }
        if (node.Kind is LdapFilterNodeKind.And or LdapFilterNodeKind.Or or LdapFilterNodeKind.Not)
        {
            foreach (var child in node.Children)
            {
                foreach (var leaf in Leaves(child, negated || node.Kind == LdapFilterNodeKind.Not))
                {
                    yield return leaf;
                }
            }
            yield break;
        }
        yield return (node, negated);
    }

    // ---------------------------------------------------------------- analysis

    /// <summary>
    /// What a filter costs before it is sent (Get-DomeniaLdapFilterAnalysis). Index use comes from the schema read in this
    /// session; without it the answer stays unknown and says so.
    /// </summary>
    public static LdapFilterAnalysis Analyze(string? filter, SchemaCatalog? catalog)
    {
        var parsed = Parse(filter);
        if (!parsed.Valid || parsed.Root is null)
        {
            var message = "Filtre non valide" + FrenchText.Colon + parsed.Error;
            return new LdapFilterAnalysis(
                false, parsed.Error, parsed.ErrorPosition, parsed.Text.Length == 0 ? null : parsed.Text, LdapFilterLevel.Invalid, LevelLabel(LdapFilterLevel.Invalid),
                Tone.Alert, LdapIndexUse.Unknown, catalog is not null, [], [], [], [], [], [], 0, 0, [message], message, null, null);
        }
        var attributes = new List<string>();
        var notIndexed = new List<string>();
        var unknown = new List<string>();
        var leading = new List<string>();
        var constructed = new List<string>();
        var confidential = new List<string>();
        int negations = 0, extensible = 0;
        foreach (var (node, negated) in Leaves(parsed.Root))
        {
            var name = node.Attribute;
            if (negated)
            {
                negations++;
            }
            if (node.Kind == LdapFilterNodeKind.Extensible)
            {
                extensible++;
            }
            AddOnce(attributes, name);
            if (node.LeadingWildcard)
            {
                AddOnce(leading, name);
            }
            if (name.Length == 0 || string.Equals(name, "anr", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            var attribute = catalog?.FindAttribute(name);
            if (attribute is null)
            {
                AddOnce(unknown, name);
                continue;
            }
            if (attribute.Constructed)
            {
                AddOnce(constructed, name);
            }
            if (!attribute.Indexed)
            {
                AddOnce(notIndexed, name);
            }
            if (attribute.Confidential)
            {
                AddOnce(confidential, name);
            }
        }
        var use = IndexUse(parsed.Root, catalog);
        var level = use switch { LdapIndexUse.Yes => LdapFilterLevel.Targeted, LdapIndexUse.No => LdapFilterLevel.Broad, _ => LdapFilterLevel.Unknown };
        var advice = new List<string>();
        if (catalog is null)
        {
            advice.Add("Index non vérifiés : lisez le schéma de l’annuaire (bouton " + FrenchText.Quote("Lire le schéma") + ") pour savoir quels attributs sont indexés.");
        }
        if (use == LdapIndexUse.Yes)
        {
            advice.Add("Filtre ciblé : un critère indexé limite les objets examinés par le contrôleur.");
        }
        else if (use == LdapIndexUse.No)
        {
            advice.Add("Filtre large : le contrôleur examine chaque objet du périmètre. Ajoutez un critère indexé (égalité ou début de valeur), ou limitez la recherche à une OU.");
        }
        else if (catalog is not null)
        {
            advice.Add(unknown.Count switch
            {
                0 => "Coût indéterminé.",
                1 => "Coût indéterminé : " + unknown[0] + " est absent du schéma lu.",
                _ => "Coût indéterminé : " + string.Join(", ", unknown) + " sont absents du schéma lu.",
            });
        }
        if (leading.Count > 0)
        {
            advice.Add("Joker en tête sur " + string.Join(", ", leading) + " : cette sous-chaîne n’utilise pas l’index habituel.");
        }
        if (negations > 0)
        {
            advice.Add("La négation (!) n’utilise aucun index : gardez-la à côté d’un critère indexé.");
        }
        if (extensible > 0)
        {
            advice.Add("Règle de correspondance (par exemple sur les bits de userAccountControl) : évaluée objet par objet.");
        }
        if (constructed.Count > 0)
        {
            advice.Add("Attribut calculé " + string.Join(", ", constructed) + " : le contrôleur ne l’évalue pas dans un filtre ; utilisez l’attribut stocké correspondant.");
        }
        if (confidential.Count > 0)
        {
            advice.Add("Attribut confidentiel " + string.Join(", ", confidential) + " : sans droit de lecture particulier, ce critère ne retient aucun objet.");
        }
        var text = "Coût LDAP" + FrenchText.Colon + LevelLabel(level) + ". " + string.Join(" ", advice);
        var tree = parsed.Items <= MaxTreeItems ? View(parsed.Root, parsed.Text, catalog, false) : null;
        return new LdapFilterAnalysis(
            true, null, null, parsed.Text, level, LevelLabel(level), LevelTone(level), use, catalog is not null, [.. attributes], [.. notIndexed], [.. unknown],
            [.. leading], [.. constructed], [.. confidential], negations, extensible, [.. advice], text, tree, Suggest(parsed, catalog));
    }

    private static void AddOnce(List<string> list, string name)
    {
        if (name.Length > 0 && !list.Contains(name, StringComparer.Ordinal))
        {
            list.Add(name);
        }
    }

    public static string LevelLabel(LdapFilterLevel level) => level switch
    {
        LdapFilterLevel.Targeted => "Ciblé",
        LdapFilterLevel.Broad => "Large",
        LdapFilterLevel.Unknown => "Inconnu",
        _ => "Invalide",
    };

    public static Tone LevelTone(LdapFilterLevel level) => level switch
    {
        LdapFilterLevel.Targeted => Tone.Ok,
        LdapFilterLevel.Broad => Tone.Warn,
        LdapFilterLevel.Unknown => Tone.Info,
        _ => Tone.Alert,
    };

    private static string KindLabel(LdapFilterNodeKind kind) => kind switch
    {
        LdapFilterNodeKind.And => "Tous les critères (ET)",
        LdapFilterNodeKind.Or => "Au moins un critère (OU)",
        LdapFilterNodeKind.Not => "Négation (NON)",
        LdapFilterNodeKind.Equality => "Égalité",
        LdapFilterNodeKind.Presence => "Présence",
        LdapFilterNodeKind.Substring => "Sous-chaîne",
        LdapFilterNodeKind.GreaterOrEqual => "Supérieur ou égal",
        LdapFilterNodeKind.LessOrEqual => "Inférieur ou égal",
        LdapFilterNodeKind.Approx => "Approché",
        _ => "Règle de correspondance",
    };

    private static string IndexLabel(LdapIndexUse use) => use switch
    {
        LdapIndexUse.Yes => "Index utilisé",
        LdapIndexUse.No => "Objet par objet",
        _ => "Index inconnu",
    };

    private static LdapFilterNodeView View(LdapFilterNode node, string text, SchemaCatalog? catalog, bool negated)
    {
        var use = IndexUse(node, catalog);
        var leaf = node.Kind is not (LdapFilterNodeKind.And or LdapFilterNodeKind.Or or LdapFilterNodeKind.Not);
        var children = node.Children.Select(c => View(c, text, catalog, negated || node.Kind == LdapFilterNodeKind.Not)).ToImmutableArray();
        return new LdapFilterNodeView(
            node.Kind, KindLabel(node.Kind), text[node.Start..node.End], leaf ? node.Attribute : null, leaf ? node.Value : null,
            node.Rule.Length > 0 ? node.Rule : null, negated, node.LeadingWildcard, use, IndexLabel(use), children);
    }

    // ---------------------------------------------------------------- suggested rewriting (improvement of SCH-006)

    /// <summary>Constructed attributes with a stored equivalent that carries exactly the same value.</summary>
    private static readonly FrozenDictionary<string, string> ExactEquivalents = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["createTimeStamp"] = "whenCreated",
        ["modifyTimeStamp"] = "whenChanged",
    }.ToFrozenDictionary(StringComparer.OrdinalIgnoreCase);

    /// <summary>Constructed attributes and the stored attribute to filter on instead (different values: advice only).</summary>
    private static readonly FrozenDictionary<string, string> StoredAdvice = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["msDS-User-Account-Control-Computed"] = "filtrez sur userAccountControl (le verrouillage se lit dans lockoutTime)",
        ["msDS-UserPasswordExpiryTimeComputed"] = "filtrez sur pwdLastSet",
        ["canonicalName"] = "filtrez sur distinguishedName ou limitez la recherche à l’OU",
        ["tokenGroups"] = "filtrez sur memberOf, ou avec la règle 1.2.840.113556.1.4.1941 pour l’appartenance imbriquée",
        ["primaryGroupToken"] = "filtrez sur primaryGroupID",
        ["msDS-PrincipalName"] = "filtrez sur sAMAccountName",
    }.ToFrozenDictionary(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Conservative rewriting: objectCategory added next to objectClass, exact stored equivalent of a constructed attribute,
    /// leading wildcard removed on an indexed text attribute (the operator checks the values still start that way). Only a
    /// rewriting that parses again is proposed; otherwise the reasons stay as advice.
    /// </summary>
    public static LdapFilterSuggestion? Suggest(LdapFilterParse parsed, SchemaCatalog? catalog)
    {
        ArgumentNullException.ThrowIfNull(parsed);
        if (!parsed.Valid || parsed.Root is null)
        {
            return null;
        }
        var root = parsed.Root;
        var text = parsed.Text;
        var reasons = new List<string>();
        var edits = new List<(int At, int Remove, string Insert)>();
        var leaves = Leaves(root).ToList();

        // 1. objectClass without objectCategory: the category is indexed. Proposed when no index serves the filter, or when the
        //    category leaves derived classes out (a computer is also of class user): the reason then names what it leaves out,
        //    so that the rewriting never changes the meaning of the filter silently.
        var level = root.Kind == LdapFilterNodeKind.And ? root.Children : [root];
        var classLeaf = level.FirstOrDefault(n => n.Kind == LdapFilterNodeKind.Equality && string.Equals(n.Attribute, "objectClass", StringComparison.OrdinalIgnoreCase)
            && SchemaRules.UsualCategory(n.Value) is not null);
        var hasCategory = level.Any(n => string.Equals(n.Attribute, "objectCategory", StringComparison.OrdinalIgnoreCase));
        var categoryAttribute = catalog?.FindAttribute("objectCategory");
        if (classLeaf is not null && !hasCategory && (catalog is null || categoryAttribute is { Indexed: true }))
        {
            var category = SchemaRules.UsualCategory(classLeaf.Value)!;
            var excluded = SchemaRules.CategoryExclusions(classLeaf.Value, catalog);
            if (!excluded.IsEmpty || IndexUse(root, catalog) != LdapIndexUse.Yes)
            {
                var clause = "(objectCategory=" + category + ")";
                if (root.Kind == LdapFilterNodeKind.And)
                {
                    edits.Add((root.Start + 2, 0, clause));
                }
                else
                {
                    edits.Add((root.Start, 0, "(&" + clause));
                    edits.Add((root.End, 0, ")"));
                }
                reasons.Add(excluded.IsEmpty
                    ? clause + " est indexé" + FrenchText.Colon + "il limite les objets examinés par le contrôleur, sans changer le résultat."
                    : clause + " cible la catégorie, indexée, mais écarte " + SchemaRules.ClassList(excluded)
                        + (excluded.Length > 1 ? ", qui dérivent de " : ", qui dérive de ") + classLeaf.Value + " avec une autre catégorie"
                        + FrenchText.Colon + "gardez objectClass seul pour " + (excluded.Length > 1 ? "les inclure." : "l’inclure."));
            }
        }

        // 2. Constructed attributes.
        foreach (var (node, _) in leaves)
        {
            if (ExactEquivalents.TryGetValue(node.Attribute, out var stored))
            {
                edits.Add((node.Start + 1, node.Attribute.Length, stored));
                reasons.Add(node.Attribute + " est calculé : " + stored + " porte la même date et se filtre.");
            }
            else if (StoredAdvice.TryGetValue(node.Attribute, out var advice))
            {
                reasons.Add(node.Attribute + " est calculé et ne se filtre pas : " + advice + ".");
            }
        }

        // 3. Leading wildcard on an indexed text attribute without substring index.
        foreach (var (node, negated) in leaves)
        {
            if (negated || !node.LeadingWildcard || node.Value.Length < 2 || node.Value[1] == '*' || node.ValueStart < 0)
            {
                continue;
            }
            var attribute = catalog?.FindAttribute(node.Attribute);
            if (attribute is not { Indexed: true, TupleIndexed: false, Constructed: false, Kind: SchemaSyntaxKind.Text })
            {
                continue;
            }
            edits.Add((node.ValueStart, 1, ""));
            reasons.Add("Sans joker en tête, " + node.Attribute + "=" + node.Value[1..] + " utilise l’index : vérifiez que les valeurs commencent bien ainsi.");
        }

        // 4. A filter made of a negation only reads the whole scope.
        if (root.Kind == LdapFilterNodeKind.Not)
        {
            reasons.Add("Un filtre fait seulement d’une négation lit tout le périmètre : ajoutez un critère indexé, par exemple (objectCategory=person).");
        }

        if (reasons.Count == 0)
        {
            return null;
        }
        string? rewritten = null;
        if (edits.Count > 0)
        {
            var builder = new StringBuilder(text);
            foreach (var (at, remove, insert) in edits.OrderByDescending(e => e.At).ThenByDescending(e => e.Remove))
            {
                builder.Remove(at, remove).Insert(at, insert);
            }
            var candidate = builder.ToString();
            if (!string.Equals(candidate, text, StringComparison.Ordinal) && Parse(candidate).Valid)
            {
                rewritten = candidate;
            }
        }
        return new LdapFilterSuggestion(rewritten, [.. reasons]);
    }

    // ---------------------------------------------------------------- insertion (SCH-005)

    /// <summary>
    /// Adds the example clause of an attribute to the filter draft (Add-DomeniaAdSchemaAttributeToFilter): inside the existing
    /// AND, or by creating one; the operator completes the value. Nothing is executed.
    /// </summary>
    public static SchemaFilterInsertResult Insert(string? filter, SchemaAttribute attribute, SchemaCatalog catalog)
    {
        ArgumentNullException.ThrowIfNull(attribute);
        ArgumentNullException.ThrowIfNull(catalog);
        var current = (filter ?? "").Trim();
        var (insertable, reason) = SchemaRules.Insertable(attribute);
        var hint = SchemaRules.QueryHint(attribute);
        if (!insertable || hint.Example.Length == 0)
        {
            var message = reason ?? (hint.Notes.Length > 0 ? hint.Notes[0] : "Attribut inutilisable dans un filtre.");
            return new SchemaFilterInsertResult(current, false, message, Analyze(current.Length == 0 ? null : current, catalog));
        }
        // A filter typed without its outer parentheses is completed first, exactly as the analysis reads it.
        if (current.Length > 0 && !current.StartsWith('('))
        {
            current = "(" + current + ")";
        }
        string next;
        if (current.Length == 0)
        {
            next = hint.Example;
        }
        else
        {
            var parsed = Parse(current);
            next = parsed is { Valid: true, Root.Kind: LdapFilterNodeKind.And }
                ? current[..^1] + hint.Example + ")"
                : "(&" + current + hint.Example + ")";
        }
        if (next.Length > MaxLength)
        {
            return new SchemaFilterInsertResult(current, false, "Filtre trop long" + FrenchText.Colon + FrenchText.Integer(MaxLength) + " caractères au plus.", Analyze(current, catalog));
        }
        var added = "Critère " + hint.Example + " ajouté au filtre : complétez la valeur avant de l’utiliser.";
        return new SchemaFilterInsertResult(next, true, added, Analyze(next, catalog));
    }

    private sealed class ParseState(string text)
    {
        public string Text { get; } = text;

        public int Pos { get; set; }

        public int Items { get; set; }
    }

    /// <summary>Syntax error with its position in the normalized text; caught by <see cref="Parse"/>, never leaves it.</summary>
    private sealed class FilterSyntaxException(string message, int position) : Exception(message)
    {
        public int Position { get; } = position;
    }
}
