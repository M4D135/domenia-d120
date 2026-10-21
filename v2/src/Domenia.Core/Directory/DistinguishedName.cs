using System.Collections.Immutable;
using System.Globalization;
using System.Text;

namespace Domenia.Core;

/// <summary>One relative distinguished name, value unescaped.</summary>
public readonly record struct RelativeName(string Type, string Value);

/// <summary>Distinguished names per RFC 4514: escaping, reading and hierarchy tests. Multi-valued RDNs are not supported.</summary>
public static class DistinguishedName
{
    /// <summary>Escapes an attribute value: special characters, leading « # » or space, trailing space, NUL.</summary>
    public static string EscapeValue(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var builder = new StringBuilder(value.Length + 8);
        for (var i = 0; i < value.Length; i++)
        {
            var c = value[i];
            switch (c)
            {
                case ',' or '+' or '"' or '\\' or '<' or '>' or ';' or '=':
                    builder.Append('\\').Append(c);
                    break;
                case '\0':
                    builder.Append("\\00");
                    break;
                case '#' when i == 0:
                    builder.Append("\\#");
                    break;
                case ' ' when i == 0 || i == value.Length - 1:
                    builder.Append("\\ ");
                    break;
                default:
                    builder.Append(c);
                    break;
            }
        }
        return builder.ToString();
    }

    public static string Rdn(string type, string value) => type + "=" + EscapeValue(value);

    /// <summary>DN of a child: escaped RDN, then the parent DN as is.</summary>
    public static string Child(string type, string value, string parentDn) => Rdn(type, value) + "," + parentDn;

    /// <summary>Reads a DN into its RDNs, from the object up to the root. Throws <see cref="FormatException"/> when malformed.</summary>
    public static ImmutableArray<RelativeName> Parse(string dn)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var result = ImmutableArray.CreateBuilder<RelativeName>();
        if (dn.Length == 0)
        {
            return result.ToImmutable();
        }
        var type = new StringBuilder();
        var value = new StringBuilder();
        var bytes = new List<byte>();
        var readingType = true;
        for (var i = 0; i < dn.Length; i++)
        {
            var c = dn[i];
            if (readingType)
            {
                if (c == '=')
                {
                    if (type.Length == 0)
                    {
                        throw new FormatException("Empty attribute type in distinguished name.");
                    }
                    readingType = false;
                }
                else if (char.IsAsciiLetterOrDigit(c) || c == '-' || c == '.')
                {
                    type.Append(c);
                }
                else
                {
                    throw new FormatException("Invalid attribute type in distinguished name.");
                }
                continue;
            }
            if (c == '\\')
            {
                if (i + 1 >= dn.Length)
                {
                    throw new FormatException("Dangling escape in distinguished name.");
                }
                if (i + 2 < dn.Length && char.IsAsciiHexDigit(dn[i + 1]) && char.IsAsciiHexDigit(dn[i + 2]))
                {
                    bytes.Add(byte.Parse(dn.AsSpan(i + 1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                    i += 2;
                    continue;
                }
                FlushBytes(bytes, value);
                value.Append(dn[i + 1]);
                i++;
                continue;
            }
            FlushBytes(bytes, value);
            if (c == ',')
            {
                result.Add(new RelativeName(type.ToString(), value.ToString()));
                type.Clear();
                value.Clear();
                readingType = true;
                continue;
            }
            if (c == '+')
            {
                throw new FormatException("Multi-valued RDNs are not supported.");
            }
            value.Append(c);
        }
        FlushBytes(bytes, value);
        if (readingType)
        {
            throw new FormatException("Distinguished name ends without a value.");
        }
        result.Add(new RelativeName(type.ToString(), value.ToString()));
        return result.ToImmutable();
    }

    /// <summary>Writes RDNs back into a DN, escaping each value.</summary>
    public static string Format(IEnumerable<RelativeName> names)
    {
        ArgumentNullException.ThrowIfNull(names);
        return string.Join(",", names.Select(n => Rdn(n.Type, n.Value)));
    }

    /// <summary>DN of the parent, or null for a single RDN. The parent part is returned exactly as written.</summary>
    public static string? Parent(string dn)
    {
        ArgumentNullException.ThrowIfNull(dn);
        for (var i = 0; i < dn.Length; i++)
        {
            if (dn[i] == '\\')
            {
                i++;
            }
            else if (dn[i] == ',')
            {
                return dn[(i + 1)..];
            }
        }
        return null;
    }

    /// <summary>True when <paramref name="dn"/> is under <paramref name="containerDn"/> (direct child only unless <paramref name="subtree"/>).</summary>
    public static bool IsWithin(string dn, string containerDn, bool subtree)
    {
        var child = Parse(dn);
        var container = Parse(containerDn);
        return IsWithin(child, container, subtree);
    }

    public static bool IsWithin(ImmutableArray<RelativeName> child, ImmutableArray<RelativeName> container, bool subtree)
    {
        if (child.Length <= container.Length || (!subtree && child.Length != container.Length + 1))
        {
            return false;
        }
        var offset = child.Length - container.Length;
        for (var i = 0; i < container.Length; i++)
        {
            if (!string.Equals(child[offset + i].Type, container[i].Type, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(child[offset + i].Value, container[i].Value, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>Same DN, ignoring case and escaping differences.</summary>
    public static bool AreEqual(string left, string right)
    {
        var a = Parse(left);
        var b = Parse(right);
        return a.Length == b.Length && Same(a, b);
    }

    private static bool Same(ImmutableArray<RelativeName> a, ImmutableArray<RelativeName> b)
    {
        for (var i = 0; i < a.Length; i++)
        {
            if (!string.Equals(a[i].Type, b[i].Type, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(a[i].Value, b[i].Value, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
        }
        return true;
    }

    private static void FlushBytes(List<byte> bytes, StringBuilder value)
    {
        if (bytes.Count == 0)
        {
            return;
        }
        value.Append(Encoding.UTF8.GetString(bytes.ToArray()));
        bytes.Clear();
    }
}
