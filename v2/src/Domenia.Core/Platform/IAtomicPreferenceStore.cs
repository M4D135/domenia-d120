using System.Text.Json;

namespace Domenia.Core;

/// <summary>A targeted local update against the latest persisted choice, under the destination lock.
/// The bounded synchronous callback may refuse; refusal/failure leaves memory and disk unchanged.
/// Implementations reject unreadable documents and pending changes to the same key.</summary>
public interface IAtomicPreferenceStore : IPreferenceStore
{
    /// <summary>Bounded read of the latest document, respecting this session's pending choice; never writes.</summary>
    Task<JsonElement?> ReadLatestAsync(string key, CancellationToken token);
    Task<JsonElement?> UpdateAsync(string key, Func<JsonElement?, JsonElement?> update, CancellationToken token);
}
