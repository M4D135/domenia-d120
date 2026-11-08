namespace Domenia.Core;

/// <summary>ICMP can be filtered while Windows management is reachable. This explicit opt-in admits one bounded
/// direct read after a completed unanswered echo, never after a DNS/target failure and never as an authentication fallback.</summary>
public static class CollectionNetworkPolicy
{
    private static readonly AsyncLocal<bool?> Active = new();
    public static bool Read(IPreferenceStore? preferences)
    {
        if (Active.Value is { } scoped) return scoped;
        return CollectionSettingsRules.Read(preferences?.TryGet(CollectionSettingsRules.PreferenceKey, out var value) == true ? value : null, [])
            .Budgets.GetValueOrDefault(CollectionSettingsRules.ReadWithoutEcho) == 1;
    }
    public static bool Eligible(PresenceMeasure presence, bool allowUnanswered) => presence.HasReading
        && (presence.Answered == true || allowUnanswered && presence.Answered == false
            && presence.Diagnostic?.Outcome is null or PresenceReadOutcome.NoReply);

    public static IDisposable Enter(bool allowUnanswered)
    { var previous = Active.Value; Active.Value = allowUnanswered; return new Scope(previous); }
    private sealed class Scope(bool? previous) : IDisposable
    { public void Dispose() => Active.Value = previous; }
}
