using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Bridge.Operations.Requetes;

/// <summary>
/// Strict reading of the arguments of the query workshop (docs/ops/requetes.md): fixed French precisions, the page's input is
/// never copied into a message; query refusals become « query.invalid » with the reason of the engine.
/// </summary>
internal static class RequetesArgs
{
    /// <summary>Arguments that may be absent: « args » absent or null gives no value; otherwise the object rules apply.</summary>
    public static IReadOnlyDictionary<string, JsonElement> Optional(JsonElement args, string[] allowed) =>
        args.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null ? new Dictionary<string, JsonElement>() : BridgeArguments.ReadObject(args, allowed);

    public static QueryRecipe Recipe(IReadOnlyDictionary<string, JsonElement> values, string name = "recipe")
    {
        if (!values.TryGetValue(name, out var element) || element.ValueKind != JsonValueKind.Object)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " est obligatoire et doit être une requête (objet JSON).");
        }
        try
        {
            return QueryRecipeJson.Read(element);
        }
        catch (QueryDefinitionException ex)
        {
            throw new DomeniaOperationException(QueryErrors.Invalid, ex.Message);
        }
    }

    public static string Text(IReadOnlyDictionary<string, JsonElement> values, string name, int maxLength)
    {
        var text = BridgeArguments.GetString(values, name);
        return text.Length <= maxLength ? text : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit faire au plus " + FrenchText.Integer(maxLength) + " caractères.");
    }

    public static string? OptionalText(IReadOnlyDictionary<string, JsonElement> values, string name, int maxLength)
    {
        var text = BridgeArguments.GetOptionalString(values, name);
        return text is null || text.Length <= maxLength ? text : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit faire au plus " + FrenchText.Integer(maxLength) + " caractères.");
    }

    public static string Id32(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var text = BridgeArguments.GetString(values, name);
        return text.Length == 32 && text.All(char.IsAsciiHexDigitLower) ? text : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un identifiant (32 caractères hexadécimaux).");
    }

    public static string RecipeId(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var text = BridgeArguments.GetString(values, name);
        return QueryRecipeJson.IdPattern().IsMatch(text) ? text : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un identifiant de requête.");
    }

    public static Guid Guid(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var text = BridgeArguments.GetString(values, name);
        return System.Guid.TryParse(text, out var guid) && guid != System.Guid.Empty ? guid : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un GUID.");
    }

    public static int Int(IReadOnlyDictionary<string, JsonElement> values, string name, int min, int max, int fallback)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return fallback;
        }
        return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) && number >= min && number <= max
            ? number
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un entier de " + FrenchText.Integer(min) + " à " + FrenchText.Integer(max) + ".");
    }

    public static long Long(IReadOnlyDictionary<string, JsonElement> values, string name, long min, long max)
    {
        return values.TryGetValue(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number) && number >= min && number <= max
            ? number
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un entier de " + FrenchText.Integer(min) + " à " + FrenchText.Integer(max) + ".");
    }

    public static decimal? OptionalDecimal(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return value.ValueKind == JsonValueKind.Number && value.TryGetDecimal(out var number) ? number : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un nombre ou null.");
    }

    public static bool Bool(IReadOnlyDictionary<string, JsonElement> values, string name, bool fallback)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return fallback;
        }
        return value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit valoir true ou false.");
    }

    public static string Choice(IReadOnlyDictionary<string, JsonElement> values, string name, string fallback, params string[] allowed)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return fallback;
        }
        return value.ValueKind == JsonValueKind.String && allowed.Contains(value.GetString(), StringComparer.Ordinal)
            ? value.GetString()!
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit valoir " + string.Join(", ", allowed) + ".");
    }

    public static QueryTarget Target(IReadOnlyDictionary<string, JsonElement> values, string name = "target") =>
        Choice(values, name, "computer", "computer", "user", "group") switch
        {
            "user" => QueryTarget.User,
            "group" => QueryTarget.Group,
            _ => QueryTarget.Computer,
        };

    public static ImmutableArray<string> Strings(IReadOnlyDictionary<string, JsonElement> values, string name, int maxItems, int maxLength)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return [];
        }
        if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > maxItems)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être une liste d’au plus " + FrenchText.Integer(maxItems) + " textes.");
        }
        return [.. value.EnumerateArray().Select(item => item.ValueKind == JsonValueKind.String && item.GetString()!.Length <= maxLength
            ? item.GetString()!
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " contient un élément invalide."))];
    }

    public static IReadOnlyDictionary<string, string> StringMap(IReadOnlyDictionary<string, JsonElement> values, string name, int maxItems)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind != JsonValueKind.Object)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " est obligatoire et doit être un objet.");
        }
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            if (map.Count >= maxItems || property.Value.ValueKind != JsonValueKind.String || !map.TryAdd(property.Name, property.Value.GetString()!))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote(name) + " contient un élément invalide.");
            }
        }
        return map;
    }

    /// <summary>Runs an engine call and turns its expected refusals into bridge errors with the engine's French reason.</summary>
    public static async Task<object?> Guard(Func<Task<object?>> body)
    {
        try
        {
            return await body().ConfigureAwait(false);
        }
        catch (QueryDefinitionException ex)
        {
            throw new DomeniaOperationException(CodeOf(ex.Message), ex.Message);
        }
        catch (LdapFilterException ex)
        {
            throw new DomeniaOperationException(QueryErrors.LdapInvalid, ex.Message);
        }
    }

    public static Task<object?> Guard(Func<object?> body) => Guard(() => Task.FromResult(body()));

    /// <summary>Error code of a refusal of the library, so the page can react (re-read, copy, archive) instead of only showing it.</summary>
    public static string CodeOf(string message)
    {
        ArgumentNullException.ThrowIfNull(message);
        if (message == QueryErrors.NotFoundMessage)
        {
            return QueryErrors.NotFound;
        }
        if (message == QueryErrors.ImportUnknownMessage)
        {
            return QueryErrors.ImportUnknown;
        }
        if (message.StartsWith("La requête a changé", StringComparison.Ordinal))
        {
            return QueryErrors.RevisionChanged;
        }
        if (message.StartsWith("Un modèle livré", StringComparison.Ordinal))
        {
            return QueryErrors.TemplateReadOnly;
        }
        if (message.StartsWith("Bibliothèque locale pleine", StringComparison.Ordinal) || message.Contains("1 000 requêtes", StringComparison.Ordinal))
        {
            return QueryErrors.LibraryFull;
        }
        return QueryErrors.Invalid;
    }
}
