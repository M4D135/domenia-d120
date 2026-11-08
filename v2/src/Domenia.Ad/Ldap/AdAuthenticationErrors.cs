using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Allowlisted WinError subcodes of LDAP 49. The server diagnostic itself is never retained or shown.</summary>
internal static class AdAuthenticationErrors
{
    internal static string Kind(string? diagnostic) => OperationFailure.LdapAuthenticationKind(diagnostic);
}
