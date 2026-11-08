using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Settings of the « Synchronisation et base autonome » screen read from Domenia.config.json, section « Index » (Domenia 1
/// Get-CfgValue 'Index' …): object quota and time budget of a pass, census threshold, age of the base after which a startup
/// notice advises an update. A missing, invalid or out of range key keeps its default; an unreadable file keeps every
/// default. <see cref="Keys"/> names the keys really taken from the file (for the page: « lu dans Domenia.config.json »).
/// </summary>
public sealed record SyncSettings(long MaxObjects, int BudgetMs, int FullRebuildDays, int StartupDeltaMaxAgeMinutes, ConfigurationFileState State, string? Problem, ImmutableArray<string> Keys)
{
    public static SyncSettings Default { get; } = new(SyncCoverageRules.DefaultMaxObjects, SyncCoverageRules.DefaultBudgetMs, SyncCoverageRules.DefaultFullRebuildDays,
        SyncCoverageRules.DefaultStartupDeltaMaxAgeMinutes, ConfigurationFileState.Absent, null, []);

    /// <summary>Where the limits come from, in plain words.</summary>
    public string Source => Keys.IsDefaultOrEmpty
        ? (State == ConfigurationFileState.Invalid ? "Réglages par défaut (Domenia.config.json ignoré" + FrenchText.Colon + Problem + ")" : "Réglages par défaut")
        : "Domenia.config.json" + FrenchText.Colon + string.Join(", ", Keys.Select(k => "Index." + k));

    /// <summary>The settings for an unreadable file: every default, the reason kept (never the content).</summary>
    public static SyncSettings Invalid(string problem) => Default with { State = ConfigurationFileState.Invalid, Problem = problem };

    /// <summary>
    /// Reads the section « Index » of the JSON of Domenia 1 (UTF-8, byte order mark tolerated, 1 Mo at most). Same rules as
    /// <see cref="LegacyConfiguration.Parse"/>: names case insensitive, a name present twice in different case makes the
    /// section unreadable. A value is a JSON integer or a text of digits (the [int] cast of Domenia 1). Pure: no file access.
    /// </summary>
    public static SyncSettings Parse(ReadOnlySpan<byte> utf8)
    {
        if (utf8.Length > LegacyConfiguration.MaxBytes)
        {
            return Invalid("fichier de plus de 1 Mo");
        }
        if (utf8.StartsWith("﻿"u8))
        {
            utf8 = utf8[3..];
        }
        try
        {
            using var document = JsonDocument.Parse(utf8.ToArray(), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return Invalid("objet JSON attendu");
            }
            var section = Unique(root, "Index", out var duplicate);
            if (duplicate)
            {
                return Invalid("section Index en double");
            }
            var read = Default with { State = ConfigurationFileState.Read };
            if (section is not { ValueKind: JsonValueKind.Object } index)
            {
                return read;
            }
            var keys = ImmutableArray.CreateBuilder<string>();
            long? Value(string name, long min, long max)
            {
                var element = Unique(index, name, out var twice);
                if (twice || element is not { } value)
                {
                    return null;
                }
                long number;
                if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var n))
                {
                    number = n;
                }
                else if (value.ValueKind == JsonValueKind.String && long.TryParse(value.GetString(), NumberStyles.AllowLeadingWhite | NumberStyles.AllowTrailingWhite, CultureInfo.InvariantCulture, out var t))
                {
                    number = t;
                }
                else
                {
                    return null;
                }
                if (number < min || number > max)
                {
                    return null;
                }
                keys.Add(name);
                return number;
            }
            var maxObjects = Value("MaxObjects", 0, 10_000_000) ?? Default.MaxObjects;
            var budget = (int)(Value("BudgetMs", 1, 7_200_000) ?? Default.BudgetMs);
            var days = (int)(Value("FullRebuildDays", 1, 90) ?? Default.FullRebuildDays);
            var startup = (int)(Value("StartupDeltaMaxAgeMinutes", 1, 525_600) ?? Default.StartupDeltaMaxAgeMinutes);
            return read with { MaxObjects = maxObjects, BudgetMs = budget, FullRebuildDays = days, StartupDeltaMaxAgeMinutes = startup, Keys = keys.ToImmutable() };
        }
        catch (JsonException)
        {
            // The parser message may quote the file: only a fixed reason is kept.
            return Invalid("JSON illisible");
        }
    }

    private static JsonElement? Unique(JsonElement element, string name, out bool duplicate)
    {
        duplicate = false;
        JsonElement? found = null;
        foreach (var property in element.EnumerateObject())
        {
            if (!string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (found is not null)
            {
                duplicate = true;
                return null;
            }
            found = property.Value;
        }
        return found;
    }
}
