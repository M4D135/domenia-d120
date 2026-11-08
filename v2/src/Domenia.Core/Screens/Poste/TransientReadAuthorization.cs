using System.Collections.Concurrent;

namespace Domenia.Core.Poste;

/// <summary>A frozen automatic collection scope; settings alone never authorize a host outside the requested population.</summary>
public static class TransientReadAuthorization
{
    private static readonly AsyncLocal<Scope?> Current = new();
    public static bool Active => Current.Value is { Active: true };
    public static IDisposable Begin(PosteConfiguration settings, IEnumerable<Guid> targets)
    {
        var previous = Current.Value;
        var ids = settings.AllowsTransient && settings.TransientMode == "automatic"
            ? targets.Where(g => g != Guid.Empty).Distinct().Take(settings.AutomaticTargetLimit).ToArray() : [];
        var scope = new Scope(previous, RemoteCollectionSettings.From(settings), ids);
        Current.Value = scope; return scope;
    }
    public static bool Covers(PosteConfiguration settings, Guid target) => Current.Value is { Active: true } scope
        && scope.Settings == RemoteCollectionSettings.From(settings) && scope.Targets.ContainsKey(target);
    public static bool Consume(PosteConfiguration settings, Guid target) => Current.Value is { Active: true } scope
        && scope.Settings == RemoteCollectionSettings.From(settings) && scope.Targets.TryRemove(target, out _);

    private sealed class Scope(Scope? previous, RemoteCollectionSettings settings, Guid[] targets) : IDisposable
    {
        private int active = 1;
        internal bool Active => Volatile.Read(ref active) == 1;
        internal RemoteCollectionSettings Settings { get; } = settings;
        internal ConcurrentDictionary<Guid, byte> Targets { get; } = new(targets.Select(id => new KeyValuePair<Guid, byte>(id, 0)));
        public void Dispose()
        {
            if (Interlocked.Exchange(ref active, 0) == 0) { return; }
            Targets.Clear();
            if (ReferenceEquals(Current.Value, this)) { Current.Value = previous; }
        }
    }
}
