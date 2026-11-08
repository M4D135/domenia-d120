using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Positive user resolution only, never a write permission. One bounded cache per source; its keys carry
/// the complete read owner. The computer is still requalified before and after every native console read.</summary>
internal sealed class AdConsoleIdentityCache(TimeProvider clock, int capacity = 4096)
{
    internal sealed record Key(long Epoch, string Domain, string Store, string Account, long Selection, string Controller, string Filter);
    internal sealed record Proof(RelationObject User, DateTimeOffset ValidatedAt);
    private sealed record Entry(Key Key, Proof Proof, long Stamp);
    private static readonly ConditionalWeakTable<AdDirectorySource, AdConsoleIdentityCache> Caches = new();
    private readonly Lock gate = new();
    private readonly Dictionary<Key, LinkedListNode<Entry>> entries = [];
    private readonly LinkedList<Entry> order = [];
    internal static AdConsoleIdentityCache For(AdDirectorySource source) => Caches.GetValue(source, s => new(s.Clock));
    internal int Count { get { lock (gate) { return entries.Count; } } }
    internal static Key Owner(AdDirectorySource source, AdReadAccess directory, DomainInfo domain, long epoch, string filter) =>
        new(epoch, domain.RootDn, source.FleetDetails.Facts.StoreId, directory.AccountKey,
            source.AccountContext is { } context ? AccountAccess.From(context).SelectionVersion : 0, directory.Controller ?? "", filter);

    internal Proof? Find(Key key)
    {
        lock (gate)
        {
            if (!entries.TryGetValue(key, out var node)) { return null; }
            var elapsed = clock.GetElapsedTime(node.Value.Stamp);
            var age = clock.GetUtcNow() - node.Value.Proof.ValidatedAt;
            if (age < TimeSpan.Zero || age >= TimeSpan.FromMinutes(5) || elapsed < TimeSpan.Zero || elapsed >= TimeSpan.FromMinutes(5))
            { entries.Remove(key); order.Remove(node); return null; }
            order.Remove(node); order.AddLast(node); return node.Value.Proof;
        }
    }

    internal void Remember(Key key, RelationObject user)
    {
        if (capacity <= 0 || user.Kind != RelationSubjectKind.User || user.Guid == Guid.Empty || user.Created == DateTimeOffset.MinValue) { return; }
        lock (gate)
        {
            if (entries.Remove(key, out var old)) { order.Remove(old); }
            while (entries.Count >= capacity && order.First is { } first)
            { entries.Remove(first.Value.Key); order.RemoveFirst(); }
            entries.Add(key, order.AddLast(new Entry(key, new(user, clock.GetUtcNow()), clock.GetTimestamp())));
        }
    }
}
