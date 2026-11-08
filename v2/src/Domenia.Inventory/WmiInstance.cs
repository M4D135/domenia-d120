using System.Globalization;

namespace Domenia.Inventory;

/// <summary>
/// One CIM instance, copied out of the WMI objects while they are still alive and then held apart from them: the reader
/// never keeps a <c>ManagementBaseObject</c> around, so a disposed searcher can never be read again. Names are compared
/// without case, as WMI does. Every accessor answers null (or an empty array) when the property is absent, empty or of an
/// unexpected type: an unreadable value is « non lu », never a zero and never a guess.
/// </summary>
public sealed class WmiInstance
{
    private readonly Dictionary<string, object?> values;

    public WmiInstance(IReadOnlyDictionary<string, object?> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        this.values = new Dictionary<string, object?>(values, StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>Names of the properties that answered.</summary>
    public IEnumerable<string> Names => values.Keys;

    /// <summary>True when the property answered with something other than null or an empty text.</summary>
    public bool Has(string name) => values.TryGetValue(name, out var value) && value is not null && value is not string { Length: 0 };

    /// <summary>Raw value of a property, for a conversion these accessors do not cover.</summary>
    public object? Raw(string name) => values.TryGetValue(name, out var value) ? value : null;

    /// <summary>Text of a property, trimmed; null when it is blank, absent, or a number (read those with <see cref="Number"/>).</summary>
    public string? Text(string name) => Raw(name) switch
    {
        string text when !string.IsNullOrWhiteSpace(text) => text.Trim(),
        _ => null,
    };

    /// <summary>Whole number of a property (WMI gives uint, ulong, ushort, int and sometimes text).</summary>
    public long? Number(string name) => AsNumber(Raw(name));

    /// <summary>Whole number of a property, when it fits an <see cref="int"/>.</summary>
    public int? Int(string name) => Number(name) is long value and >= int.MinValue and <= int.MaxValue ? (int)value : null;

    /// <summary>Boolean of a property (WMI gives booleans, and 0/1 for some flags).</summary>
    public bool? Bool(string name) => Raw(name) switch
    {
        bool flag => flag,
        string text when bool.TryParse(text, out var parsed) => parsed,
        _ => Number(name) switch { 0 => false, 1 => true, _ => null },
    };

    /// <summary>Array of whole numbers (chassis types, port numbers…), empty when the property did not answer.</summary>
    public int[] Ints(string name)
    {
        var raw = Raw(name);
        if (raw is null)
        {
            return [];
        }

        if (raw is not Array array)
        {
            return AsNumber(raw) is long single and >= int.MinValue and <= int.MaxValue ? [(int)single] : [];
        }

        var result = new List<int>(array.Length);
        foreach (var item in array)
        {
            if (AsNumber(item) is long value and >= int.MinValue and <= int.MaxValue)
            {
                result.Add((int)value);
            }
        }

        return [.. result];
    }

    /// <summary>Array of texts (IP addresses, DNS servers…), empty when the property did not answer.</summary>
    public string[] Strings(string name)
    {
        var raw = Raw(name);
        if (raw is null)
        {
            return [];
        }

        if (raw is not Array array)
        {
            return Text(name) is string one ? [one] : [];
        }

        var result = new List<string>(array.Length);
        foreach (var item in array)
        {
            if (item is string text && !string.IsNullOrWhiteSpace(text))
            {
                result.Add(text.Trim());
            }
        }

        return [.. result];
    }

    /// <summary>A DMTF date property (« 20261021162600.500000+120 ») in UTC, or null when it cannot be read.</summary>
    public DateTimeOffset? Dmtf(string name) => CimQuery.ParseDmtf(Text(name));

    /// <summary>Instances of this one, keys and values only (a nested CIM_OBJECT stays unread and is said as such).</summary>
    public static long? AsNumber(object? value) => value switch
    {
        ulong unsigned when unsigned <= long.MaxValue => (long)unsigned,
        long signed => signed,
        uint unsigned => unsigned,
        int signed when signed >= 0 => signed,
        ushort unsigned => unsigned,
        byte unsigned => unsigned,
        short signed when signed >= 0 => signed,
        string text when long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) => parsed,
        _ => null,
    };
}
