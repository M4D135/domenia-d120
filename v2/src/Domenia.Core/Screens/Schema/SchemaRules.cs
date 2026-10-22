using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// Pure rules of the schema screen, ported from Domenia 1 (Domenia-DirectorySchema.Model.ps1, point 28): syntax in plain
/// words, decoded flags, catalog, attributes a class may carry, filtering of the list, details and filter hints. No LDAP,
/// no disk, no clock: values already read only.
/// </summary>
public static partial class SchemaRules
{
    /// <summary>Most rows of a list (Domenia 1 Find-DomeniaAdSchemaEntries accepts 1 to 5 000; 500 by default).</summary>
    public const int MaxListLimit = 5000;

    public const int DefaultListLimit = 500;

    /// <summary>Longest filter text of the list (Domenia 1 TxtAdSchemaFilter MaxLength).</summary>
    public const int MaxListText = 128;

    /// <summary>Classes walked at most for one class (a schema loop never hangs the engine).</summary>
    public const int MaxClassWalk = 256;

    /// <summary>Longest description kept (Domenia 1 ConvertTo-DomeniaFlatText … 500).</summary>
    public const int MaxDescription = 500;

    /// <summary>Classes listed at most under « Utilisé par ».</summary>
    public const int MaxUsedBy = 60;

    [GeneratedRegex("^[A-Za-z0-9-]{1,128}$", RegexOptions.CultureInvariant)]
    private static partial Regex NamePattern();

    public static bool IsValidName(string? name) => name is not null && NamePattern().IsMatch(name);

    // ---------------------------------------------------------------- syntax

    /// <summary>attributeSyntax OID in plain words (Get-DomeniaAdSyntaxLabel).</summary>
    public static string SyntaxLabel(string? attributeSyntax) => (attributeSyntax ?? "").Trim() switch
    {
        "2.5.5.1" => "Référence à un objet (DN)",
        "2.5.5.2" => "Identifiant OID",
        "2.5.5.3" => "Texte sensible à la casse",
        "2.5.5.4" => "Texte (Teletex)",
        "2.5.5.5" => "Texte ASCII (IA5 ou imprimable)",
        "2.5.5.6" => "Texte numérique",
        "2.5.5.7" => "Référence avec données (DN binaire)",
        "2.5.5.8" => "Booléen",
        "2.5.5.9" => "Entier",
        "2.5.5.10" => "Octets",
        "2.5.5.11" => "Date et heure",
        "2.5.5.12" => "Texte Unicode",
        "2.5.5.13" => "Adresse de présentation",
        "2.5.5.14" => "Référence avec texte (DN chaîne)",
        "2.5.5.15" => "Descripteur de sécurité",
        "2.5.5.16" => "Grand entier (compteur ou date FILETIME)",
        "2.5.5.17" => "SID",
        _ => "Syntaxe non reconnue",
    };

    /// <summary>Family used to suggest a filter (Get-DomeniaAdSyntaxKind).</summary>
    public static SchemaSyntaxKind SyntaxKind(string? attributeSyntax) => (attributeSyntax ?? "").Trim() switch
    {
        "2.5.5.1" or "2.5.5.7" or "2.5.5.14" => SchemaSyntaxKind.Dn,
        "2.5.5.2" or "2.5.5.3" or "2.5.5.4" or "2.5.5.5" or "2.5.5.6" or "2.5.5.12" => SchemaSyntaxKind.Text,
        "2.5.5.8" => SchemaSyntaxKind.Bool,
        "2.5.5.9" => SchemaSyntaxKind.Int,
        "2.5.5.16" => SchemaSyntaxKind.LargeInt,
        "2.5.5.11" => SchemaSyntaxKind.Time,
        "2.5.5.10" or "2.5.5.15" => SchemaSyntaxKind.Binary,
        "2.5.5.17" => SchemaSyntaxKind.Sid,
        _ => SchemaSyntaxKind.Other,
    };

    /// <summary>Short French name of a syntax family (overview of the screen).</summary>
    public static string SyntaxFamilyLabel(SchemaSyntaxKind kind) => kind switch
    {
        SchemaSyntaxKind.Dn => "Référence (DN)",
        SchemaSyntaxKind.Text => "Texte",
        SchemaSyntaxKind.Bool => "Booléen",
        SchemaSyntaxKind.Int => "Entier",
        SchemaSyntaxKind.LargeInt => "Grand entier",
        SchemaSyntaxKind.Time => "Date et heure",
        SchemaSyntaxKind.Binary => "Octets",
        SchemaSyntaxKind.Sid => "SID",
        _ => "Autre",
    };

