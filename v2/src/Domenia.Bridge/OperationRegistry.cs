using System.Collections.Frozen;
using System.Text.Json;

namespace Domenia.Bridge;

/// <summary>Handler of one declared operation. Runs off the UI thread; returns the data sent back to the page.</summary>
public delegate Task<object?> OperationHandler(JsonElement arguments, BridgeContext context, CancellationToken cancellationToken);

/// <summary>One operation the page is allowed to call.</summary>
public sealed record OperationDefinition(string Name, OperationClass Class, OperationHandler Handler, string Description);

/// <summary>Closed list of operations: the page can only call what is registered here, nothing else.</summary>
public sealed class OperationRegistry
{
    private readonly FrozenDictionary<string, OperationDefinition> operations;

    public OperationRegistry(IEnumerable<OperationDefinition> definitions)
    {
        ArgumentNullException.ThrowIfNull(definitions);
        var map = new Dictionary<string, OperationDefinition>(StringComparer.Ordinal);
        foreach (var definition in definitions)
        {
            if (!IsValidName(definition.Name))
            {
                throw new ArgumentException($"Invalid operation name: {definition.Name}", nameof(definitions));
            }
            if (!map.TryAdd(definition.Name, definition))
            {
                throw new ArgumentException($"Duplicate operation: {definition.Name}", nameof(definitions));
            }
        }
        operations = map.ToFrozenDictionary(StringComparer.Ordinal);
    }

    public IReadOnlyCollection<string> Names => operations.Keys;

    public bool TryGet(string name, out OperationDefinition definition) => operations.TryGetValue(name, out definition!);

    /// <summary>Operation names are dotted lower camel case, e.g. "search.run" or "store.status".</summary>
    public static bool IsValidName(string? name)
    {
        if (string.IsNullOrEmpty(name) || name.Length > 64)
        {
            return false;
        }
        var segments = name.Split('.');
        return segments.Length >= 2 && segments.All(s => s.Length > 0 && char.IsAsciiLetterLower(s[0]) && s.All(char.IsAsciiLetterOrDigit));
    }
}
