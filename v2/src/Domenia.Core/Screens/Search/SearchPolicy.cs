using System.Collections.Immutable;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Settings that bound the search screen, as Domenia 1 read them (RCH-067, RCH-073, RCH-090, RCH-092, RCH-093): the
/// revalidation of the listed objects that only an administrator turns on (Streaming.RevalidateListedObjects and
/// Streaming.RevalidateIntervalSeconds of Domenia.config.json), the actions an administrator hides or greys (UI.Elements,
/// the GuiElementPolicy of Domenia 1 with the identifiers of Domenia 2: « rechercher.export »), and the survey budgets of
/// Paramètres (preference settings.collection: concurrency, maxTargets, ex Park.MaxTargets and Collection.Concurrency).
/// Values out of bounds are ignored and said (<see cref="Problems"/>), never guessed.
/// </summary>
public sealed record SearchPolicy(
    bool RevalidateListed,
    int RevalidateSeconds,
    string RevalidateSource,
    int MaxTargets,
    int Concurrency,
    int PingBatch,
    ImmutableArray<string> HiddenActions,
    ImmutableArray<string> DisabledActions,
    ImmutableArray<string> Problems);

/// <summary>Pure rules of <see cref="SearchPolicy"/>: reading of the configuration file and of the collection settings.</summary>
public static class SearchPolicyRules
{
    /// <summary>Revalidation of the listed objects: every 60 s by default, 30 to 600 (Domenia 1 RevalidateIntervalSeconds).</summary>
    public const int RevalidateDefault = 60;
    public const int RevalidateMinimum = 30;
    public const int RevalidateMaximum = 600;

    /// <summary>Workstations read at the same time by a survey (Collection.Concurrency of Domenia 1: 4 by default, 1 to 8).</summary>
    public const int ConcurrencyDefault = 4;
    public const int ConcurrencyMaximum = 8;

    /// <summary>Survey ceiling stored by Paramètres (1 to 20 000); the admission still caps a survey at 5 000 (SearchSurvey.Admit).</summary>
    public const int MaxTargetsStoredMaximum = 20000;

    /// <summary>ICMP echoes sent in parallel by batches of 192 (256 at most), as the mass ping of Domenia 1 (RCH-092).</summary>
    public const int PingBatch = 192;
    public const int PingBatchMaximum = 256;

    /// <summary>Prefix of the identifiers of this screen in UI.Elements.</summary>
    public const string ElementPrefix = "rechercher.";

    public static SearchPolicy Default { get; } = new(false, RevalidateDefault, "défaut", SearchSurvey.MaxTargets, ConcurrencyDefault, PingBatch, [], [], []);

