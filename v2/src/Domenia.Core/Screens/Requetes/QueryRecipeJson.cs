using System.Buffers;
using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Domenia.Core.Queries;

/// <summary>
/// Strict JSON form of a recipe. Reading accepts the Domenia 2 page form (camelCase) and the Domenia 1 form (PascalCase,
/// Domenia.Query/1 and /2), refuses any unknown property and any newer format. Writing produces the Domenia 1 compatible
/// form (PascalCase, nulls omitted, Target omitted for computers), used for the library, the packs, the fingerprint and
/// the scripts. Data only: nothing here ever executes a recipe.
/// </summary>
public static partial class QueryRecipeJson
{
    private static readonly string[] RecipeProperties =
        ["Format", "Id", "Name", "Target", "Junction", "Clauses", "GroupBy", "Refinements", "ProbeSelection", "ObjectIds", "Parameters", "ParameterValues", "Expression", "CoherenceHours", "ReadDefinition"];

    [GeneratedRegex("^[a-zA-Z0-9_.-]{1,80}$", RegexOptions.CultureInvariant, 1000)]
    public static partial Regex IdPattern();

    /// <summary>Reads a recipe from the page or a file; <see cref="QueryDefinitionException"/> with a French reason otherwise.</summary>
    public static QueryRecipe Read(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw Invalid("une requête est un objet JSON.");
        }
        var values = Properties(element, RecipeProperties, "requête");
        var format = OptionalString(values, "Format") ?? QueryRecipe.FormatV1;
        CheckFormat(format, "Domenia.Query", 3, "requête");
        var id = OptionalString(values, "Id") ?? "";
        var name = OptionalString(values, "Name") ?? "";
        var target = QueryTarget.Computer;
        if (values.TryGetValue("Target", out var t) && t.ValueKind != JsonValueKind.Null)
        {
            target = t.ValueKind == JsonValueKind.String ? ParseEnum<QueryTarget>(t.GetString()!, "cible") : throw Invalid("cible inconnue.");
        }
        var junction = values.TryGetValue("Junction", out var j) && j.ValueKind == JsonValueKind.String ? ParseEnum<QueryJunction>(j.GetString()!, "combinaison") : QueryJunction.All;
        var groupBy = OptionalString(values, "GroupBy");
        var probe = values.TryGetValue("ProbeSelection", out var p) && p.ValueKind != JsonValueKind.Null ? ReadSegment(p) : null;
        ImmutableArray<string>? objectIds = null;
        if (values.TryGetValue("ObjectIds", out var ids) && ids.ValueKind != JsonValueKind.Null)
        {
            if (ids.ValueKind != JsonValueKind.Array || ids.GetArrayLength() > QueryLimits.MaxObjectIds)
            {
                throw Invalid("la sélection accepte au plus 20 000 GUID.");
            }
            objectIds = [.. ids.EnumerateArray().Select(i => i.ValueKind == JsonValueKind.String ? i.GetString()! : throw Invalid("GUID invalide dans la sélection."))];
        }
        ImmutableSortedDictionary<string, QueryValue>? parameterValues = null;
        if (values.TryGetValue("ParameterValues", out var pv) && pv.ValueKind != JsonValueKind.Null)
        {
            if (pv.ValueKind != JsonValueKind.Object)
            {
                throw Invalid("valeurs de paramètres invalides.");
            }
            var builder = ImmutableSortedDictionary.CreateBuilder<string, QueryValue>(StringComparer.Ordinal);
            foreach (var entry in pv.EnumerateObject())
            {
                if (!builder.TryAdd(entry.Name, ReadValue(entry.Value, "valeur de paramètre")))
                {
                    throw Invalid("valeur de paramètre en double.");
                }
            }
            parameterValues = builder.ToImmutable();
        }
        decimal? coherence = null;
        if (values.TryGetValue("CoherenceHours", out var ch) && ch.ValueKind != JsonValueKind.Null)
        {
            coherence = ch.ValueKind == JsonValueKind.Number && ch.TryGetDecimal(out var hours) ? hours : throw Invalid("fenêtre de cohérence invalide.");
        }
        ImmutableArray<QueryParameter> parameters = [];
        if (values.TryGetValue("Parameters", out var ps) && ps.ValueKind != JsonValueKind.Null)
        {
            if (ps.ValueKind != JsonValueKind.Array || ps.GetArrayLength() > QueryLimits.MaxParameters * 2)
            {
                throw Invalid("paramètres invalides.");
            }
            parameters = [.. ps.EnumerateArray().Select(ReadParameter)];
        }
        return new QueryRecipe(
            format,
            id,
            name,
            target,
            junction,
            ReadClauses(values, "Clauses"),
            string.IsNullOrEmpty(groupBy) ? null : groupBy,
            ReadClauses(values, "Refinements"),
            probe,
            objectIds,
            parameters,
            parameterValues,
            values.TryGetValue("Expression", out var e) && e.ValueKind != JsonValueKind.Null ? ReadNode(e, 0) : null,
            coherence,
            values.TryGetValue("ReadDefinition", out var rd) && rd.ValueKind != JsonValueKind.Null ? ReadDefinition(rd) : null);
    }

    /// <summary>Reads a recipe from JSON text (files, preferences).</summary>
    public static QueryRecipe Read(string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 64 });
            return Read(document.RootElement);
        }
        catch (JsonException)
        {
            throw Invalid("JSON illisible.");
        }
    }

    /// <summary>A literal: null, text, number, true/false, or { "parameter": "Nom" } (any case).</summary>
    public static QueryValue ReadValue(JsonElement element, string what)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Null:
            case JsonValueKind.Undefined:
                return QueryValue.None;
            case JsonValueKind.String:
                return QueryValue.FromText(element.GetString()!);
            case JsonValueKind.Number:
                return element.TryGetDecimal(out var number) ? QueryValue.FromNumber(number) : throw Invalid(what + " hors limites.");
            case JsonValueKind.True:
                return QueryValue.FromBoolean(true);
            case JsonValueKind.False:
                return QueryValue.FromBoolean(false);
            case JsonValueKind.Object:
                var values = Properties(element, ["Parameter"], what);
                return values.TryGetValue("Parameter", out var name) && name.ValueKind == JsonValueKind.String
                    ? QueryValue.FromParameter(name.GetString()!)
                    : throw Invalid(what + " : référence de paramètre invalide.");
            default:
                throw Invalid(what + " invalide.");
        }
    }

    /// <summary>
    /// Compact JSON of a recipe in the Domenia 1 compatible form. <paramref name="effectiveParameters"/> replaces the
    /// parameter values by those given (fingerprint: an explicit default never changes it).
    /// </summary>
    public static string Write(QueryRecipe recipe, bool indented = false, IReadOnlyDictionary<string, QueryValue>? effectiveParameters = null)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = indented, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            WriteRecipe(writer, recipe, effectiveParameters);
        }
        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    /// <summary>Writes a recipe as one JSON object (Domenia 1 compatible property names).</summary>
    public static void WriteRecipe(Utf8JsonWriter writer, QueryRecipe recipe, IReadOnlyDictionary<string, QueryValue>? effectiveParameters = null)
    {
        ArgumentNullException.ThrowIfNull(writer);
        ArgumentNullException.ThrowIfNull(recipe);
        writer.WriteStartObject();
        writer.WriteString("Format", recipe.MinimalFormat());
        writer.WriteString("Id", recipe.Id);
        writer.WriteString("Name", recipe.Name);
        if (recipe.Target != QueryTarget.Computer)
        {
            writer.WriteString("Target", recipe.Target.ToString());
        }
        writer.WriteString("Junction", recipe.Junction.ToString());
        WriteClauses(writer, "Clauses", recipe.Clauses);
        writer.WriteString("GroupBy", recipe.GroupBy ?? "");
        WriteClauses(writer, "Refinements", recipe.Refinements);
        if (recipe.ProbeSelection is { } segment)
        {
            writer.WritePropertyName("ProbeSelection");
            writer.WriteStartObject();
            writer.WriteString("Key", segment.Key);
            writer.WriteString("Mode", segment.Mode);
            if (segment.Value is not null)
            {
                writer.WriteString("Value", segment.Value);
            }
            if (segment.Low is decimal low)
            {
                writer.WriteNumber("Low", low);
            }
            if (segment.High is decimal high)
            {
                writer.WriteNumber("High", high);
            }
            if (!segment.Excluded.IsDefaultOrEmpty)
            {
                writer.WriteStartArray("Excluded");
                foreach (var item in segment.Excluded.Order(StringComparer.Ordinal))
                {
                    writer.WriteStringValue(item);
                }
                writer.WriteEndArray();
            }
            writer.WriteEndObject();
        }
        if (recipe.ObjectIds is { } objectIds)
        {
            writer.WriteStartArray("ObjectIds");
            foreach (var id in objectIds.Select(NormalizeGuid).Order(StringComparer.Ordinal))
            {
                writer.WriteStringValue(id);
            }
            writer.WriteEndArray();
        }
        if (!recipe.Parameters.IsDefaultOrEmpty)
        {
            writer.WriteStartArray("Parameters");
            foreach (var parameter in recipe.Parameters)
            {
                writer.WriteStartObject();
                writer.WriteString("Name", parameter.Name);
                writer.WriteString("Field", parameter.Field);
                writer.WritePropertyName("Default");
                WriteValue(writer, parameter.Default);
                if (parameter.Label is not null)
                {
                    writer.WriteString("Label", parameter.Label);
                }
                if (parameter.Minimum is decimal min)
                {
                    writer.WriteNumber("Minimum", min);
                }
                if (parameter.Maximum is decimal max)
                {
                    writer.WriteNumber("Maximum", max);
                }
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
        }
        var parameters = effectiveParameters ?? recipe.ParameterValues;
        if (parameters is not null && parameters.Count > 0)
        {
            writer.WritePropertyName("ParameterValues");
            writer.WriteStartObject();
            foreach (var pair in parameters.OrderBy(p => p.Key, StringComparer.Ordinal))
            {
                writer.WritePropertyName(pair.Key);
                WriteValue(writer, pair.Value);
            }
            writer.WriteEndObject();
        }
        if (recipe.Expression is { } expression)
        {
            writer.WritePropertyName("Expression");
            WriteNode(writer, expression);
        }
        if (recipe.CoherenceHours is decimal coherence)
        {
            writer.WriteNumber("CoherenceHours", coherence);
        }
        if (recipe.ReadDefinition is { } read)
        {
            writer.WritePropertyName("ReadDefinition");
            writer.WriteStartObject();
            writer.WriteString("Format", read.Format);
            writer.WriteString("Namespace", read.Namespace);
            writer.WriteString("ClassName", read.ClassName);
            writer.WriteString("CanonicalQuery", read.CanonicalQuery);
            writer.WriteStartArray("Properties");
            foreach (var property in read.Properties)
            {
                writer.WriteStringValue(property);
            }
            writer.WriteEndArray();
            writer.WriteString("RequestKey", read.RequestKey);
            writer.WriteNumber("Limit", read.Limit);
            writer.WriteEndObject();
        }
        writer.WriteEndObject();
    }

    /// <summary>
    /// SHA-256 of everything a definition evaluates, in canonical form (Domenia 1 Get-DomeniaQueryDefinitionFingerprint):
    /// key order, number scale, GUID order and an explicit default parameter value never change it; any other element does.
    /// </summary>
    public static string Fingerprint(QueryRecipe recipe, IReadOnlyDictionary<string, QueryValue>? effectiveParameters = null)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        using var document = JsonDocument.Parse(Write(recipe, effectiveParameters: effectiveParameters));
        var builder = new StringBuilder();
        Canonical(document.RootElement, builder, 0);
        return Sha256(builder.ToString());
    }

    public static string Sha256(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text ?? "")));

    /// <summary>Lower-case « D » form of a GUID, or the trimmed text when it is not one.</summary>
    public static string NormalizeGuid(string value) =>
        Guid.TryParse((value ?? "").Trim().Trim('{', '}'), out var guid) ? guid.ToString("D") : (value ?? "").Trim().ToLowerInvariant();

    internal static QueryDefinitionException Invalid(string reason) => new(QueryTexts.InvalidMessage(reason));

    /// <summary>Contract version check (Domenia 1 point 133): versions 1 to <paramref name="max"/> are read, a newer one is refused with its version.</summary>
    public static void CheckFormat(string format, string family, int max, string what)
    {
        ArgumentNullException.ThrowIfNull(format);
        var slash = format.LastIndexOf('/');
        if (slash <= 0 || !string.Equals(format[..slash], family, StringComparison.Ordinal)
            || !int.TryParse(format[(slash + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out var version) || version < 1)
        {
            throw Invalid("format de " + what + " inconnu.");
        }
        if (version > max)
        {
            throw new QueryDefinitionException("Format de " + what + " plus récent (" + format + ") que cette version de Domenia : mettez Domenia à jour. Rien n’a été lu.");
        }
    }

    private static Dictionary<string, JsonElement> Properties(JsonElement element, string[] allowed, string what)
    {
        var values = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            var name = allowed.FirstOrDefault(a => string.Equals(a, property.Name, StringComparison.OrdinalIgnoreCase))
                ?? throw Invalid("propriété de " + what + " non reconnue (" + Clip(property.Name) + ").");
            if (!values.TryAdd(name, property.Value))
            {
                throw Invalid("propriété de " + what + " en double.");
            }
        }
        return values;
    }

    private static string Clip(string text) => text.Length <= 40 && !text.Any(char.IsControl) ? text : "…";

    private static string? OptionalString(Dictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return value.ValueKind == JsonValueKind.String ? value.GetString() : throw Invalid(FrenchText.Quote(name) + " doit être un texte.");
    }

    private static T ParseEnum<T>(string text, string what) where T : struct, Enum =>
        Enum.TryParse<T>(text, ignoreCase: true, out var value) && Enum.IsDefined(value) && !text.Any(char.IsDigit) ? value : throw Invalid(what + " inconnue.");

    private static ImmutableArray<QueryClause> ReadClauses(Dictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var array) || array.ValueKind == JsonValueKind.Null)
        {
            return [];
        }
        if (array.ValueKind != JsonValueKind.Array || array.GetArrayLength() > QueryLimits.MaxConditions * 2)
        {
            throw Invalid("liste de conditions invalide.");
        }
        return [.. array.EnumerateArray().Select(ReadClause)];
    }

    private static QueryClause ReadClause(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw Invalid("condition invalide.");
        }
        var values = Properties(element, ["Field", "Operator", "Value"], "condition");
        var field = OptionalString(values, "Field") ?? throw Invalid("condition sans information.");
        var op = OptionalString(values, "Operator") ?? throw Invalid("condition sans opérateur.");
        return new QueryClause(field, ParseEnum<QueryOperator>(op, "opérateur"), values.TryGetValue("Value", out var v) ? ReadValue(v, "valeur") : QueryValue.None);
    }

    private static QueryNode ReadNode(JsonElement element, int depth)
    {
        if (depth > QueryLimits.MaxTreeDepth)
        {
            throw Invalid("arbre de conditions limité à 8 niveaux.");
        }
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw Invalid("groupe de conditions invalide.");
        }
        var values = Properties(element, ["Kind", "Clause", "Children", "CollectionField", "Quantifier"], "groupe");
        var kind = ParseEnum<QueryNodeKind>(OptionalString(values, "Kind") ?? "", "type de groupe");
        var clause = values.TryGetValue("Clause", out var c) && c.ValueKind != JsonValueKind.Null ? ReadClause(c) : null;
        ImmutableArray<QueryNode> children = [];
        if (values.TryGetValue("Children", out var list) && list.ValueKind != JsonValueKind.Null)
        {
            if (list.ValueKind != JsonValueKind.Array || list.GetArrayLength() > QueryLimits.MaxTreeNodes)
            {
                throw Invalid("enfants de groupe invalides.");
            }
            children = [.. list.EnumerateArray().Select(child => ReadNode(child, depth + 1))];
        }
        var collection = OptionalString(values, "CollectionField");
        var quantifier = OptionalString(values, "Quantifier") is string q ? ParseEnum<CollectionQuantifier>(q, "quantificateur") : (CollectionQuantifier?)null;
        return new QueryNode(kind, clause, children, collection, quantifier);
    }

    private static QueryParameter ReadParameter(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw Invalid("paramètre invalide.");
        }
        var values = Properties(element, ["Name", "Field", "Default", "Label", "Minimum", "Maximum"], "paramètre");
        return new QueryParameter(
            OptionalString(values, "Name") ?? "",
            OptionalString(values, "Field") ?? "",
            values.TryGetValue("Default", out var d) ? ReadValue(d, "valeur par défaut") : QueryValue.None,
            OptionalString(values, "Label"),
            OptionalNumber(values, "Minimum"),
            OptionalNumber(values, "Maximum"));
    }

    private static decimal? OptionalNumber(Dictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return value.ValueKind == JsonValueKind.Number && value.TryGetDecimal(out var number) ? number : throw Invalid("borne de paramètre invalide.");
    }

    private static QueryProbeSegment ReadSegment(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw Invalid("segment de sonde invalide.");
        }
        var values = Properties(element, ["Key", "Mode", "Value", "Low", "High", "Excluded", "Numeric"], "segment");
        string? value = null;
        if (values.TryGetValue("Value", out var v) && v.ValueKind != JsonValueKind.Null)
        {
            value = v.ValueKind switch
            {
                JsonValueKind.String => v.GetString(),
                JsonValueKind.Number => v.GetRawText(),
                JsonValueKind.True => "True",
                JsonValueKind.False => "False",
                _ => throw Invalid("valeur de segment invalide."),
            };
        }
        ImmutableArray<string> excluded = [];
        if (values.TryGetValue("Excluded", out var ex) && ex.ValueKind == JsonValueKind.Array)
        {
            excluded = [.. ex.EnumerateArray().Select(x => x.ValueKind == JsonValueKind.String ? x.GetString()! : x.GetRawText())];
        }
        return new QueryProbeSegment(OptionalString(values, "Key") ?? "", OptionalString(values, "Mode") ?? "", value, OptionalNumber(values, "Low"), OptionalNumber(values, "High"), excluded);
    }

    private static WmiReadDefinition ReadDefinition(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw Invalid("lecture WMI invalide.");
        }
        var values = Properties(element, ["Format", "Namespace", "ClassName", "CanonicalQuery", "Properties", "RequestKey", "Limit"], "lecture WMI");
        ImmutableArray<string> properties = [];
        if (values.TryGetValue("Properties", out var p) && p.ValueKind == JsonValueKind.Array)
        {
            properties = [.. p.EnumerateArray().Select(x => x.ValueKind == JsonValueKind.String ? x.GetString()! : throw Invalid("propriété WMI invalide."))];
        }
        var limit = values.TryGetValue("Limit", out var l) && l.ValueKind == JsonValueKind.Number && l.TryGetInt32(out var n) ? n : 0;
        return new WmiReadDefinition(OptionalString(values, "Format") ?? "", OptionalString(values, "Namespace") ?? "", OptionalString(values, "ClassName") ?? "",
            OptionalString(values, "CanonicalQuery") ?? "", properties, OptionalString(values, "RequestKey") ?? "", limit);
    }

    private static void WriteClauses(Utf8JsonWriter writer, string name, ImmutableArray<QueryClause> clauses)
    {
        writer.WriteStartArray(name);
        foreach (var clause in clauses.IsDefault ? [] : clauses)
        {
            WriteClause(writer, clause);
        }
        writer.WriteEndArray();
    }

    private static void WriteClause(Utf8JsonWriter writer, QueryClause clause)
    {
        writer.WriteStartObject();
        writer.WriteString("Field", clause.Field);
        writer.WriteString("Operator", clause.Operator.ToString());
        writer.WritePropertyName("Value");
        WriteValue(writer, clause.Value);
        writer.WriteEndObject();
    }

    private static void WriteNode(Utf8JsonWriter writer, QueryNode node)
    {
        writer.WriteStartObject();
        writer.WriteString("Kind", node.Kind.ToString());
        if (node.Kind == QueryNodeKind.Clause && node.Clause is { } clause)
        {
            writer.WritePropertyName("Clause");
            WriteClause(writer, clause);
        }
        else
        {
            writer.WriteStartArray("Children");
            foreach (var child in node.Children.IsDefault ? [] : node.Children)
            {
                WriteNode(writer, child);
            }
            writer.WriteEndArray();
        }
        if (node.Kind == QueryNodeKind.Collection)
        {
            writer.WriteString("CollectionField", node.CollectionField ?? "");
            writer.WriteString("Quantifier", (node.Quantifier ?? CollectionQuantifier.Any).ToString());
        }
        writer.WriteEndObject();
    }

    /// <summary>Writes a literal (Domenia 1 form for a parameter: { "Parameter": "Nom" }).</summary>
    public static void WriteValue(Utf8JsonWriter writer, QueryValue value)
    {
        ArgumentNullException.ThrowIfNull(writer);
        switch (value.Kind)
        {
            case QueryValueKind.Text:
                writer.WriteStringValue(value.Text);
                break;
            case QueryValueKind.Number:
                writer.WriteNumberValue(value.Number);
                break;
            case QueryValueKind.Boolean:
                writer.WriteBooleanValue(value.Flag);
                break;
            case QueryValueKind.Parameter:
                writer.WriteStartObject();
                writer.WriteString("Parameter", value.Text);
                writer.WriteEndObject();
                break;
            default:
                writer.WriteNullValue();
                break;
        }
    }

    // Canonical text (Domenia 1 ConvertTo-DomeniaQueryCanonicalText): members sorted ordinally, null equal to absent,
    // numbers in one invariant form, length-prefixed strings.
    private static void Canonical(JsonElement element, StringBuilder builder, int depth)
    {
        if (depth > 64)
        {
            throw Invalid("définition de requête trop profonde.");
        }
        switch (element.ValueKind)
        {
            case JsonValueKind.Null:
            case JsonValueKind.Undefined:
                builder.Append("null");
                break;
            case JsonValueKind.String:
                var text = element.GetString()!;
                builder.Append('s').Append(text.Length.ToString(CultureInfo.InvariantCulture)).Append(':').Append(text);
                break;
            case JsonValueKind.True:
                builder.Append("true");
                break;
            case JsonValueKind.False:
                builder.Append("false");
                break;
            case JsonValueKind.Number:
                builder.Append('n').Append(element.TryGetDecimal(out var number) ? (number / 1.000000000000000000000000000000000m).ToString("G29", CultureInfo.InvariantCulture) : element.GetRawText());
                break;
            case JsonValueKind.Array:
                builder.Append('[');
                foreach (var item in element.EnumerateArray())
                {
                    Canonical(item, builder, depth + 1);
                    builder.Append(',');
                }
                builder.Append(']');
                break;
            case JsonValueKind.Object:
                builder.Append('{');
                foreach (var property in element.EnumerateObject().Where(p => p.Value.ValueKind != JsonValueKind.Null).OrderBy(p => p.Name, StringComparer.Ordinal))
                {
                    builder.Append('s').Append(property.Name.Length.ToString(CultureInfo.InvariantCulture)).Append(':').Append(property.Name).Append('=');
                    Canonical(property.Value, builder, depth + 1);
                    builder.Append(';');
                }
                builder.Append('}');
                break;
        }
    }
}
