namespace Domenia.Core;

/// <summary>A campaign deadline is a ceiling, never a prediction. Per-host transport deadlines remain independent.
/// Automatic sizing allows large populations but always stops within one day; committed work can be resumed explicitly.</summary>
public static class CollectionCampaignBudget
{
    public static TimeSpan For(int targets, int concurrency, int configuredMinutes = 0)
    {
        if (configuredMinutes > 0) { return TimeSpan.FromMinutes(Math.Clamp(configuredMinutes, 1, 1440)); }
        var seconds = 300L + (long)Math.Max(0, targets) * 60 / Math.Clamp(concurrency, 1, 8);
        return TimeSpan.FromSeconds(Math.Clamp(seconds, 600L, 86400L));
    }
}
