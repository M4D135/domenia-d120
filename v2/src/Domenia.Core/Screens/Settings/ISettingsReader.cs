namespace Domenia.Core;

/// <summary>
/// Reads of the Paramètres screen served by the source of the mode (docs/PLATFORM.md): the local base of Domenia (its state,
/// its measures and the Domenia 1 data found for the takeover) and the facts of the simulation. Read only by construction:
/// measuring keeps the result for the session but never changes the base. In simulation the base is a fictitious one kept
/// in memory (never a SQLite file, SIMULATION.md § 1); in directory mode Domenia.Store will serve it (wave 3).
/// </summary>
public interface ISettingsReader : IScreenReader
{
    /// <summary>Snapshot of the local base as last known (no measure is taken).</summary>
    Task<LocalStoreSnapshot> LocalStoreAsync(CancellationToken cancellationToken);

    /// <summary>
    /// Measures the base read only (PAR-011, PAR-025): sizes of the file and of its journal, rows and bytes per category,
    /// timed reads with their SQLite plan, and the free space of its volume. The result is kept for the session.
    /// </summary>
    Task<LocalStoreSnapshot> MeasureAsync(CancellationToken cancellationToken);

    /// <summary>Nine read-only integrity checks of the base (PAR-026); the report is kept for the session. Nothing is repaired.</summary>
    Task<LocalStoreSnapshot> CheckIntegrityAsync(CancellationToken cancellationToken);

    /// <summary>Facts of the simulation (seed, reference, fictitious directory, overlay); null outside the simulation.</summary>
    Task<SimulationFacts?> SimulationAsync(CancellationToken cancellationToken);
}
