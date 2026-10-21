using System.Text;
using Domenia.App.Capture;
using Domenia.App.E2e;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.App;

internal static class Program
{
    private const string FatalMessage = "Domenia a rencontré une erreur imprévue et va se fermer. Le détail technique est dans le journal de l’application.";

    private static int failed;

    /// <summary>Set with --capture only (docs/CAPTURE.md); the run then ends by itself with code 0 or 2.</summary>
    private static CaptureSession? capture;

    /// <summary>Set with --e2e-port and DOMENIA_E2E=1 only (docs/E2E.md): the harness drives the window.</summary>
    private static E2eArguments? e2e;

    [STAThread]
    private static int Main(string[] args)
    {
        // Last resort traces: a crash or a forgotten task never leaves the journal empty.
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            var exception = e.ExceptionObject as Exception ?? new InvalidOperationException(e.ExceptionObject?.ToString());
            TechnicalLog.Error("Erreur fatale imprévue.", exception);
            var session = capture;
            if (session is not null)
            {
                // Any thread: the run still ends with its summary and code 2, not with the runtime's crash code.
                session.Error("Erreur fatale imprévue.", exception);
                session.Abort("Erreur fatale imprévue : l’application s’arrête.");
                Environment.Exit(session.Finish());
            }
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            TechnicalLog.Error("Tâche en échec jamais observée.", e.Exception);
            e.SetObserved();
        };
        // --capture <folder> and --e2e-port <n> are taken out first: without them, the command line reaches the mode
        // resolver unchanged.
        var request = CaptureArguments.Parse(args);
        var e2eRequest = E2eArguments.Parse(request.Remaining, Environment.GetEnvironmentVariable(E2eArguments.Variable));
#pragma warning disable CA1031 // Startup failures of any kind are traced and told to the operator in French.
        try
        {
            var decision = ResolveMode(e2eRequest.Remaining);
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
            Run(decision);
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
        // Without --capture the exit code stays 0, as before the option existed; an E2E run that failed ends with 2.
        return capture?.Finish() ?? (e2e is not null && Volatile.Read(ref failed) != 0 ? E2eArguments.FailureCode : 0);
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
        catch (IOException ex)
        {
            TechnicalLog.Warning($"Sortie d’erreur non écrite : {ex.GetType().Name}.");
        }
    }

    private static void Run(ModeDecision decision)
    {
        ApplicationConfiguration.Initialize();
        // Exceptions of the UI thread (async event handlers included) are traced, then the application closes cleanly.
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) =>
        {
            Fail("Erreur imprévue sur le fil de l’interface.", e.Exception);
            Application.Exit();
        };
        using var composition = Composition.Create(decision, capture is not null, e2e is not null);
        using var form = new MainForm(composition, capture, e2e);
        Application.Run(form);
    }

    private static void Fail(string message, Exception exception)
    {
        TechnicalLog.Error(message, exception);
        if (capture is not null)
        {
            // Unattended run: no message box would ever be closed. The failure ends the run with code 2.
            capture.Error(message, exception);
            capture.Abort(message);
            return;
        }
        // One message box only, even if several failures arrive while closing; none in E2E mode, where nobody would close
        // it (the harness reads the exit code and the journal).
        if (Interlocked.Exchange(ref failed, 1) == 0 && e2e is null)
        {
            MessageBox.Show(FatalMessage, ProductInfo.Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
