using System.Collections.Frozen;
using System.Collections.Immutable;

namespace Domenia.Core;

// Directory schema screen (docs/ops/schema.md, Domenia 1 points 28 and 29: SCH-001 to SCH-008). Records of the read
// (definitions as the controller gives them), of the catalog kept for the session, and of the bridge results.

/// <summary>Bounds of one schema read (Domenia 1 AdSchemaRead): 8 000 attributes, 3 000 classes, 90 seconds.</summary>
public sealed record SchemaReadLimits(int MaxAttributes, int MaxClasses, TimeSpan Budget)
{
    public static SchemaReadLimits Default { get; } = new(8000, 3000, TimeSpan.FromSeconds(90));
}

/// <summary>Stage of a schema read, pushed to the page as « schema.read:stage ».</summary>
public enum SchemaReadStage
{
    Context,
    Attributes,
    Classes,
}

/// <summary>One attributeSchema entry as read (lDAPDisplayName, adminDescription, attributeSyntax…). Never an object value.</summary>
public sealed record SchemaAttributeDefinition(
    string Name,
    string? Description,
    string? Oid,
    string Syntax,
    int? OmSyntax,
    bool SingleValued,
    long? SearchFlags,
    long? SystemFlags,
    bool InGlobalCatalog,
    long? RangeLower,
    long? RangeUpper,
    long? LinkId,
    bool Defunct);

/// <summary>One classSchema entry as read (subClassOf, auxiliary classes, mustContain and mayContain, system ones included).</summary>
public sealed record SchemaClassDefinition(
    string Name,
    string? Description,
    string? Oid,
    string? SubClassOf,
    ImmutableArray<string> Auxiliary,
    ImmutableArray<string> Must,
    ImmutableArray<string> May,
    int? Category,
    bool Defunct);

/// <summary>Result of one bounded read of the schema partition of the session controller.</summary>
public sealed record SchemaReadResult(
    ImmutableArray<SchemaAttributeDefinition> Attributes,
    ImmutableArray<SchemaClassDefinition> Classes,
    string Server,
    DateTimeOffset ObservedAt,
    bool Truncated,
    long DurationMs,
    string DomainDn,
    string SchemaNamingContext);

/// <summary>Family of an attribute syntax, used to suggest a filter clause (Domenia 1 Get-DomeniaAdSyntaxKind).</summary>
public enum SchemaSyntaxKind
{
    Dn,
    Text,
    Bool,
    Int,
    LargeInt,
    Time,
    Binary,
    Sid,
    Other,
}

/// <summary>objectClassCategory of a class (Domenia 1 Get-DomeniaAdClassCategoryLabel).</summary>
public enum SchemaClassCategory
{
    Structural,
    Abstract,
    Auxiliary,
    Class88,
    Unknown,
}

/// <summary>Bits of searchFlags.</summary>
public sealed record SchemaSearchFlags(
    bool Indexed,
    bool ContainerIndexed,
    bool Anr,
    bool PreserveOnDelete,
    bool Copy,
    bool TupleIndexed,
    bool SubtreeIndexed,
    bool Confidential,
    bool NeverAudit,
    bool RodcFiltered);

/// <summary>Bits of systemFlags.</summary>
public sealed record SchemaSystemFlags(
    bool NotReplicated,
    bool PartialSetRequired,
    bool Constructed,
    bool Operational,
    bool BaseSchema,
    bool Rdn);

/// <summary>Attribute of the catalog: decoded flags, syntax in plain words. Defunct entries are kept and flagged.</summary>
public sealed record SchemaAttribute(
    string Name,
    string Description,
    string? Oid,
    string Syntax,
    string SyntaxLabel,
    SchemaSyntaxKind Kind,
    int? OmSyntax,
    bool SingleValued,
    bool Indexed,
    bool TupleIndexed,
    bool ContainerIndexed,
    bool Anr,
    bool Confidential,
    bool Constructed,
    bool NotReplicated,
    bool InGlobalCatalog,
    bool Linked,
    long? LinkId,
    bool Defunct,
    long? RangeLower,
    long? RangeUpper,
    bool PreserveOnDelete,
    bool RodcFiltered,
    bool BaseSchema);

/// <summary>Class of the catalog.</summary>
public sealed record SchemaClass(
    string Name,
    string Description,
    string? Oid,
    string SubClassOf,
    ImmutableArray<string> Auxiliary,
    ImmutableArray<string> Must,
    ImmutableArray<string> May,
    SchemaClassCategory Category,
    string CategoryLabel,
    bool Defunct);

