namespace Domenia.Core;

/// <summary>Opaque collection correlation. No login, target or credential is placed in the receipt context.</summary>
public sealed record CollectionWriteContext(string RequestId, string StoreId, string DomainDn, long SessionEpoch);

/// <summary>The expected context is captured by the asynchronous writer, independently of the submitted patch. A completed
/// request cannot be silently replayed by a later session. Explicit local/import writes have no collection context.</summary>
public static class CollectionWrites
{
    private static readonly AsyncLocal<Scope?> Current = new();
    public static IDisposable Enter(CollectionWriteContext identity, Func<bool> stillCurrent)
    {
        var scope = new Scope(identity, stillCurrent, Current.Value);
        Current.Value = scope;
        return scope;
    }
    public static void Validate(CollectionWriteContext? identity, string storeId, string domainDn)
    {
        if (identity is null) return;
        var scope = Current.Value;
        if (!Guid.TryParseExact(identity.RequestId, "N", out var request) || request == Guid.Empty
            || identity.StoreId != storeId || !DistinguishedName.AreEqual(identity.DomainDn, domainDn)
            || identity.SessionEpoch < 0 || scope is null || scope.Identity != identity
            || !scope.Active || !scope.StillCurrent())
            throw new InvalidDataException("Contexte du relevé distant modifié ou terminé ; les valeurs précédentes sont conservées. Relancez la collecte.");
    }
    private sealed class Scope(CollectionWriteContext identity, Func<bool> stillCurrent, Scope? previous) : IDisposable
    {
        private int active = 1;
        public CollectionWriteContext Identity { get; } = identity;
        public Func<bool> StillCurrent { get; } = stillCurrent;
        public bool Active => Volatile.Read(ref active) != 0;
        public void Dispose() { Interlocked.Exchange(ref active, 0); Current.Value = previous; }
    }
}
