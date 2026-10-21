using System.Text.Json;

namespace Domenia.Core;

/// <summary>How the configuration file next to the executable was found.</summary>
public enum ConfigurationFileState
{
    /// <summary>No file: default settings, nothing to report.</summary>
    Absent,

    /// <summary>File read and understood.</summary>
    Read,

    /// <summary>File present but unusable (JSON error, too large, duplicate names, unreadable): ignored, traced.</summary>
    Invalid,
}

/// <summary>What Domenia 2 takes from Domenia.config.json today: Auth.DemoProvider only.</summary>
/// <param name="Problem">Short technical reason for <see cref="ConfigurationFileState.Invalid"/>; never the content of the file.</param>
public sealed record LegacyConfiguration(ConfigurationFileState State, bool DemoProvider, string? Problem)
{
    public const string FileName = "Domenia.config.json";

    /// <summary>Larger files are refused before parsing.</summary>
    public const int MaxBytes = 1_048_576;

    public static LegacyConfiguration Absent { get; } = new(ConfigurationFileState.Absent, false, null);

    public static LegacyConfiguration Invalid(string problem) => new(ConfigurationFileState.Invalid, false, problem);

    /// <summary>
    /// Reads the JSON of Domenia 1 (UTF-8, byte order mark tolerated). Same rules as Domenia 1: section and key names are
    /// case insensitive (ConvertFrom-Json), a name present twice in different case makes the file unreadable, and only the
    /// JSON boolean true enables the demonstration provider (Test-DomeniaDemoProviderEnabled: the text "true" does not).
    /// Pure: no file access.
    /// </summary>
    public static LegacyConfiguration Parse(ReadOnlySpan<byte> utf8)
    {
        if (utf8.Length > MaxBytes)
        {
            return Invalid("fichier de plus de 1 Mo");
        }
        if (utf8.StartsWith("\uFEFF"u8))
        {
            utf8 = utf8[3..];
        }
        try
        {
            // Whole input validated: nothing may follow the root value.
            using var document = JsonDocument.Parse(utf8.ToArray(), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return Invalid("objet JSON attendu");
            }
            if (!TryGetUnique(root, "Auth", out var auth, out var duplicate))
            {
                return duplicate ? Invalid("section Auth en double") : new(ConfigurationFileState.Read, false, null);
            }
            if (auth.ValueKind != JsonValueKind.Object)
            {
                return new(ConfigurationFileState.Read, false, null);
            }
            if (!TryGetUnique(auth, "DemoProvider", out var demo, out duplicate))
            {
                return duplicate ? Invalid("clé Auth.DemoProvider en double") : new(ConfigurationFileState.Read, false, null);
            }
            return new(ConfigurationFileState.Read, demo.ValueKind == JsonValueKind.True, null);
        }
        catch (JsonException)
        {
            // The parser message may quote the file: only a fixed reason is kept.
            return Invalid("JSON illisible");
        }
    }

    private static bool TryGetUnique(JsonElement element, string name, out JsonElement value, out bool duplicate)
    {
        value = default;
        duplicate = false;
        var found = false;
        foreach (var property in element.EnumerateObject())
        {
            if (!string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (found)
            {
                duplicate = true;
                return false;
            }
            value = property.Value;
            found = true;
        }
        return found;
    }
}
