using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Core.Queries.Wmi;

/// <summary>Only single-key object paths from the closed relation catalog. No arbitrary WMI path is ever followed.</summary>
public sealed partial record WorkshopRelationPath(string ClassName, string Property, string Value)
{
    [GeneratedRegex("^([A-Za-z_][A-Za-z0-9_]{0,127})\\.([A-Za-z_][A-Za-z0-9_]{0,127})=(.*)$", RegexOptions.CultureInvariant, 500)]
    private static partial Regex PathPattern();

    public static WorkshopRelationPath? Parse(string? text, string host, string ns)
    {
        if (text is null || text.Length is 0 or > 4096 || text.Any(char.IsControl)) { return null; }
        if (text.StartsWith(@"\\", StringComparison.Ordinal))
        {
            var separator = text.IndexOf('\\', 2); var colon = text.IndexOf(':');
            if (separator < 0 || colon <= separator || (!text[2..separator].Equals(host, StringComparison.OrdinalIgnoreCase)
                && !text[2..separator].Equals(host.Split('.')[0], StringComparison.OrdinalIgnoreCase)) || !text[(separator + 1)..colon].Equals(ns, StringComparison.OrdinalIgnoreCase)) { return null; }
            text = text[(colon + 1)..];
        }
        var match = PathPattern().Match(text);
        if (!match.Success) { return null; }
        var literal = match.Groups[3].Value;
        if (literal.Length > 1 && literal[0] == '"' && literal[^1] == '"')
        {
            var value = new StringBuilder();
            for (var i = 1; i < literal.Length - 1; i++)
            {
                var c = literal[i];
                if (c == '\\') { if (++i >= literal.Length - 1 || literal[i] is not ('\\' or '"')) { return null; } c = literal[i]; }
                else if (c == '"') { return null; }
                value.Append(c);
            }
            literal = value.ToString();
        }
        else if (literal.Length == 0 || !literal.All(char.IsAsciiDigit)) { return null; }
        return literal.Length <= 256 ? new(match.Groups[1].Value, match.Groups[2].Value, literal) : null;
    }
}
