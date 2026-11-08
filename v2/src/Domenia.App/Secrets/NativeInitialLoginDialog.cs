using Domenia.Core;

namespace Domenia.App.Secrets;

/// <summary>Owned native choice before the first web document. No credentials, vault access or authentication here.</summary>
internal static class NativeInitialLoginDialog
{
    internal static async Task<InitialLoginChoice> ShowAsync(LoginAppearance appearance, ShellPolicy policy, string? feedback, string? rememberedLogin, CancellationToken token, WindowsSessionChoice choice)
    {
        var owner = Application.OpenForms.OfType<MainForm>().FirstOrDefault(form => !form.IsDisposed && form.IsHandleCreated)
            ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Fenêtre principale indisponible : aucun choix de connexion possible.");
        var completion = new TaskCompletionSource<InitialLoginChoice>(TaskCreationOptions.RunContinuationsAsynchronously);
        EventHandler closed = (_, _) => completion.TrySetCanceled(new CancellationToken(true));
        owner.Disposed += closed;
        try
        {
            owner.BeginInvoke(() =>
            {
#pragma warning disable CA1031 // Forward native presentation errors; no secret is present in this choice window.
                try
                {
                    token.ThrowIfCancellationRequested();
                    using var form = new ChoiceForm(appearance, policy, feedback, rememberedLogin, token, choice);
                    owner.PrepareLoginDialog(form);
                    using var cancelled = token.Register(() =>
                    {
                        try { owner.BeginInvoke(() => { if (!form.IsDisposed) { form.DialogResult = DialogResult.Cancel; form.Close(); } }); }
                        catch (InvalidOperationException) { /* The native owner already closed. */ }
                    });
                    var selected = form.ShowDialog(owner) == DialogResult.OK ? form.Choice : InitialLoginChoice.Offline;
                    if (token.IsCancellationRequested) completion.TrySetCanceled(token);
                    else completion.TrySetResult(selected);
                }
                catch (OperationCanceledException) { completion.TrySetCanceled(token); }
                catch (Exception error) { completion.TrySetException(error); }
#pragma warning restore CA1031
            });
            return await completion.Task.ConfigureAwait(false);
        }
        finally { owner.Disposed -= closed; }
    }

    private sealed class ChoiceForm : Form
    {
        internal InitialLoginChoice Choice { get; private set; } = InitialLoginChoice.Offline;

        internal ChoiceForm(LoginAppearance appearance, ShellPolicy policy, string? feedback, string? rememberedLogin, CancellationToken token, WindowsSessionChoice choice)
        {
            Text = "Domenia — Connexion";
            LoginWindowStyle.Configure(this);
            var layout = LoginWindowStyle.Stack();
            layout.Controls.Add(LoginWindowStyle.Brand());
            var heading = LoginWindowStyle.Line("Connexion", size: 24F, bold: true);
            heading.Margin = new Padding(0, 0, 0, 20); layout.Controls.Add(heading);
            var remembered = !string.IsNullOrWhiteSpace(rememberedLogin);
            var preferOther = remembered || !choice.Available;
            layout.Controls.Add(LoginWindowStyle.IdentityCard(rememberedLogin ?? choice.Login,
                remembered ? "IDENTIFIANT MÉMORISÉ" : "IDENTITÉ WINDOWS"));
            var status = LoginWindowStyle.Line(feedback ?? "", LoginVisualRole.Warning);
            status.Visible = !string.IsNullOrWhiteSpace(feedback);
            status.AccessibleName = "Résultat de la connexion précédente";
            NativeGuiPolicy.Apply(status, "LblLoginError", policy);
            layout.Controls.Add(status);
            var windows = LoginWindowStyle.Action(choice.Label, preferOther ? LoginVisualRole.Normal : LoginVisualRole.Primary);
            windows.AccessibleDescription = "Effectuer un seul essai de connexion avec la session Windows courante.";
            var other = LoginWindowStyle.Action(remembered ? "Se connecter avec ce compte" : "Utiliser un autre compte", preferOther ? LoginVisualRole.Primary : LoginVisualRole.Normal);
            var primary = preferOther ? other : windows;
            var alternative = preferOther ? windows : other;
            primary.TabIndex = 0; alternative.TabIndex = 1;
            other.AccessibleDescription = "Ouvrir la saisie native d’un compte et de son mot de passe.";
            var offline = LoginWindowStyle.Action("Continuer hors connexion", LoginVisualRole.Quiet); offline.TabIndex = 2;
            offline.AccessibleDescription = "Ouvrir les données locales sans envoyer de connexion à l’annuaire. Échap effectue le même choix.";
            offline.DialogResult = DialogResult.Cancel;
            void Select(InitialLoginChoice choice) { Choice = choice; DialogResult = DialogResult.OK; Close(); }
            windows.Click += (_, _) => Select(InitialLoginChoice.WindowsIdentity);
            other.Click += (_, _) => Select(InitialLoginChoice.OtherAccount);
            NativeGuiPolicy.Apply(windows, "BtnLogin", policy);
            NativeGuiPolicy.Apply(other, "BtnLogin", policy);
            NativeGuiPolicy.Apply(offline, "BtnCancel", policy, cancellation: true);
            windows.Enabled = choice.Available && GuiElementPolicies.Allows(policy.GuiPolicy, "BtnLogin");
            windows.AccessibleDescription = choice.Reason ?? "Un seul essai explicite avec cette identité Windows.";
            if (!choice.Available) layout.Controls.Add(LoginWindowStyle.Line(choice.Reason ?? "Session Windows indisponible.", LoginVisualRole.Muted, 9F));
            layout.Controls.Add(primary);
            var alternatives = new TableLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                ColumnCount = 2, RowCount = 1, Dock = DockStyle.Top, Margin = Padding.Empty, TabIndex = 1 };
            alternatives.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            alternatives.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            alternatives.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            alternative.Dock = DockStyle.Fill; alternative.Margin = new Padding(0, 0, 6, 8);
            offline.Dock = DockStyle.Fill; offline.Margin = new Padding(6, 0, 0, 8);
            alternatives.Controls.Add(alternative, 0, 0); alternatives.Controls.Add(offline, 1, 0);
            layout.Controls.Add(alternatives);
            var footer = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                Dock = DockStyle.Top, WrapContents = true, Margin = Padding.Empty, TabIndex = 2 };
            var themeFeedback = LoginWindowStyle.Line("", LoginVisualRole.Muted, 9F); themeFeedback.Margin = Padding.Empty;
            var theme = LoginWindowStyle.ThemeButton(this, appearance, themeFeedback, token);
            theme.TabIndex = 3; theme.Margin = Padding.Empty;
            NativeGuiPolicy.Apply(theme, "BtnSuiteLoginTheme", policy);
            footer.Controls.Add(theme); layout.Controls.Add(footer); layout.Controls.Add(themeFeedback);
            LoginWindowStyle.Mount(this, layout); CancelButton = offline;
            Shown += (_, _) =>
            {
                LoginWindowStyle.Bound(this);
                if (primary.Enabled && primary.Visible) primary.Focus(); else offline.Focus();
            };
        }
    }
}
