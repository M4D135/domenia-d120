using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Home page operations (docs/OPERATIONS.md § 4 to 7). Handlers only validate the arguments and delegate.</summary>
public sealed class DashboardOperations : IOperationModule
{
    private static readonly string[] RefreshArguments = ["id"];
    private static readonly string[] SetEnabledArguments = ["id", "enabled"];

    public string Screen => "dashboard";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return Definitions(DashboardService.From(context));
    }

    /// <summary>The operations over a given service (tests and hosts that compose by hand).</summary>
    public static IReadOnlyList<OperationDefinition> Definitions(DashboardService service)
    {
        ArgumentNullException.ThrowIfNull(service);
        return
        [
            new OperationDefinition("dashboard.summary", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.GetSummaryAsync(cancellationToken).ConfigureAwait(false);
            }, "Tous les widgets de l’Accueil, depuis le dernier état connu ; aucune lecture réseau."),

            new OperationDefinition("dashboard.widget.refresh", OperationClass.NetworkRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, RefreshArguments);
                var id = BridgeArguments.GetString(values, "id");
                return await service.RefreshAsync(id, cancellationToken).ConfigureAwait(false);
            }, "Remesure d’un widget, à la demande de l’opérateur.", ServedInSimulation: true),

            // LocalWrite: the state is remembered in the preferences of the application, never in the directory.
            new OperationDefinition("dashboard.widget.setEnabled", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, SetEnabledArguments);
                var id = BridgeArguments.GetString(values, "id");
                var enabled = BridgeArguments.GetBoolean(values, "enabled");
                return await service.SetEnabledAsync(id, enabled, cancellationToken).ConfigureAwait(false);
            }, "Active ou désactive la mesure d’un widget ; l’état est mémorisé dans les préférences locales."),
        ];
    }
}
