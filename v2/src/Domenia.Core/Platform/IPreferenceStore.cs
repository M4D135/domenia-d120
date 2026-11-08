using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Local preferences of the application (operation class LocalWrite): a small key/value document kept in the user data
/// folder, never in the directory. Simulation uses a separate document. Each screen owns the keys of its prefix
/// (« dashboard. », « session. »…), so adding a screen never edits a central list.
/// </summary>
public interface IPreferenceStore
{
    /// <summary>False when the values live in memory only (capture mode, no data folder, tests).</summary>
    bool Persistent { get; }

    /// <summary>Value stored under <paramref name="key"/>; false when absent. Never throws for an unreadable document.</summary>
    bool TryGet(string key, out JsonElement value);

    /// <summary>
    /// Stores (or removes, with null) a value, then writes the whole document atomically (temporary file then replace).
    /// The value stays in memory for the session even when the write fails; the failure is raised as
    /// <see cref="IOException"/> or <see cref="UnauthorizedAccessException"/> so the caller can tell the operator.
    /// </summary>
    Task SetAsync(string key, JsonElement? value, CancellationToken cancellationToken);
}

/// <summary>Rules shared by every preference store.</summary>
public static class PreferenceKeys
{
    public const int MaxLength = 128;

    /// <summary>Dotted names, first segment lower camel case (« dashboard.disabledWidgets », « session.workingScope.3fa2… »).</summary>
    public static bool IsValid(string? key)
    {
        if (string.IsNullOrEmpty(key) || key.Length > MaxLength)
        {
            return false;
        }
        var segments = key.Split('.');
        // Lengths first: keys come from the document too (« .x » must be refused, never index an empty segment).
        return segments.Length >= 2
            && segments.All(s => s.Length > 0 && s.All(char.IsAsciiLetterOrDigit))
            && char.IsAsciiLetterLower(segments[0][0]);
    }

    public static void Require(string key)
    {
        if (!IsValid(key))
        {
            throw new ArgumentException("Invalid preference key.", nameof(key));
        }
    }
}

/// <summary>Preferences kept in memory only: nothing is read or written on disk.</summary>
public sealed partial class MemoryPreferenceStore : IAtomicPreferenceStore, IConfigurationPreferenceStore
{
    private readonly Lock gate = new();
    private readonly Dictionary<string, JsonElement> values = new(StringComparer.Ordinal);

    public bool Persistent => false;

    /// <summary>Number of SetAsync calls that changed something (tests).</summary>
    public int Writes { get; private set; }

    public bool TryGet(string key, out JsonElement value)
    {
        PreferenceKeys.Require(key);
        lock (gate)
        {
            return values.TryGetValue(key, out value);
        }
    }

    public Task<JsonElement?> ReadLatestAsync(string key, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        return Task.FromResult(TryGet(key, out var value) ? (JsonElement?)value.Clone() : null);
    }

    public Task<JsonElement?> UpdateAsync(string key, Func<JsonElement?, JsonElement?> update, CancellationToken token)
    {
        PreferenceKeys.Require(key);
        ArgumentNullException.ThrowIfNull(update);
        lock (gate)
        {
            token.ThrowIfCancellationRequested();
            var next = update(values.TryGetValue(key, out var current) ? current.Clone() : null)?.Clone();
            token.ThrowIfCancellationRequested();
            if (next?.GetRawText() == (values.TryGetValue(key, out var previous) ? previous.GetRawText() : null)) return Task.FromResult(next);
            PreferenceDocumentLimits.RequireChange(values, key, next);
            if (next is { } value) values[key] = value;
            else values.Remove(key);
            Writes++;
            return Task.FromResult(next);
        }
    }

    public Task SetAsync(string key, JsonElement? value, CancellationToken cancellationToken)
    {
        PreferenceKeys.Require(key);
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            PreferenceDocumentLimits.RequireChange(values, key, value);
            if (value is JsonElement element)
            {
                values[key] = element.Clone();
            }
            else
            {
                values.Remove(key);
            }
            Writes++;
        }
        return Task.CompletedTask;
    }
}
