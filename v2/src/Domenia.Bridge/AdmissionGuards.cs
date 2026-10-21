using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Admission rules evaluated by the dispatcher before any handler runs.</summary>
public static class AdmissionGuards
{
    /// <summary>
    /// Simulation (docs/OPERATIONS.md § 1.5): read only by default. Write is admitted for the write circuit only
    /// (<see cref="IsWriteCircuit"/>: write.execute, whose executors of the simulation change the in-memory overlay of the
    /// fictitious directory, never anything real; decision of David, 21/10); any other Write is refused (simulation.readOnly)
    /// whatever its declaration says. NetworkRead is refused (simulation.unavailable) unless the operation is marked as served
    /// by the simulated source: refused by default, so a future remote tool can never run for real in simulation. Local,
    /// LocalRead and LocalWrite (preferences and receipts of the simulation, never the directory) are admitted.
    /// </summary>
    public static BridgeError? ReadOnlySimulation(OperationDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(definition);
        return definition.Class switch
        {
            OperationClass.Local or OperationClass.LocalRead or OperationClass.LocalWrite => null,
            OperationClass.NetworkRead when definition.ServedInSimulation => null,
            OperationClass.NetworkRead => new BridgeError(DomeniaErrors.SimulationUnavailable, DomeniaErrors.SimulationUnavailableMessage),
            OperationClass.Write when IsWriteCircuit(definition) => null,
            // Any other Write, and any class added later, is refused until this guard says otherwise.
            _ => new BridgeError(DomeniaErrors.SimulationReadOnly, DomeniaErrors.SimulationReadOnlyMessage),
        };
    }

    /// <summary>
    /// Directory mode (docs/OPERATIONS.md § 1.5): read only by default. Write is admitted for the write circuit only
    /// (<see cref="IsWriteCircuit"/>: write.execute, which runs a plan confirmed by the operator once, with its receipt and its
    /// re-read); any other Write is refused (write.unavailable) before its handler, whatever module declares it. Any class
    /// added later is refused too until this guard knows it. Local, LocalRead, LocalWrite (local preferences and receipts) and
    /// NetworkRead (bounded reads, after an operator gesture) are admitted.
    /// </summary>
    public static BridgeError? ReadOnlyDirectory(OperationDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(definition);
        return definition.Class switch
        {
            OperationClass.Local or OperationClass.LocalRead or OperationClass.LocalWrite or OperationClass.NetworkRead => null,
            OperationClass.Write when IsWriteCircuit(definition) => null,
            _ => new BridgeError(DomeniaErrors.WriteUnavailable, DomeniaErrors.WriteUnavailableMessage),
        };
    }

    /// <summary>
    /// The single door of the writes: the generic execution of the write circuit (write.execute, declared by
    /// <see cref="WriteOperations"/>). The composition refuses two operations of the same name, so no other module can take it.
    /// </summary>
    public static bool IsWriteCircuit(OperationDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(definition);
        return definition.Class == OperationClass.Write && string.Equals(definition.Name, WriteCircuit.ExecuteOperation, StringComparison.Ordinal);
    }

    /// <summary>Guard of a mode: every mode has one, so no operation is ever admitted without a rule.</summary>
    public static Func<OperationDefinition, BridgeError?> For(AppMode mode) => mode == AppMode.Simulation ? ReadOnlySimulation : ReadOnlyDirectory;
}
