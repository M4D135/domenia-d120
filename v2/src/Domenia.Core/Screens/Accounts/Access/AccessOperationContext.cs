namespace Domenia.Core;

/// <summary>Scope of a declared operation, installed by the bridge after registry lookup. No arguments or secrets.</summary>
public static class AccessOperationContext
{
    private static readonly AsyncLocal<string?> Current = new();
    public static IDisposable Enter(string operation)
    {
        if (!ValidOperation(operation)) throw new ArgumentException("Opération d’accès invalide.", nameof(operation));
        var previous = Current.Value; Current.Value = operation;
        return new Restore(previous);
    }
    public static bool ValidOperation(string? value) => value is { Length: > 0 and <= 128 }
        && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_');
    public static string DirectoryScope(string scope) => scope == CredentialRules.Directory && Current.Value is { } operation
        ? CredentialRules.DirectoryOperationPrefix + operation : scope;
    private sealed class Restore(string? previous) : IDisposable
    {
        private bool disposed;
        public void Dispose() { if (!disposed) { disposed = true; Current.Value = previous; } }
    }
}
