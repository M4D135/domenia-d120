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

    public static bool IsDisabled(int userAccountControl) => (userAccountControl & AccountDisabled) != 0;

    public static bool HasFlag(int value, int flag) => (value & flag) != 0;
}
