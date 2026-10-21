using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Domenia.App;

/// <summary>The only window: a WebView2 surface serving the local web interface, locked to the virtual host.</summary>
internal sealed class MainForm : Form
{
    private static readonly JsonSerializerOptions ResponseJson = new() { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };
    private readonly WebView2 webView = new() { Dock = DockStyle.Fill };
    private readonly BridgeDispatcher dispatcher;
    private readonly CancellationTokenSource lifetime = new();

    public MainForm()
    {
        Text = ProductInfo.Name;
        MinimumSize = new Size(1024, 680);
        Size = new Size(1440, 900);
        StartPosition = FormStartPosition.CenterScreen;
        Controls.Add(webView);
        dispatcher = new BridgeDispatcher(HostOperations.CreateRegistry(), PostToPage);
        Load += async (_, _) => await InitializeWebViewAsync().ConfigureAwait(true);
        FormClosed += (_, _) => lifetime.Cancel();
    }

    private async Task InitializeWebViewAsync()
    {
        Directory.CreateDirectory(AppPaths.WebViewUserData);
        var options = new CoreWebView2EnvironmentOptions { AreBrowserExtensionsEnabled = false };
        var environment = await CoreWebView2Environment.CreateAsync(AppPaths.WebViewRuntime, AppPaths.WebViewUserData, options).ConfigureAwait(true);
        await webView.EnsureCoreWebView2Async(environment).ConfigureAwait(true);
        var core = webView.CoreWebView2;
#if DEBUG
        core.Settings.AreDevToolsEnabled = true;
#else
        core.Settings.AreDevToolsEnabled = false;
#endif
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsZoomControlEnabled = true;
        core.Settings.AreHostObjectsAllowed = false;
        core.Settings.IsWebMessageEnabled = true;
        core.Settings.IsGeneralAutofillEnabled = false;
        core.Settings.IsPasswordAutosaveEnabled = false;
        core.SetVirtualHostNameToFolderMapping(ProductInfo.WebHost, AppPaths.WebRoot, CoreWebView2HostResourceAccessKind.Deny);
        core.NavigationStarting += (_, e) =>
        {
            // Only the local interface may be shown; any other address is cancelled.
            if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps || !string.Equals(uri.Host, ProductInfo.WebHost, StringComparison.OrdinalIgnoreCase))
            {
                e.Cancel = true;
            }
        };
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.WebMessageReceived += OnWebMessageReceived;
        core.Navigate($"https://{ProductInfo.WebHost}/index.html");
    }

    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (!Uri.TryCreate(e.Source, UriKind.Absolute, out var source) || !string.Equals(source.Host, ProductInfo.WebHost, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }
        var json = e.WebMessageAsJson;
        _ = Task.Run(() => dispatcher.HandleAsync(json, lifetime.Token));
    }

    private void PostToPage(BridgeResponse response)
    {
        var json = JsonSerializer.Serialize(response, ResponseJson);
        if (IsDisposed)
        {
            return;
        }
        BeginInvoke(() =>
        {
            if (!IsDisposed && webView.CoreWebView2 is not null)
            {
                webView.CoreWebView2.PostWebMessageAsJson(json);
            }
        });
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            lifetime.Dispose();
            webView.Dispose();
        }
        base.Dispose(disposing);
    }
}
