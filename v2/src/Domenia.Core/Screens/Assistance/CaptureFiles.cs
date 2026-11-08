using System.Collections.Immutable;
using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Domenia.Core;

/// <summary>
/// Historical capture files (Domenia 1 Use-DomeniaCaptureFile, ConvertTo-DomeniaStoredCapture, format Domenia.Capture.1): only
/// the allowlist is written and read back; a capture of another domain, of an unknown format or dated in the future is refused;
/// coverage not provided becomes partial. A loaded capture stays historical (source « cache ») and never becomes a current
/// directory read. The JSON keeps the property names of Domenia 1, so files of both versions are interchangeable.
/// </summary>
public static class CaptureFiles
{
    public const string Format = "Domenia.Capture.1";
    public const int MaxBytes = 1_048_576;
    private static readonly TimeSpan FutureTolerance = TimeSpan.FromMinutes(5);

    private static readonly JsonSerializerOptions Indented = new() { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private static string TypeOf(string kind) => kind switch
    {
        "user" => "Utilisateur",
        "computer" => "Machine",
        "group" => "Groupe",
        _ => "Objet",
    };

    private static string KindOf(string? type) => type switch
    {
        "Utilisateur" or "user" or "User" => "user",
        "Machine" or "computer" or "Computer" or "Poste" => "computer",
        "Groupe" or "group" or "Group" => "group",
        _ => "object",
    };

    /// <summary>JSON text of a capture, as Domenia 1 writes it (the source is always « Cache »: a file is never a fresh read).</summary>
    public static string Export(SupportSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var fields = new JsonObject();
        var coverage = new JsonObject();
        foreach (var field in snapshot.Fields)
        {
            if (field.Coverage != FieldCoverage.NotProvided)
            {
                var values = new JsonArray();
                foreach (var value in field.Values.Take(SupportSnapshots.MaxValues))
                {
                    values.Add((JsonNode?)JsonValue.Create(value));
                }
                fields[field.Name] = values;
            }
            coverage[field.Name] = field.Coverage.ToString();
        }
        var capture = new JsonObject
        {
            ["Format"] = SupportSnapshots.CurrentFormat,
            ["Id"] = snapshot.Id,
            ["Identity"] = snapshot.Identity,
            ["Scope"] = snapshot.Scope,
            ["Dn"] = snapshot.Dn,
            ["Name"] = snapshot.Name,
            ["Type"] = TypeOf(snapshot.Kind),
            ["Source"] = "Cache",
            ["ObservedAtUtc"] = snapshot.ObservedAt.UtcDateTime.ToString("o", CultureInfo.InvariantCulture),
            ["CapturedAtUtc"] = snapshot.CapturedAt.UtcDateTime.ToString("o", CultureInfo.InvariantCulture),
            ["Fields"] = fields,
            ["Coverage"] = coverage,
            ["FieldCount"] = snapshot.FieldCount,
        };
        return new JsonObject { ["Format"] = Format, ["Capture"] = capture }.ToJsonString(Indented);
    }

    /// <summary>
    /// Reads a capture file back for the domain of the session. Every refusal raises assistance.captureInvalid with a fixed
    /// reason (the content of the file is never repeated).
    /// </summary>
    public static SupportSnapshot Import(string content, string domainRootDn, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(content);
        ArgumentNullException.ThrowIfNull(domainRootDn);
        if (content.Length == 0 || content.Length > MaxBytes)
        {
            throw Refuse("fichier vide ou trop volumineux (1 Mio au plus).");
        }
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(content, documentOptions: new JsonDocumentOptions { MaxDepth = 16, CommentHandling = JsonCommentHandling.Disallow });
        }
        catch (JsonException)
        {
            throw Refuse("JSON illisible.");
        }
        if (root is not JsonObject document || Text(document, "Format") != Format)
        {
            throw Refuse("format inconnu (Domenia.Capture.1 attendu).");
        }
        if (document["Capture"] is not JsonObject capture || capture["Format"] is not JsonValue formatValue
            || !formatValue.TryGetValue<int>(out var format) || format != SupportSnapshots.CurrentFormat)
        {
            throw Refuse("capture absente ou d’une version inconnue.");
        }
        var scope = Text(capture, "Scope");
        if (scope is null || !string.Equals(scope.Trim(), domainRootDn.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            throw Refuse("capture d’un autre domaine.");
        }
        if (!TryDate(Text(capture, "ObservedAtUtc"), out var observed) || !TryDate(Text(capture, "CapturedAtUtc"), out var captured))
        {
            throw Refuse("dates de la capture invalides.");
        }
        if (observed > now + FutureTolerance || captured > now + FutureTolerance)
        {
            throw Refuse("capture datée dans le futur.");
        }
        var properties = new Dictionary<string, IReadOnlyList<object?>>(StringComparer.OrdinalIgnoreCase);
        var declared = new Dictionary<string, FieldCoverage>(StringComparer.Ordinal);
        var fields = capture["Fields"] as JsonObject;
        var coverage = capture["Coverage"] as JsonObject;
        foreach (var name in SupportSnapshots.FieldNames)
        {
            if (fields is not null && fields.TryGetPropertyValue(name, out var node) && node is not null)
            {
                properties[name] = Values(node);
            }
            var state = coverage is not null && coverage.TryGetPropertyValue(name, out var stateNode) && stateNode is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
            declared[name] = state == "Provided" ? FieldCoverage.Provided : FieldCoverage.Partial;
        }
        var snapshot = SupportSnapshots.Create(properties, domainRootDn, Text(capture, "Dn") ?? "", Text(capture, "Name") ?? "", KindOf(Text(capture, "Type")),
            SnapshotSource.Cache, observed, captured);
        return SupportSnapshots.AsHistorical(snapshot, declared);
    }

    private static IReadOnlyList<object?> Values(JsonNode node)
    {
        if (node is JsonArray array)
        {
            return [.. array.Take(SupportSnapshots.MaxValues + 1).Select(ValueText)];
        }
        return [ValueText(node)];
    }

    private static object? ValueText(JsonNode? node) => node switch
    {
        JsonValue value when value.TryGetValue<string>(out var text) => text,
        JsonValue value => value.ToJsonString(),
        null => null,
        // Nested objects are not part of the format: excluded rather than flattened.
        _ => new object(),
    };

    private static string? Text(JsonObject source, string name) =>
        source.TryGetPropertyValue(name, out var node) && node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static bool TryDate(string? text, out DateTimeOffset value) =>
        DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out value);

    private static DomeniaOperationException Refuse(string reason) =>
        new(AssistanceErrors.CaptureInvalid, "Capture refusée" + FrenchText.Colon + reason + " Rien n’a été chargé.");
}
