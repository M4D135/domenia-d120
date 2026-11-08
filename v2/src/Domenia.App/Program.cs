using System.Text;
using System.Reflection;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.App.Capture;
using Domenia.App.E2e;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.App;

internal static class Program
{
    private static Func<bool>? expertReport;

    private static int failed;

    /// <summary>Set with --capture only (docs/CAPTURE.md); the run then ends by itself with code 0 or 2.</summary>
    private static CaptureSession? capture;

    /// <summary>Set with --e2e-port and DOMENIA_E2E=1 only (docs/E2E.md): the harness drives the window.</summary>
    private static E2eArguments? e2e;

    [STAThread]
    private static int Main(string[] args)
    {
        if (!DemoSessionProcess.Configure(args))
        {
            WriteStandardError("Utilisez --demo-session seul ; aucune commande réelle ne peut être combinée à la démonstration.");
            return 2;
        }
        // The closed grammar runs before maintenance commands, journal initialization and any source composition.
        if (AutomationCommandLine.IsRequested(args))
            return AutomationHostCommand.Run(args, () => CheckPackage(args, out _));
        var selfTest = StartupPreflight.Requested(args);
        string? selfTestOutput = null;
        if (selfTest)
        {
            try { selfTestOutput = StartupPreflight.Parse(args); }
            catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException)
            { WriteStandardError("Autotest refusé : arguments ou destination invalides ; aucun accès AD."); return 2; }
        }
        if (PortableConfigurationCommand.TryRun(args, out var seedExitCode)) { return seedExitCode; }
        if (PackageUpdateAssistant.TryRun(args, out var updateExitCode)) { return updateExitCode; }
        // Closed native reader: no UI, profile, journal, or command text. The child authenticates its private parent pipe.
        if (Domenia.Inventory.NativeReadWorkerHost.IsRequested(args)) { return Domenia.Inventory.NativeReadWorkerHost.Run(args); }
        var interactive = !selfTest && !PackageLifecycleCommand.IsRequested(args) && !OfflineDossierCommand.IsRequested(args)
            && !args.Any(x => x.Equals("--check-only", StringComparison.OrdinalIgnoreCase) || x.Equals("-CheckOnly", StringComparison.OrdinalIgnoreCase)
                || x.Equals("--capture", StringComparison.OrdinalIgnoreCase) || x.Equals("--capture-routes", StringComparison.OrdinalIgnoreCase)
                || x.Equals("--capture-themes", StringComparison.OrdinalIgnoreCase) || x.Equals("--e2e-port", StringComparison.OrdinalIgnoreCase));
        if (interactive) StartupBootstrap.Begin(typeof(Program).Assembly.GetName().Version?.ToString() ?? "inconnue");
        var visible = interactive ? StartupTrace.Clock.Measure(StartupPhase.NativeVisible) : null;
        using var startup = interactive ? new StartupWindow() : null;
        visible?.Dispose();
        using var package = CheckPackage(args, out var checkOnly, startup);
        if (package is null) { return startup?.Token.IsCancellationRequested == true ? 0 : checkOnly || selfTest ? 1 : 2; }
        if (interactive || args.Any(x => x.Equals("--capture", StringComparison.OrdinalIgnoreCase) || x.Equals("--e2e-port", StringComparison.OrdinalIgnoreCase))) StartupTrace.PackageVerified();
        if (checkOnly || selfTest)
        {
#pragma warning disable CA1031 // Command-line diagnostics must fail without opening UI or an operator profile.
            try
            {
                var assemblies = OperationModules.LoadDomeniaAssemblies();
                if (checkOnly)
                {
                    return StartupCheckCommand.Run(package, assemblies, WriteStandardError);
                }
                var result = StartupPreflight.DiagnoseAsync(assemblies, CancellationToken.None).GetAwaiter().GetResult();
                if (selfTestOutput is not null) StartupPreflight.Save(selfTestOutput, result);
                WriteStandardError(System.Text.Json.JsonSerializer.Serialize(result));
                return result.Passed ? 0 : 1;
            }
            catch (Exception failure) { WriteStandardError("Contrôle local non validé : " + failure.GetType().Name + ". Aucun accès AD."); return 1; }
#pragma warning restore CA1031
        }
        if (PackageLifecycleCommand.IsRequested(args))
        { return PackageLifecycleCommand.Run(PackageLayout.ApplicationRoot, args, Console.Error, TimeProvider.System, healthCheck: PackageUpdateAssistant.CheckHealth); }
        // Last resort traces: a crash or a forgotten task never leaves the journal empty.
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            var exception = e.ExceptionObject as Exception ?? new InvalidOperationException(e.ExceptionObject?.ToString());
            Fail("Erreur fatale imprévue.", exception);
            if (capture is { } session) Environment.Exit(session.Finish());
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            _ = Incident(e.Exception);
            e.SetObserved();
        };
        // LDAP failures of Domenia.Ad (operation and result code only, never a DN, a value or a secret) go to the technical journal.
        AdConnection.TechnicalTrace += TechnicalLog.Warning;
        // « Domenia.exe dossier … » writes the offline diagnostic dossier and ends: no window, no WebView2, no profile.
        if (OfflineDossierCommand.IsRequested(args))
        {
            return DossierCommandLine.Run(args);
        }
        // --capture <folder> and --e2e-port <n> are taken out first: without them, the command line reaches the mode
        // resolver unchanged.
        var request = CaptureArguments.Parse(args);
        var e2eRequest = E2eArguments.Parse(request.Remaining, Environment.GetEnvironmentVariable(E2eArguments.Variable));
