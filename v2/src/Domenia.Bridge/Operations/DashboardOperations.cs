using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>session.info and the home page operations (docs/OPERATIONS.md § 3 to 7). Handlers only validate and delegate.</summary>
public static class DashboardOperations
{
    private static readonly string[] RefreshArguments = ["id"];
    private static readonly string[] SetEnabledArguments = ["id", "enabled"];

    public static IReadOnlyList<OperationDefinition> Create(DashboardService service)
    {
        ArgumentNullException.ThrowIfNull(service);
        return
        [
            new OperationDefinition("session.info", OperationClass.Local, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.GetSessionInfoAsync(cancellationToken).ConfigureAwait(false);
            }, "Session, domaine, contrôleur, périmètre, droits estimés et état de la base locale."),

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

            new OperationDefinition("dashboard.widget.setEnabled", OperationClass.Local, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, SetEnabledArguments);
                var id = BridgeArguments.GetString(values, "id");
                var enabled = BridgeArguments.GetBoolean(values, "enabled");
                return await service.SetEnabledAsync(id, enabled, cancellationToken).ConfigureAwait(false);
            }, "Active ou désactive la mesure d’un widget pour la session."),
        ];
    }
}
