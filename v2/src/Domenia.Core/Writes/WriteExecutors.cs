using System.Collections.Frozen;
using System.Reflection;

namespace Domenia.Core;

/// <summary>
/// Executor of one kind of write (docs/WRITES.md § 2), served by the source of the mode: Domenia.Simulation writes to the
/// in-memory overlay of the fictitious directory, Domenia.Ad will write to Active Directory (wave 3). Each kind declares its
/// own interface derived from this one in Domenia.Core (with the read that builds its plan, such as
/// <see cref="IAccountUnlockExecutor.PlanAsync"/>), implemented once per source. The generic circuit
/// (<see cref="WriteCircuit"/>) only calls the three methods below, in this order, at most once each per plan.
/// </summary>
public interface IWriteExecutor
{
    /// <summary>Kind of the plans this executor runs (« account.unlock »), the same as <see cref="WritePlanDraft.Kind"/>.</summary>
    string Kind { get; }

    /// <summary>
    /// Reads the target again just before sending and compares it with the plan (same object, same place, same values
    /// « before »). Never writes. A stale plan is reported (<see cref="WritePrecheck.Stale"/>), never thrown.
    /// </summary>
    Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken);

    /// <summary>
    /// Sends the write of the plan, once. Called with <see cref="CancellationToken.None"/> by the circuit: a write is never
    /// interrupted halfway. An expected refusal before anything was applied throws <see cref="DomeniaOperationException"/>
    /// (result « not applied »); any other exception means the outcome is unknown. Never retries anything itself.
    /// </summary>
    Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken);

    /// <summary>Reads the target again to prove the effect of the plan (postcondition, Domenia 1 OPE-009). Never writes.</summary>
    Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken);
}

/// <summary>
/// Write executors usable with the directory source of the session, found by reflection like the screen readers (no central
/// list): a public, non-abstract class implementing one or more interfaces derived from <see cref="IWriteExecutor"/>, with
/// exactly one public constructor taking a single parameter that accepts the source. Executors of another source are
/// ignored. Constructors stay cheap: nothing is read before the first plan.
/// </summary>
public sealed class WriteExecutors : IDisposable
{
    private readonly FrozenDictionary<Type, IWriteExecutor> byInterface;
    private readonly FrozenDictionary<string, IWriteExecutor> byKind;

    private WriteExecutors(FrozenDictionary<Type, IWriteExecutor> byInterface, FrozenDictionary<string, IWriteExecutor> byKind)
    {
        this.byInterface = byInterface;
        this.byKind = byKind;
    }

    /// <summary>No executor at all (directory mode while Domenia.Ad is not wired, tests).</summary>
    public static WriteExecutors None { get; } = new(FrozenDictionary<Type, IWriteExecutor>.Empty, FrozenDictionary<string, IWriteExecutor>.Empty);

    /// <summary>Kinds of write served (journal and tests).</summary>
    public IReadOnlyCollection<string> Kinds => [.. byKind.Keys.Order(StringComparer.Ordinal)];

    /// <summary>
    /// Builds the executors matching <paramref name="source"/>. Two implementations of the same interface or of the same kind
    /// for one source are a programming error (InvalidOperationException), never a silent choice.
    /// </summary>
    public static WriteExecutors Discover(IDirectorySource source, IEnumerable<Assembly> assemblies)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(assemblies);
        var interfaces = new Dictionary<Type, IWriteExecutor>();
        var kinds = new Dictionary<string, IWriteExecutor>(StringComparer.Ordinal);
        foreach (var type in assemblies.Distinct().SelectMany(ExportedTypes).OrderBy(t => t.FullName, StringComparer.Ordinal))
        {
            if (!type.IsClass || type.IsAbstract || type.ContainsGenericParameters || !typeof(IWriteExecutor).IsAssignableFrom(type))
            {
                continue;
            }
            var constructors = type.GetConstructors(BindingFlags.Public | BindingFlags.Instance);
            if (constructors.Length != 1)
            {
                continue;
            }
            var parameters = constructors[0].GetParameters();
            if (parameters.Length != 1 || !parameters[0].ParameterType.IsInstanceOfType(source))
            {
                continue;
            }
            var own = type.GetInterfaces().Where(i => i != typeof(IWriteExecutor) && typeof(IWriteExecutor).IsAssignableFrom(i)).ToList();
            if (own.Count == 0)
            {
                continue;
            }
            var instance = (IWriteExecutor)constructors[0].Invoke([source]);
            foreach (var contract in own)
            {
                if (!interfaces.TryAdd(contract, instance))
                {
                    throw new InvalidOperationException($"Two executors implement {contract.FullName} for the same source: {interfaces[contract].GetType().FullName} and {type.FullName}.");
                }
            }
            if (!kinds.TryAdd(instance.Kind, instance))
            {
                throw new InvalidOperationException($"Two executors run the kind {instance.Kind} for the same source: {kinds[instance.Kind].GetType().FullName} and {type.FullName}.");
            }
        }
        return new WriteExecutors(interfaces.ToFrozenDictionary(), kinds.ToFrozenDictionary(StringComparer.Ordinal));
    }

    /// <summary>Executors given by hand (tests, hosts composing without reflection).</summary>
    public static WriteExecutors From(IEnumerable<IWriteExecutor> executors)
    {
        ArgumentNullException.ThrowIfNull(executors);
        var interfaces = new Dictionary<Type, IWriteExecutor>();
        var kinds = new Dictionary<string, IWriteExecutor>(StringComparer.Ordinal);
        foreach (var executor in executors)
        {
            foreach (var contract in executor.GetType().GetInterfaces().Where(i => i != typeof(IWriteExecutor) && typeof(IWriteExecutor).IsAssignableFrom(i)))
            {
                if (!interfaces.TryAdd(contract, executor))
                {
                    throw new InvalidOperationException($"Two executors implement {contract.FullName}.");
                }
            }
            if (!kinds.TryAdd(executor.Kind, executor))
            {
                throw new InvalidOperationException($"Two executors run the kind {executor.Kind}.");
            }
        }
        return new WriteExecutors(interfaces.ToFrozenDictionary(), kinds.ToFrozenDictionary(StringComparer.Ordinal));
    }

    /// <summary>Executor of a write interface, or null when the source of this mode has none.</summary>
    public T? Find<T>() where T : class, IWriteExecutor => byInterface.TryGetValue(typeof(T), out var executor) ? (T)executor : null;

    /// <summary>Executor of a write interface; without one, refused like a directory read of this version (source.unavailable).</summary>
    public T Require<T>() where T : class, IWriteExecutor =>
        Find<T>() ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);

    /// <summary>Executor of the kind of a plan, or null.</summary>
    public IWriteExecutor? ForKind(string kind)
    {
        ArgumentNullException.ThrowIfNull(kind);
        return byKind.GetValueOrDefault(kind);
    }

    /// <summary>
    /// Disposes the executors that hold resources (secrets of the password reset, timers), once each, with the engine context.
    /// </summary>
    public void Dispose()
    {
        foreach (var executor in byKind.Values.Distinct().OfType<IDisposable>())
        {
            executor.Dispose();
        }
    }

    private static IEnumerable<Type> ExportedTypes(Assembly assembly)
    {
        try
        {
            return assembly.GetExportedTypes();
        }
        catch (ReflectionTypeLoadException ex)
        {
            // A type that cannot load is skipped; the others stay usable.
            return ex.Types.OfType<Type>().Where(t => t.IsPublic);
        }
    }
}
