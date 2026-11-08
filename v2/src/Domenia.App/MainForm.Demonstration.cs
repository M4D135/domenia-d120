using System.Diagnostics;
using Domenia.Core;

namespace Domenia.App;

internal sealed partial class MainForm
{
    private async void BeginDemonstration(string action)
    {
        try
        {
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            limit.CancelAfter(TimeSpan.FromSeconds(20));
            if (!await PrepareTransitionAsync(limit.Token).ConfigureAwait(true)) return;
            if (action is "reset" or "exit")
            {
                if (!DemoSessionProcess.Active) throw new InvalidOperationException("Contexte de démonstration absent.");
                if (action == "reset") DemoSessionProcess.RequestReset();
                closingChecked = true;
                Close();
                return;
            }
            var start = new ProcessStartInfo(Path.Combine(PackageLayout.ApplicationRoot, "Domenia.exe"))
            { UseShellExecute = false, WorkingDirectory = AppPaths.AppDirectory };
            start.ArgumentList.Add(DemoSessionArguments.Argument);
            using var child = Process.Start(start) ?? throw new InvalidOperationException("Démonstration non démarrée.");
            Hide();
            await child.WaitForExitAsync(lifetime.Token).ConfigureAwait(true);
            if (child.ExitCode != 0) throw new InvalidOperationException("La démonstration s’est arrêtée avant une sortie normale.");
        }
#pragma warning disable CA1031 // The previous window must be restored on every failure of the isolated child.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            TechnicalLog.Warning("Démonstration non terminée normalement (" + ex.GetType().Name + ").");
            if (!IsDisposed) MessageBox.Show(this, "La démonstration n’a pas pu démarrer ou s’est interrompue. Votre contexte précédent est conservé.",
                "Démonstration", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        finally
        {
            composition.Demonstration.Finish();
            if (!IsDisposed && !closingChecked) { ResumeTransition(); Show(); Activate(); }
        }
    }
}
