namespace Domenia.Core;

/// <summary>
/// Scheduler of the reads of the Assistance (docs/ops/assistance.md § 10): subject reads, recipe steps and pins found again.
/// One read at a time per object, <see cref="MaxRunning"/> reads at a time in all, <see cref="MaxQueued"/> waiting at most:
/// beyond, nothing is started and the operator is told (Domenia 1 « moteur occupé, rien n’a été lancé »). Running and waiting
/// reads are counted for the engine state. Nothing is ever retried here. One instance per engine context
/// (<see cref="From"/>), thread safe; it will hand over to the scheduler of Domenia.Engine when that one exists.
/// </summary>
public sealed class AssistanceScheduler : IDisposable
{
    public const int MaxRunning = 3;
    public const int MaxQueued = 12;

    private readonly SemaphoreSlim slots = new(MaxRunning, MaxRunning);
    private readonly Lock gate = new();
    private readonly Dictionary<string, (SemaphoreSlim Gate, int Users)> objects = new(StringComparer.OrdinalIgnoreCase);
    private int running;
    private int waiting;

    public static AssistanceScheduler From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static _ => new AssistanceScheduler());
    }

    /// <summary>Reads running now and reads waiting for a slot or for their object.</summary>
    public (int Running, int Queued) Counts
    {
        get
        {
            lock (gate)
            {
                return (running, waiting);
            }
        }
    }

    /// <summary>
    /// Runs one read of <paramref name="objectKey"/> (its DN or identity) when its object is free and a slot is available.
    /// Refused at once (<see cref="AssistanceErrors.EngineBusy"/>) when the waiting list is full; cancellable while waiting.
    /// </summary>
    public async Task<T> RunAsync<T>(string objectKey, Func<CancellationToken, Task<T>> read, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrEmpty(objectKey);
        ArgumentNullException.ThrowIfNull(read);
        SemaphoreSlim objectGate;
        lock (gate)
        {
            if (waiting >= MaxQueued)
            {
                throw new DomeniaOperationException(AssistanceErrors.EngineBusy,
                    "Moteur occupé" + FrenchText.Colon + AssistanceText.Count(running, "lecture en cours", "lectures en cours") + " et "
                    + AssistanceText.Count(waiting, "en attente", "en attente") + ". Rien n’a été lancé" + FrenchText.Nbsp + "; réessayez après la fin des lectures.");
            }
            waiting++;
            objectGate = objects.TryGetValue(objectKey, out var known) ? known.Gate : new SemaphoreSlim(1, 1);
            objects[objectKey] = (objectGate, (known.Gate is null ? 0 : known.Users) + 1);
        }
        var objectTaken = false;
        var slotTaken = false;
        var counted = false;
        var last = false;
        try
        {
            await objectGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            objectTaken = true;
            await slots.WaitAsync(cancellationToken).ConfigureAwait(false);
            slotTaken = true;
            lock (gate)
            {
                waiting--;
                running++;
                counted = true;
            }
            return await read(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            lock (gate)
            {
                if (counted)
                {
                    running--;
                }
                else
                {
                    waiting--;
                }
                var entry = objects[objectKey];
                if (entry.Users <= 1)
                {
                    // Nobody else holds or waits for this object: its gate goes with the last user.
                    objects.Remove(objectKey);
                    last = true;
                }
                else
                {
                    objects[objectKey] = (entry.Gate, entry.Users - 1);
                }
            }
            if (slotTaken)
            {
                slots.Release();
            }
            if (objectTaken)
            {
                objectGate.Release();
            }
            if (last)
            {
                objectGate.Dispose();
            }
        }
    }

    public void Dispose() => slots.Dispose();
}
