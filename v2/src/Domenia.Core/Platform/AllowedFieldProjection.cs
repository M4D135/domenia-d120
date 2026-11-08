using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Positive attribute projection before a presentation/export boundary. Unknown fields are omitted;
/// secret attributes stay excluded even when a caller mistakenly includes them in its schema.</summary>
public static class AllowedFieldProjection
{
    public static ImmutableDictionary<string, IReadOnlyList<object?>> Select(
        IReadOnlyDictionary<string, IReadOnlyList<object?>> values, IReadOnlyCollection<string> allowed, bool allowRanges = false)
    {
        ArgumentNullException.ThrowIfNull(values); ArgumentNullException.ThrowIfNull(allowed);
        if (values.Count > 4096 || allowed.Count > 512) throw new InvalidDataException("Projection d’attributs hors limites.");
        var fields = allowed.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var result = ImmutableDictionary.CreateBuilder<string, IReadOnlyList<object?>>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in values)
        {
            var name = pair.Key;
            var range = name.IndexOf(";range=", StringComparison.OrdinalIgnoreCase);
            var field = allowRanges && range > 0 ? name[..range] : name;
            if (name.Length > 256 || !fields.Contains(field) || ShellSecrets.IsSecretAttribute(field)) continue;
            if (!result.TryAdd(name, pair.Value)) throw new InvalidDataException("Attributs ambigus dans la projection d’export.");
        }
        return result.ToImmutable();
    }
}