    /// <summary>
    /// Policy from the root of Domenia.config.json (null: no file) and the stored collection settings of Paramètres (null: never
    /// set). Section and key names are read without case, as Domenia 1 (Get-CfgValue).
    /// </summary>
    public static SearchPolicy Read(JsonElement? configuration, JsonElement? collectionSettings)
    {
        var problems = new List<string>();
        var revalidate = false;
        var seconds = RevalidateDefault;
        var source = "défaut";
        var hidden = new SortedSet<string>(StringComparer.Ordinal);
        var disabled = new SortedSet<string>(StringComparer.Ordinal);
        if (configuration is JsonElement root && root.ValueKind == JsonValueKind.Object)
        {
            if (Section(root, "Streaming") is JsonElement streaming)
            {
                if (Value(streaming, "RevalidateListedObjects") is JsonElement flag)
                {
                    if (Flag(flag) is bool on)
                    {
                        revalidate = on;
                        source = "Domenia.config.json";
                    }
                    else
                    {
                        problems.Add("Streaming.RevalidateListedObjects illisible" + FrenchText.Colon + "revalidation laissée désactivée.");
                    }
                }
                if (Value(streaming, "RevalidateIntervalSeconds") is JsonElement interval)
                {
                    if (interval.ValueKind == JsonValueKind.Number && interval.TryGetInt32(out var value) && value >= RevalidateMinimum && value <= RevalidateMaximum)
                    {
                        seconds = value;
                    }
                    else
                    {
                        problems.Add("Streaming.RevalidateIntervalSeconds hors limites (30 à 600)" + FrenchText.Colon + "60 secondes.");
                    }
                }
            }
            if (Section(root, "UI") is JsonElement ui && Value(ui, "Elements") is JsonElement elements && elements.ValueKind == JsonValueKind.Object)
            {
                foreach (var element in elements.EnumerateObject())
                {
                    if (!element.Name.StartsWith(ElementPrefix, StringComparison.OrdinalIgnoreCase) || element.Name.Length > 64 || element.Value.ValueKind != JsonValueKind.String)
                    {
                        continue;
                    }
                    var id = element.Name.ToLowerInvariant();
                    switch (Mode(element.Value.GetString()))
                    {
                        case "hidden":
                            hidden.Add(id);
                            break;
                        case "disabled":
                            disabled.Add(id);
                            break;
                        case "default":
                            break;
                        default:
                            problems.Add("UI.Elements" + FrenchText.Colon + "valeur inconnue pour " + id + " (Default, Disabled ou Hidden).");
                            break;
                    }
                }
            }
        }
        var concurrency = ConcurrencyDefault;
        var maxTargets = SearchSurvey.MaxTargets;
        if (collectionSettings is JsonElement settings && settings.ValueKind == JsonValueKind.Object)
        {
            if (settings.TryGetProperty("concurrency", out var c))
            {
                if (c.ValueKind == JsonValueKind.Number && c.TryGetInt32(out var n) && n >= 1 && n <= ConcurrencyMaximum)
                {
                    concurrency = n;
                }
                else
                {
                    problems.Add("Postes lus en même temps hors limites (1 à 8)" + FrenchText.Colon + "4.");
                }
            }
            if (settings.TryGetProperty("maxTargets", out var m))
            {
                if (m.ValueKind == JsonValueKind.Number && m.TryGetInt32(out var n) && n >= 1 && n <= MaxTargetsStoredMaximum)
                {
                    maxTargets = n;
                }
                else
                {
                    problems.Add("Plafond d’un relevé de liste hors limites" + FrenchText.Colon + FrenchText.Integer(SearchSurvey.MaxTargets) + ".");
                }
            }
        }
        disabled.ExceptWith(hidden);
        return new SearchPolicy(revalidate, seconds, source, maxTargets, concurrency, PingBatch, [.. hidden], [.. disabled], [.. problems]);
    }

    /// <summary>« Hidden », « Disabled », « Default » and the synonyms of Domenia 1 (Hide, Collapsed, Masqué, Grayed, Grisé…).</summary>
    public static string Mode(string? value)
    {
        var text = (value ?? "").Trim().ToLowerInvariant().Replace('é', 'e');
        return text switch
        {
            "hidden" or "hide" or "collapsed" or "masque" => "hidden",
            "disabled" or "disable" or "grayed" or "greyed" or "grise" => "disabled",
            "" or "default" or "visible" or "enabled" or "show" => "default",
            _ => "unknown",
        };
    }

    private static JsonElement? Section(JsonElement root, string name)
    {
        var value = Value(root, name);
        return value is JsonElement element && element.ValueKind == JsonValueKind.Object ? element : null;
    }

    private static JsonElement? Value(JsonElement parent, string name)
    {
        foreach (var property in parent.EnumerateObject())
        {
            if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                return property.Value;
            }
        }
        return null;
    }

    /// <summary>JSON true or false, 0 or 1, « true », « false », « oui », « non » (ConvertTo-SuiteFlag of Domenia 1); null otherwise.</summary>
    private static bool? Flag(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Number when value.TryGetInt32(out var n) && n is 0 or 1 => n == 1,
        JsonValueKind.String => value.GetString()!.Trim().ToLowerInvariant() switch
        {
            "true" or "1" or "oui" or "yes" => true,
            "false" or "0" or "non" or "no" => false,
            _ => null,
        },
        _ => null,
    };
}
