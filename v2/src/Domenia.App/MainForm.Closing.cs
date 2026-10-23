using Domenia.Core;

namespace Domenia.App;

internal sealed partial class MainForm
{
    private readonly WriteCircuit closingWrites;
    private bool closingChecked;
    private bool checkingClose;

    private async void CheckClosing(object? sender, FormClosingEventArgs e)
    {
        if (closingChecked) { return; }
        e.Cancel = true;
        if (checkingClose) { return; }
        checkingClose = true;
        try
        {
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            var decision = await Task.Run(() => closingWrites.PrepareCloseAsync(limit.Token)).ConfigureAwait(true);
            if (!decision.Allowed)
            {
                TechnicalLog.Warning("Fermeture différée : écriture en cours.");
                if (capture is null && e2e is null)
                { MessageBox.Show(this, decision.Detail, "Écriture en cours", MessageBoxButtons.OK, MessageBoxIcon.Information); }
                return;
            }
            if (decision.ConfirmationRequired)
            {
                TechnicalLog.Warning(decision.Detail);
                if (capture is not null || e2e is not null)
                {
                    // Simulation scenarios deliberately exercise uncertain receipts in memory. Native uncertainty remains a failure.
                    if (mode == AppMode.Directory) { Environment.ExitCode = 2; }
                }
                else if (MessageBox.Show(this, decision.Detail + "\n\nFermer Domenia malgré cette incertitude ?", "Reçus à vérifier",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
                { closingWrites.CancelClose(); return; }
            }
            closingChecked = true;
            Close();
        }
        finally { checkingClose = false; }
    }
}
