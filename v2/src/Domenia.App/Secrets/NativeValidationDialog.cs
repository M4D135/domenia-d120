using Domenia.Core;

namespace Domenia.App.Secrets;

/// <summary>Native waiting/diagnostic companion to the secure entry. One real validation, no secret in this form.</summary>
internal static class NativeValidationDialog
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    internal static async Task<T> RunAsync<T>(LoginAppearance appearance, ShellPolicy policy, Func<CancellationToken, Task<T>> validate, CancellationToken token)
    {
        if (!await Gate.WaitAsync(0, token).ConfigureAwait(false)) throw new DomeniaOperationException(AccountAccess.ValidationBusy, "Une validation est déjà affichée.");
        try
        {
            var owner = Application.OpenForms.OfType<MainForm>().FirstOrDefault(f => !f.IsDisposed && f.IsHandleCreated)
                ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Fenêtre de connexion indisponible ; aucun essai envoyé.");
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(token);
            var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
            var entered = 0;
            EventHandler closed = (_, _) => { RequestCancellation(stop); if (Volatile.Read(ref entered) == 0) completion.TrySetCanceled(new CancellationToken(true)); };
            owner.Disposed += closed;
            try
            {
                owner.BeginInvoke(async () =>
                {
                    Interlocked.Exchange(ref entered, 1);
#pragma warning disable CA1031 // Native UI boundary; forward the real failure, never log secret-bearing callback arguments.
                    try
                    {
                        stop.Token.ThrowIfCancellationRequested();
                        Task<T> validationCompletion;
                        using (var form = new ValidationForm<T>(appearance, policy, validate, stop))
                        {
                            owner.PrepareLoginDialog(form);
                            using var registration = stop.Token.Register(() =>
                            {
                                try { owner.BeginInvoke(() => { if (!form.IsDisposed) form.RequestStop(); }); }
                                catch (InvalidOperationException) { }
                            });
                            form.ShowDialog(owner);
                            validationCompletion = form.Completion;
                        } // Dispose all WinForms resources on the UI thread, even if the owner closed mid-validation.
                        // The message loop may have ended. Await independently while retaining the caller's SecureString.
                        completion.TrySetResult(await validationCompletion.ConfigureAwait(false));
                    }
                    catch (OperationCanceledException) { completion.TrySetCanceled(new CancellationToken(true)); }
                    catch (Exception error) { completion.TrySetException(error); }
#pragma warning restore CA1031
                });
                return await completion.Task.ConfigureAwait(false);
            }
            finally { owner.Disposed -= closed; }
        }
        finally { Gate.Release(); }
    }

    private static void RequestCancellation(CancellationTokenSource stop)
    {
        try { _ = stop.CancelAsync().ContinueWith(static done => { _ = done.Exception; }, CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default); }
        catch (ObjectDisposedException) { }
    }

    private sealed class ValidationForm<T> : Form
    {
        private readonly AuthenticationTrace trace = new(TimeProvider.System);
        private readonly TextBox technical = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Dock = DockStyle.Top, Height = 220, Font = new Font("Consolas", 9F) };
        private readonly Label stage = LoginWindowStyle.Line("");
        private readonly Button cancel = LoginWindowStyle.Action("Annuler la connexion");
        private readonly System.Windows.Forms.Timer refresh = new() { Interval = 100 };
        private readonly CancellationTokenSource stop;
        private readonly TaskCompletionSource<T> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private volatile bool finished;
        private bool began;
        internal Task<T> Completion => completion.Task;
        internal ValidationForm(LoginAppearance appearance, ShellPolicy policy, Func<CancellationToken, Task<T>> validate, CancellationTokenSource stop)
        {
            this.stop = stop;
            var diagnostic = policy.LoginDiagnostic;
            Text = "Domenia — Validation de la connexion" + (diagnostic ? " · diagnostic" : "");
            LoginWindowStyle.Configure(this);
            var layout = LoginWindowStyle.Stack(); layout.Controls.Add(LoginWindowStyle.Brand());
            var heading = LoginWindowStyle.Line("Connexion", size: 24F, bold: true);
            heading.Margin = new Padding(0, 0, 0, 6); layout.Controls.Add(heading);
            var subtitle = LoginWindowStyle.Line("Validation de la connexion", LoginVisualRole.Muted);
            subtitle.Margin = new Padding(0, 0, 0, 20); layout.Controls.Add(subtitle);
            var progress = new LoginCard(); progress.Controls.Add(stage); layout.Controls.Add(progress);
            stage.Text = "Validation en cours. Annuler demande l’arrêt ; les appels Windows ne sont jamais forcés.";
            stage.AccessibleName = "Étape de la connexion";
            LoginWindowStyle.TrackText(this, stage);
            progress.Controls.Add(technical); technical.Visible = diagnostic;
            var feedback = LoginWindowStyle.Line("", LoginVisualRole.Muted, 9F);
            var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, WrapContents = true, Margin = Padding.Empty };
            var theme = LoginWindowStyle.ThemeButton(this, appearance, feedback, stop.Token);
            NativeGuiPolicy.Apply(theme, "BtnSuiteLoginTheme", policy);
            actions.Controls.Add(cancel); actions.Controls.Add(theme);
            var toggle = LoginWindowStyle.Action("Diagnostic"); toggle.Dock = DockStyle.None;
            var copy = LoginWindowStyle.Action("Copier le diagnostic"); copy.Dock = DockStyle.None; copy.Visible = diagnostic;
            var open = LoginWindowStyle.Action("Ouvrir le journal"); open.Dock = DockStyle.None; open.Visible = diagnostic;
            toggle.Click += (_, _) =>
            {
                diagnostic = !diagnostic; technical.Visible = diagnostic; copy.Visible = diagnostic && GuiElementPolicies.Allows(policy.GuiPolicy, "BtnCopyLoginDiag"); open.Visible = diagnostic;
                RefreshTrace(); LoginWindowStyle.Refit(this);
            };
            copy.Click += (_, _) =>
            {
                RefreshTrace();
                try { Clipboard.SetText(technical.Text); feedback.Text = "Diagnostic affiché copié, sans identifiant ni secret."; }
                catch (System.Runtime.InteropServices.ExternalException) { feedback.Text = "Presse-papiers indisponible ; diagnostic conservé à l’écran."; }
            };
            open.Click += (_, _) =>
            {
                var path = TechnicalLog.FilePath;
                if (path is null || !File.Exists(path)) { feedback.Text = "Journal local indisponible ; le diagnostic affiché reste copiable."; return; }
                try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true }); }
                catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
                { feedback.Text = "Ouverture du journal impossible ; le diagnostic affiché reste copiable."; }
            };
            actions.Controls.Add(toggle); actions.Controls.Add(copy); actions.Controls.Add(open);
            NativeGuiPolicy.Apply(copy, "BtnCopyLoginDiag", policy);
            cancel.Dock = DockStyle.None;
            layout.Controls.Add(actions); layout.Controls.Add(feedback); LoginWindowStyle.Mount(this, layout);
            CancelButton = cancel;
            cancel.Click += (_, _) => { if (finished) Close(); else RequestStop(); };
            FormClosing += (_, e) =>
            {
                if (finished) return;
                RequestStop();
                if (began && e.CloseReason == CloseReason.UserClosing) e.Cancel = true;
                else if (!began) completion.TrySetCanceled(new CancellationToken(true));
            };
            refresh.Tick += (_, _) => RefreshTrace();
            Shown += async (_, _) =>
            {
                began = true; LoginWindowStyle.Bound(this); Activate(); cancel.Focus(); refresh.Start();
                try
                {
                    var result = await Task.Run(async () =>
                    {
                        using var attached = trace.Attach();
                        using var step = AuthenticationTrace.Step(AuthenticationStage.Validation);
                        stop.Token.ThrowIfCancellationRequested();
                        return await validate(stop.Token).ConfigureAwait(false);
                    }).ConfigureAwait(false);
                    var validation = result switch { AccessValidation a => a, AccessChange a => a.Result, AccessSwitch a => a.Result, _ => null };
                    trace.Finish(validation?.Kind == "cancelled", validation?.Success == false || result is SessionSnapshot { Connection: ConnectionState.Disconnected });
                    completion.TrySetResult(result);
                }
                catch (OperationCanceledException) { trace.Finish(true, false); completion.TrySetCanceled(new CancellationToken(true)); }
#pragma warning disable CA1031 // Observe callback failure and return it intact; no exception message enters the diagnostic.
                catch (Exception error) { trace.Finish(false, true); completion.TrySetException(error); }
#pragma warning restore CA1031
                finally
                {
                    TechnicalLog.Info("Connexion : phases de l’essai terminé (sans identité ni cible)." + Environment.NewLine + trace.Text);
                    finished = true;
                    void FinishWindow()
                    {
                        if (IsDisposed) return;
                        refresh.Stop(); RefreshTrace(); cancel.Text = "Fermer"; cancel.Enabled = true;
                        if (!diagnostic || stop.IsCancellationRequested) Close();
                    }
                    try { if (!IsDisposed && IsHandleCreated) BeginInvoke(FinishWindow); }
                    catch (InvalidOperationException) { }
                }
            };
        }
        internal void RequestStop()
        {
            if (finished) { if (!IsDisposed) Close(); return; }
            if (!stop.IsCancellationRequested) { trace.CancellationRequested(); RequestCancellation(stop); }
            if (!IsDisposed) { cancel.Enabled = false; stage.Text = "Annulation demandée. Attente de la fin réelle de l’appel Windows ; nettoyage natif conservé."; }
        }
        private void RefreshTrace()
        {
            var text = trace.Text; if (technical.Text != text) technical.Text = text;
            if (!stop.IsCancellationRequested) stage.Text = finished ? "Validation terminée. Le résultat sera présenté après fermeture." : (text.Split(Environment.NewLine).LastOrDefault() ?? "Validation en cours.") + " — attente totale " + (trace.ElapsedMilliseconds / 1000).ToString("F0", System.Globalization.CultureInfo.InvariantCulture) + " s.";
        }
        protected override void Dispose(bool disposing) { if (disposing) refresh.Dispose(); base.Dispose(disposing); }
    }
}
