using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.App;

/// <summary>
/// Operations of the host itself (identity and mode, docs/OPERATIONS.md § 2). Found by the composition like every other
/// module; public for that reason only.
/// </summary>
public sealed class HostOperations : IOperationModule
{
    public string Screen => "app";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var info = AppInfoBuilder.Build(context.Decision, Environment.Version.ToString(), AppPaths.WebViewRuntime is null ? "windows" : "embarque");
        return
        [
            new OperationDefinition("app.info", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(info);
            }, "Identité de l’application, du moteur web et du mode de fonctionnement."),
        ];
    }
}
