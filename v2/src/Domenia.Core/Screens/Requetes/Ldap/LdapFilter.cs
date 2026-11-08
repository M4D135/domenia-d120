using System.Collections.Immutable;
using System.Globalization;
using System.Text;

namespace Domenia.Core.Queries.Ldap;

public enum LdapFilterKind
{
    And,
    Or,
    Not,
    Equality,
    Substring,
    GreaterOrEqual,
    LessOrEqual,
    Present,
    Approx,
    Extensible,
}

/// <summary>
/// Search filter (RFC 4515) as a tree. Assertion values keep their octets (<see cref="Bytes"/>): binary attributes
/// (objectGUID, objectSid) compare octets, the others the UTF-8 text.
/// </summary>
public sealed record LdapFilter(
    LdapFilterKind Kind,
    ImmutableArray<LdapFilter> Children,
    string? Attribute,
    ImmutableArray<byte> Bytes,
    string? Initial,
    ImmutableArray<string> Any,
    string? Final,
    string? MatchingRule,
    bool DnAttributes)
{
    /// <summary>The assertion value as text (UTF-8; invalid sequences replaced).</summary>
    public string Text => Bytes.IsDefaultOrEmpty ? "" : Encoding.UTF8.GetString(Bytes.AsSpan());

    public static LdapFilter And(IEnumerable<LdapFilter> children) => new(LdapFilterKind.And, [.. children], null, [], null, [], null, null, false);

    public static LdapFilter Or(IEnumerable<LdapFilter> children) => new(LdapFilterKind.Or, [.. children], null, [], null, [], null, null, false);

    public static LdapFilter Not(LdapFilter child) => new(LdapFilterKind.Not, [child], null, [], null, [], null, null, false);

    public static LdapFilter Item(LdapFilterKind kind, string attribute, string value) =>
        new(kind, [], attribute, [.. Encoding.UTF8.GetBytes(value)], null, [], null, null, false);

    public static LdapFilter Present(string attribute) => new(LdapFilterKind.Present, [], attribute, [], null, [], null, null, false);

    public static LdapFilter Substring(string attribute, string? initial, IEnumerable<string> any, string? final) =>
        new(LdapFilterKind.Substring, [], attribute, [], initial, [.. any], final, null, false);

    public static LdapFilter Extensible(string? attribute, string rule, string value) =>
        new(LdapFilterKind.Extensible, [], attribute, [.. Encoding.UTF8.GetBytes(value)], null, [], null, rule, false);

    /// <summary>Number of nodes (items and groups).</summary>
    public int Size => 1 + (Children.IsDefaultOrEmpty ? 0 : Children.Sum(c => c.Size));

    public int Depth => 1 + (Children.IsDefaultOrEmpty ? 0 : Children.Max(c => c.Depth));
}

/// <summary>Refusal of a filter text: French message and 1-based position.</summary>
public sealed class LdapFilterException(string message, int position) : Exception(message)
{
    public int Position { get; } = position;
}

/// <summary>Reads and writes LDAP filters (RFC 4515), with the white space between components that a pretty form adds.</summary>
public static class LdapFilterText
{
    public const int MaxLength = QueryLimits.MaxLdapLength;
    public const int MaxDepth = 32;
    public const int MaxNodes = 512;

