using System.Runtime.InteropServices;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Domenia.App;

/// <summary>The only window: a WebView2 surface serving the local web interface, locked to the virtual host.</summary>
internal sealed class MainForm : Form
{
    private const string RuntimeMissingMessage = "Le moteur d’affichage WebView2 est introuvable : ni celui du pack (dossier runtime\\webview2), ni celui de Windows. Relancez Domenia depuis le pack complet. Le détail technique est dans le journal de l’application.";
    private const string StartFailedMessage = "L’affichage de Domenia n’a pas pu démarrer. Le détail technique est dans le journal de l’application.";
    private const string NoDataFolderMessage = "Dossier de données introuvable : Windows ne fournit pas de dossier %LOCALAPPDATA% pour ce compte. Domenia n’écrit nulle part ailleurs et ne peut donc pas démarrer l’affichage.";

    private readonly WebView2 webView = new() { Dock = DockStyle.Fill };
    private readonly BridgeDispatcher dispatcher;
    private readonly CancellationTokenSource lifetime = new();
    private readonly AppMode mode;

    public MainForm(Composition composition)
    {
        ArgumentNullException.ThrowIfNull(composition);
        mode = composition.Decision.Mode;
        // « Domenia — Simulation » stays visible even if the page fails to load.
        Text = composition.WindowTitle;
        MinimumSize = new Size(1024, 680);
        Size = new Size(1440, 900);
        StartPosition = FormStartPosition.CenterScreen;
        Controls.Add(webView);
        dispatcher = new BridgeDispatcher(composition.Registry, PostToPage, composition.Admission);
        dispatcher.UnhandledError += (operation, exception) => TechnicalLog.Error($"Échec imprévu de l’opération {operation}.", exception);
        // Code and declared name only: the content of a refused message never reaches the journal.
        dispatcher.Refused += (code, operation) => TechnicalLog.Warning($"Message de l’interface refusé : {code}" + (operation is null ? "." : $" ({operation})."));
        Load += async (_, _) => await InitializeWebViewAsync().ConfigureAwait(true);
        FormClosed += (_, _) => lifetime.Cancel();
    }

    private async Task InitializeWebViewAsync()
    {
        var userData = AppPaths.WebViewUserData(mode);
        if (userData is null)
        {
            TechnicalLog.Warning("Dossier de données introuvable : l’affichage n’est pas démarré.");
            ShowFallback(NoDataFolderMessage);
            return;
        }
        CoreWebView2Environment environment;
        try
        {
            Directory.CreateDirectory(userData);
            var options = new CoreWebView2EnvironmentOptions { AreBrowserExtensionsEnabled = false };
            environment = await CoreWebView2Environment.CreateAsync(AppPaths.WebViewRuntime, userData, options).ConfigureAwait(true);
            await webView.EnsureCoreWebView2Async(environment).ConfigureAwait(true);
        }
        catch (WebView2RuntimeNotFoundException ex)
        {
            TechnicalLog.Error("Moteur WebView2 introuvable.", ex);
            ShowFallback(RuntimeMissingMessage);
            return;
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or ArgumentException or IOException or UnauthorizedAccessException)
        {
            TechnicalLog.Error("Démarrage de WebView2 impossible.", ex);
            ShowFallback(StartFailedMessage);
            return;
        }
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
        // SmartScreen would send addresses to a reputation service: local content needs none.
        core.Settings.IsReputationCheckingRequired = false;
        core.SetVirtualHostNameToFolderMapping(ProductInfo.WebHost, AppPaths.WebRoot, CoreWebView2HostResourceAccessKind.Deny);
        // Every request of the page, its frames and workers: only the local interface (and inline data) is served.
        core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
        core.WebResourceRequested += (_, e) =>
        {
            if (!IsAllowedResource(e.Request.Uri))
            {
                e.Response = environment.CreateWebResourceResponse(null, 403, "Forbidden", "");
                TechnicalLog.Warning($"Requête de la page bloquée : {Describe(e.Request.Uri)}.");
            }
        };
        core.NavigationStarting += (_, e) =>
        {
            // Only the local interface may be shown; any other address is cancelled.
            if (!IsInterfaceAddress(e.Uri))
            {
                e.Cancel = true;
                TechnicalLog.Warning($"Navigation bloquée : {Describe(e.Uri)}.");
            }
        };
        core.FrameNavigationStarting += (_, e) =>
        {
            // Same rule for frames, plus their empty documents.
            if (!IsInterfaceAddress(e.Uri) && e.Uri is not ("about:blank" or "about:srcdoc"))
            {
                e.Cancel = true;
                TechnicalLog.Warning($"Navigation de cadre bloquée : {Describe(e.Uri)}.");
            }
        };
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.WebMessageReceived += OnWebMessageReceived;
        core.Navigate($"https://{ProductInfo.WebHost}/index.html");
    }

    private static bool IsInterfaceAddress(string? address) =>
        Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps
        && string.Equals(uri.Host, ProductInfo.WebHost, StringComparison.OrdinalIgnoreCase);

    private static bool IsAllowedResource(string? address) =>
        IsInterfaceAddress(address)
        || (Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.Scheme is "data" or "blob" or "about");

    /// <summary>Scheme and host only: paths and queries never reach the journal.</summary>
    private static string Describe(string? address) =>
        Uri.TryCreate(address, UriKind.Absolute, out var uri) ? uri.Scheme + "://" + uri.Host : "adresse illisible";

    private void ShowFallback(string message)
    {
        // The window title (« Domenia — Simulation ») stays; the web surface is replaced by an explicit message.
        Controls.Remove(webView);
        Controls.Add(new Label { Dock = DockStyle.Fill, Text = message, TextAlign = ContentAlignment.MiddleCenter, Padding = new Padding(48) });
    }

    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (!Uri.TryCreate(e.Source, UriKind.Absolute, out var source) || !string.Equals(source.Host, ProductInfo.WebHost, StringComparison.OrdinalIgnoreCase))
        {
            TechnicalLog.Warning($"Message de l’interface refusé : origine {Describe(e.Source)} non admise.");
            return;
        }
        var json = e.WebMessageAsJson;
        var token = lifetime.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await dispatcher.HandleAsync(json, token).ConfigureAwait(false);
            }
#pragma warning disable CA1031 // Nothing may escape a detached task untraced.
            catch (Exception ex)
#pragma warning restore CA1031
            {
                TechnicalLog.Error("Message de l’interface non traité.", ex);
            }
        }, CancellationToken.None);
    }

    private void PostToPage(BridgeResponse response)
    {
        var json = JsonSerializer.Serialize(response, BridgeJson.Options);
        if (IsDisposed || !IsHandleCreated)
        {
            return;
        }
        try
        {
            BeginInvoke(() =>
            {
                if (!IsDisposed && webView.CoreWebView2 is not null)
                {
                    webView.CoreWebView2.PostWebMessageAsJson(json);
                }
            });
        }
        catch (InvalidOperationException ex)
        {
            // The window closed between the check and the call (ObjectDisposedException included): the answer is dropped.
            TechnicalLog.Warning($"Réponse non transmise à la page : fenêtre fermée ({ex.GetType().Name}).");
        }
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
