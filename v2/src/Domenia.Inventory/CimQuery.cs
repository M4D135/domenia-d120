using System.Globalization;

namespace Domenia.Inventory;

/// <summary>
/// Guards and conversions of the read-only CIM traffic (docs/ops/poste.md § 8.2). Pure: no WMI, no clock, no network, so
/// every rule is checkable by a unit test. The transport refuses anything these helpers refuse: a query that is not a plain
/// SELECT, a host name that could change the WMI path, a literal that could rewrite the query.
/// </summary>
public static class CimQuery
{
    /// <summary>Longest WQL accepted. A longer text is a programming error, never a slow query.</summary>
    public const int MaxLength = 4_000;

    /// <summary>Longest host name accepted (RFC 1123 allows 253 for a fully qualified name).</summary>
    public const int MaxHostNameLength = 253;

    /// <summary>Whole words no read-only query may contain. Matched on word boundaries, so a property name is never caught.</summary>
    private static readonly string[] ForbiddenWords =
    [
        "INSERT", "DELETE", "UPDATE", "DROP", "CREATE", "ALTER", "CALL", "EXECUTE", "ASSOCIATORS", "REFERENCES", "SET",
    ];

    /// <summary>
    /// True when the text is a plain projection the transport may send: it starts with SELECT, holds no statement
    /// separator, no double underscore (WMI system classes and qualifiers), and none of the words of a change or of a
    /// method call. Everything else is refused before anything leaves the process.
    /// </summary>
    public static bool IsReadOnlySelect(string? wql)
    {
        if (string.IsNullOrWhiteSpace(wql))
        {
            return false;
        }

        var text = wql.Trim();
        if (text.Length is 0 or > MaxLength)
        {
            return false;
        }

        if (text.IndexOfAny([';', '\r', '\n', '\0']) >= 0)
        {
            return false;
        }

        if (text.Contains("__", StringComparison.Ordinal))
        {
            return false;
        }

        if (!text.StartsWith("SELECT", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        // A projection lists properties, then FROM, then an optional WHERE: nothing after the condition.
        if (CountOccurrence(text, "FROM", StringComparison.OrdinalIgnoreCase) != 1)
        {
            return false;
        }

        foreach (var word in ForbiddenWords)
        {
            if (ContainsWord(text, word))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>
    /// A host name or an IPv4 address: letters, digits, « - » and « . » only. Anything else could change the WMI path
    /// (« \\host\root\cimv2 ») and is refused before the transport is built.
    /// </summary>
    public static bool IsHostName(string? host) =>
        !string.IsNullOrEmpty(host)
        && host.Length <= MaxHostNameLength
        && host.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '.')
        && host[0] is not '-' and not '.'
        && host[^1] is not '-' and not '.';

    /// <summary>
    /// A value to embed in a WQL string literal: no control character, no backslash (WMI's own escape character), 256
    /// characters at most, double quotes doubled. The result is ready to sit between two quotes.
    /// </summary>
    public static string Literal(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        if (value.Length > 256 || value.Any(char.IsControl) || value.Contains('\\', StringComparison.Ordinal))
        {
            throw new Domenia.Core.DomeniaOperationException(Domenia.Core.DomeniaErrors.ArgumentsInvalid, "Valeur refusée pour la mesure du poste : caractères non admis.");
        }

        return "\"" + value.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
    }

    /// <summary>
    /// A DMTF date (« 20261021162600.500000+120 ») in UTC, or null when it cannot be read. An unreadable date is never
    /// guessed: the caller says « non lu ».
    /// </summary>
    public static DateTimeOffset? ParseDmtf(string? text)
    {
        if (text is null || text.Length < 25
            || !DateTime.TryParseExact(text[..14], "yyyyMMddHHmmss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var local)
            || !int.TryParse(text.AsSpan(15, 6), NumberStyles.None, CultureInfo.InvariantCulture, out var microseconds)
            || text[21] is not ('+' or '-')
            || !int.TryParse(text.AsSpan(22, 3), NumberStyles.None, CultureInfo.InvariantCulture, out var minutes)
            || minutes > 14 * 60)
        {
            return null;
        }

        var offset = TimeSpan.FromMinutes(text[21] == '-' ? -minutes : minutes);
        return new DateTimeOffset(local.AddTicks(microseconds * 10L), offset).ToUniversalTime();
    }

    /// <summary>
    /// The « productState » of root\SecurityCenter2 as three facts (Domenia 1): the middle byte says whether the product
    /// is enabled, the last one whether its signatures are up to date. A state that does not decode stays unknown.
    /// </summary>
    public static (bool? Enabled, bool? UpToDate) DecodeProductState(int? productState)
    {
        if (productState is not int state || state is < 0 or > 0xFFFFFF)
        {
            return (null, null);
        }

        var middle = (state >> 8) & 0xFF;
        var low = state & 0xFF;
        return (middle >= 16, low == 0);
    }

    /// <summary>Conversion status of Win32_EncryptableVolume, in the words of Domenia 1 (point 99).</summary>
    public static string BitLockerConversion(int? conversion) => conversion switch
    {
        0 => "Non chiffré",
        1 => "Entièrement chiffré",
        2 => "Chiffrement en cours",
        3 => "Déchiffrement en cours",
        4 => "Chiffrement en pause",
        5 => "Déchiffrement en pause",
        null => "Non renseigné",
        var code => "Code " + code.Value.ToString(CultureInfo.InvariantCulture),
    };

    /// <summary>Protection status of Win32_EncryptableVolume: 0 disabled, 1 enabled, 2 unknown (point 99).</summary>
    public static string BitLockerProtection(int? protection) => protection switch
    {
        0 => "Désactivée",
        1 => "Activée",
        2 => "Inconnue",
        null => "Non renseignée",
        var code => "Code " + code.Value.ToString(CultureInfo.InvariantCulture),
    };

    /// <summary>Health status of MSFT_PhysicalDisk: only 0, 1 and 2 are states (point 83); anything else stays unknown.</summary>
    public static string PhysicalDiskHealth(int? health) => health switch
    {
        0 => "Sain",
        1 => "Avertissement",
        2 => "Défaillant",
        null => "inconnu",
        var code => "inconnu (code " + code.Value.ToString(CultureInfo.InvariantCulture) + ")",
    };

    /// <summary>MediaType of MSFT_PhysicalDisk: 3 is a hard disk, 4 a solid-state drive, anything else is unnamed.</summary>
    public static string PhysicalDiskMedia(int? mediaType) => mediaType switch
    {
        3 => "Disque dur",
        4 => "SSD",
        null => "Type non précisé",
        var code => "Type " + code.Value.ToString(CultureInfo.InvariantCulture),
    };

    /// <summary>Logon type of Win32_LogonSession: 2 is an interactive console session, 10 a remote desktop.</summary>
    public static string LogonType(int? logonType) => logonType switch
    {
        2 => "console",
        3 => "service",
        5 => "authentification réseau",
        7 => "authentification en lot",
        8 => "service réseau",
        9 => "authentification par réseau (générique)",
        10 => "bureau à distance",
        11 => "bureau à distance par cache",
        null => "non renseigné",
        var code => "type " + code.Value.ToString(CultureInfo.InvariantCulture),
    };

    /// <summary>Chassis types of Win32_SystemEnclosure, translated by the labels of Core (never asserted on a name alone).</summary>
    public static bool LooksLikeLaptop(IEnumerable<int> chassisTypes) =>
        chassisTypes.Any(code => code is 9 or 10 or 14 or 30 or 31);

    /// <summary>Chassis types that say « virtual » without asserting it (Domenia 1 keeps the wording « présumé »).</summary>
    public static bool LooksLikeVirtualMachine(IEnumerable<int> chassisTypes) => chassisTypes.Any(code => code is 1 or 2 or 3 or 4 or 21);

    private static int CountOccurrence(string text, string value, StringComparison comparison)
    {
        var count = 0;
        var index = text.IndexOf(value, comparison);
        while (index >= 0)
        {
            count++;
            index = text.IndexOf(value, index + value.Length, comparison);
        }

        return count;
    }

    private static bool ContainsWord(string text, string word)
    {
        var index = text.IndexOf(word, StringComparison.OrdinalIgnoreCase);
        while (index >= 0)
        {
            var startsWord = index == 0 || !IsWordChar(text[index - 1]);
            var after = index + word.Length;
            var endsWord = after >= text.Length || !IsWordChar(text[after]);
            if (startsWord && endsWord)
            {
                return true;
            }

            index = text.IndexOf(word, index + 1, StringComparison.OrdinalIgnoreCase);
        }

        return false;
    }

    private static bool IsWordChar(char value) => char.IsLetterOrDigit(value) || value == '_';
}
