using System.Collections.Frozen;

namespace Domenia.Core;

/// <summary>Shared boundary for directory payloads, plans, exports and compensation. Attribute options cannot hide a secret.</summary>
public static class SecretAttributes
{
    private static readonly FrozenSet<string> Names = new[]
    {
        "unicodePwd", "userPassword", "unixUserPassword", "clearTextPassword", "dBCSPwd", "supplementalCredentials",
        "ntPwdHistory", "lmPwdHistory", "currentValue", "priorValue", "pekList", "trustAuthIncoming", "trustAuthOutgoing",
        "ms-Mcs-AdmPwd", "msFVE-RecoveryPassword", "msFVE-KeyPackage", "msDS-KeyCredentialLink",
    }.ToFrozenSet(StringComparer.OrdinalIgnoreCase);
    public static bool Contains(string? attribute)
    {
        if (string.IsNullOrWhiteSpace(attribute)) return false;
        var name = attribute.AsSpan().Trim();
        var option = name.IndexOf(';');
        if (option >= 0) name = name[..option].Trim();
        // These two expiration timestamps contain no password. Unknown future secret-family members fail closed.
        if (name.Equals("msLAPS-PasswordExpirationTime", StringComparison.OrdinalIgnoreCase)
            || name.Equals("ms-Mcs-AdmPwdExpirationTime", StringComparison.OrdinalIgnoreCase)) return false;
        return Names.Contains(name.ToString()) || name.StartsWith("msLAPS-", StringComparison.OrdinalIgnoreCase)
            || name.StartsWith("msDS-ManagedPassword", StringComparison.OrdinalIgnoreCase);
    }
}
