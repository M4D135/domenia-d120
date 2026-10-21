using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Admission rules evaluated by the dispatcher before any handler runs.</summary>
public static class AdmissionGuards
{
    /// <summary>
    /// Simulation (docs/OPERATIONS.md § 1.5): Write is always refused (simulation.readOnly); NetworkRead is refused
    /// (simulation.unavailable) unless the operation is marked as served by the simulated source. Refused by default, so a
    /// future remote tool can never run for real in simulation.
    /// </summary>
    public static BridgeError? ReadOnlySimulation(OperationDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(definition);
        return definition.Class switch
        {
            OperationClass.Write => new BridgeError(DomeniaErrors.SimulationReadOnly, DomeniaErrors.SimulationReadOnlyMessage),
            OperationClass.NetworkRead when !definition.ServedInSimulation => new BridgeError(DomeniaErrors.SimulationUnavailable, DomeniaErrors.SimulationUnavailableMessage),
            _ => null,
        };
    }

    /// <summary>Guard of a mode; directory mode has none yet (writes will bring their own plan and confirmation).</summary>
    public static Func<OperationDefinition, BridgeError?>? For(AppMode mode) => mode == AppMode.Simulation ? ReadOnlySimulation : null;
}
