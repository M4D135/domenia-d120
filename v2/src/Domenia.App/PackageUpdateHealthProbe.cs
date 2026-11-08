using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Domenia.App;

/// <summary>Installed EXE/runtime probe. Deliberately creates no Composition, directory source, credential vault or database.</summary>
internal static class PackageUpdateHealthProbe
{
    internal sealed record Result(string BrowserVersion, bool DocumentLoaded, bool ScriptReady);

    internal static Result Run(PackageHealthRequest request, PackageIntegrity pack)
    {
        using var paths = new PackageLifecycleFiles();
        var profile = Path.Combine(request.TransactionDirectory, "health-profile-" + request.Attempt);
        if (PackageLifecycleFiles.Exists(profile)) { throw new InvalidDataException("Profil de contrôle déjà présent ; nouvelle tentative explicite requise."); }
        paths.PrivateDirectory(profile);
        // Overrides are removed only in this disposable child; no user setting or shared profile is changed.
        foreach (var key in Environment.GetEnvironmentVariables().Keys.Cast<string>().Where(k => k.StartsWith("WEBVIEW2_", StringComparison.OrdinalIgnoreCase)))
        { Environment.SetEnvironmentVariable(key, null); }
        ApplicationConfiguration.Initialize();
        var browser = pack.AdmitBrowser(request.Target, AppPaths.InstalledBrowserVersion);
        using var form = new ProbeForm(browser, profile, pack.Browser == BrowserSource.Evergreen);
        Application.Run(form);
        return form.Result ?? throw new IOException("Le contrôle du moteur d’affichage n’a pas abouti (" + (form.Failure ?? "fermeture") + ").");
    }

    private sealed class ProbeForm : Form
    {
        private readonly WebView2 view = new() { Dock = DockStyle.Fill };
        private bool resourcesDisposed;
        private readonly CancellationTokenSource timeout = new(TimeSpan.FromSeconds(45));
        internal Result? Result { get; private set; }
        internal string? Failure { get; private set; }

        internal ProbeForm(string? browserFolder, string profile, bool evergreen)
        {
            Text = "Domenia — vérification de la mise à jour";
            ClientSize = new(480, 180); StartPosition = FormStartPosition.CenterScreen;
            Controls.Add(view);
            Load += async (_, _) =>
            {
#pragma warning disable CA1031 // Isolated startup boundary: return a failure receipt, never start the normal application.
                try
                {
                    var options = AppPaths.BrowserOptions(evergreen);
                    options.AdditionalBrowserArguments = "--disable-background-networking --disable-sync --no-first-run";
                    var environment = await CoreWebView2Environment.CreateAsync(browserFolder, profile, options)
                        .WaitAsync(timeout.Token).ConfigureAwait(true);
                    if (!string.Equals(Path.TrimEndingDirectorySeparator(environment.UserDataFolder), profile, StringComparison.OrdinalIgnoreCase))
                    { throw new UnauthorizedAccessException("Profil WebView2 redirigé ; contrôle isolé refusé."); }
                    await view.EnsureCoreWebView2Async(environment).WaitAsync(timeout.Token).ConfigureAwait(true);
                    var core = view.CoreWebView2;
                    PackageIntegrity.ConfirmBrowserProcess(browserFolder, checked((int)core.BrowserProcessId));
                    core.Settings.AreDevToolsEnabled = false; core.Settings.IsWebMessageEnabled = false;
                    core.Settings.AreDefaultContextMenusEnabled = false;
                    core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
                    core.NewWindowRequested += (_, e) => e.Handled = true;
                    core.DownloadStarting += (_, e) => e.Cancel = true;
                    core.NavigationStarting += (_, e) => e.Cancel = e.Uri != "about:blank";
                    core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
                    core.WebResourceRequested += (_, e) => e.Response = environment.CreateWebResourceResponse(null, 403, "Contrôle local uniquement", "Content-Type: text/plain");
                    var loaded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                    core.NavigationCompleted += (_, e) => loaded.TrySetResult(e.IsSuccess);
                    core.NavigateToString("<!doctype html><html lang=\"fr\"><meta charset=\"utf-8\"><title>Domenia</title><body><p id=\"health\">Contrôle local du moteur d’affichage</p></body></html>");
                    if (!await loaded.Task.WaitAsync(timeout.Token).ConfigureAwait(true)) { throw new IOException("Document de contrôle non chargé."); }
                    var script = await core.ExecuteScriptAsync("document.readyState === 'complete' && document.getElementById('health')?.textContent === 'Contrôle local du moteur d’affichage' && (6 * 7) === 42")
                        .WaitAsync(timeout.Token).ConfigureAwait(true);
                    if (!JsonSerializer.Deserialize<bool>(script)) { throw new IOException("Exécution JavaScript non confirmée."); }
                    Result = new(environment.BrowserVersionString, true, true);
                }
                catch (Exception error) { Failure = error.GetType().Name; }
#pragma warning restore CA1031
                finally { if (!IsDisposed) Close(); }
            };
            FormClosed += (_, _) => timeout.Cancel();
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing && !resourcesDisposed) { resourcesDisposed = true; timeout.Cancel(); view.Dispose(); timeout.Dispose(); }
            base.Dispose(disposing);
        }
    }
}
