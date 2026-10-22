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

    /// <summary>Uses the same closed grammar, secret filter and MSI guard as the query workshop.</summary>
    public static bool IsReadOnlySelect(string? wql, string namespaceName = @"root\cimv2")
    {
        if (string.IsNullOrWhiteSpace(wql) || wql.Length > MaxLength) { return false; }
        try
        {
            var plan = Domenia.Core.Queries.Wmi.WqlRules.Parse(wql);
            Domenia.Core.Queries.Wmi.WqlRules.CheckTarget(namespaceName, plan.ClassName);
            return !plan.ClassName.StartsWith("__", StringComparison.Ordinal);
        }
        catch (Domenia.Core.Queries.QueryDefinitionException) { return false; }
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
        && host.Split('.').All(label => label.Length is > 0 and <= 63 && label[0] != '-' && label[^1] != '-');

    /// <summary>
    /// A value to embed in a WQL string literal: no control character, no backslash (WMI's own escape character), 256
    /// characters at most, double quotes doubled. The result is ready to sit between two quotes.
    /// </summary>
    public static string Literal(string? value)
    {
        value ??= "";
        if (value.Length > 256 || value.Any(char.IsControl))
        {
            throw new Domenia.Core.DomeniaOperationException(Domenia.Core.DomeniaErrors.ArgumentsInvalid, "Valeur WQL refusée.");
        }
        return "'" + value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("'", "\\'", StringComparison.Ordinal) + "'";
    }

    public static DateTimeOffset? ParseDmtf(string? text) => WmiWorkstationProbe.ParseDmtf(text);

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
        return (middle is 0x10 or 0x11 ? true : middle is 0x00 or 0x01 ? false : null, low == 0 ? true : low == 0x10 ? false : null);
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
        3 => "authentification réseau",
        4 => "authentification en lot",
        5 => "service",
        7 => "déverrouillage",
        8 => "authentification réseau en texte clair",
        9 => "nouvelles informations d’identification",
        10 => "bureau à distance",
        11 => "session interactive en cache",
        null => "non renseigné",
        var code => "type " + code.Value.ToString(CultureInfo.InvariantCulture),
    };

    /// <summary>Chassis types of Win32_SystemEnclosure, translated by the labels of Core (never asserted on a name alone).</summary>
    public static bool LooksLikeLaptop(IEnumerable<int> chassisTypes) =>
        chassisTypes.Any(code => code is 9 or 10 or 14 or 30 or 31);

}