#pragma warning disable CA1031 // Startup failures of any kind are traced and told to the operator in French.
        try
        {
            var launch = LaunchArguments.Parse(e2eRequest.Remaining);
            if (!launch.Valid) throw new ArgumentException(launch.Error);
            var decision = DemoSessionProcess.Active ? DemoSessionArguments.Decision() : ResolveMode(launch.Remaining);
            // Checked before the capture opens capture.log: a refused E2E start touches no profile and no capture folder.
            if (e2eRequest.Requested && !StartE2e(e2eRequest, request.Requested))
            {
                return E2eArguments.FailureCode;
            }
            GuardBrowserArguments(e2e is not null);
            if (request.Requested && !StartCapture(request, decision))
            {
                return CaptureSession.FailureCode;
            }
            startup?.Token.ThrowIfCancellationRequested();
            Run(decision, launch.Options, startup);
        }
        catch (OperationCanceledException) when (startup?.Token.IsCancellationRequested == true)
        {
            TechnicalLog.Info("Démarrage annulé après la fin du travail en cours ; aucune connexion automatique.");
            return 0;
        }
        catch (Exception ex)
        {
            if (request.Requested && capture is null)
            {
                // Unattended run stopped before capture.log exists: no message box, code 2.
                TechnicalLog.Error("Échec du démarrage.", ex);
                WriteStandardError(CaptureTexts.StartFailed);
                return CaptureSession.FailureCode;
            }
            Fail("Échec du démarrage.", ex);
        }
