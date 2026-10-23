using System.Text.Json;

namespace Domenia.Inventory;

internal static class RemoteTaskReadJson
{
    internal static void Object(JsonElement value, params string[] keys)
    {
        if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Count() != keys.Length
            || value.EnumerateObject().Select(p => p.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != keys.Length
            || keys.Any(k => !value.TryGetProperty(k, out _))) { throw new JsonException("Réponse hors contrat fermé."); }
    }
    internal static string? Text(JsonElement value, string key, int max = 4096)
    {
        var item = value.GetProperty(key);
        if (item.ValueKind == JsonValueKind.Null) { return null; }
        if (item.ValueKind != JsonValueKind.String || item.GetString() is not { } text || text.Length > max || text.Any(char.IsControl)) { throw new JsonException(); }
        return text;
    }
    internal static int Int(JsonElement value, string key) => value.GetProperty(key).ValueKind == JsonValueKind.Number && value.GetProperty(key).TryGetInt32(out var number) ? number : throw new JsonException();
    internal static bool Bool(JsonElement value, string key) => value.GetProperty(key).ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => throw new JsonException() };
    internal static object? Value(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Null => null,
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Number => value.TryGetInt64(out var number) ? number : throw new JsonException(),
        JsonValueKind.String => value.GetString() is { Length: <= 4096 } text && !text.Any(char.IsControl) ? text : throw new JsonException(),
        JsonValueKind.Array => value.GetArrayLength() <= 64 ? value.EnumerateArray().Select(v => v.ValueKind == JsonValueKind.Array ? throw new JsonException() : Value(v)).ToArray() : throw new JsonException(),
        _ => throw new JsonException(),
    };
}
