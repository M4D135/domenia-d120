using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using Domenia.App.Capture;
using Domenia.App.E2e;
using Domenia.Bridge;
using Domenia.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Domenia.App;

/// <summary>The only window: a WebView2 surface serving the local web interface, locked to the virtual host.</summary>
internal sealed partial class MainForm : Form
{
    private const string RuntimeMissingMessage = "Le moteur d’affichage WebView2 est introuvable : le moteur exigé par cette édition n’est pas disponible. Le détail technique est dans le journal de l’application.";
    private const string StartFailedMessage = "L’affichage de Domenia n’a pas pu démarrer. Le détail technique est dans le journal de l’application.";
    private const string NoDataFolderMessage = "Dossier de données introuvable : Windows ne fournit pas de dossier %LOCALAPPDATA% pour ce compte. Domenia n’écrit nulle part ailleurs et ne peut donc pas démarrer l’affichage.";

    private bool hostClosing;
    private bool initialPageReady;

    private readonly WebView2 webView = new() { Dock = DockStyle.Fill };
    private readonly StartupMonitor openingMonitor = new(TimeProvider.System);
    private readonly StartupDisplayOptions openingDisplay;
    private readonly Label startupStatus = new() { Dock = DockStyle.Top, Height = 58, TextAlign = ContentAlignment.MiddleCenter,
        Text = "Initialisation de l’affichage WebView2… La fenêtre reste disponible." };
    // Page messages being handled off the UI thread: waited for (bounded) before the engine services are disposed.
    private readonly ConcurrentDictionary<int, Task> inFlight = new();
    private BridgeDispatcher dispatcher;
    private readonly Composition composition;
    private readonly CancellationTokenSource lifetime = new();
    private readonly AppMode mode;
    private readonly CaptureSession? capture;
    private readonly E2eArguments? e2e;
    private bool waitingForInitialInterface;
    private readonly NativeWindowActivation initialActivation;

    /// <summary>Stopwatch timestamp of the window load: start of the single startup budget of the capture mode.</summary>
    private long startupBegan;

