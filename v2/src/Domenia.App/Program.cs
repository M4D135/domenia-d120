using Domenia.Core;

namespace Domenia.App;

internal static class Program
{
    private const string FatalMessage = "Domenia a rencontré une erreur imprévue et va se fermer. Le détail technique est dans le journal de l’application.";

    private static int failed;

    [STAThread]
    private static void Main(string[] args)
    {
        // Last resort traces: a crash or a forgotten task never leaves the journal empty.
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            TechnicalLog.Error("Erreur fatale imprévue.", e.ExceptionObject as Exception ?? new InvalidOperationException(e.ExceptionObject?.ToString()));
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            TechnicalLog.Error("Tâche en échec jamais observée.", e.Exception);
            e.SetObserved();
        };
#pragma warning disable CA1031 // Startup failures of any kind are traced and told to the operator in French.
        try
        {
            Run(args);
        }
        catch (Exception ex)
        {
            Fail("Échec du démarrage.", ex);
        }
#pragma warning restore CA1031
    }

    private static void Run(string[] args)
    {
        // The mode is decided once: --simulation, then DOMENIA_SIMULATION, then the local join state (no network).
        var decision = ModeResolver.Resolve(args, Environment.GetEnvironmentVariable(ModeResolver.SimulationVariable), DomainJoin.Read);
        TechnicalLog.Info($"Démarrage de {ProductInfo.Name} {ProductInfo.Version} : mode {decision.Mode}, raison {decision.Reason}.");
        foreach (var warning in decision.Warnings)
        {
            TechnicalLog.Warning(warning);
        }
        ApplicationConfiguration.Initialize();
        // Exceptions of the UI thread (async event handlers included) are traced, then the application closes cleanly.
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) =>
        {
            Fail("Erreur imprévue sur le fil de l’interface.", e.Exception);
            Application.Exit();
        };
        using var composition = Composition.Create(decision);
        using var form = new MainForm(composition);
        Application.Run(form);
    }

    private static void Fail(string message, Exception exception)
    {
        TechnicalLog.Error(message, exception);
        // One message box only, even if several failures arrive while closing.
        if (Interlocked.Exchange(ref failed, 1) == 0)
        {
            MessageBox.Show(FatalMessage, ProductInfo.Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
