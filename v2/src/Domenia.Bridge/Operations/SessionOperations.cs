using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Session operations (docs/OPERATIONS.md § 3 and 11): session.info and the choice of the working OU, shared by every
/// section without a scope of its own.
/// </summary>
public sealed class SessionOperations : IOperationModule
{
    private static readonly string[] SetScopeArguments = ["dn", "subtree"];

    public string Screen => "session";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var dashboard = DashboardService.From(context);
        var scope = WorkingScope.From(context);
        var source = context.Directory;
        return
        [
            // LocalRead: the working OU is restored from the preferences file and checked in the local OU index.
            new OperationDefinition("session.info", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                return await dashboard.GetSessionInfoAsync(cancellationToken).ConfigureAwait(false);
            }, "Session, domaine, contrôleur, OU de travail, droits estimés et état de la base locale."),

            // LocalWrite: the choice is remembered in the preferences of the application, never in the directory.
            new OperationDefinition("session.setScope", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, SetScopeArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var subtree = BridgeArguments.GetBoolean(values, "subtree");
                var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                await scope.SetAsync(session, dn, subtree, cancellationToken).ConfigureAwait(false);
                return await dashboard.GetSessionInfoAsync(cancellationToken).ConfigureAwait(false);
            }, "Choisit l’OU de travail (vérifiée, mémorisée par domaine) et renvoie la session à jour."),
        ];
    }
}