    /// <summary>Parses a filter; a single item without its outer parentheses is accepted (« objectClass=user »).</summary>
    public static LdapFilter Parse(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (text.Length > MaxLength)
        {
            throw new LdapFilterException("Filtre LDAP limité à 8 192 caractères.", MaxLength);
        }
        var trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            throw new LdapFilterException("Filtre LDAP vide : saisissez par exemple (operatingSystem=*Windows 11*).", 1);
        }
        var offset = text.IndexOf(trimmed[0], StringComparison.Ordinal);
        var source = trimmed[0] == '(' ? trimmed : "(" + trimmed + ")";
        var shift = trimmed[0] == '(' ? offset : offset - 1;
        var parser = new Parser(source, shift);
        var filter = parser.Filter(0);
        parser.SkipSpace();
        if (!parser.End)
        {
            throw parser.Error("Texte en trop après la fin du filtre");
        }
        return filter;
    }

    /// <summary>Compact canonical form « (&amp;(a=b)(c=*d*)) ».</summary>
    public static string Format(LdapFilter filter)
    {
        ArgumentNullException.ThrowIfNull(filter);
        var builder = new StringBuilder();
        Write(filter, builder, -1, 0);
        return builder.ToString();
    }

    /// <summary>Indented form for the text editor: one component per line, two spaces per level.</summary>
    public static string Pretty(LdapFilter filter)
    {
        ArgumentNullException.ThrowIfNull(filter);
        var builder = new StringBuilder();
        Write(filter, builder, 0, 0);
        return builder.ToString();
    }

    /// <summary>Escapes an assertion value: « * ( ) \ » and NUL as \xx; other characters kept (UTF-8 is admitted).</summary>
    public static string Escape(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var builder = new StringBuilder(value.Length + 8);
        foreach (var c in value)
        {
            switch (c)
            {
                case '*':
                    builder.Append("\\2a");
                    break;
                case '(':
                    builder.Append("\\28");
                    break;
                case ')':
                    builder.Append("\\29");
                    break;
                case '\\':
                    builder.Append("\\5c");
                    break;
                case '\0':
                    builder.Append("\\00");
                    break;
                default:
                    builder.Append(c);
                    break;
            }
        }
        return builder.ToString();
    }

    private static string EscapeBytes(ImmutableArray<byte> bytes)
    {
        if (bytes.IsDefaultOrEmpty)
        {
            return "";
        }
        var span = bytes.AsSpan();
        try
        {
            var text = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(span);
            if (!text.Any(c => char.IsControl(c) && c != '\0'))
            {
                return Escape(text);
            }
        }
        catch (DecoderFallbackException)
        {
            // Binary value (GUID, SID): written as escaped octets below.
        }
        var builder = new StringBuilder(bytes.Length * 3);
        foreach (var b in span)
        {
            builder.Append('\\').Append(b.ToString("x2", CultureInfo.InvariantCulture));
        }
        return builder.ToString();
    }

    private static void Write(LdapFilter filter, StringBuilder builder, int indent, int depth)
    {
        var pretty = indent >= 0;
        void Line()
        {
            if (pretty)
            {
                builder.Append('\n').Append(' ', (depth + 1) * 2);
            }
        }
        switch (filter.Kind)
        {
            case LdapFilterKind.And:
            case LdapFilterKind.Or:
            case LdapFilterKind.Not:
                builder.Append('(').Append(filter.Kind switch { LdapFilterKind.And => '&', LdapFilterKind.Or => '|', _ => '!' });
                // A NOT of a single item stays on one line in the pretty form: « (!(a=b)) ».
                var inline = pretty && filter.Kind == LdapFilterKind.Not && filter.Children.Length == 1 && filter.Children[0].Children.IsDefaultOrEmpty;
                foreach (var child in filter.Children)
                {
                    if (!inline)
                    {
                        Line();
                    }
                    Write(child, builder, inline ? -1 : indent, depth + 1);
                }
                if (pretty && !inline && filter.Children.Length > 0)
                {
                    builder.Append('\n').Append(' ', depth * 2);
                }
                builder.Append(')');
                break;
            case LdapFilterKind.Present:
                builder.Append('(').Append(filter.Attribute).Append("=*)");
                break;
            case LdapFilterKind.Substring:
                builder.Append('(').Append(filter.Attribute).Append('=');
                if (filter.Initial is not null)
                {
                    builder.Append(Escape(filter.Initial));
                }
                builder.Append('*');
                foreach (var part in filter.Any)
                {
                    builder.Append(Escape(part)).Append('*');
                }
                if (filter.Final is not null)
                {
                    builder.Append(Escape(filter.Final));
                }
                builder.Append(')');
                break;
            case LdapFilterKind.Extensible:
                builder.Append('(');
                if (filter.Attribute is not null)
                {
                    builder.Append(filter.Attribute);
                }
                if (filter.DnAttributes)
                {
                    builder.Append(":dn");
                }
                if (filter.MatchingRule is not null)
                {
                    builder.Append(':').Append(filter.MatchingRule);
                }
                builder.Append(":=").Append(EscapeBytes(filter.Bytes)).Append(')');
                break;
            default:
                var op = filter.Kind switch
                {
                    LdapFilterKind.GreaterOrEqual => ">=",
                    LdapFilterKind.LessOrEqual => "<=",
                    LdapFilterKind.Approx => "~=",
                    _ => "=",
                };
                builder.Append('(').Append(filter.Attribute).Append(op).Append(EscapeBytes(filter.Bytes)).Append(')');
                break;
        }
    }

    private sealed class Parser(string text, int shift)
    {
        private int index;
        private int nodes;

        public bool End => index >= text.Length;

        public LdapFilterException Error(string reason) =>
            new(reason + " (position " + (Math.Min(index, text.Length) + shift + 1).ToString(CultureInfo.InvariantCulture) + ").", Math.Min(index, text.Length) + shift + 1);

        public void SkipSpace()
        {
            while (index < text.Length && char.IsWhiteSpace(text[index]))
            {
                index++;
            }
        }

        public LdapFilter Filter(int depth)
        {
            if (depth > MaxDepth)
            {
                throw Error("Filtre LDAP trop imbriqué (32 niveaux au plus)");
            }
            if (++nodes > MaxNodes)
            {
                throw Error("Filtre LDAP trop long (512 éléments au plus)");
            }
            SkipSpace();
            if (End || text[index] != '(')
            {
                throw Error("Parenthèse ouvrante « ( » attendue");
            }
            index++;
            SkipSpace();
            if (End)
            {
                throw Error("Filtre incomplet");
            }
            LdapFilter result;
            switch (text[index])
            {
                case '&':
                case '|':
                    var kind = text[index] == '&' ? LdapFilterKind.And : LdapFilterKind.Or;
                    index++;
                    var children = new List<LdapFilter>();
                    SkipSpace();
                    while (!End && text[index] == '(')
                    {
                        children.Add(Filter(depth + 1));
                        SkipSpace();
                    }
                    result = new LdapFilter(kind, [.. children], null, [], null, [], null, null, false);
                    break;
                case '!':
                    index++;
                    var child = Filter(depth + 1);
                    result = LdapFilter.Not(child);
                    SkipSpace();
                    break;
                default:
                    result = Item();
                    break;
            }
            if (End || text[index] != ')')
            {
                throw Error("Parenthèse fermante « ) » attendue");
            }
            index++;
            return result;
        }

        private LdapFilter Item()
        {
            var start = index;
            string? attribute = null;
            if (text[index] != ':')
            {
                attribute = Attribute();
            }
            var dnAttributes = false;
            string? rule = null;
            if (!End && text[index] == ':')
            {
                // Extensible match: attr[:dn][:rule]:=value or [:dn]:rule:=value.
                index++;
                if (Peek("dn:") || Peek("DN:"))
                {
                    dnAttributes = true;
                    index += 3;
                }
                else if (Peek("dn") && index + 2 < text.Length && text[index + 2] == ':')
                {
                    dnAttributes = true;
                    index += 3;
                }
                if (!End && text[index] != '=')
                {
                    rule = Oid();
                    if (End || text[index] != ':')
                    {
                        throw Error("« := » attendu après la règle de correspondance");
                    }
                    index++;
                }
                if (End || text[index] != '=')
                {
                    throw Error("« := » attendu dans le filtre étendu");
                }
                index++;
                if (attribute is null && rule is null)
                {
                    throw Error("Un filtre étendu sans attribut doit nommer sa règle de correspondance");
                }
                return new LdapFilter(LdapFilterKind.Extensible, [], attribute, [.. Value(allowStar: false)], null, [], null, rule, dnAttributes);
            }
            if (attribute is null)
            {
                index = start;
                throw Error("Nom d’attribut attendu");
            }
            if (End)
            {
                throw Error("Opérateur attendu (=, >=, <=, ~=)");
            }
            LdapFilterKind kind;
            switch (text[index])
            {
                case '>' when Peek(">="):
                    kind = LdapFilterKind.GreaterOrEqual;
                    index += 2;
                    break;
                case '<' when Peek("<="):
                    kind = LdapFilterKind.LessOrEqual;
                    index += 2;
                    break;
                case '~' when Peek("~="):
                    kind = LdapFilterKind.Approx;
                    index += 2;
                    break;
                case '=':
                    kind = LdapFilterKind.Equality;
                    index++;
                    break;
                default:
                    throw Error("Opérateur attendu (=, >=, <=, ~=) après l’attribut « " + attribute + " »");
            }
            if (kind != LdapFilterKind.Equality)
            {
                return new LdapFilter(kind, [], attribute, [.. Value(allowStar: false)], null, [], null, null, false);
            }
            // Equality, presence or substrings: split the raw value on unescaped stars.
            var parts = new List<List<byte>> { new() };
            while (!End && text[index] != ')')
            {
                if (text[index] == '*')
                {
                    parts.Add([]);
                    index++;
                    continue;
                }
                if (text[index] == '(')
                {
                    throw Error("Parenthèse « ( » non échappée dans une valeur : écrivez \\28");
                }
                AppendChar(parts[^1]);
            }
            if (parts.Count == 1)
            {
                return new LdapFilter(LdapFilterKind.Equality, [], attribute, [.. parts[0]], null, [], null, null, false);
            }
            if (parts.Count == 2 && parts[0].Count == 0 && parts[1].Count == 0)
            {
                return LdapFilter.Present(attribute);
            }
            var any = parts.Skip(1).Take(parts.Count - 2).Select(p => p.Count == 0 ? throw Error("Deux « * » consécutifs dans une sous-chaîne") : Decode(p));
            return LdapFilter.Substring(attribute, parts[0].Count == 0 ? null : Decode(parts[0]), [.. any], parts[^1].Count == 0 ? null : Decode(parts[^1]));
        }

        private bool Peek(string token) => string.CompareOrdinal(text, index, token, 0, token.Length) == 0;

        private string Attribute()
        {
            var start = index;
            if (!End && char.IsAsciiDigit(text[index]))
            {
                return Oid();
            }
            while (!End && (char.IsAsciiLetterOrDigit(text[index]) || text[index] == '-'))
            {
                index++;
            }
            if (index == start || !char.IsAsciiLetter(text[start]))
            {
                index = start;
                throw Error("Nom d’attribut attendu");
            }
            // Attribute options (« ;binary »).
            while (!End && text[index] == ';')
            {
                index++;
                var option = index;
                while (!End && (char.IsAsciiLetterOrDigit(text[index]) || text[index] == '-'))
                {
                    index++;
                }
                if (index == option)
                {
                    throw Error("Option d’attribut vide");
                }
            }
            return text[start..index];
        }

        private string Oid()
        {
            var start = index;
            while (!End && (char.IsAsciiLetterOrDigit(text[index]) || text[index] is '.' or '-'))
            {
                index++;
            }
            if (index == start)
            {
                throw Error("Règle de correspondance ou OID attendu");
            }
            return text[start..index];
        }

        private List<byte> Value(bool allowStar)
        {
            var bytes = new List<byte>();
            while (!End && text[index] != ')')
            {
                if (text[index] == '*' && !allowStar)
                {
                    throw Error("« * » non admis ici : écrivez \\2a pour un astérisque littéral");
                }
                if (text[index] == '(')
                {
                    throw Error("Parenthèse « ( » non échappée dans une valeur : écrivez \\28");
                }
                AppendChar(bytes);
            }
            return bytes;
        }

        private void AppendChar(List<byte> bytes)
        {
            var c = text[index];
            if (c == '\\')
            {
                if (index + 2 >= text.Length || !char.IsAsciiHexDigit(text[index + 1]) || !char.IsAsciiHexDigit(text[index + 2]))
                {
                    throw Error("Échappement invalide : « \\ » doit être suivi de deux chiffres hexadécimaux");
                }
                bytes.Add(byte.Parse(text.AsSpan(index + 1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                index += 3;
                return;
            }
            if (char.IsHighSurrogate(c) && index + 1 < text.Length && char.IsLowSurrogate(text[index + 1]))
            {
                bytes.AddRange(Encoding.UTF8.GetBytes(text.Substring(index, 2)));
                index += 2;
                return;
            }
            bytes.AddRange(Encoding.UTF8.GetBytes(c.ToString()));
            index++;
        }

        private static string Decode(List<byte> bytes) => Encoding.UTF8.GetString([.. bytes]);
    }
}