    // ---------------------------------------------------------------- flags

    /// <summary>searchFlags bits (ConvertFrom-DomeniaAdSearchFlags).</summary>
    public static SchemaSearchFlags SearchFlags(long value) => new(
        (value & 1) != 0, (value & 2) != 0, (value & 4) != 0, (value & 8) != 0, (value & 16) != 0,
        (value & 32) != 0, (value & 64) != 0, (value & 128) != 0, (value & 256) != 0, (value & 512) != 0);

    /// <summary>systemFlags bits (ConvertFrom-DomeniaAdSystemFlags).</summary>
    public static SchemaSystemFlags SystemFlags(long value) => new(
        (value & 1) != 0, (value & 2) != 0, (value & 4) != 0, (value & 8) != 0, (value & 16) != 0, (value & 32) != 0);

    /// <summary>objectClassCategory (Get-DomeniaAdClassCategoryLabel): missing means structural, like Domenia 1.</summary>
    public static SchemaClassCategory ClassCategory(int? category) => (category ?? 1) switch
    {
        0 => SchemaClassCategory.Class88,
        1 => SchemaClassCategory.Structural,
        2 => SchemaClassCategory.Abstract,
        3 => SchemaClassCategory.Auxiliary,
        _ => SchemaClassCategory.Unknown,
    };

    public static string ClassCategoryLabel(SchemaClassCategory category) => category switch
    {
        SchemaClassCategory.Class88 => "Classe 88",
        SchemaClassCategory.Structural => "Structurelle",
        SchemaClassCategory.Abstract => "Abstraite",
        SchemaClassCategory.Auxiliary => "Auxiliaire",
        _ => "Inconnue",
    };

    // ---------------------------------------------------------------- catalog

    /// <summary>
    /// Indexes the schema read once (ConvertTo-DomeniaAdSchemaCatalog): names outside [A-Za-z0-9-]{1,128} are skipped,
    /// descriptions are flattened to one line of 500 characters at most, defunct entries are kept and flagged.
    /// </summary>
    public static SchemaCatalog BuildCatalog(SchemaReadResult read)
    {
        ArgumentNullException.ThrowIfNull(read);
        var attributes = new Dictionary<string, SchemaAttribute>(StringComparer.OrdinalIgnoreCase);
        foreach (var a in read.Attributes)
        {
            if (a is null || !IsValidName(a.Name))
            {
                continue;
            }
            var search = SearchFlags(a.SearchFlags ?? 0);
            var system = SystemFlags(a.SystemFlags ?? 0);
            attributes[a.Name] = new SchemaAttribute(
                a.Name, FlatText(a.Description), CleanOid(a.Oid), (a.Syntax ?? "").Trim(), SyntaxLabel(a.Syntax), SyntaxKind(a.Syntax), a.OmSyntax,
                a.SingleValued, search.Indexed, search.TupleIndexed, search.ContainerIndexed, search.Anr, search.Confidential, system.Constructed,
                system.NotReplicated, a.InGlobalCatalog, (a.LinkId ?? 0) != 0, a.LinkId is 0 ? null : a.LinkId, a.Defunct, a.RangeLower, a.RangeUpper,
                search.PreserveOnDelete, search.RodcFiltered, system.BaseSchema);
        }
        var classes = new Dictionary<string, SchemaClass>(StringComparer.OrdinalIgnoreCase);
        foreach (var c in read.Classes)
        {
            if (c is null || !IsValidName(c.Name))
            {
                continue;
            }
            var category = ClassCategory(c.Category);
            classes[c.Name] = new SchemaClass(
                c.Name, FlatText(c.Description), CleanOid(c.Oid), ValidOrEmpty(c.SubClassOf), Names(c.Auxiliary), Names(c.Must), Names(c.May),
                category, ClassCategoryLabel(category), c.Defunct);
        }
        return new SchemaCatalog(
            attributes.ToFrozenDictionary(StringComparer.OrdinalIgnoreCase),
            classes.ToFrozenDictionary(StringComparer.OrdinalIgnoreCase),
            read.Server, read.ObservedAt, read.Truncated, read.DurationMs, read.DomainDn);
    }

