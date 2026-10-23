namespace Domenia.Core;

/// <summary>Authentication/account failures only; ERROR_ACCESS_DENIED is a resource-rights refusal.</summary>
public static class WindowsAuthenticationErrors
{
    public static bool IsRejected(int error)
    {
        var code = error >= 0 && error <= ushort.MaxValue ? error
            : ((uint)error & 0xffff0000) == 0x80070000 ? error & ushort.MaxValue : -1;
        return code is 1326 or 1327 or 1328 or 1329 or 1330 or 1331 or 1385 or 1793 or 1907 or 1909;
    }
}
