using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Strict validation of the « args » of a request (docs/OPERATIONS.md § 1.4). Failures raise arguments.invalid with a fixed
/// precision; the page's input is never copied into the message.
/// </summary>
public static class BridgeArguments
{
    public const string NoneAccepted = "cette opération n’en accepte aucun.";
    public const string ObjectExpected = "un objet JSON est attendu.";
    public const string PropertyNotAllowed = "propriété non admise.";

    /// <summary>Operation without arguments: « args » absent, null or {}.</summary>
    public static void RequireNone(JsonElement arguments)
    {
        switch (arguments.ValueKind)
        {
            case JsonValueKind.Undefined:
            case JsonValueKind.Null:
                return;
            case JsonValueKind.Object:
                if (arguments.EnumerateObject().Any())
                {
                    throw Invalid(NoneAccepted);
                }
                return;
            default:
                throw Invalid(ObjectExpected);
        }
    }

    /// <summary>Object with only the allowed properties, each at most once.</summary>
    public static IReadOnlyDictionary<string, JsonElement> ReadObject(JsonElement arguments, IReadOnlyCollection<string> allowedNames)
    {
        ArgumentNullException.ThrowIfNull(allowedNames);
        if (arguments.ValueKind != JsonValueKind.Object)
        {
            throw Invalid(ObjectExpected);
        }
        var values = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in arguments.EnumerateObject())
        {
            if (!allowedNames.Contains(property.Name, StringComparer.Ordinal) || !values.TryAdd(property.Name, property.Value))
            {
                throw Invalid(PropertyNotAllowed);
            }
        }
        return values;
    }

    public static string GetString(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        ArgumentNullException.ThrowIfNull(values);
        return values.TryGetValue(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()!
            : throw Invalid(FrenchText.Quote(name) + " est obligatoire et doit être un texte.");
    }

    public static bool GetBoolean(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        ArgumentNullException.ThrowIfNull(values);
        if (values.TryGetValue(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False)
        {
            return value.GetBoolean();
        }
        throw Invalid(FrenchText.Quote(name) + " est obligatoire et doit valoir true ou false.");
    }

    private static BridgeOperationException Invalid(string precision) =>
        new(DomeniaErrors.ArgumentsInvalid, "Arguments invalides" + FrenchText.Colon + precision);
}
