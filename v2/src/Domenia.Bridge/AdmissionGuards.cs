using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Admission rules evaluated by the dispatcher before any handler runs.</summary>
public static class AdmissionGuards
{
    /// <summary>
    /// Simulation (docs/OPERATIONS.md § 1.5): Write is always refused (simulation.readOnly), whatever its declaration says;
    /// NetworkRead is refused (simulation.unavailable) unless the operation is marked as served by the simulated source.
    /// Refused by default, so a future remote tool can never run for real in simulation. Local, LocalRead and LocalWrite
    /// (preferences of the simulation, never the directory) are admitted.
    /// </summary>
    public static BridgeError? ReadOnlySimulation(OperationDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(definition);
        return definition.Class switch
        {
            OperationClass.Local or OperationClass.LocalRead or OperationClass.LocalWrite => null,
            OperationClass.NetworkRead when definition.ServedInSimulation => null,
            OperationClass.NetworkRead => new BridgeError(DomeniaErrors.SimulationUnavailable, DomeniaErrors.SimulationUnavailableMessage),
            // Write, and any class added later, is refused until this guard says otherwise.
            _ => new BridgeError(DomeniaErrors.SimulationReadOnly, DomeniaErrors.SimulationReadOnlyMessage),
        };
    }

    /// <summary>
    /// Directory mode (docs/OPERATIONS.md § 1.5): Write is refused (write.unavailable) before its handler, whatever module
    /// declares it, until the chain plan, confirmation, receipt and re-read exists in the bridge. Any class added later is
    /// refused too until this guard knows it. Local, LocalRead, LocalWrite (local preferences) and NetworkRead (bounded
    /// reads, after an operator gesture) are admitted.
    /// </summary>
    public static BridgeError? ReadOnlyDirectory(OperationDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(definition);
        return definition.Class switch
        {
            OperationClass.Local or OperationClass.LocalRead or OperationClass.LocalWrite or OperationClass.NetworkRead => null,
            _ => new BridgeError(DomeniaErrors.WriteUnavailable, DomeniaErrors.WriteUnavailableMessage),
        };
    }

    /// <summary>Guard of a mode: every mode has one, so no operation is ever admitted without a rule.</summary>
    public static Func<OperationDefinition, BridgeError?> For(AppMode mode) => mode == AppMode.Simulation ? ReadOnlySimulation : ReadOnlyDirectory;
}