    /// <param name="capture">Set with --capture only: fixed geometry, capture profile, then the sequence and closing.</param>
    /// <param name="e2e">Set with --e2e-port and DOMENIA_E2E=1 only (docs/E2E.md): emptied E2E profile and DevTools
    /// protocol on the loopback port, for the end-to-end harness.</param>
    public MainForm(Composition composition, CaptureSession? capture = null, E2eArguments? e2e = null)
    {
        ArgumentNullException.ThrowIfNull(composition);
        initialActivation = new NativeWindowActivation(this, "interface");
        ProductBrand.Apply(this);
        this.composition = composition;
        closingWrites = composition.Writes;
        closingTaskJournal = composition.PosteTaskJournal;
        mode = composition.Decision.Mode;
        this.capture = capture;
        this.e2e = e2e is { Enabled: true } ? e2e : null;
        waitingForInitialInterface = composition.OffersInitialLogin(capture is not null, this.e2e is not null);
        if (waitingForInitialInterface)
        {
            // Keep the UI-thread owner and message loop alive without painting an empty host behind the login.
            // Set this before the first handle/show: hiding at Shown would already have flashed a white window.
            Opacity = 0;
            ShowInTaskbar = false;
        }
        // « Domenia — Simulation » stays visible even if the page fails to load; a driven window says so.
        Text = composition.WindowTitle + (this.e2e is null ? "" : E2eTexts.WindowTitleSuffix);
        var workArea = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1440, 900);
        MinimumSize = new Size(Math.Min(WindowRules.MinWidth, workArea.Width), Math.Min(WindowRules.MinHeight, workArea.Height));
        Size = new Size(Math.Min(1440, workArea.Width), Math.Min(900, workArea.Height));
        StartPosition = FormStartPosition.CenterScreen;
        Controls.Add(webView);
        Controls.Add(startupStatus);
        openingDisplay = composition.StartupDisplay;
        startupStatus.Visible = openingDisplay.Show;
        SetStartupStatus("Initialisation de l’affichage WebView2…");
        var openingTimer = new System.Windows.Forms.Timer { Interval = 250 };
        openingTimer.Tick += (_, _) => { if (startupStatus.Visible) startupStatus.Text = openingMonitor.Describe(false, openingDisplay.WarningSeconds); };
        startupStatus.VisibleChanged += (_, _) => { if (startupStatus.Visible) openingTimer.Start(); else openingTimer.Stop(); };
        Shown += (_, _) => { if (startupStatus.Visible) openingTimer.Start(); };
        Disposed += (_, _) => openingTimer.Dispose();
        StartupTrace.InterfaceBecameReady += HideStartupStatus;
        Disposed += (_, _) => StartupTrace.InterfaceBecameReady -= HideStartupStatus;
        dispatcher = CreateDispatcher();
        AttachLocalAccessExpiry();
        AttachPackageUpdateHost();
        composition.Demonstration.Attach(action => BeginInvoke(() => BeginDemonstration(action)));
        if (capture is not null)
        {
            StartPosition = FormStartPosition.Manual;
            Location = Point.Empty;
            webView.Dock = DockStyle.None;
        }
        Load += async (_, _) =>
        {
            startupBegan = Stopwatch.GetTimestamp();
            if (capture is not null)
            {
                ApplyCaptureGeometry(capture);
            }
            await InitializeWebViewAsync().ConfigureAwait(true);
        };
        FormClosing += CheckClosing;
        Activated += (_, _) => { windowActive = true; PublishWindowActivity(); };
        Deactivate += (_, _) => { windowActive = false; PublishWindowActivity(); };
        Resize += (_, _) => PublishWindowActivity();
        VisibleChanged += (_, _) => PublishWindowActivity();
        FormClosed += (_, _) =>
        {
            Secrets.ClipboardGuard.ClearOwned();
            DrainPendingMessages();
        };
    }

    private void SetStartupStatus(string text)
    {
        openingMonitor.Phase(text);
        startupStatus.Text = openingMonitor.Describe(false, openingDisplay.WarningSeconds);
    }

    private void HideStartupStatus()
    {
        try
        {
            if (!IsDisposed && IsHandleCreated) BeginInvoke(() =>
            {
                if (IsDisposed) return;
                initialPageReady = true;
                startupStatus.Visible = false;
                if (!waitingForInitialInterface) HostIncidentReport.SessionShown();
            });
        }
        catch (InvalidOperationException) { /* The native host closed after the page's local readiness event. */ }
    }

    internal void PrepareLoginDialog(Form dialog)
    {
        if (!waitingForInitialInterface) return;
        dialog.StartPosition = FormStartPosition.CenterScreen;
        dialog.ShowInTaskbar = true;
    }

    private void RevealInitialInterface()
    {
        if (!waitingForInitialInterface || IsDisposed || lifetime.IsCancellationRequested) return;
        waitingForInitialInterface = false;
        ShowInTaskbar = true;
        Opacity = 1;
        if (initialPageReady) HostIncidentReport.SessionShown();
        initialActivation.Request();
    }

    /// <summary>
    /// The page always gets the same viewport (1600 × 1000 CSS pixels): the WebView2 surface keeps that size even when
    /// Windows limits the window to a smaller screen (non-interactive session of the lab VM).
    /// </summary>
    private void ApplyCaptureGeometry(CaptureSession session)
    {
        var viewport = LogicalToDeviceUnits(CaptureSequence.Viewport);
        ClientSize = viewport;
        webView.Bounds = new Rectangle(Point.Empty, viewport);
        var limited = ClientSize != viewport ? " (fenêtre limitée par l’écran, surface conservée)" : "";
        session.Write($"Fenêtre : zone cliente {ClientSize.Width.ToString(CultureInfo.InvariantCulture)} × {ClientSize.Height.ToString(CultureInfo.InvariantCulture)} px, surface WebView2 {viewport.Width.ToString(CultureInfo.InvariantCulture)} × {viewport.Height.ToString(CultureInfo.InvariantCulture)} px, {DeviceDpi.ToString(CultureInfo.InvariantCulture)} ppp{limited}.");
    }

    private async Task InitializeWebViewAsync()
    {
        var userData = AppPaths.WebViewUserData(mode, capture is not null, e2e is not null);
        if (userData is null)
        {
            TechnicalLog.Warning("Dossier de données introuvable : l’affichage n’est pas démarré.");
            ShowFallback(NoDataFolderMessage);
            return;
        }
        // Profile name only: the full path holds the Windows account name, and capture.log lives outside the data folder.
        capture?.Write($"Profil WebView2 de capture : %LOCALAPPDATA%\\Domenia\\{Path.GetFileName(userData)} (vidé au démarrage ; les préférences de l’opérateur ne sont pas touchées).");
        CoreWebView2Environment environment;
        try
        {
            if (e2e is not null)
            {
                // Every E2E run starts from an empty profile (web storage, cache, cookies): off the UI thread.
                await Task.Run(() => EmptyE2eProfile(userData)).ConfigureAwait(true);
            }
            Directory.CreateDirectory(userData);
            var options = AppPaths.BrowserOptions(AppPaths.Browser == BrowserSource.Evergreen);
            if (e2e is not null)
            {
                // Loopback DevTools port only; the environment variable that could override it was neutralized at start.
                options.AdditionalBrowserArguments = e2e.BrowserArguments;
            }
            using (StartupTrace.Clock.Measure(StartupPhase.WebViewEnvironment))
                environment = await Bounded(CoreWebView2Environment.CreateAsync(AppPaths.WebViewRuntime, userData, options)).ConfigureAwait(true);
            SetStartupStatus("Création de la surface d’affichage…");
            using (StartupTrace.Clock.Measure(StartupPhase.WebViewControl))
                await Bounded(webView.EnsureCoreWebView2Async(environment)).ConfigureAwait(true);
            PackageIntegrity.ConfirmBrowserProcess(AppPaths.WebViewRuntime, checked((int)webView.CoreWebView2.BrowserProcessId));
        }
        catch (WebView2RuntimeNotFoundException ex)
        {
            TechnicalLog.Error("Moteur WebView2 introuvable.", ex);
            capture?.Error("Moteur WebView2 introuvable.", ex);
            ShowFallback(RuntimeMissingMessage);
            return;
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or ArgumentException or IOException or UnauthorizedAccessException or TimeoutException or InvalidDataException or System.ComponentModel.Win32Exception)
        {
            TechnicalLog.Error("Démarrage de WebView2 impossible.", ex);
            capture?.Error("Démarrage de WebView2 impossible.", ex);
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
        core.NavigationCompleted += (_, result) =>
        {
            StartupTrace.Clock.Mark(StartupPhase.Navigation);
            SetStartupStatus("Préparation des écrans et de l’état local…");
            if (!result.IsSuccess) ShowFallback(StartFailedMessage);
            else { if (!openingDisplay.KeepUntilReady) startupStatus.Visible = false; RevealInitialInterface(); }
            PublishWindowActivity(force: true);
        };
        SetStartupStatus("Chargement de l’interface locale…");
        if (e2e is not null)
        {
            // The profile folder was deleted before the start; whatever could not be deleted is cleared here.
            try
            {
                await core.Profile.ClearBrowsingDataAsync().ConfigureAwait(true);
            }
            catch (COMException ex)
            {
                TechnicalLog.Warning($"Profil WebView2 E2E : effacement des données de navigation en échec (HRESULT 0x{ex.HResult.ToString("X8", CultureInfo.InvariantCulture)}).");
            }
            TechnicalLog.Info(E2eTexts.Active(e2e.Port, Path.GetFileName(userData)));
        }
        if (capture is null)
        {
            if (composition.OffersInitialLogin(capture: false, e2e: e2e is not null))
            {
                SetStartupStatus("Choisissez votre connexion dans la fenêtre native. Vous pouvez continuer hors connexion.");
                try { await Task.Run(() => composition.PresentInitialLoginAsync(lifetime.Token), lifetime.Token).ConfigureAwait(true); }
                catch (OperationCanceledException) when (lifetime.IsCancellationRequested || IsDisposed) { return; }
                catch (Exception error) when (error is DomeniaOperationException or IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException)
                {
                    TechnicalLog.Warning("Entrée de connexion non terminée (" + error.GetType().Name + ") ; ouverture de l’interface sans nouvel essai de connexion.");
                    if (IsDisposed || lifetime.IsCancellationRequested) return;
                    MessageBox.Show(this, "L’entrée de connexion n’a pas pu se terminer correctement. Domenia ouvre l’interface sans nouvel essai ; l’état de session affiché fait foi et les actions de connexion restent disponibles.",
                        "Domenia — Connexion", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
                if (IsDisposed || lifetime.IsCancellationRequested) return;
                SetStartupStatus("Chargement de l’interface locale…");
            }
            core.Navigate(StartAddress);
            return;
        }
        await new CaptureRunner(core, capture).RunAsync(environment, StartAddress, startupBegan, lifetime.Token).ConfigureAwait(true);
        // The sequence is over (or stopped): the application closes by itself and Main returns the exit code.
        if (!IsDisposed)
        {
            Close();
        }
    }

    private static string StartAddress => $"https://{ProductInfo.WebHost}/index.html";

    /// <summary>
    /// Deletes the E2E profile folder (its fixed name comes from AppPaths, never from the command line). A folder that is a
    /// link is left alone (its target is not ours to delete); a file still held by a browser process that has not exited
    /// yet is traced, and ClearBrowsingDataAsync clears the rest once WebView2 has started.
    /// </summary>
    private static void EmptyE2eProfile(string folder)
    {
        try
        {
            var info = new DirectoryInfo(folder);
            if (!info.Exists)
            {
                return;
            }
            if (info.Attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                TechnicalLog.Warning("Profil WebView2 E2E non vidé : le dossier est un lien ; les données de navigation seront effacées par WebView2.");
                return;
            }
            info.Delete(recursive: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            TechnicalLog.Warning($"Profil WebView2 E2E vidé en partie ({ex.GetType().Name}) ; les données de navigation restantes seront effacées par WebView2.");
        }
    }

    /// <summary>
    /// In capture mode a WebView2 start that never ends must not keep the process alive: every startup call shares one
    /// budget (CaptureSequence.StartupLimit) counted from the window load.
    /// </summary>
    private Task<T> Bounded<T>(Task<T> task) => capture is null ? task : task.WaitAsync(CaptureSequence.StartupLeft(startupBegan));

    private Task Bounded(Task task) => capture is null ? task : task.WaitAsync(CaptureSequence.StartupLeft(startupBegan));

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
        startupStatus.Visible = false;
        Controls.Remove(webView);
        Controls.Add(new Label { Dock = DockStyle.Fill, Text = message, TextAlign = ContentAlignment.MiddleCenter, Padding = new Padding(48) });
        RevealInitialInterface();
        if (capture is not null)
        {
            // Nobody is there to read the message: the capture stops and the application closes with code 2.
            capture.Abort(message);
            BeginInvoke(() => Close());
        }
    }

    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (hostClosing) return;
        if (!Uri.TryCreate(e.Source, UriKind.Absolute, out var source) || !string.Equals(source.Host, ProductInfo.WebHost, StringComparison.OrdinalIgnoreCase))
        {
            TechnicalLog.Warning($"Message de l’interface refusé : origine {Describe(e.Source)} non admise.");
            return;
        }
        var json = e.WebMessageAsJson;
        var token = lifetime.Token;
        var task = DispatchMessageAsync(json, token);
        // Added before the continuation is attached: a task already finished is removed at once.
        inFlight[task.Id] = task;
        _ = task.ContinueWith(t => inFlight.TryRemove(t.Id, out _), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }

    private async Task DispatchMessageAsync(string json, CancellationToken token)
    {
        // Parsing and admission are bounded synchronously. The dispatcher starts workers only for admitted requests.
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
    }

    /// <summary>Fence new messages, request cancellation off the UI thread, retain engine resources until the
    /// final pending handler and physical worker really finish. Composition owns the single three-second wait.</summary>
    private void DrainPendingMessages()
    {
        if (hostClosing) return;
        hostClosing = true;
        composition.BeginHostClose(inFlight.Values.ToArray(),
            () => Task.WhenAll(Task.Run(dispatcher.Dispose), lifetime.CancelAsync()), lifetime.Dispose);
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
                    PublishWindowActivity();
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
            DrainPendingMessages();
            webView.Dispose();
        }
        base.Dispose(disposing);
    }
}
