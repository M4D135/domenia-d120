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

    /// <summary>
    /// Escapes a value for an ADsPath (« LDAP://serveur/DN », Domenia 1 ConvertTo-DomeniaAdsPathDn): the RFC 4514 rules and,
    /// besides them, a « / » of the value written « \/ », the slash being the separator of the path. Takes the raw value.
    /// </summary>
    public static string EscapeAdsPathValue(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return EscapeValue(value).Replace("/", "\\/", StringComparison.Ordinal);
    }

    /// <summary>One RDN of an ADsPath: the type as written, the value escaped for a path.</summary>
    public static string AdsPathRdn(string type, string value)
    {
        ArgumentNullException.ThrowIfNull(type);
        return type + "=" + EscapeAdsPathValue(value);
    }

    /// <summary>
    /// DN written for an ADsPath. The DN is read first and written again, so a value already written « \/ » stays written
    /// once: no double escaping, whatever the form it arrived in. Throws <see cref="FormatException"/> when malformed.
    /// </summary>
    public static string AdsPathDn(string dn)
    {
        ArgumentNullException.ThrowIfNull(dn);
        return string.Join(',', Parse(dn).Select(n => AdsPathRdn(n.Type, n.Value)));
    }

    /// <summary>ADsPath of an object (« LDAP://serveur/DN »); an empty DN addresses the server itself.</summary>
    public static string AdsPath(string server, string dn)
    {
        ArgumentNullException.ThrowIfNull(server);
        ArgumentNullException.ThrowIfNull(dn);
        var host = server.Trim();
        if (host.Length == 0 || host.Any(char.IsWhiteSpace) || host.Contains("://", StringComparison.Ordinal)
            || host.Contains('/', StringComparison.Ordinal) || host.Contains('\\', StringComparison.Ordinal))
        {
            throw new FormatException("Invalid ADsPath server.");
        }
        var path = AdsPathDn(dn);
        return "LDAP://" + host + (path.Length == 0 ? "" : "/" + path);
    }

    /// <summary>Reads a DN into its RDNs, from the object up to the root. Throws <see cref="FormatException"/> when malformed.</summary>
    public static ImmutableArray<RelativeName> Parse(string dn) => ParseCore(dn, false);

    /// <summary>Display-only decoding: invalid UTF-8 octets remain visible; never use this projection for a scope or a write.</summary>
    public static ImmutableArray<RelativeName> ParseForDisplay(string dn) => ParseCore(dn, true);

    private static ImmutableArray<RelativeName> ParseCore(string dn, bool display)
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
            if (c == '"' && value.Length == 0 && bytes.Count == 0)
            {
                // The quoted form of RFC 4514 (CN="Le Gall, Anne"): a comma inside the quotes belongs to the value.
                i++;
                var closed = false;
                while (i < dn.Length)
                {
                    if (dn[i] == '\\')
                    {
                        ReadEscaped(dn, ref i, value, bytes, display);
                        i++;
                        continue;
                    }
                    if (dn[i] == '"')
                    {
                        closed = true;
                        i++;
                        break;
                    }
                    FlushBytes(bytes, value, display);
                    value.Append(dn[i]);
                    i++;
                }
                if (!closed)
                {
                    throw new FormatException("A quoted value of a distinguished name is not closed.");
                }
                FlushBytes(bytes, value, display);
                if (i < dn.Length && dn[i] != ',' && dn[i] != '+')
                {
                    throw new FormatException("Text follows the closing quote of a distinguished name value.");
                }
                i--;
                continue;
            }
            if (c == '\\')
            {
                ReadEscaped(dn, ref i, value, bytes, display);
                continue;
            }
            FlushBytes(bytes, value, display);
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
        FlushBytes(bytes, value, display);
        if (readingType)
        {
            throw new FormatException("Distinguished name ends without a value.");
        }
        result.Add(new RelativeName(type.ToString(), value.ToString()));
        return result.ToImmutable();
    }

    /// <summary>Reads one escape of a value (a « \xXX » pair of octets, or the next character taken as is). On return, i is the last read character.</summary>
    private static void ReadEscaped(string dn, ref int i, StringBuilder value, List<byte> bytes, bool display)
    {
        if (i + 1 >= dn.Length)
        {
            throw new FormatException("Dangling escape in distinguished name.");
        }
        if (i + 2 < dn.Length && char.IsAsciiHexDigit(dn[i + 1]) && char.IsAsciiHexDigit(dn[i + 2]))
        {
            bytes.Add(byte.Parse(dn.AsSpan(i + 1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
            i += 2;
            return;
        }
        FlushBytes(bytes, value, display);
        value.Append(dn[i + 1]);
        i++;
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
        var afterEquals = false;
        for (var i = 0; i < dn.Length; i++)
        {
            var c = dn[i];
            if (c == '\\')
            {
                i++;
                afterEquals = false;
            }
            else if (c == '"')
            {
                if (afterEquals)
                {
                    // A value written between quotes (RFC 4514) keeps its commas: the first free comma is the one after the quotes.
                    i++;
                    while (i < dn.Length)
                    {
                        if (dn[i] == '\\')
                        {
                            i++;
                        }
                        else if (dn[i] == '"')
                        {
                            break;
                        }
                        i++;
                    }
                }
                afterEquals = false;
            }
            else if (c == ',')
            {
                return dn[(i + 1)..];
            }
            else
            {
                afterEquals = c == '=';
            }
        }
        return null;
    }

    /// <summary>
    /// Site or owning OU read from a DN (Domenia 1 Get-DomeniaDnSite): the name just above « CN=Sites,CN=Configuration » is the
    /// site; otherwise the nearest « OU » of the DN is the OU of membership; null when the DN names neither. A name read here is
    /// a display value, never a delimiter of the perimeter (<see cref="IsWithin(string,string,bool)"/> is).
    /// </summary>
    public static string? SiteOf(string dn)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var names = ParseForDisplay(dn);
        for (var i = 1; i < names.Length - 1; i++)
        {
            if (SameName(names[i], "CN", "Sites") && SameName(names[i + 1], "CN", "Configuration"))
            {
                return names[i - 1].Value;
            }
        }
        foreach (var name in names)
        {
            if (string.Equals(name.Type, "OU", StringComparison.OrdinalIgnoreCase))
            {
                return name.Value;
            }
        }
        return null;
    }

    private static bool SameName(RelativeName name, string type, string value) =>
        string.Equals(name.Type, type, StringComparison.OrdinalIgnoreCase) && string.Equals(name.Value, value, StringComparison.OrdinalIgnoreCase);

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

    private static void FlushBytes(List<byte> bytes, StringBuilder value, bool display)
    {
        if (bytes.Count == 0)
        {
            return;
        }
        value.Append(display ? AdText.DecodeUtf8(bytes.ToArray()) : Encoding.UTF8.GetString(bytes.ToArray()));
        bytes.Clear();
    }
}
