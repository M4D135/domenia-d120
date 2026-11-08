using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>What the preferences document of the mode holds, read without locking nor changing it.</summary>
public sealed record PreferenceDocumentInfo(bool Exists, long Bytes, DateTimeOffset? ModifiedAt, bool Readable, string State, ImmutableDictionary<string, JsonElement> Values);

/// <summary>
/// Read-only inspection of preferences.json / preferences-simulation.json for the Paramètres screen (keys by screen, export).
/// The document is opened for reading only, shared with the writers of every Domenia instance (no lock taken), and never
/// written here: every change goes through <see cref="IPreferenceStore"/>. Same format rules as <see cref="FilePreferenceStore"/>.
/// </summary>
public static class PreferenceDocument
{
    public static PreferenceDocumentInfo Inspect(string? path)
    {
        var empty = ImmutableDictionary<string, JsonElement>.Empty;
        if (string.IsNullOrEmpty(path))
        {
            return new PreferenceDocumentInfo(false, 0, null, true, "memory", empty);
        }
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists)
            {
                return new PreferenceDocumentInfo(false, 0, null, true, "absent", empty);
            }
            var modified = new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero);
            if (info.Length > FilePreferenceStore.MaxBytes)
            {
                return new PreferenceDocumentInfo(true, info.Length, modified, false, "tooLarge", empty);
            }
            byte[] bytes;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                bytes = new byte[stream.Length];
                stream.ReadExactly(bytes);
            }
            return Parse(bytes, info.Length, modified);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new PreferenceDocumentInfo(true, 0, null, false, "locked", empty);
        }
    }

    /// <summary>Values of a document (format « domenia.preferences », version 1); malformed keys are left out, never an error.</summary>
    public static PreferenceDocumentInfo Parse(byte[] bytes, long length, DateTimeOffset? modified)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        var empty = ImmutableDictionary<string, JsonElement>.Empty;
        try
        {
            using var document = JsonDocument.Parse(bytes);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("format", out var format) || format.ValueKind != JsonValueKind.String || format.GetString() != FilePreferenceStore.Format
                || !root.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var v) || v != FilePreferenceStore.Version
                || !root.TryGetProperty("values", out var values) || values.ValueKind != JsonValueKind.Object)
            {
                return new PreferenceDocumentInfo(true, length, modified, false, "unknownFormat", empty);
            }
            var builder = ImmutableDictionary.CreateBuilder<string, JsonElement>(StringComparer.Ordinal);
            foreach (var property in values.EnumerateObject())
            {
                if (PreferenceKeys.IsValid(property.Name))
                {
                    builder[property.Name] = property.Value.Clone();
                }
            }
            return new PreferenceDocumentInfo(true, length, modified, true, "read", builder.ToImmutable());
        }
        catch (JsonException)
        {
            return new PreferenceDocumentInfo(true, length, modified, false, "unreadable", empty);
        }
    }
}
