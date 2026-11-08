namespace Domenia.Core;

public sealed partial class MemoryPreferenceStore
{
    public Task<ConfigurationSnapshot> ReadConfigurationAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        lock (gate) return Task.FromResult(ConfigurationChanges.MemorySnapshot(values));
    }
    public Task<ConfigurationApplied> CommitConfigurationAsync(ConfigurationCommit request, CancellationToken token, Func<CancellationToken, IDisposable>? qualifySource = null)
    {
        lock (gate)
        {
            token.ThrowIfCancellationRequested();
            using var held = qualifySource?.Invoke(token);
            var change = ConfigurationChanges.Apply(ConfigurationChanges.MemorySnapshot(values), request, null, null);
            token.ThrowIfCancellationRequested();
            _ = PreferenceDocumentLimits.Encode(change.Values);
            values.Clear();
            foreach (var pair in change.Values) values.Add(pair.Key, pair.Value);
            Writes++;
            return Task.FromResult(change.Result);
        }
    }
}
