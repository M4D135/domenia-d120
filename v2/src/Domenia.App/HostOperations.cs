using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.App;

/// <summary>Operations of the host itself (identity and mode). Domain operations come from Domenia.Bridge.</summary>
internal static class HostOperations
{
    public static OperationDefinition AppInfoOperation(AppInfo info) => new("app.info", OperationClass.Local, (args, _, _) =>
    {
        BridgeArguments.RequireNone(args);
        return Task.FromResult<object?>(info);
    }, "Identité de l’application, du moteur web et du mode de fonctionnement.");

    public static OperationRegistry CreateRegistry(AppInfo info, DashboardService dashboard) =>
        new([AppInfoOperation(info), .. DashboardOperations.Create(dashboard)]);
}
