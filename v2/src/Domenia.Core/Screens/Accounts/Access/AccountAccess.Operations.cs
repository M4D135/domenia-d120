using System.Collections.Immutable;
namespace Domenia.Core;

public sealed partial class AccountAccess
{
    /// <summary>Memory only; no credential lease, SID resolution or validation is started by the health screen.</summary>
    public ImmutableArray<ProviderState> PausedProviderStates()
    {
        lock (gate)
        {
            return [.. faults.Values.Select(f => f.Scope).Distinct(StringComparer.Ordinal)
                .Select(scope => new ProviderState(CredentialRules.ScopeLabel(scope), null, ProviderStateKind.Blocked, null, 0))];
        }
    }
}
