using System.Collections.Immutable;
using System.Text.Json;

namespace Domenia.Core.Accueil;

/// <summary>One profile-backed catalog for every consumer; no process-wide mutable definitions.</summary>
public static class ProfileProbeCatalog
{
    public static PersonalProbeSnapshot Read(IPreferenceStore preferences)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        return PersonalProbeCatalog.Read(preferences.TryGet(PersonalProbeCatalog.PreferenceKey, out var value) ? value : null);
    }

    public static async Task<PersonalProbeSnapshot> ReadAsync(IPreferenceStore preferences, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        token.ThrowIfCancellationRequested();
        var value = preferences is IAtomicPreferenceStore atomic
            ? await atomic.ReadLatestAsync(PersonalProbeCatalog.PreferenceKey, token).ConfigureAwait(false)
            : preferences.TryGet(PersonalProbeCatalog.PreferenceKey, out var existing) ? existing : (JsonElement?)null;
        token.ThrowIfCancellationRequested();
        return PersonalProbeCatalog.Read(value);
    }

    public static async Task<ImmutableArray<FrozenProbe>> ResolveAsync(IPreferenceStore preferences, IEnumerable<string> keys, CancellationToken token)
    {
        var snapshot = await ReadAsync(preferences, token).ConfigureAwait(false);
        var result = snapshot.Resolve(keys);
        PersonalProbeCatalog.Validate(result);
        return result;
    }

    public static async Task ConfirmAsync(IPreferenceStore preferences, ImmutableArray<FrozenProbe> definitions, CancellationToken token)
    {
        PersonalProbeCatalog.Validate(definitions);
        if (!definitions.Any(p => PersonalProbeCatalog.IsKey(p.Key))) { return; }
        // Imports only append immutable versions. An unrelated addition does not invalidate a plan,
        // but a removed or corrupted definition never falls back to its alias or an older cached value.
        _ = await ResolveAsync(preferences, definitions.Select(p => p.Key), token).ConfigureAwait(false);
    }
}
