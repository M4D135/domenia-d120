using System.Collections.Frozen;
using System.Diagnostics.CodeAnalysis;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Handler of one declared operation. Runs off the UI thread; returns the data sent back to the page.</summary>
public delegate Task<object?> OperationHandler(JsonElement arguments, BridgeContext context, CancellationToken cancellationToken);

/// <summary>
/// One operation the page is allowed to call. <see cref="ServedInSimulation"/> marks a NetworkRead operation answered by the
/// simulated source; any other NetworkRead operation is refused in simulation (simulation.unavailable).
/// </summary>
public sealed record OperationDefinition(string Name, OperationClass Class, OperationHandler Handler, string Description, bool ServedInSimulation = false)
{
    /// <summary>One trusted priority for admission, native budgets and presentation. Never taken from page arguments.</summary>
    public OperationPriority Priority => Class is OperationClass.Write or OperationClass.LocalWrite ? OperationPriority.Write
        : Scheduling?.Priority is OperationPriority.Selection or OperationPriority.Background ? Scheduling.Priority : OperationPriority.Explicit;
    public bool Foreground => Priority != OperationPriority.Background && ActivityRules.IsForeground(Name, OperationTracking.KindOf(Class));
    /// <summary>Trusted server-side scheduling declaration. Missing metadata keeps immediate admission; page input cannot select a priority.</summary>
    public OperationScheduling? Scheduling { get; init; }
    /// <summary>Server opt-in for the closed directory reads reviewed for sharing. No result cache or write sharing.</summary>
    public bool ShareRead { get; init; }
    /// <summary>Trusted local qualification for target-bound reads. Null observation means execute independently, without sharing.</summary>
    internal Func<JsonElement, CancellationToken, Task<string?>>? CaptureReadIdentity { get; init; }
}

/// <summary>Closed list of operations: the page can only call what is registered here, nothing else.</summary>
public sealed class OperationRegistry
{
    private readonly FrozenDictionary<string, OperationDefinition> operations;
    internal TimeProvider Clock { get; private init; } = TimeProvider.System;
    internal QueueTiming QueueTiming { get; private init; } = Domenia.Core.QueueTiming.Default;
    internal OperationActivity? Activity { get; private init; }
    internal Func<CancellationToken, Task<BridgeSessionStamp>> CaptureSession { get; private init; }
        = static token => { token.ThrowIfCancellationRequested(); return Task.FromResult(new BridgeSessionStamp("standalone", "")); };
    internal Func<CancellationToken, Task<WorkstationCapabilityMemory.Context?>>? CaptureCapabilities { get; private init; }

    internal OperationRegistry(IEnumerable<OperationDefinition> definitions, TimeProvider clock,
        Func<CancellationToken, Task<BridgeSessionStamp>> captureSession,
        Func<CancellationToken, Task<WorkstationCapabilityMemory.Context?>>? captureCapabilities = null,
        QueueTiming? queueTiming = null, OperationActivity? activity = null) : this(definitions)
    {
        Clock = clock;
        CaptureSession = captureSession;
        CaptureCapabilities = captureCapabilities;
        QueueTiming = queueTiming ?? Domenia.Core.QueueTiming.Default;
        Activity = activity;
    }

    public OperationRegistry(IEnumerable<OperationDefinition> definitions)
    {
        ArgumentNullException.ThrowIfNull(definitions);
        var map = new Dictionary<string, OperationDefinition>(StringComparer.Ordinal);
        foreach (var definition in definitions)
        {
            if (definition is null || !Enum.IsDefined(definition.Class) || definition.Handler is null)
                throw new ArgumentException("Opération sans classe ou exécuteur déclaré.", nameof(definitions));
            if (!IsValidName(definition.Name))
            {
                throw new ArgumentException($"Invalid operation name: {definition.Name}", nameof(definitions));
            }
            // Check before a definition can enter any queue, including standalone registries.
            CompiledOperationContracts.RequireAssembly(definition.Handler.Method.Module.Assembly);
            BridgeScheduling.Validate(definition);
            if (!map.TryAdd(definition.Name, definition))
            {
                throw new ArgumentException($"Duplicate operation: {definition.Name}", nameof(definitions));
            }
        }
        operations = map.ToFrozenDictionary(StringComparer.Ordinal);
    }

    public IReadOnlyCollection<string> Names => operations.Keys;

    public bool TryGet(string name, [NotNullWhen(true)] out OperationDefinition? definition) => operations.TryGetValue(name, out definition);

    /// <summary>Operation names are dotted lower camel case, e.g. "search.run" or "store.status".</summary>
    public static bool IsValidName(string? name)
    {
        if (string.IsNullOrEmpty(name) || name.Length > 64)
        {
            return false;
        }
        var segments = name.Split('.');
        return segments.Length >= 2 && segments.All(s => s.Length > 0 && char.IsAsciiLetterLower(s[0]) && s.All(char.IsAsciiLetterOrDigit));
    }
}
