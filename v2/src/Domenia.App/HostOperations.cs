using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.App;

/// <summary>Operations of the host itself (identity, health of the bridge). Domain operations register elsewhere.</summary>
internal static class HostOperations
{
    public static OperationRegistry CreateRegistry() => new(
    [
        new OperationDefinition("app.info", OperationClass.Local, (_, _, _) =>
            Task.FromResult<object?>(new { name = ProductInfo.Name, version = ProductInfo.Version, runtime = Environment.Version.ToString(), webViewRuntime = AppPaths.WebViewRuntime is null ? "windows" : "embarque" }),
            "Identité de l’application et du moteur web."),
    ]);
}
