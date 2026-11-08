using System.Diagnostics;

namespace Domenia.App;

internal sealed record PackageUpdateOutcome(int Code, string Message, string? Target, bool CanOpen);

/// <summary>Small native assistant window; closing during replacement never terminates its transaction.</summary>
internal static class PackageUpdateProgress
{
    internal static int Run(Func<Action<string>, Task<PackageUpdateOutcome>> run)
    {
        ApplicationConfiguration.Initialize();
        using var form = new ProgressForm(run); Application.Run(form); return form.ExitCode;
    }
    private sealed class ProgressForm : Form
    {
        private readonly Label detail = new() { Dock = DockStyle.Fill, Padding = new(16), AutoSize = false };
        private readonly ProgressBar progress = new() { Dock = DockStyle.Bottom, Height = 12, Style = ProgressBarStyle.Marquee };
        private readonly Button close = new() { Text = "Fermer", Enabled = false, AutoSize = true };
        private readonly Button open = new() { Text = "Ouvrir Domenia", Visible = false, AutoSize = true };
        private bool finished;
        private PackageUpdateOutcome? outcome;
        internal int ExitCode { get; private set; } = 2;
        internal ProgressForm(Func<Action<string>, Task<PackageUpdateOutcome>> run)
        {
            Text = "Domenia — assistant de mise à jour"; ClientSize = new(600, 230); StartPosition = FormStartPosition.CenterScreen;
            var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 48, FlowDirection = FlowDirection.RightToLeft, Padding = new(8) };
            actions.Controls.Add(close); actions.Controls.Add(open); Controls.Add(detail); Controls.Add(progress); Controls.Add(actions);
            close.Click += (_, _) => Close();
            open.Click += (_, _) => OpenInstalled();
            FormClosing += (_, e) => { if (!finished) e.Cancel = true; };
            Load += async (_, _) =>
            {
#pragma warning disable CA1031 // Native assistant boundary: show retained evidence, never reinterpret an exception as success.
                try
                {
                    outcome = await run(text =>
                    {
                        if (!IsDisposed) BeginInvoke((Action)(() => { if (!IsDisposed) detail.Text = text; }));
                    }).ConfigureAwait(true);
                    ExitCode = outcome.Code; detail.Text = outcome.Message;
                    open.Visible = outcome.CanOpen; open.Text = outcome.Code == 0 ? "Ouvrir Domenia" : "Ouvrir la version restaurée";
                }
                catch (Exception error)
                {
                    detail.Text = "La mise à jour n’est pas confirmée. Conservez le paquet préparé, le dossier .domenia-lifecycle et le marqueur pending.\n\n"
                        + error.Message + "\n\nUne reprise ou une restauration explicite est nécessaire si le marqueur reste présent.";
                }
#pragma warning restore CA1031
                finally { finished = true; progress.Visible = false; close.Enabled = true; close.Focus(); }
            };
        }
        private void OpenInstalled()
        {
            if (outcome is not { CanOpen: true, Target: { } target }) return;
            try
            {
                using var verified = PackageIntegrity.Open(target, true);
                using var process = Process.Start(new ProcessStartInfo(Path.Combine(target, "Domenia.exe")) { UseShellExecute = false, WorkingDirectory = target })
                    ?? throw new IOException("Domenia n’a pas démarré.");
                open.Enabled = false;
                detail.Text += "\n\nLancement demandé ; l’ouverture de votre session réelle reste distincte du contrôle local effectué.";
            }
            catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
            { MessageBox.Show(this, error.Message, "Lancement non confirmé", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        }
    }
}
