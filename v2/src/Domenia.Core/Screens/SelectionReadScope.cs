namespace Domenia.Core;

/// <summary>Tracks the generation actually admitted by this read. Only acquiring its own credential under the account
/// lock may advance the stamp (for example consuming a one-shot lease). An unrelated selection change is never accepted.</summary>
public sealed class SelectionReadScope : IDisposable
{
    private static readonly AsyncLocal<SelectionReadScope?> Current = new();
    private readonly SelectionReadScope? previous;
    private readonly AccountAccess accounts;
    private long expected;
    private bool disposed;
    private SelectionReadScope(AccountAccess accounts)
    {
        this.accounts = accounts; expected = accounts.SelectionVersion;
        previous = Current.Value; Current.Value = this;
    }
    public static SelectionReadScope Enter(EngineContext context) => new(AccountAccess.From(context));
    public long Generation => Interlocked.Read(ref expected);
    public void RequireCurrent()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (accounts.SelectionVersion != Generation) throw Changed();
    }
    internal static void BeforeAcquire(AccountAccess accounts, long generation)
    {
        for (var scope = Current.Value; scope is not null; scope = scope.previous)
            if (ReferenceEquals(scope.accounts, accounts) && (scope.disposed || scope.Generation != generation)) throw Changed();
    }
    internal static void Acquired(AccountAccess accounts, long before, long after)
    {
        BeforeAcquire(accounts, before);
        for (var scope = Current.Value; scope is not null; scope = scope.previous)
            if (ReferenceEquals(scope.accounts, accounts)) Interlocked.Exchange(ref scope.expected, after);
    }
    public void Dispose() { if (!disposed) { disposed = true; Current.Value = previous; } }
    private static DomeniaOperationException Changed() => new("selection.changed", "Compte de lecture modifié ; relisez la sélection avant de continuer.");
}
