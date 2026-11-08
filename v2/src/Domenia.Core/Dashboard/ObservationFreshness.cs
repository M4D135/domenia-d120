using System.Text.Json;

namespace Domenia.Core;

/// <summary>Display eligibility only; independent of collection reuse and durable retention.</summary>
public static class ObservationFreshness
{
    public static readonly TimeSpan FutureTolerance = TimeSpan.FromMinutes(5);
    public static bool Recent(DateTimeOffset? at, DateTimeOffset now, TimeSpan maximum) =>
        at is { } value && value > DateTimeOffset.MinValue && value <= now + FutureTolerance && now - value < maximum;

    public static int ReadDays(IPreferenceStore? preferences, int fallback = 30)
    {
        if (preferences is null) return fallback;
        if (preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var json) && json.ValueKind == JsonValueKind.Object)
        {
            var values = json.TryGetProperty("budgets", out var nested) && nested.ValueKind == JsonValueKind.Object ? nested : json;
            if (values.TryGetProperty(CollectionSettingsRules.ObservationMaxAgeDays, out _))
                return CollectionSettingsRules.Read(json, []).Budgets[CollectionSettingsRules.ObservationMaxAgeDays];
        }
        return fallback;
    }
}
