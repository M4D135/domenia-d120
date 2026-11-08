using System.Collections.Immutable;

namespace Domenia.Core;

public enum RuntimeResourceKind { NativeProcess, NativeSession, ReadTimer, Worker }
public sealed record RuntimeResourceCount(RuntimeResourceKind Kind, int Held, int StopRequested);
public sealed record RuntimeResourceFailure(string Id, RuntimeResourceKind Kind, string ErrorType);
public sealed record RuntimeResourceSummary(int Held, int StopRequested, long ReleaseFailures, long Untracked,
    ImmutableArray<RuntimeResourceCount> ByKind, ImmutableArray<RuntimeResourceFailure> Failures);

/// <summary>Ownership ledger, never an admission pool. Releasing requests a safe stop only; the resource's own finalizer
/// removes its registration after its real cleanup. No process, CTS, semaphore or physical place is disposed here.</summary>
public sealed class RuntimeResourceRegistry
{
    private sealed class Entry(string id, string owner, RuntimeResourceKind kind, Func<Task>? stop)
    {
        internal string Id { get; } = id;
        internal string Owner { get; } = owner;
        internal RuntimeResourceKind Kind { get; } = kind;
        internal Func<Task>? Stop { get; } = stop;
        internal bool Requested;
    }
    private readonly Lock gate = new();
    private readonly Dictionary<string, Entry> entries = new(StringComparer.Ordinal);
    private readonly Queue<RuntimeResourceFailure> failures = new();
    private long failed, untracked;
    public const int MaximumResources = 4096;

    public Registration? Register(string owner, RuntimeResourceKind kind, Func<Task>? requestStop = null)
    {
        if (!Enum.IsDefined(kind) || string.IsNullOrEmpty(owner) || owner.Length > 64
            || !owner.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_'))
            throw new ArgumentException("Propriétaire ou type de ressource invalide.");
        lock (gate)
        {
            if (entries.Count >= MaximumResources) { untracked++; return null; }
            var entry = new Entry(Guid.NewGuid().ToString("N"), owner, kind, requestStop);
            entries.Add(entry.Id, entry);
            return new Registration(this, entry.Id);
        }
    }

    /// <summary>All selected callbacks are attempted independently, outside the registry lock and outside the caller's
    /// UI thread. A failed callback remains registered, and a request is never reported as physical completion.</summary>
    public Task RequestReleaseAsync(string? owner = null, RuntimeResourceKind? kind = null, string? id = null)
    {
        Entry[] selected;
        lock (gate)
        {
            selected = entries.Values.Where(e => !e.Requested && (owner is null || owner == e.Owner)
                && (kind is null || kind == e.Kind) && (id is null || id == e.Id) && e.Stop is not null).ToArray();
            foreach (var entry in selected) entry.Requested = true;
        }
        return Task.WhenAll(selected.Select(entry => Task.Run(async () =>
        {
            try { await entry.Stop!().ConfigureAwait(false); }
#pragma warning disable CA1031 // Every safe-stop callback must be attempted; its failure cannot release another resource.
            catch (Exception error)
            {
                lock (gate)
                {
                    failed++;
                    failures.Enqueue(new(entry.Id, entry.Kind, error.GetType().Name));
                    while (failures.Count > 32) failures.Dequeue();
                }
            }
#pragma warning restore CA1031
        })));
    }

    public RuntimeResourceSummary Snapshot()
    {
        lock (gate)
            return new(entries.Count, entries.Values.Count(e => e.Requested), failed, untracked,
                [.. Enum.GetValues<RuntimeResourceKind>().Select(kind => new RuntimeResourceCount(kind,
                    entries.Values.Count(e => e.Kind == kind), entries.Values.Count(e => e.Kind == kind && e.Requested)))], [.. failures]);
    }

    public sealed class Registration : IDisposable
    {
        private readonly RuntimeResourceRegistry registry;
        public string Id { get; }
        private int closed;
        internal Registration(RuntimeResourceRegistry registry, string id) { this.registry = registry; Id = id; }
        public void Dispose()
        {
            if (Interlocked.Exchange(ref closed, 1) != 0) return;
            lock (registry.gate) registry.entries.Remove(Id);
        }
    }
}

public sealed partial class OperationActivity
{
    public RuntimeResourceRegistry Resources { get; } = new();
}

public static class RuntimeResources
{
    // Host checks and native tests may run before an engine session exists. This ledger carries no target or credential.
    public static RuntimeResourceRegistry Unscoped { get; } = new();
    public static IDisposable? Register(RuntimeResourceKind kind, Func<Task>? requestStop = null) =>
        (OperationsMeasurements.Activity?.Resources ?? Unscoped).Register(OperationRequests.CurrentRequest?.Reference ?? "host", kind, requestStop);
}
