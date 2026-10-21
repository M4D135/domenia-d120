using System.Collections.Concurrent;

namespace Domenia.Core;

/// <summary>
/// Services given to every operation module (docs/PLATFORM.md): mode, directory source, local preferences, clock,
/// technical journal, screen readers, write executors, write receipts and the operations journal of the session. Shared
/// engine services (dashboard, working scope, write circuit…) are created on first use by <see cref="Shared{T}"/> and
/// disposed with the context.
/// </summary>
public sealed class EngineContext : IDisposable
{
    private readonly ConcurrentDictionary<Type, Lazy<object>> services = new();
    private int disposed;

    public EngineContext(
        ModeDecision decision,
        IDirectorySource directory,
        IPreferenceStore preferences,
        TimeProvider clock,
        ITechnicalJournal log,
        ScreenReaders? readers = null,
        OperationJournal? journal = null,
        WriteExecutors? writers = null,
        IReceiptStore? receipts = null)
    {
        ArgumentNullException.ThrowIfNull(decision);
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(preferences);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        Decision = decision;
        Directory = directory;
        Preferences = preferences;
        Clock = clock;
        Log = log;
        Readers = readers ?? ScreenReaders.None;
        Journal = journal ?? new OperationJournal();
        Writers = writers ?? WriteExecutors.None;
        Receipts = receipts ?? new MemoryReceiptStore();
    }

    /// <summary>Startup decision (mode, reason, banner).</summary>
    public ModeDecision Decision { get; }

    public AppMode Mode => Decision.Mode;

    /// <summary>Read-only directory source of the mode (simulated directory, or Active Directory).</summary>
    public IDirectorySource Directory { get; }

    /// <summary>Local preferences of the mode (separate document in simulation; memory only in capture mode).</summary>
    public IPreferenceStore Preferences { get; }

    public TimeProvider Clock { get; }

    /// <summary>Technical journal: codes, counts and failures only, never page input nor secrets.</summary>
    public ITechnicalJournal Log { get; }

    /// <summary>Read interfaces of the screens served by the source of this mode.</summary>
    public ScreenReaders Readers { get; }

    /// <summary>Operations journal of the session, shown on the home page (« Dernières opérations »).</summary>
    public OperationJournal Journal { get; }

    /// <summary>
    /// Write executors served by the source of this mode (docs/WRITES.md): the in-memory overlay in simulation, Active Directory
    /// later; none while Domenia.Ad is not wired. Only <see cref="WriteCircuit"/> runs them.
    /// </summary>
    public WriteExecutors Writers { get; }

    /// <summary>Durable write receipts of the mode (receipts.jsonl, receipts-simulation.jsonl; memory only in capture mode).</summary>
    public IReceiptStore Receipts { get; }

    /// <summary>
    /// One instance per context of an engine service, created by <paramref name="factory"/> on first use. Each service
    /// exposes a single static accessor (« DashboardService.From(context) ») that passes its own factory, so the first
    /// factory is always the right one.
    /// </summary>
    public T Shared<T>(Func<EngineContext, T> factory) where T : class
    {
        ArgumentNullException.ThrowIfNull(factory);
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        var lazy = services.GetOrAdd(typeof(T), _ => new Lazy<object>(() => factory(this), LazyThreadSafetyMode.ExecutionAndPublication));
        return (T)lazy.Value;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }
        foreach (var service in services.Values)
        {
            if (service.IsValueCreated && service.Value is IDisposable disposable)
            {
                disposable.Dispose();
            }
        }
        services.Clear();
    }
}
