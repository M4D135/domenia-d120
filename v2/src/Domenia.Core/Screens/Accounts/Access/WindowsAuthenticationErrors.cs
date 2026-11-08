namespace Domenia.Core;

/// <summary>Authentication/account failures only; ERROR_ACCESS_DENIED is a resource-rights refusal.</summary>
public static class WindowsAuthenticationErrors
{
    public static bool IsRejected(int error) => OperationFailure.IsAuthenticationRejected(error);
}
