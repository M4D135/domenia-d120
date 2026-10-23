using Domenia.Core;

namespace Domenia.App.Secrets;

internal sealed class CredentialWindow : Form
{
    private readonly SecureEntry secret = new();
    private readonly CheckBox remember = new() { AutoSize = true, Text = "Mémoriser sur ce PC après validation", Checked = false };
    private readonly Button accept = new() { Text = "Valider", AutoSize = true };
    private readonly Button reveal = new() { Text = "Afficher", AutoSize = true };
    private readonly Label status = new() { AutoSize = true, MaximumSize = new Size(480, 0) };
    private readonly System.Windows.Forms.Timer conceal = new() { Interval = AccountsConfiguration.RevealSeconds * 1000 };
    private CredentialWindowEntry? accepted;

    internal CredentialWindow(CredentialWindowRequest request, IAccountsCredentialVault vault)
    {
        var contrast = SystemInformation.HighContrast || request.Theme == "contrast";
        var light = request.Theme == "light";
        var background = contrast ? SystemColors.Window : light ? Color.FromArgb(246, 248, 252) : Color.FromArgb(20, 28, 46);
        var foreground = contrast ? SystemColors.WindowText : light ? Color.FromArgb(15, 23, 42) : Color.FromArgb(230, 234, 242);
        var muted = contrast ? SystemColors.WindowText : light ? Color.FromArgb(91, 100, 120) : Color.FromArgb(154, 167, 189);
        Text = "Domenia — " + request.Title;
        BackColor = background; ForeColor = foreground;
        Font = new Font("Segoe UI", 10F); Padding = new Padding(26);
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
        ShowInTaskbar = false; StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.Dpi; AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        var layout = new TableLayoutPanel { AutoSize = true, ColumnCount = 1, Dock = DockStyle.Fill, BackColor = background };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 480));
        Label TextLine(string text, bool title = false) => new()
        {
            Text = text, AutoSize = true, MaximumSize = new Size(480, 0), Margin = new Padding(0, 0, 0, 12),
            ForeColor = title ? foreground : muted, Font = new Font(title ? "Segoe UI Semibold" : "Segoe UI", title ? 16F : 10F),
        };
        layout.Controls.Add(TextLine(request.Title, true));
        layout.Controls.Add(TextLine(request.Purpose));
        if (request.CanEditLogin) { layout.Controls.Add(new Label { Text = "&Compte (DOMAINE\\compte ou compte@domaine)", AutoSize = true, ForeColor = foreground, Margin = new Padding(0, 0, 0, 6) }); }
        var login = new TextBox { Text = request.Login, ReadOnly = !request.CanEditLogin, Dock = DockStyle.Fill, BorderStyle = BorderStyle.FixedSingle,
            Font = new Font("Consolas", 11F), BackColor = background, ForeColor = foreground, AccessibleName = "Compte choisi", TabStop = request.CanEditLogin,
            MaxLength = CredentialRules.MaxLoginLength, Margin = new Padding(0, 0, 0, 16) };
        layout.Controls.Add(login);
        layout.Controls.Add(new Label { Text = "&Mot de passe", AutoSize = true, ForeColor = foreground, Margin = new Padding(0, 0, 0, 6) });
        var row = new TableLayoutPanel { AutoSize = true, ColumnCount = 2, Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 12) };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        secret.Dock = DockStyle.Fill; secret.BackColor = background; secret.ForeColor = foreground;
        secret.BorderStyle = BorderStyle.FixedSingle; secret.Font = new Font("Consolas", 12F); secret.AccessibleName = "Mot de passe";
        secret.TabIndex = 0; reveal.TabIndex = 1;
        row.Controls.Add(secret, 0, 0); row.Controls.Add(reveal, 1, 0); layout.Controls.Add(row);
        var caps = new Label { AutoSize = true, MinimumSize = new Size(0, 24), ForeColor = foreground, AccessibleName = "État du verrouillage majuscule", Margin = new Padding(0, 0, 0, 6) };
        layout.Controls.Add(caps);
        void UpdateCaps() => caps.Text = Control.IsKeyLocked(Keys.CapsLock) ? "Verr. Maj activé : les lettres sont saisies en majuscules." : "";
        secret.KeyUp += (_, _) => UpdateCaps(); secret.Enter += (_, _) => UpdateCaps();
        login.KeyUp += (_, _) => UpdateCaps(); Activated += (_, _) => UpdateCaps();
        layout.Controls.Add(TextLine("La saisie reste dans cette fenêtre. Aucun mot de passe n’est transmis à la page web ni au journal. Masquez-le avant de valider."));
        var canStore = !request.CanEditLogin && vault.Available && !request.VaultTargets.IsEmpty;
        var load = new Button { Text = "Utiliser le coffre Windows", AutoSize = true, Enabled = canStore && request.CanUseVault, Margin = new Padding(0, 0, 0, 10) };
        layout.Controls.Add(load);
        remember.Enabled = canStore; remember.ForeColor = foreground; remember.Margin = new Padding(0, 0, 0, 12); layout.Controls.Add(remember);
        status.ForeColor = muted; status.Margin = new Padding(0, 0, 0, 16);
        status.Text = request.VaultReason ?? "La mémorisation est facultative et propre à ce compte et à cet usage.";
        layout.Controls.Add(status);
        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Dock = DockStyle.Fill, Margin = Padding.Empty };
        var cancel = new Button { Text = "Annuler", DialogResult = DialogResult.Cancel, AutoSize = true };
        buttons.Controls.Add(cancel); buttons.Controls.Add(accept); layout.Controls.Add(buttons);
        foreach (var button in new[] { reveal, load, accept, cancel })
        {
            button.FlatStyle = FlatStyle.Flat; button.ForeColor = foreground; button.BackColor = background;
            button.Padding = new Padding(8, 4, 8, 4); button.FlatAppearance.BorderColor = contrast ? SystemColors.WindowText : muted;
        }
        Controls.Add(layout); AcceptButton = accept; CancelButton = cancel; accept.Enabled = false;
        void CheckInput() => accept.Enabled = !secret.Revealed && secret.SecretLength > 0 && (!request.CanEditLogin || CredentialRules.IsWellFormed(login.Text));
        secret.SecretChanged += (_, _) => CheckInput();
        login.TextChanged += (_, _) => CheckInput();
        reveal.Click += (_, _) =>
        {
            secret.Revealed = !secret.Revealed; reveal.Text = secret.Revealed ? "Masquer" : "Afficher";
            conceal.Stop(); if (secret.Revealed) { conceal.Start(); } CheckInput(); secret.Focus();
        };
        conceal.Tick += (_, _) => { conceal.Stop(); secret.Revealed = false; reveal.Text = "Afficher"; CheckInput(); };
        Deactivate += (_, _) => { conceal.Stop(); secret.Revealed = false; reveal.Text = "Afficher"; CheckInput(); };
        load.Click += (_, _) =>
        {
            try
            {
                using var stored = vault.Read(request.VaultTargets[0]);
                if (stored is null) { status.Text = "Aucun mot de passe mémorisé pour ce compte et cet usage."; return; }
                if (stored.Length > CredentialRules.MaxPasswordLength) { status.Text = "Le secret mémorisé dépasse la limite de saisie de cette version."; return; }
                secret.Assign(stored); secret.Revealed = false; reveal.Text = "Afficher"; conceal.Stop(); CheckInput();
                status.Text = "Mot de passe chargé. Cliquez sur Valider pour effectuer un seul essai d’authentification.";
                secret.Focus();
            }
            catch (DomeniaOperationException error) { status.Text = error.Message; }
        };
        accept.Click += (_, _) =>
        {
            CheckInput(); if (!accept.Enabled) { return; }
            accepted?.Dispose(); accepted = new(secret.CopySecret(), remember.Enabled && remember.Checked, request.CanEditLogin ? login.Text.Trim() : request.Login);
            DialogResult = DialogResult.OK; Close();
        };
        Shown += (_, _) => { UpdateCaps(); if (request.CanEditLogin) { login.Focus(); login.SelectAll(); } else { secret.Focus(); } };
        FormClosed += (_, _) => { conceal.Stop(); secret.Wipe(); };
    }

    internal CredentialWindowEntry? TakeEntry()
    { var result = accepted; accepted = null; return result; }
    protected override void Dispose(bool disposing)
    { if (disposing) { conceal.Dispose(); accepted?.Dispose(); accepted = null; } base.Dispose(disposing); }
}