/// <summary>
/// The schema read once in this session for one domain (Domenia 1 ConvertTo-DomeniaAdSchemaCatalog): attributes and classes
/// keyed by lDAPDisplayName (case ignored), names sorted once so that filtering never sorts thousands of keys again.
/// </summary>
public sealed class SchemaCatalog
{
    private readonly Lazy<FrozenDictionary<string, ImmutableArray<(string Class, bool Required)>>> usedBy;
    private readonly Lazy<FrozenDictionary<string, ImmutableArray<string>>> subclasses;

    public SchemaCatalog(
        FrozenDictionary<string, SchemaAttribute> attributes,
        FrozenDictionary<string, SchemaClass> classes,
        string server,
        DateTimeOffset observedAt,
        bool truncated,
        long durationMs,
        string domainDn)
    {
        ArgumentNullException.ThrowIfNull(attributes);
        ArgumentNullException.ThrowIfNull(classes);
        Attributes = attributes;
        Classes = classes;
        AttributeNames = [.. attributes.Values.Select(a => a.Name).Order(StringComparer.OrdinalIgnoreCase).ThenBy(n => n, StringComparer.Ordinal)];
        ClassNames = [.. classes.Values.Select(c => c.Name).Order(StringComparer.OrdinalIgnoreCase).ThenBy(n => n, StringComparer.Ordinal)];
        Server = server;
        ObservedAt = observedAt;
        Truncated = truncated;
        DurationMs = durationMs;
        DomainDn = domainDn;
        usedBy = new Lazy<FrozenDictionary<string, ImmutableArray<(string, bool)>>>(BuildUsedBy, LazyThreadSafetyMode.ExecutionAndPublication);
        subclasses = new Lazy<FrozenDictionary<string, ImmutableArray<string>>>(BuildSubclasses, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public FrozenDictionary<string, SchemaAttribute> Attributes { get; }

    public FrozenDictionary<string, SchemaClass> Classes { get; }

    /// <summary>Attribute names in alphabetical order (case ignored).</summary>
    public ImmutableArray<string> AttributeNames { get; }

    /// <summary>Class names in alphabetical order (case ignored).</summary>
    public ImmutableArray<string> ClassNames { get; }

    public string Server { get; }

    public DateTimeOffset ObservedAt { get; }

    public bool Truncated { get; }

    public long DurationMs { get; }

    /// <summary>Root DN of the domain the schema was read for: never used for another domain.</summary>
    public string DomainDn { get; }

    public int AttributeCount => Attributes.Count;

    public int ClassCount => Classes.Count;

    public SchemaAttribute? FindAttribute(string? name) =>
        string.IsNullOrWhiteSpace(name) ? null : Attributes.GetValueOrDefault(name.Trim());

    public SchemaClass? FindClass(string? name) =>
        string.IsNullOrWhiteSpace(name) ? null : Classes.GetValueOrDefault(name.Trim());

    /// <summary>Classes that declare the attribute themselves (mustContain or mayContain), in name order.</summary>
    public ImmutableArray<(string Class, bool Required)> ClassesDeclaring(string attribute) =>
        usedBy.Value.GetValueOrDefault(attribute, []);

    /// <summary>Direct subclasses of a class, in name order.</summary>
    public ImmutableArray<string> SubclassesOf(string className) => subclasses.Value.GetValueOrDefault(className, []);

    private FrozenDictionary<string, ImmutableArray<(string, bool)>> BuildUsedBy()
    {
        var map = new Dictionary<string, Dictionary<string, bool>>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in ClassNames)
        {
            var schemaClass = Classes[name];
            foreach (var attribute in schemaClass.Must)
            {
                Entry(attribute)[schemaClass.Name] = true;
            }
            foreach (var attribute in schemaClass.May)
            {
                var entry = Entry(attribute);
                entry.TryAdd(schemaClass.Name, false);
            }
        }
        return map.ToFrozenDictionary(
            p => p.Key,
            p => p.Value.Select(e => (e.Key, e.Value)).OrderBy(e => e.Key, StringComparer.OrdinalIgnoreCase).ToImmutableArray(),
            StringComparer.OrdinalIgnoreCase);

        Dictionary<string, bool> Entry(string attribute)
        {
            if (!map.TryGetValue(attribute, out var entry))
            {
                entry = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
                map.Add(attribute, entry);
            }
            return entry;
        }
    }

    private FrozenDictionary<string, ImmutableArray<string>> BuildSubclasses()
    {
        var map = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in ClassNames)
        {
            var schemaClass = Classes[name];
            if (schemaClass.SubClassOf.Length == 0 || string.Equals(schemaClass.SubClassOf, schemaClass.Name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (!map.TryGetValue(schemaClass.SubClassOf, out var list))
            {
                list = [];
                map.Add(schemaClass.SubClassOf, list);
            }
            list.Add(schemaClass.Name);
        }
        return map.ToFrozenDictionary(p => p.Key, p => p.Value.ToImmutableArray(), StringComparer.OrdinalIgnoreCase);
    }
}

// ---------------------------------------------------------------- bridge results

/// <summary>Bounds shown to the operator before a read.</summary>
public sealed record SchemaLimitsInfo(int Attributes, int Classes, int Seconds);

/// <summary>Count of one family (syntax family, class category) for the overview.</summary>
public sealed record SchemaFamilyCount(string Id, string Label, int Count);

/// <summary>Figures of the schema read, for the overview of the screen.</summary>
public sealed record SchemaStatistics(
    int Indexed,
    int TupleIndexed,
    int InGlobalCatalog,
    int Confidential,
    int Constructed,
    int Linked,
    int Defunct,
    int SingleValued,
    double IndexedPercent,
    ImmutableArray<SchemaFamilyCount> Syntaxes,
    ImmutableArray<SchemaFamilyCount> Categories);

/// <summary>Result of schema.status and schema.read (docs/ops/schema.md § 2): what is known of the schema in this session.</summary>
public sealed record SchemaStatus(
    bool Read,
    string? Server,
    DateTimeOffset? ReadAt,
    int Classes,
    int Attributes,
    bool Truncated,
    long? DurationMs,
    string Text,
    Tone Tone,
    string? LastError,
    bool Simulated,
    SchemaLimitsInfo Limits,
    SchemaStatistics? Statistics);

/// <summary>One row of the catalog list: a class or an attribute (fields of the other kind are null).</summary>
public sealed record SchemaListRow(
    string Name,
    string Kind,
    string Nature,
    string Detail,
    string Description,
    bool Defunct,
    string? Category,
    string? SubClassOf,
    string? SyntaxLabel,
    string? IndexText,
    bool? SingleValued,
    bool? Indexed,
    bool? InGlobalCatalog,
    bool? Confidential,
    bool? Constructed);

/// <summary>Result of schema.list (Domenia 1 Find-DomeniaAdSchemaEntries): every match counted, the first ones returned.</summary>
public sealed record SchemaListResult(
    string Kind,
    string Text,
    int Total,
    int Shown,
    int Limit,
    string Summary,
    ImmutableArray<SchemaListRow> Rows);

/// <summary>One attribute a class may carry (Domenia 1 ConvertTo-DomeniaAdAttributeRow).</summary>
public sealed record SchemaClassAttributeRow(
    string Name,
    bool Required,
    string Origin,
    string SyntaxLabel,
    SchemaSyntaxKind Kind,
    bool SingleValued,
    string Values,
    string IndexText,
    bool Indexed,
    bool InGlobalCatalog,
    bool Confidential,
    bool Constructed,
    bool Defunct,
    string Description);

/// <summary>
/// One class met while walking a class: the class itself, a superclass or an auxiliary class, with the class that brought it
/// (<see cref="Via"/>); <see cref="Known"/> is false for a class absent from the schema read.
/// </summary>
public sealed record SchemaLineageItem(string Name, string Relation, string? Via, string? CategoryLabel, bool Known, int Depth);

/// <summary>Result of schema.class (SCH-003).</summary>
public sealed record SchemaClassDetail(
    string Name,
    string? Oid,
    string Description,
    SchemaClassCategory Category,
    string CategoryLabel,
    bool Defunct,
    string SubClassOf,
    ImmutableArray<string> Auxiliary,
    ImmutableArray<string> Chain,
    ImmutableArray<string> Superclasses,
    ImmutableArray<SchemaLineageItem> Lineage,
    ImmutableArray<string> Subclasses,
    ImmutableArray<SchemaClassAttributeRow> Attributes,
    ImmutableArray<string> Missing,
    int RequiredCount,
    int OptionalCount,
    bool WalkTruncated,
    string Summary,
    string Filter,
    string RecommendedFilter,
    string? RecommendedNote,
    string FilterAdvice);

/// <summary>One flag of an attribute, as a labelled switch for the detail sheet.</summary>
public sealed record SchemaFlag(string Id, string Label, bool On, Tone Tone, string Tip);

/// <summary>Example clause and notes on the cost of an attribute in a filter (Domenia 1 Get-DomeniaAdAttributeQueryHint).</summary>
public sealed record SchemaQueryHint(string Example, ImmutableArray<string> Notes);

/// <summary>A class that declares an attribute.</summary>
public sealed record SchemaUsage(string Name, bool Required);

/// <summary>Result of schema.attribute (SCH-002, SCH-004).</summary>
public sealed record SchemaAttributeDetail(
    string Name,
    string? Oid,
    string Description,
    string Syntax,
    string SyntaxLabel,
    SchemaSyntaxKind Kind,
    int? OmSyntax,
    bool SingleValued,
    string ValuesLabel,
    string IndexText,
    bool InGlobalCatalog,
    bool Defunct,
    bool Constructed,
    ImmutableArray<SchemaFlag> Flags,
    long? LinkId,
    string? LinkLabel,
    string? LinkPartner,
    long? RangeLower,
    long? RangeUpper,
    string? RangeLabel,
    string Summary,
    SchemaQueryHint Hint,
    bool Insertable,
    string? InsertReason,
    ImmutableArray<SchemaUsage> UsedBy,
    int UsedByTotal);

/// <summary>Index use of a filter node: answered from an index, read object by object, or unknown (schema not read).</summary>
public enum LdapIndexUse
{
    Yes,
    No,
    Unknown,
}

/// <summary>Kind of a filter node (RFC 4515).</summary>
public enum LdapFilterNodeKind
{
    And,
    Or,
    Not,
    Equality,
    Presence,
    Substring,
    GreaterOrEqual,
    LessOrEqual,
    Approx,
    Extensible,
}

/// <summary>Cost level of a filter (Domenia 1: Ciblé, Large, Inconnu, Invalide).</summary>
public enum LdapFilterLevel
{
    Targeted,
    Broad,
    Unknown,
    Invalid,
}

/// <summary>A node of the filter as the page shows it (tree of the analysis): text, attribute and index use.</summary>
public sealed record LdapFilterNodeView(
    LdapFilterNodeKind Kind,
    string Label,
    string Text,
    string? Attribute,
    string? Value,
    string? Rule,
    bool Negated,
    bool LeadingWildcard,
    LdapIndexUse IndexUse,
    string IndexLabel,
    ImmutableArray<LdapFilterNodeView> Children);

/// <summary>Suggested rewriting of a filter (improvement of SCH-006): a new filter when one is safe to propose, and why.</summary>
public sealed record LdapFilterSuggestion(string? Filter, ImmutableArray<string> Reasons);

/// <summary>Result of schema.filter.analyze (SCH-006): what a filter costs before it is sent; nothing contacts a controller.</summary>
public sealed record LdapFilterAnalysis(
    bool Valid,
    string? Error,
    int? ErrorPosition,
    string? Normalized,
    LdapFilterLevel Level,
    string LevelLabel,
    Tone Tone,
    LdapIndexUse IndexUse,
    bool SchemaUsed,
    ImmutableArray<string> Attributes,
    ImmutableArray<string> NotIndexed,
    ImmutableArray<string> Unknown,
    ImmutableArray<string> LeadingWildcards,
    ImmutableArray<string> Constructed,
    ImmutableArray<string> Confidential,
    int Negations,
    int Extensible,
    ImmutableArray<string> Advice,
    string Text,
    LdapFilterNodeView? Tree,
    LdapFilterSuggestion? Suggestion);

/// <summary>Result of schema.filter.insert (SCH-005): the draft filter and its analysis; nothing is executed.</summary>
public sealed record SchemaFilterInsertResult(string Filter, bool Changed, string Message, LdapFilterAnalysis Analysis);

/// <summary>Error codes of the schema screen (docs/ops/schema.md § 9).</summary>
public static class SchemaErrors
{
    public const string NotRead = "schema.notRead";
    public const string NotReadMessage = "Schéma non lu dans cette session : lisez-le d’abord (lecture explicite, rien n’est modifié).";

    public const string UnknownClass = "schema.unknownClass";
    public const string UnknownClassMessage = "Classe inconnue du schéma lu : rien n’a été affiché.";

    public const string UnknownAttribute = "schema.unknownAttribute";
    public const string UnknownAttributeMessage = "Attribut inconnu du schéma lu : rien n’a été affiché.";

    public const string ReadFailed = "schema.readFailed";

    public const string ReadBusy = "schema.readBusy";
    public const string ReadBusyMessage = "Une lecture du schéma est déjà en cours : attendez sa fin (une seule lecture à la fois).";
}
