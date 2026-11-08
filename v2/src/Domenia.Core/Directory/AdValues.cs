using System.Globalization;

namespace Domenia.Core;

/// <summary>Active Directory encodings: userAccountControl flags and FILETIME large integers.</summary>
public static class AdValues
{
    /// <summary>« Never » for accountExpires and msDS-UserPasswordExpiryTimeComputed.</summary>
    public const long Never = long.MaxValue;

    public const int AccountDisabled = 0x2;
    public const int LockedOut = 0x10;
    public const int PasswordNotRequired = 0x20;
    public const int NormalAccount = 0x200;
    public const int WorkstationTrustAccount = 0x1000;
    public const int ServerTrustAccount = 0x2000;
    public const int DontExpirePassword = 0x10000;
    public const int SmartCardRequired = 0x40000;
    public const int TrustedForDelegation = 0x80000;
    public const int PasswordExpired = 0x800000;

    private static readonly long MaxFileTime = DateTime.MaxValue.ToFileTimeUtc();

    /// <summary>Converts a FILETIME to a UTC date; 0, negative, « never » and out-of-range values have no date.</summary>
    public static DateTimeOffset? FromFileTime(long? value)
    {
        if (value is not long v || v <= 0 || v == Never || v > MaxFileTime)
        {
            return null;
        }
        return new DateTimeOffset(DateTime.FromFileTimeUtc(v), TimeSpan.Zero);
    }

    public static long ToFileTime(DateTimeOffset value) => value.UtcDateTime.ToFileTimeUtc();

    /// <summary>
    /// GUID given as text (Domenia 1 ConvertTo-DomeniaGuidText and Test-DomeniaGuidText): the « D » form, the « B » form with
    /// braces and the thirty-two hex digits without a separator are read; anything else stays unread (null), never a zero GUID.
    /// </summary>
    public static Guid? GuidFromText(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }
        var cleaned = text.Trim();
        if (cleaned.Length == 34 && cleaned[0] == '{' && cleaned[^1] == '}')
        {
            cleaned = cleaned[1..^1];
        }
        if (cleaned.Length == 32 && Guid.TryParseExact(cleaned, "N", out var packed))
        {
            return packed;
        }
        return Guid.TryParse(cleaned, out var value) ? value : null;
    }

    /// <summary>Text of a GUID in the « D » form, or null when there is no GUID to write.</summary>
    public static string? GuidText(Guid? value) => value is Guid id ? id.ToString("D", CultureInfo.InvariantCulture) : null;

    public static bool IsDisabled(int userAccountControl) => (userAccountControl & AccountDisabled) != 0;

    public static bool HasFlag(int value, int flag) => (value & flag) != 0;
}