    /// <summary>One line, 500 characters at most (ConvertTo-DomeniaFlatText).</summary>
    public static string FlatText(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }
        var flat = WhiteSpaceRun().Replace(text, " ").Trim();
        return flat.Length > MaxDescription ? flat[..MaxDescription] : flat;
    }

    [GeneratedRegex(@"[\r\n\t ]+", RegexOptions.CultureInvariant)]
    private static partial Regex WhiteSpaceRun();

    [GeneratedRegex(@"^\d+(\.\d+)+$", RegexOptions.CultureInvariant)]
    private static partial Regex OidPattern();

    private static string? CleanOid(string? oid) => oid is not null && OidPattern().IsMatch(oid.Trim()) ? oid.Trim() : null;

    private static string ValidOrEmpty(string? name) => IsValidName(name?.Trim()) ? name!.Trim() : "";

    /// <summary>Distinct valid names, in the order read (Get-SchemaNames of the worker).</summary>
    private static ImmutableArray<string> Names(ImmutableArray<string> names)
    {
        if (names.IsDefaultOrEmpty)
        {
            return [];
        }
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = ImmutableArray.CreateBuilder<string>();
        foreach (var name in names)
        {
            if (IsValidName(name) && seen.Add(name))
            {
                result.Add(name);
            }
        }
        return result.ToImmutable();
    }

    // ---------------------------------------------------------------- texts of one attribute

    /// <summary>Index in plain words (Get-DomeniaAdAttributeIndexText).</summary>
    public static string IndexText(SchemaAttribute? attribute)
    {
        if (attribute is null)
        {
            return "Inconnu";
        }
        if (attribute.Constructed)
        {
            return "Calculé, non filtrable";
        }
        if (attribute.Indexed)
        {
            return attribute.TupleIndexed ? "Indexé, sous-chaîne comprise" : "Indexé";
        }
        return "Non indexé";
    }

    /// <summary>
    /// How to use one attribute in an LDAP filter (Get-DomeniaAdAttributeQueryHint): an example clause by syntax and what the
    /// schema says about its cost. A constructed attribute has no example: it is never a filter criterion.
    /// </summary>
    public static SchemaQueryHint QueryHint(SchemaAttribute? attribute)
    {
        if (attribute is null)
        {
            return new SchemaQueryHint("", ["Attribut inconnu du schéma lu."]);
        }
        var name = attribute.Name;
        var notes = new List<string>();
        var example = "(" + name + "=valeur*)";
        switch (attribute.Kind)
        {
            case SchemaSyntaxKind.Bool:
                example = "(" + name + "=TRUE)";
                break;
            case SchemaSyntaxKind.Dn:
                example = "(" + name + "=CN=…,OU=…,DC=…)";
                notes.Add("Valeur exacte : le chemin LDAP complet de l’objet visé, sans joker.");
                break;
            case SchemaSyntaxKind.Int:
                example = "(" + name + ">=1)";
                break;
            case SchemaSyntaxKind.LargeInt:
                example = "(" + name + ">=133000000000000000)";
                notes.Add("Une date y est un nombre FILETIME : intervalles de 100 ns depuis le 01/01/1601 UTC.");
                break;
            case SchemaSyntaxKind.Time:
                example = "(" + name + ">=20260101000000.0Z)";
                notes.Add("Date au format AAAAMMJJhhmmss.0Z, en UTC.");
                break;
            case SchemaSyntaxKind.Sid:
                example = "(" + name + "=S-1-5-21-…)";
                break;
            case SchemaSyntaxKind.Binary:
                example = "(" + name + "=\\00\\01…)";
                notes.Add("Octets écrits en hexadécimal échappé (\\xx).");
                break;
            default:
                break;
        }
        if (attribute.Constructed)
        {
            notes.Insert(0, "Attribut calculé par le contrôleur : il se lit, mais il ne sert pas de critère de filtre.");
            example = "";
        }
        else if (attribute.Indexed)
        {
            notes.Add("Attribut indexé : une égalité ou un début de valeur limite les objets que le contrôleur examine.");
            if (attribute.Kind == SchemaSyntaxKind.Text && !attribute.TupleIndexed)
            {
                notes.Add("Un joker en tête (*valeur) n’utilise pas cet index.");
            }
        }
        else
        {
            notes.Add("Attribut non indexé : combinez-le avec un critère sur un attribut indexé, ou limitez la recherche à une OU.");
        }
        if (!attribute.SingleValued)
        {
            notes.Add("Plusieurs valeurs possibles : le filtre retient l’objet dès qu’une valeur correspond.");
        }
        if (attribute.Confidential)
        {
            notes.Add("Attribut confidentiel : sans droit de lecture particulier, un filtre sur cet attribut ne retient aucun objet.");
        }
        if (attribute.NotReplicated)
        {
            notes.Add("Non répliqué : chaque contrôleur a sa propre valeur.");
        }
        if (attribute.Linked)
        {
            notes.Add("Attribut lié : sa valeur est maintenue par le contrôleur à partir de l’attribut associé.");
        }
        if (attribute.Defunct)
        {
            notes.Insert(0, "Attribut obsolète dans ce schéma : ne l’utilisez pas dans une nouvelle requête.");
        }
        return new SchemaQueryHint(example, [.. notes]);
    }

    // ---------------------------------------------------------------- list

    /// <summary>
    /// Classes or attributes whose name or description contains <paramref name="text"/> (Find-DomeniaAdSchemaEntries, case
    /// ignored): every match is counted, only the first <paramref name="limit"/> become rows; names come sorted from the catalog.
    /// </summary>
    public static SchemaListResult FindEntries(SchemaCatalog catalog, string? text, bool attributes, int limit)
    {
        ArgumentNullException.ThrowIfNull(catalog);
        limit = Math.Clamp(limit, 1, MaxListLimit);
        var term = (text ?? "").Trim();
        var rows = ImmutableArray.CreateBuilder<SchemaListRow>();
        var total = 0;
        foreach (var name in attributes ? catalog.AttributeNames : catalog.ClassNames)
        {
            string description;
            if (attributes)
            {
                description = catalog.Attributes[name].Description;
            }
            else
            {
                description = catalog.Classes[name].Description;
            }
            if (term.Length > 0 && !name.Contains(term, StringComparison.OrdinalIgnoreCase) && !description.Contains(term, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            total++;
            if (rows.Count >= limit)
            {
                continue;
            }
            rows.Add(attributes ? AttributeRow(catalog.Attributes[name]) : ClassRow(catalog.Classes[name]));
        }
        var kind = attributes ? "attributes" : "classes";
        return new SchemaListResult(kind, term, total, rows.Count, limit, ListSummary(attributes, total, rows.Count), rows.ToImmutable());
    }

    /// <summary>« 12 classes trouvées. » or « 1 234 attributs trouvés, 500 affichés : précisez le filtre. »</summary>
    public static string ListSummary(bool attributes, int total, int shown)
    {
        var text = attributes
            ? FrenchText.Count(total, "attribut trouvé", "attributs trouvés")
            : FrenchText.Count(total, "classe trouvée", "classes trouvées");
        if (total > shown)
        {
            text += ", " + FrenchText.Count(shown, attributes ? "affiché" : "affichée", attributes ? "affichés" : "affichées") + FrenchText.Colon + "précisez le filtre";
        }
        return text + ".";
    }

    private static SchemaListRow ClassRow(SchemaClass c) => new(
        c.Name, "class", c.Defunct ? "Obsolète" : c.CategoryLabel, c.SubClassOf.Length > 0 ? "Hérite de " + c.SubClassOf : "Classe racine",
        c.Description, c.Defunct, c.CategoryLabel, c.SubClassOf, null, null, null, null, null, null, null);

    private static SchemaListRow AttributeRow(SchemaAttribute a) => new(
        a.Name, "attribute", a.Defunct ? "Obsolète" : a.SyntaxLabel, (a.SingleValued ? "Une valeur" : "Plusieurs valeurs") + " · " + IndexText(a),
        a.Description, a.Defunct, null, null, a.SyntaxLabel, IndexText(a), a.SingleValued, a.Indexed && !a.Constructed, a.InGlobalCatalog,
        a.Confidential, a.Constructed);

    // ---------------------------------------------------------------- class

    /// <summary>
    /// Attributes an object of the class may carry (Get-DomeniaAdClassAttributes): its own mustContain and mayContain, those of
    /// its superclasses up to top and of the auxiliary classes, mandatory first; bounded to 256 classes.
    /// </summary>
    public static SchemaClassDetail ClassDetail(SchemaCatalog catalog, string className)
    {
        ArgumentNullException.ThrowIfNull(catalog);
        var root = catalog.FindClass(className) ?? throw new DomeniaOperationException(SchemaErrors.UnknownClass, SchemaErrors.UnknownClassMessage);
        var found = new Dictionary<string, (string Name, bool Required, string Origin, int Order)>(StringComparer.OrdinalIgnoreCase);
        var chain = new List<string>();
        var lineage = new List<SchemaLineageItem>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var queue = new Queue<(string Name, string Relation, string? Via, int Depth)>();
        queue.Enqueue((root.Name, "self", null, 0));
        var walkTruncated = false;
        while (queue.Count > 0)
        {
            if (seen.Count >= MaxClassWalk)
            {
                walkTruncated = true;
                break;
            }
            var (name, relation, via, depth) = queue.Dequeue();
            if (!seen.Add(name))
            {
                continue;
            }
            var current = catalog.FindClass(name);
            if (current is null)
            {
                lineage.Add(new SchemaLineageItem(name, relation, via, null, false, depth));
                continue;
            }
            chain.Add(current.Name);
            lineage.Add(new SchemaLineageItem(current.Name, relation, via, current.CategoryLabel, true, depth));
            foreach (var attribute in current.Must)
            {
                found[attribute] = found.TryGetValue(attribute, out var known)
                    ? known with { Required = true }
                    : (attribute, true, current.Name, found.Count);
            }
            foreach (var attribute in current.May)
            {
                found.TryAdd(attribute, (attribute, false, current.Name, found.Count));
            }
            var parent = current.SubClassOf;
            if (parent.Length > 0 && !string.Equals(parent, current.Name, StringComparison.OrdinalIgnoreCase))
            {
                queue.Enqueue((parent, "parent", current.Name, depth + 1));
            }
            foreach (var auxiliary in current.Auxiliary)
            {
                queue.Enqueue((auxiliary, "auxiliary", current.Name, depth + 1));
            }
        }
        var rows = new List<SchemaClassAttributeRow>();
        var missing = new List<string>();
        foreach (var entry in found.Values.OrderBy(e => e.Order))
        {
            var attribute = catalog.FindAttribute(entry.Name);
            if (attribute is null)
            {
                missing.Add(entry.Name);
                continue;
            }
            rows.Add(new SchemaClassAttributeRow(
                attribute.Name, entry.Required, entry.Origin, attribute.SyntaxLabel, attribute.Kind, attribute.SingleValued,
                attribute.SingleValued ? "Une" : "Plusieurs", IndexText(attribute), attribute.Indexed && !attribute.Constructed, attribute.InGlobalCatalog,
                attribute.Confidential, attribute.Constructed, attribute.Defunct, attribute.Description));
        }
        // Mandatory first, then by name (Sort-Object Obligatoire descending, Attribut).
        var ordered = rows.OrderByDescending(r => r.Required).ThenBy(r => r.Name, StringComparer.OrdinalIgnoreCase).ToImmutableArray();
        var required = ordered.Count(r => r.Required);
        var summary = root.Name + " · classe " + root.CategoryLabel.ToLower(CultureInfo.InvariantCulture) + " · chaîne : "
            + string.Join(" → ", chain) + " · " + FrenchText.Count(ordered.Length, "attribut possible", "attributs possibles") + ".";
        var filter = "(objectClass=" + root.Name + ")";
        return new SchemaClassDetail(
            root.Name, root.Oid, root.Description, root.Category, root.CategoryLabel, root.Defunct, root.SubClassOf, root.Auxiliary,
            [.. chain], Superclasses(catalog, root), [.. lineage], catalog.SubclassesOf(root.Name), ordered, [.. missing], required, ordered.Length - required, walkTruncated,
            summary, filter, RecommendedFilter(root.Name, catalog), RecommendedNote(root.Name, catalog), ClassFilterAdvice(root.Name));
    }

    /// <summary>The class and its superclasses up to top, following subClassOf (bounded, a loop never hangs).</summary>
    private static ImmutableArray<string> Superclasses(SchemaCatalog catalog, SchemaClass root)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var current = root; current is not null && seen.Add(current.Name) && result.Count < MaxClassWalk;)
        {
            result.Add(current.Name);
            if (current.SubClassOf.Length == 0 || string.Equals(current.SubClassOf, current.Name, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }
            var parent = catalog.FindClass(current.SubClassOf);
            if (parent is null)
            {
                result.Add(current.SubClassOf);
                break;
            }
            current = parent;
        }
        return [.. result];
    }

    /// <summary>
    /// Filter that targets a class through the indexed objectCategory when the usual category is known; otherwise the
    /// objectClass clause itself.
    /// </summary>
    public static string RecommendedFilter(string className, SchemaCatalog? catalog = null)
    {
        var category = UsualCategory(className);
        if (category is null)
        {
            return "(objectClass=" + className + ")";
        }
        if (catalog is not null && catalog.FindAttribute("objectCategory") is null)
        {
            return "(objectClass=" + className + ")";
        }
        return string.Equals(category, className, StringComparison.OrdinalIgnoreCase)
            ? "(objectCategory=" + category + ")"
            : "(&(objectCategory=" + category + ")(objectClass=" + className + "))";
    }

    /// <summary>
    /// Structural classes derived from <paramref name="className"/> whose usual category differs from the one that targets it: a
    /// filter on that category leaves their objects out (objectCategory=person leaves out computer, which derives from user, and
    /// the managed service accounts, which derive from computer). Read from the schema when it is known (walk bounded to 256
    /// classes), otherwise from the base schema. Empty when the class has no usual category.
    /// </summary>
    public static ImmutableArray<string> CategoryExclusions(string className, SchemaCatalog? catalog)
    {
        ArgumentNullException.ThrowIfNull(className);
        var category = UsualCategory(className);
        if (category is null)
        {
            return [];
        }
        if (catalog is null)
        {
            return className.ToLowerInvariant() switch
            {
                "person" or "organizationalperson" or "user" => ["computer", "msDS-GroupManagedServiceAccount", "msDS-ManagedServiceAccount"],
                "computer" => ["msDS-GroupManagedServiceAccount", "msDS-ManagedServiceAccount"],
                _ => [],
            };
        }
        var found = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { className };
        var queue = new Queue<string>(catalog.SubclassesOf(className));
        while (queue.Count > 0 && seen.Count < MaxClassWalk)
        {
            var name = queue.Dequeue();
            if (!seen.Add(name))
            {
                continue;
            }
            foreach (var child in catalog.SubclassesOf(name))
            {
                queue.Enqueue(child);
            }
            var derived = catalog.FindClass(name);
            if (derived is null || derived.Defunct || derived.Category is not (SchemaClassCategory.Structural or SchemaClassCategory.Class88))
            {
                continue;
            }
            if (!string.Equals(UsualCategory(name) ?? name, category, StringComparison.OrdinalIgnoreCase))
            {
                found.Add(derived.Name);
            }
        }
        return [.. found];
    }

    /// <summary>« computer », « computer et msDS-ManagedServiceAccount », « a, b, c et 2 autres ».</summary>
    public static string ClassList(IReadOnlyList<string> names)
    {
        ArgumentNullException.ThrowIfNull(names);
        if (names.Count <= 3)
        {
            return names.Count <= 1 ? string.Join("", names) : string.Join(", ", names.Take(names.Count - 1)) + " et " + names[^1];
        }
        return string.Join(", ", names.Take(3)) + " et " + FrenchText.Count(names.Count - 3, "autre", "autres");
    }

    /// <summary>
    /// What the recommended filter of a class leaves out, when its category does not cover every derived class; null otherwise.
    /// </summary>
    public static string? RecommendedNote(string className, SchemaCatalog? catalog)
    {
        var recommended = RecommendedFilter(className, catalog);
        if (recommended.StartsWith("(objectClass=", StringComparison.Ordinal))
        {
            return null;
        }
        var excluded = CategoryExclusions(className, catalog);
        if (excluded.IsEmpty)
        {
            return null;
        }
        return "Le filtre recommandé écarte " + ClassList(excluded) + (excluded.Length > 1 ? ", qui dérivent de " : ", qui dérive de ") + className
            + " avec une autre catégorie" + FrenchText.Colon + "gardez (objectClass=" + className + ") pour " + (excluded.Length > 1 ? "les inclure." : "l’inclure.");
    }

    /// <summary>Usual objectCategory of the common classes (defaultObjectCategory of the base schema).</summary>
    public static string? UsualCategory(string className) => className.ToLowerInvariant() switch
    {
        "user" or "inetorgperson" or "contact" or "person" or "organizationalperson" => "person",
        "computer" => "computer",
        "group" => "group",
        "organizationalunit" => "organizationalUnit",
        "printqueue" => "printQueue",
        "msds-groupmanagedserviceaccount" => "msDS-GroupManagedServiceAccount",
        "msds-managedserviceaccount" => "msDS-ManagedServiceAccount",
        "grouppolicycontainer" => "groupPolicyContainer",
        "foreignsecurityprincipal" => "foreignSecurityPrincipal",
        "volume" => "volume",
        _ => null,
    };

    /// <summary>Domenia 1 advice on objectClass and objectCategory (Show-DomeniaAdSchemaSelection).</summary>
    public static string ClassFilterAdvice(string className) =>
        "Filtre sur cette classe : (objectClass=" + className + "). Les classes dérivées en font partie (un poste est aussi de classe user) : "
        + "ajoutez un critère objectCategory pour cibler. Choisissez un attribut pour son détail.";

    // ---------------------------------------------------------------- attribute

    /// <summary>Detail of one attribute (Format-DomeniaAdSchemaAttributeDetail), with its flags, filter hint and users.</summary>
    public static SchemaAttributeDetail AttributeDetail(SchemaCatalog catalog, string name)
    {
        ArgumentNullException.ThrowIfNull(catalog);
        var a = catalog.FindAttribute(name) ?? throw new DomeniaOperationException(SchemaErrors.UnknownAttribute, SchemaErrors.UnknownAttributeMessage);
        var hint = QueryHint(a);
        var summary = a.Name + " · " + a.SyntaxLabel + " · " + (a.SingleValued ? "une valeur" : "plusieurs valeurs") + " · " + IndexText(a)
            + " · " + (a.InGlobalCatalog ? "dans le catalogue global" : "hors catalogue global");
        var (insertable, reason) = Insertable(a);
        var users = catalog.ClassesDeclaring(a.Name);
        string? partner = null;
        string? linkLabel = null;
        if (a.LinkId is long link)
        {
            var other = link % 2 == 0 ? link + 1 : link - 1;
            partner = catalog.Attributes.Values.FirstOrDefault(x => x.LinkId == other)?.Name;
            linkLabel = link % 2 == 0
                ? "Lien direct n° " + link.ToString(CultureInfo.InvariantCulture) + (partner is null ? "" : FrenchText.Colon + "son lien retour est " + partner)
                : "Lien retour n° " + link.ToString(CultureInfo.InvariantCulture) + (partner is null ? "" : FrenchText.Colon + "calculé à partir de " + partner);
        }
        return new SchemaAttributeDetail(
            a.Name, a.Oid, a.Description, a.Syntax, a.SyntaxLabel, a.Kind, a.OmSyntax, a.SingleValued, a.SingleValued ? "Une valeur" : "Plusieurs valeurs",
            IndexText(a), a.InGlobalCatalog, a.Defunct, a.Constructed, Flags(a), a.LinkId, linkLabel, partner, a.RangeLower, a.RangeUpper,
            RangeLabel(a), summary, hint, insertable, reason,
            [.. users.Take(MaxUsedBy).Select(u => new SchemaUsage(u.Class, u.Required))], users.Length);
    }

    /// <summary>
    /// Whether the attribute can be added to the filter draft (Domenia 1 BtnAdSchemaInsert): never for a constructed or defunct
    /// attribute; the reason says why.
    /// </summary>
    public static (bool Insertable, string? Reason) Insertable(SchemaAttribute attribute)
    {
        ArgumentNullException.ThrowIfNull(attribute);
        if (attribute.Constructed)
        {
            return (false, "Attribut calculé : il ne sert pas de critère de filtre.");
        }
        if (attribute.Defunct)
        {
            return (false, "Attribut obsolète : il ne sert pas dans une nouvelle requête.");
        }
        return (true, null);
    }

    private static ImmutableArray<SchemaFlag> Flags(SchemaAttribute a) =>
    [
        new("indexed", "Indexé", a.Indexed && !a.Constructed, Tone.Ok, "Une égalité ou un début de valeur limite les objets examinés."),
        new("tupleIndexed", "Sous-chaîne indexée", a.TupleIndexed, Tone.Ok, "Un joker en tête (*valeur) utilise aussi l’index."),
        new("anr", "Résolution ambiguë (ANR)", a.Anr, Tone.Info, "Recherché par une requête anr=…, comme le fait la barre de recherche."),
        new("inGlobalCatalog", "Catalogue global", a.InGlobalCatalog, Tone.Info, "Répliqué dans le catalogue global de la forêt."),
        new("singleValued", "Une seule valeur", a.SingleValued, Tone.Info, a.SingleValued ? "Une seule valeur par objet." : "Plusieurs valeurs possibles."),
        new("confidential", "Confidentiel", a.Confidential, Tone.Warn, "Lisible seulement avec un droit particulier : un filtre sans ce droit ne retient rien."),
        new("constructed", "Calculé", a.Constructed, Tone.Warn, "Calculé par le contrôleur : il se lit, il ne se filtre pas."),
        new("notReplicated", "Non répliqué", a.NotReplicated, Tone.Warn, "Chaque contrôleur a sa propre valeur."),
        new("linked", "Lié", a.Linked, Tone.Info, "Valeur maintenue par le contrôleur à partir de l’attribut associé."),
        new("rodcFiltered", "Filtré des RODC", a.RodcFiltered, Tone.Info, "Jamais répliqué sur un contrôleur en lecture seule."),
        new("defunct", "Obsolète", a.Defunct, Tone.Alert, "Désactivé dans ce schéma : à ne plus utiliser."),
    ];

    private static string? RangeLabel(SchemaAttribute a)
    {
        if (a.RangeLower is null && a.RangeUpper is null)
        {
            return null;
        }
        var unit = a.Kind == SchemaSyntaxKind.Text ? " caractères" : a.Kind == SchemaSyntaxKind.Binary ? " octets" : "";
        var lower = a.RangeLower is long l ? FrenchText.Integer(l) : null;
        var upper = a.RangeUpper is long u ? FrenchText.Integer(u) : null;
        if (lower is not null && upper is not null)
        {
            return "De " + lower + " à " + upper + unit;
        }
        return upper is not null ? "Au plus " + upper + unit : "Au moins " + lower + unit;
    }

    // ---------------------------------------------------------------- status

    /// <summary>
    /// Status sentence (Update-DomeniaAdSchemaStatus): « Schéma lu le 22/10/2026 14:05 sur DC01 : 52 classes, 318 attributs. »,
    /// plus the warning of an incomplete read.
    /// </summary>
    public static string StatusText(SchemaCatalog? catalog, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        if (catalog is null)
        {
            return "Schéma non lu dans cette session. La lecture est explicite et ne modifie rien.";
        }
        var local = TimeZoneInfo.ConvertTime(catalog.ObservedAt, zone);
        var text = "Schéma lu le " + local.ToString("dd'/'MM'/'yyyy' à 'HH':'mm", CultureInfo.InvariantCulture) + " sur " + catalog.Server + FrenchText.Colon
            + FrenchText.Count(catalog.ClassCount, "classe", "classes") + ", " + FrenchText.Count(catalog.AttributeCount, "attribut", "attributs") + ".";
        if (catalog.Truncated)
        {
            text += " Lecture incomplète (limite atteinte) : un attribut absent de la liste peut exister.";
        }
        return text;
    }

    /// <summary>Figures of the overview: indexes, global catalog, families of syntax and categories of classes.</summary>
    public static SchemaStatistics Statistics(SchemaCatalog catalog)
    {
        ArgumentNullException.ThrowIfNull(catalog);
        var attributes = catalog.Attributes.Values.ToList();
        var indexed = attributes.Count(a => a.Indexed && !a.Constructed);
        var syntaxes = attributes.GroupBy(a => a.Kind).OrderByDescending(g => g.Count()).ThenBy(g => g.Key)
            .Select(g => new SchemaFamilyCount(Camel(g.Key.ToString()), SyntaxFamilyLabel(g.Key), g.Count())).ToImmutableArray();
        var categories = catalog.Classes.Values.GroupBy(c => c.Category).OrderBy(g => g.Key)
            .Select(g => new SchemaFamilyCount(Camel(g.Key.ToString()), ClassCategoryLabel(g.Key), g.Count())).ToImmutableArray();
        return new SchemaStatistics(
            indexed, attributes.Count(a => a.TupleIndexed), attributes.Count(a => a.InGlobalCatalog), attributes.Count(a => a.Confidential),
            attributes.Count(a => a.Constructed), attributes.Count(a => a.Linked), attributes.Count(a => a.Defunct) + catalog.Classes.Values.Count(c => c.Defunct),
            attributes.Count(a => a.SingleValued), attributes.Count == 0 ? 0 : Math.Round(indexed * 100.0 / attributes.Count, 1, MidpointRounding.AwayFromZero),
            syntaxes, categories);
    }

    private static string Camel(string name) => name.Length == 0 ? name : char.ToLowerInvariant(name[0]) + name[1..];
}
