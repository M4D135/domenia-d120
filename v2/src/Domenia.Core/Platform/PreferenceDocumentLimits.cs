using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>One budget for normal changes, imports and simulation. Unknown screen keys are preserved within it.</summary>
public static class PreferenceDocumentLimits
{
    public const int MaxKeys = 256;
    public const int MaxBytes = 1_048_576;

    public static byte[] Encode(IReadOnlyDictionary<string, JsonElement> values)
    {
        if (values.Count > MaxKeys) throw new InvalidDataException("Plus de 256 préférences ; choix précédent conservé.");
        long rawBytes = 0;
        foreach (var (key, value) in values)
        {
            PreferenceKeys.Require(key);
            rawBytes += Encoding.UTF8.GetByteCount(value.GetRawText());
            if (rawBytes > MaxBytes) throw TooLarge();
        }
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject(); writer.WriteString("format", "domenia.preferences"); writer.WriteNumber("version", 1);
            writer.WriteStartObject("values");
            foreach (var (key, value) in values.OrderBy(p => p.Key, StringComparer.Ordinal))
            { writer.WritePropertyName(key); value.WriteTo(writer); }
            writer.WriteEndObject(); writer.WriteEndObject();
        }
        if (buffer.Length > MaxBytes) throw TooLarge();
        return buffer.ToArray();
    }

    public static void RequireChange(IReadOnlyDictionary<string, JsonElement> current, string key, JsonElement? value)
    {
        var next = new Dictionary<string, JsonElement>(current, StringComparer.Ordinal);
        if (value is { } element) next[key] = element; else next.Remove(key);
        _ = Encode(next);
    }

    private static InvalidDataException TooLarge() => new("Préférences supérieures à 1 Mio ; choix précédent conservé.");
}
