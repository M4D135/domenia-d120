using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Domenia.Core.Accueil;

public static partial class ProbeCatalog
{
    private static readonly string[] DetailedNames =
    [
        "Id", "Category", "Name", "Namespace", "Class", "Properties", "Filter", "Mode", "Transform", "Visual",
        "Slow", "SkipOnDc", "Origin", "Description", "Rights", "Compatibility", "UnknownMeaning", "Limitations",
        "SourceUrls", "Fields", "ProviderQualification", "DocumentationReviewedUtc", "Behavior", "Privilege", "Cost",
    ];

    /// <summary>
    /// Actual embedded-catalog loader. Kept internal: this does not create a profile import path or a mutable global catalog.
    /// A custom entry retains its origin and must carry its own complete declarations before it is made available.
    /// </summary>
    internal static ImmutableArray<ProbeDefinition> ReadDetailed(string json)
    {
        if (json is null || json.Length > 1_048_576 || Encoding.UTF8.GetByteCount(json) > 1_048_576)
        { throw InvalidCatalog("taille hors limites (1 Mio)."); }
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 16 });
            var root = CatalogObject(document.RootElement, ["SchemaVersion", "DocumentationReviewedUtc", "Qualification", "Probes"]);
            if (!root.TryGetValue("SchemaVersion", out var schema) || schema.ValueKind != JsonValueKind.Number || !schema.TryGetInt32(out var version) || version != 1)
            { throw InvalidCatalog("version non reconnue."); }
            OptionalCatalogText(root, "DocumentationReviewedUtc", 32);
            OptionalCatalogText(root, "Qualification", 2048);
            var values = CatalogArray(root, "Probes", 0, 256);
            var result = ImmutableArray.CreateBuilder<ProbeDefinition>();
            var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var element in values.EnumerateArray())
            {
                var probe = ReadDetailedProbe(element);
                if (!ids.Add(probe.Id)) { throw InvalidCatalog("identifiant répété : " + probe.Id + "."); }
                var contract = Contract(probe);
                if (!contract.Valid) { throw InvalidCatalog(probe.Id + " : " + string.Join(" ", contract.Errors)); }
                result.Add(probe);
            }
            return result.ToImmutable();
        }
        catch (JsonException error) { throw new InvalidDataException("Catalogue de sondes JSON illisible.", error); }
    }

    private static ProbeDefinition ReadDetailedProbe(JsonElement element)
    {
        var values = CatalogObject(element, DetailedNames);
        // An absent historical Origin means the delivered detailed catalog. An explicitly unknown origin is never relabelled.
        var origin = OptionalCatalogText(values, "Origin", 64) ?? "Catalogue détaillé";
        if (origin is not ("Catalogue détaillé" or "Personnalisée")) { throw InvalidCatalog("origine inconnue."); }
        var properties = CatalogStrings(values, "Properties", 1, 64, 128);
        var fields = ImmutableArray.CreateBuilder<ProbeField>();
        foreach (var field in CatalogArray(values, "Fields", 1, 64).EnumerateArray())
        {
            var parts = CatalogObject(field, ["Name", "CimType", "Kind", "IsArray", "Unit", "Description"]);
            var type = CatalogText(parts, "CimType", 32);
            var array = CatalogFlag(parts, "IsArray");
            if (!CimTypePattern().IsMatch(type) || type.EndsWith("[]", StringComparison.Ordinal) != array)
            { throw InvalidCatalog("type CIM absent, inconnu ou incohérent."); }
            fields.Add(new(CatalogText(parts, "Name", 128), type, CatalogText(parts, "Kind", 32), array,
                CatalogText(parts, "Unit", 128, empty: true), CatalogText(parts, "Description", 2048)));
        }
        OptionalCatalogText(values, "DocumentationReviewedUtc", 32);
        var probe = new ProbeDefinition(CatalogText(values, "Id", 128), CatalogText(values, "Category", 128),
            CatalogText(values, "Name", 256), CatalogText(values, "Namespace", 256), CatalogText(values, "Class", 128),
            properties, CatalogText(values, "Filter", 512, empty: true), CatalogText(values, "Mode", 16),
            CatalogText(values, "Transform", 4096), CatalogText(values, "Visual", 32), CatalogFlag(values, "Slow"),
            CatalogFlag(values, "SkipOnDc"), origin, CatalogText(values, "Description", 4096), CatalogText(values, "Rights", 2048),
            CatalogText(values, "Compatibility", 2048), CatalogText(values, "UnknownMeaning", 2048), CatalogText(values, "Limitations", 4096),
            CatalogStrings(values, "SourceUrls", 1, 16, 2048), fields.ToImmutable(),
            OptionalCatalogText(values, "ProviderQualification", 2048) ?? "À qualifier sous Windows")
        {
            Behavior = values.TryGetValue("Behavior", out var behavior) ? ReadBehavior(behavior) : null,
            Privilege = values.TryGetValue("Privilege", out var privilege) ? ReadPrivilege(privilege) : null,
            Cost = values.TryGetValue("Cost", out var cost) ? ReadCost(cost) : null,
        };
        if (!KnownTransform(probe.Transform) || probe.Visual is not ("Column" or "Kpi" or "Text" or "Pie" or "Bar"))
        { throw InvalidCatalog("transformation ou représentation inconnue."); }
        return probe;
    }

    private static ProbeBehavior ReadBehavior(JsonElement element)
    {
        var parts = CatalogObject(element, ["Reads", "Writes", "Code", "Methods", "Target"]);
        return new(CatalogText(parts, "Reads", 32), CatalogFlag(parts, "Writes"), CatalogText(parts, "Code", 32),
            CatalogStrings(parts, "Methods", 0, 0, 128), CatalogText(parts, "Target", 512));
    }

    private static ProbePrivilege ReadPrivilege(JsonElement element)
    {
        var parts = CatalogObject(element, ["Level", "Text"]);
        return new(CatalogText(parts, "Level", 64), CatalogText(parts, "Text", 2048));
    }

    private static ProbeCost ReadCost(JsonElement element)
    {
        var parts = CatalogObject(element, ["Level", "Reason"]);
        return new(CatalogText(parts, "Level", 32), CatalogText(parts, "Reason", 2048));
    }

    private static Dictionary<string, JsonElement> CatalogObject(JsonElement value, string[] allowed)
    {
        if (value.ValueKind != JsonValueKind.Object) { throw InvalidCatalog("objet attendu."); }
        var result = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (!allowed.Contains(property.Name, StringComparer.Ordinal) || !result.TryAdd(property.Name, property.Value))
            { throw InvalidCatalog("propriété inconnue ou répétée : " + property.Name + "."); }
        }
        return result;
    }

    private static string CatalogText(Dictionary<string, JsonElement> values, string name, int limit, bool empty = false)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind != JsonValueKind.String)
        { throw InvalidCatalog("texte requis : " + name + "."); }
        var text = value.GetString()!;
        if (text.Length > limit || text.Any(char.IsControl) || !empty && string.IsNullOrWhiteSpace(text))
        { throw InvalidCatalog("texte hors limites : " + name + "."); }
        return text;
    }

    private static string? OptionalCatalogText(Dictionary<string, JsonElement> values, string name, int limit) =>
        values.ContainsKey(name) ? CatalogText(values, name, limit) : null;

    private static bool CatalogFlag(Dictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        { throw InvalidCatalog("booléen explicite requis : " + name + "."); }
        return value.GetBoolean();
    }

    private static JsonElement CatalogArray(Dictionary<string, JsonElement> values, string name, int minimum, int maximum)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind != JsonValueKind.Array
            || value.GetArrayLength() < minimum || value.GetArrayLength() > maximum)
        { throw InvalidCatalog("liste absente ou hors limites : " + name + "."); }
        return value;
    }

    private static ImmutableArray<string> CatalogStrings(Dictionary<string, JsonElement> values, string name, int minimum, int maximum, int limit)
    {
        var result = ImmutableArray.CreateBuilder<string>();
        var unique = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var value in CatalogArray(values, name, minimum, maximum).EnumerateArray())
        {
            if (value.ValueKind != JsonValueKind.String || value.GetString() is not { } text
                || string.IsNullOrWhiteSpace(text) || text.Length > limit || text.Any(char.IsControl) || !unique.Add(text))
            { throw InvalidCatalog("liste de textes invalide ou répétée : " + name + "."); }
            result.Add(text);
        }
        return result.ToImmutable();
    }

    private static bool KnownTransform(string value)
    {
        if (value is "Text" or "GB" or "GBfromKB" or "MB" or "Mbps" or "Number" or "DaysSince" or "Year" or "PercentFree" or "Release") { return true; }
        if (!value.StartsWith("Map:", StringComparison.Ordinal)) { return false; }
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var pair in value[4..].Split(';'))
        {
            var cells = pair.Split('=');
            if (cells.Length != 2 || string.IsNullOrWhiteSpace(cells[1]) || !seen.Add(cells[0])) { return false; }
        }
        return true;
    }

    private static InvalidDataException InvalidCatalog(string detail) => new("Catalogue de sondes refusé : " + detail);

    [GeneratedRegex(@"^(string|datetime|boolean|uint8|uint16|uint32|uint64|sint8|sint16|sint32|sint64|real32|real64)(\[\])?$")]
    private static partial Regex CimTypePattern();
}