#pragma warning restore CA1031
        // Keep a failure raised by the native close guard, even if the UI itself completed normally.
        var captureCode = capture?.Finish() ?? 0;
        return Volatile.Read(ref failed) != 0 || Environment.ExitCode != 0 ? E2eArguments.FailureCode : captureCode;
    }

    private static PackageIntegrity? CheckPackage(string[] args, out bool checkOnly, StartupWindow? startup = null)
    {
        checkOnly = args.Any(x => x.Equals("--check-only", StringComparison.OrdinalIgnoreCase) || x.Equals("-CheckOnly", StringComparison.OrdinalIgnoreCase));
        var lifecycle = PackageLifecycleCommand.IsRequested(args);
        var automation = AutomationCommandLine.IsRequested(args);
        var localDiagnostic = checkOnly || StartupPreflight.Requested(args);
        var unattended = localDiagnostic || lifecycle || automation || args.Any(x => x.Equals("--capture", StringComparison.OrdinalIgnoreCase) || x.Equals("--e2e-port", StringComparison.OrdinalIgnoreCase)) || OfflineDossierCommand.IsRequested(args);
#pragma warning disable CA1031 // Startup boundary: refuse safely before the UI or any native session exists.
        try
        {
            if (!OperatingSystem.IsWindows() || !Environment.Is64BitProcess) { throw new InvalidOperationException("Domenia exige Windows 64 bits."); }
            if (checkOnly && args.Length != 1) { throw new ArgumentException("Utilisez --check-only seul pour vérifier le paquet sans ouvrir de session."); }
            var required = typeof(Program).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
                .Any(x => x.Key == "DomeniaPackageManifest" && x.Value == "required");
            using var measurement = localDiagnostic || lifecycle || automation ? null : StartupTrace.Clock.Measure(StartupPhase.Integrity);
            var started = System.Diagnostics.Stopwatch.GetTimestamp();
            var result = PackageIntegrity.Open(PackageLayout.ApplicationRoot, required || localDiagnostic || lifecycle, startup?.Token ?? CancellationToken.None,
                (done, total) => startup?.Phase($"Intégrité : {done} fichiers vérifiés sur {total}. Lecture complète des empreintes SHA256…"));
            try
            {
                if (result.Packaged)
                {
                    result.VerifyReleaseContract(PackageLayout.ApplicationRoot, required);
                    result.VerifyCompiledRelease(OperationModules.LoadDomeniaAssemblies());
                    var release = PackageLifecycle.Release(PackageLayout.ApplicationRoot, result.Components);
                    if (release is not null && (release.Build != ProductInfo.Version || release.Version != ProductInfo.DevelopmentVersion))
                    { throw new InvalidDataException("Identité du paquet différente de l’identité compilée ; aucun lancement."); }
                }
                // These commands deliberately skip WebView host inspection; they still enforce the same
                // machine publisher policy, including a development build without a package manifest.
                if (lifecycle || automation || OfflineDossierCommand.IsRequested(args))
                {
                    var policy = PackagePublisherPolicy.ReadMachine();
                    var publisher = result.Packaged ? result.VerifyPublisher(policy)
                        : PackagePublisherTrust.Verify(Path.Combine(PackageLayout.ApplicationRoot, "Domenia.exe"), policy);
                    publisher.RequireAllowed(policy);
                    WriteStandardError("Éditeur de l’exécutable : " + publisher.Notice);
                }
            }
            catch { result.Dispose(); throw; }
            var message = result.Packaged
                ? $"Runtime {ProductInfo.Version} : {result.FilesChecked} fichiers vérifiés en {System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds:F0} ms (plafond {PackageIntegrity.MaximumFiles}), {result.BytesHashed} octets hachés, {result.HashReads} lectures. Empreintes strictes octet par octet, y compris les fins de ligne."
                : "Exécution depuis une compilation de développement, sans manifeste de paquet.";
            if (localDiagnostic || lifecycle || automation) { WriteStandardError(message); } else { TechnicalLog.Info(message); }
            if (!lifecycle && !automation && !OfflineDossierCommand.IsRequested(args))
            {
                try
                {
                    using var hostTime = localDiagnostic ? null : StartupTrace.Clock.Measure(StartupPhase.Host);
                    AppPaths.AdmitBrowser(result);
                    string BrowserVersion(string? folder)
                    {
                        try
                        {
                            return result.Browser == BrowserSource.Evergreen
                                ? Microsoft.Web.WebView2.Core.CoreWebView2Environment.GetAvailableBrowserVersionString(folder, AppPaths.BrowserOptions(evergreen: true))
                                : Microsoft.Web.WebView2.Core.CoreWebView2Environment.GetAvailableBrowserVersionString(folder);
                        }
                        catch (Exception error) when (result.IsLight)
                        { throw new InvalidDataException(LightEngine() + " : le chargeur Windows ne reconnaît pas le moteur qualifié.", error); }
                    }
                    string LightEngine() => result.Browser == BrowserSource.Socle ? "DOMENIA_WEBVIEW2_SOCLE" : "DOMENIA_WEBVIEW2_EVERGREEN";
                    var host = StartupHostCheck.Inspect(Path.Combine(PackageLayout.ApplicationRoot, "Domenia.exe"), AppPaths.WebViewRuntime, BrowserVersion);
                    if (result.IsLight && result.BrowserVersion != host.Browser)
                        throw new InvalidDataException(LightEngine() + " : version du chargeur différente du moteur qualifié.");
                    var source = result.Browser switch
                    {
                        BrowserSource.Evergreen => "Evergreen préinstallé",
                        BrowserSource.Socle => "fixe du Socle",
                        _ => AppPaths.UsesInstalledWebView ? "Windows" : "fixe du pack",
                    };
                    var skipped = result.EvergreenSkipped is null ? "" : " (Evergreen non retenu : " + result.EvergreenSkipped + ")";
                    var hostMessage = $"Hôte : .NET {host.Runtime} ; WebView2 {source} {host.Browser}{skipped} ; {host.Signature}.";
                    if (localDiagnostic) WriteStandardError(hostMessage); else TechnicalLog.Info(hostMessage);
                }
                catch { result.Dispose(); throw; }
            }
            return result;
        }
        catch (OperationCanceledException) when (startup?.Token.IsCancellationRequested == true)
        {
            WriteStandardError("Démarrage annulé ; contrôle d’intégrité interrompu, aucun lancement applicatif.");
            return null;
        }
        catch (Exception ex)
        {
            startup?.Hide();
            var reference = "INC-" + Guid.NewGuid().ToString("N").ToUpperInvariant();
            var message = "Domenia | Démarrage refusé\nRéférence : " + reference + "\n" + StartupBootstrap.Clean(ex.Message);
            if (!unattended) message += "\n" + StartupBootstrap.FailureLocation(StartupBootstrap.Failure(ex, reference));
            WriteStandardError(message);
            // The package was not admitted: keep the failure UI in user32, without initializing WinForms or the journal.
            if (!unattended) { StartupWindow.ShowFailure(message); }
            return null;
        }
#pragma warning restore CA1031
    }

    /// <summary>
    /// --e2e-port with DOMENIA_E2E=1 (docs/E2E.md). A refusal (port, variable, repeated option, capture requested too)
    /// is traced and ends the process with code 2 before any window, profile or file is touched.
    /// </summary>
    private static bool StartE2e(E2eArguments request, bool captureRequested)
    {
        var refusal = request.Error ?? (captureRequested ? E2eTexts.WithCapture : null);
        if (refusal is not null || !request.Enabled)
        {
            refusal ??= E2eTexts.PortInvalid;
            TechnicalLog.Warning(refusal);
            WriteStandardError(refusal);
            return false;
        }
        e2e = request;
        return true;
    }

    /// <summary>
    /// WebView2 also reads browser arguments from the environment: a variable that would open the DevTools protocol (or,
    /// in E2E mode, replace the loopback port of --e2e-port) is removed from this process, so neither the WebView2 loader
    /// nor the browser processes it starts ever see it. Only the variable name is traced, never its value.
    /// </summary>
    private static void GuardBrowserArguments(bool e2eActive)
    {
#if DEBUG
        const bool debugBuild = true;
#else
        const bool debugBuild = false;
#endif
        var variables = BrowserArgumentsGuard.VariablesToNeutralize(
            Environment.GetEnvironmentVariable(BrowserArgumentsGuard.ArgumentsVariable),
            Environment.GetEnvironmentVariable(BrowserArgumentsGuard.ScriptDebuggerVariable),
            e2eActive,
            debugBuild);
        foreach (var variable in variables)
        {
            Environment.SetEnvironmentVariable(variable, null);
            TechnicalLog.Warning(E2eTexts.Neutralized(variable));
        }
    }

    /// <summary>
    /// The mode is decided once: --simulation, then DOMENIA_SIMULATION, then Auth.DemoProvider of Domenia.config.json next
    /// to the executable (read only when needed; absent or invalid: traced, never blocking), then the local join state (no
    /// network).
    /// </summary>
    private static ModeDecision ResolveMode(IReadOnlyList<string> args)
    {
        var decision = ModeResolver.Resolve(
            args,
            Environment.GetEnvironmentVariable(ModeResolver.SimulationVariable),
            DomainJoin.Read,
            static () => LegacyConfigurationFile.Read(AppPaths.AppDirectory, AppTechnicalJournal.Instance).DemoProvider);
        TechnicalLog.Info($"Démarrage de {ProductInfo.Name} {ProductInfo.Version} : mode {decision.Mode}, raison {decision.Reason}.");
        foreach (var warning in decision.Warnings)
        {
            TechnicalLog.Warning(warning);
        }
        return decision;
    }

    /// <summary>
    /// Checks the mode and the folder, then opens capture.log; a refusal is traced and ends the process with code 2.
    /// Simulation only: in directory mode the images would show real data (join domain, Windows account, later the
    /// directory itself), so nothing at all is written to the folder.
    /// </summary>
    private static bool StartCapture(CaptureArguments request, ModeDecision decision)
    {
        var folder = string.Empty;
        var refusal = request.Error
            ?? (decision.Mode == AppMode.Simulation ? null : CaptureTexts.SimulationOnly)
            ?? CaptureFolder.Prepare(request.Folder ?? string.Empty, out folder);
        var session = refusal is null ? CaptureSession.Open(folder, CapturePlan.For(request.Routes, request.Themes)) : null;
        if (session is null)
        {
            // No window and no message box: the option is meant for unattended runs. The folder is never copied.
            refusal ??= CaptureTexts.LogNotCreated;
            TechnicalLog.Warning(refusal);
            WriteStandardError(refusal);
            return false;
        }
        capture = session;
        session.Write($"Capture {ProductInfo.Name} {ProductInfo.Version} (.NET {Environment.Version}) dans {folder}");
        session.Write($"Mode : {ModeTexts.SimulationLabel} ({decision.Reason}) — {decision.Detail}");
        foreach (var warning in decision.Warnings)
        {
            session.Write("ATTENTION " + warning);
        }
        // Routes are checked by a strict expression: they can be written as they are.
        var extra = request.Routes.Length == 0
            ? ""
            : $" ; écrans en plus : {string.Join(", ", request.Routes.Select(r => r.Value))} ; thèmes : {string.Join(", ", request.Themes.Select(CaptureThemes.Id))}";
        session.Write($"Séquence : {session.Steps} étapes{extra}.");
        // An image of an earlier run never passes for one of this run, even if this run stops early.
        session.ClearEarlierImages();
        TechnicalLog.Info($"Capture d’écrans demandée : {session.Steps} étapes ({request.Routes.Length} écran(s) en plus de la séquence, {request.Themes.Length} thème(s)).");
        return true;
    }

    /// <summary>
    /// French message on the standard error, in UTF-8: a window application has no console code page to follow, and the
    /// ANSI default would break the accents for the scripts that read it.
    /// </summary>
    private static void WriteStandardError(string message)
    {
        try
        {
            // The standard error handle belongs to the parent process: the stream is left open.
            using var writer = new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false), bufferSize: -1, leaveOpen: true);
            writer.WriteLine(message);
        }
        catch (IOException)
        {
            System.Diagnostics.Trace.WriteLine("Sortie d’erreur non écrite.");
        }
    }

    private static void Run(ModeDecision decision, LaunchOptions launch, StartupWindow? startup)
    {
        ApplicationConfiguration.Initialize();
        // Exceptions of the UI thread (async event handlers included) are traced, then the application closes cleanly.
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) =>
        {
            Fail("Erreur imprévue sur le fil de l’interface.", e.Exception);
            Application.Exit();
        };
        do
        {
            HostIncidentReport.Starting();
            startup?.Phase("Initialisation locale : configuration, préférences et modules…");
            using var composition = Composition.Create(decision, capture is not null, e2e is not null, launch, startup is null ? null : startup.Phase);
            expertReport = () => composition.ExpertReport;
            startup?.Token.ThrowIfCancellationRequested();
            startup?.Phase("Ouverture de la fenêtre applicative…");
            MainForm form;
            using (StartupTrace.Clock.Measure(StartupPhase.Window)) form = new MainForm(composition, capture, e2e);
            using (form)
            {
                // The cancellation control remains live during MainForm construction. Close the bootstrap first at
                // Shown, then inspect its final token: no last click can be lost between this check and its destruction.
                startup?.Token.ThrowIfCancellationRequested();
                form.Shown += (_, _) =>
                {
                    startup?.Hide();
                    if (startup?.Token.IsCancellationRequested == true) form.BeginInvoke(() => form.Close());
                };
                Application.Run(form);
            }
        } while (DemoSessionProcess.BeginRequestedReset());
    }

    private static bool ExpertReport()
    {
#pragma warning disable CA1031 // Context/profile can already be unavailable during a fatal failure.
        try { return expertReport?.Invoke() == true; } catch (Exception) { return false; }
#pragma warning restore CA1031
    }

    private static void Fail(string message, Exception exception)
    {
        var report = Incident(exception);
        if (capture is not null)
        {
            // Unattended run: no message box would ever be closed. The failure ends the run with code 2.
            capture.Error(report.Code + " · " + message, exception);
            capture.Abort(report.Code + " · " + message);
            return;
        }
        // One message box only, even if several failures arrive while closing; none in E2E mode, where nobody would close
        // it (the harness reads the exit code and the journal).
        if (Interlocked.Exchange(ref failed, 1) == 0 && e2e is null)
        {
            MessageBox.Show(report.Message, report.Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static HostIncidentReport Incident(Exception exception)
    {
#pragma warning disable CA1031 // Even a failed journal type initializer must leave a masked native report.
        try { return TechnicalLog.Incident(exception, ExpertReport()); }
        catch (Exception)
        {
            return HostIncidentReport.Create(exception, _ => { }, () => false,
                () => new TechnicalJournalStatus("unavailable", null, 0, 0, null), ExpertReport());
        }
#pragma warning restore CA1031
    }
}
