using System.Globalization;
using System.Text.Json;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private sealed record DirectoryReadDetails(int Version, string? Depth, bool? Complete, string? Reader,
        string? Invocation = null, string? ReaderFingerprint = null, string? Cut = null, long Limit = 0,
        int? CheckpointItems = null, bool Incremental = false);

    // All consumers use this codec. Old checkpoints keep their richer controller and reader fingerprints.
    private static DirectoryReadDetails ReadDirectoryDetails(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return new(1, null, null, null);
        if (raw.Length > 16384) throw new InvalidDataException("Repère de lecture trop volumineux.");
        if (raw.StartsWith('{'))
        {
            var value = JsonSerializer.Deserialize<DirectoryReadDetails>(raw, Json);
            if (value is not { Version: 1 } || value.Depth is not ("Subtree" or "OneLevel")
                || value.Reader is { Length: > 260 } || value.Reader?.Any(char.IsControl) == true)
                throw new InvalidDataException("Repère de lecture JSON non reconnu.");
            return value;
        }
        var parts = raw.Split(';');
        string? Value(string key) => parts.FirstOrDefault(p => p.StartsWith(key + "=", StringComparison.Ordinal))?[(key.Length + 1)..];
        var depth = Value("depth");
        var invocation = Guid.TryParse(Value("invocation"), out var id) && id != Guid.Empty ? id.ToString("D") : null;
        var reader = Value("reader");
        return new(1, depth is "Subtree" or "OneLevel" ? depth : null,
            parts.Contains("partial", StringComparer.Ordinal) ? false : parts.Contains("full", StringComparer.Ordinal) ? true : null,
            null, invocation, reader is { Length: 64 } && reader.All(char.IsAsciiHexDigit) ? reader : null,
            Value("cut") is { Length: > 0 } cut ? cut : null,
            long.TryParse(Value("limit"), NumberStyles.None, CultureInfo.InvariantCulture, out var limit) ? limit : 0,
            int.TryParse(Value("checkpoint-count"), NumberStyles.None, CultureInfo.InvariantCulture, out var count) && count is >= 0 and <= SyncRowsLimit ? count : null,
            parts.Contains("incremental", StringComparer.Ordinal));
    }
}
