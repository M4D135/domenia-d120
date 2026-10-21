using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Domenia.Bridge;

/// <summary>
/// JSON rules of the contract (docs/OPERATIONS.md § 1.2): camelCase names, enumerations as camelCase text, dates in UTC to the
/// second with « Z », dates as yyyy-MM-dd, null fields written. Only <see cref="BridgeResponse.Error"/> is omitted when null.
/// </summary>
public static class BridgeJson
{
    public static JsonSerializerOptions Options { get; } = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.Never,
            WriteIndented = false,
        };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        options.Converters.Add(new UtcSecondsConverter());
        options.Converters.Add(new IsoDateConverter());
        options.MakeReadOnly(populateMissingResolver: true);
        return options;
    }

    /// <summary>Instant as « 2026-10-21T16:14:00Z »: always UTC, truncated to the second.</summary>
    private sealed class UtcSecondsConverter : JsonConverter<DateTimeOffset>
    {
        private const string Format = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'";

        public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            var text = reader.GetString();
            return DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var value)
                ? value
                : throw new JsonException("Invalid date and time.");
        }

        public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options)
        {
            ArgumentNullException.ThrowIfNull(writer);
            writer.WriteStringValue(value.UtcDateTime.ToString(Format, CultureInfo.InvariantCulture));
        }
    }

    /// <summary>Local calendar day as « 2026-10-21 ».</summary>
    private sealed class IsoDateConverter : JsonConverter<DateOnly>
    {
        private const string Format = "yyyy'-'MM'-'dd";

        public override DateOnly Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            DateOnly.TryParseExact(reader.GetString(), Format, CultureInfo.InvariantCulture, DateTimeStyles.None, out var value)
                ? value
                : throw new JsonException("Invalid date.");

        public override void Write(Utf8JsonWriter writer, DateOnly value, JsonSerializerOptions options)
        {
            ArgumentNullException.ThrowIfNull(writer);
            writer.WriteStringValue(value.ToString(Format, CultureInfo.InvariantCulture));
        }
    }
}
