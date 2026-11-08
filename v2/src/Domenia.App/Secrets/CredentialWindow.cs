using Domenia.Core;

namespace Domenia.App.Secrets;

internal sealed class CredentialWindow : Form
{
    private readonly SecureEntry secret = new();
    private readonly CheckBox remember = new() { AutoSize = true, Text = "Mémoriser sur ce PC après validation", Checked = false };
    private readonly Button accept = LoginWindowStyle.Action("Valider", LoginVisualRole.Primary);
    private readonly Button reveal = LoginWindowStyle.Action("Afficher");
    private readonly Label status = LoginWindowStyle.Line("", LoginVisualRole.Muted, 9F);
    private readonly System.Windows.Forms.Timer conceal = new() { Interval = AccountsConfiguration.RevealSeconds * 1000 };
    private CredentialWindowEntry? accepted;

    internal CredentialWindow(CredentialWindowRequest request, IAccountsCredentialVault vault, ShellPolicy? guiPolicy = null, int revealSeconds = AccountsConfiguration.RevealSeconds)
    {
        var policy = guiPolicy ?? ShellPolicies.Default;
        secret.RevealDurationSeconds = Math.Clamp(revealSeconds, 1, 30);
        conceal.Interval = secret.RevealDurationSeconds * 1000;
        Text = "Domenia — " + request.Title + (policy.LoginDiagnostic ? " · diagnostic" : "");
        LoginWindowStyle.Configure(this);
        var document = LoginWindowStyle.Stack();
        document.Controls.Add(LoginWindowStyle.Brand());
        var heading = LoginWindowStyle.Line("Connexion", size: 24F, bold: true);
        heading.Margin = new Padding(0, 0, 0, 6); document.Controls.Add(heading);
        var subtitle = LoginWindowStyle.Line(request.Title, LoginVisualRole.Muted);
        subtitle.Margin = new Padding(0, 0, 0, 16); document.Controls.Add(subtitle);
        var purpose = LoginWindowStyle.Line(request.Purpose, LoginVisualRole.Muted);
        purpose.Margin = new Padding(0, 0, 0, 12); purpose.Visible = !string.IsNullOrWhiteSpace(request.Purpose); document.Controls.Add(purpose);
        var layout = LoginWindowStyle.Stack(); layout.Margin = new Padding(0, 0, 0, 16); layout.TabIndex = 0; document.Controls.Add(layout);
        var themeFeedback = LoginWindowStyle.Line("", LoginVisualRole.Muted, 9F);
        var themeButton = LoginWindowStyle.ThemeButton(this, request.Appearance ?? new(request.Theme), themeFeedback, CancellationToken.None);
        NativeGuiPolicy.Apply(themeButton, "BtnSuiteLoginTheme", policy);
        if (policy.LoginDiagnostic)
        {
            const string text = "Aucun essai envoyé. Les étapes de validation apparaîtront après « Valider ».";
            var diagnosticText = LoginWindowStyle.Line(text, LoginVisualRole.Muted, 9F);
            layout.Controls.Add(diagnosticText);
        }
        var accountFields = LoginWindowStyle.Stack(); accountFields.Margin = new Padding(0, 0, 0, 12); accountFields.TabIndex = 0;
        var passwordFields = LoginWindowStyle.Stack(); passwordFields.Margin = new Padding(0, 0, 0, 8); passwordFields.TabIndex = 1;
        layout.Controls.Add(accountFields); layout.Controls.Add(passwordFields);
        var accountLabel = LoginWindowStyle.Line("&Compte", size: 10F, bold: true); accountLabel.UseMnemonic = true;
        accountLabel.Margin = new Padding(0, 0, 0, 4);
        accountFields.Controls.Add(accountLabel);
        var login = new TextBox { Text = request.Login, ReadOnly = !request.CanEditLogin, Dock = DockStyle.Top, BorderStyle = BorderStyle.FixedSingle,
            Font = new Font("Consolas", 11F), AccessibleName = "Compte choisi", TabStop = request.CanEditLogin,
            MaxLength = CredentialRules.MaxLoginLength, Margin = Padding.Empty, TabIndex = 0 };
        var loginInput = LoginWindowStyle.Input(login); loginInput.TabIndex = 0; loginInput.TabStop = false;
        accountFields.Controls.Add(loginInput);
        var loginHint = LoginWindowStyle.Line(DirectoryLogin.Hint(login.Text, request.LoginDomain), LoginVisualRole.Muted, 9F);
        loginHint.Margin = new Padding(0, 6, 0, 0); loginHint.Visible = request.CanEditLogin;
        loginHint.AccessibleName = "Format du compte";
        accountFields.Controls.Add(loginHint);
        var rememberLogin = new CheckBox { AutoSize = true, Text = "Se souvenir de mon identifiant", Checked = request.RememberLogin,
            Visible = request.OfferRememberLogin, TabIndex = 1, Margin = new Padding(0, 6, 0, 0),
            AccessibleDescription = "Proposer ce compte au prochain démarrage. Le mot de passe reste à saisir." };
        accountFields.Controls.Add(rememberLogin);
        if (request.CanEditLogin)
        {
            login.PlaceholderText = "Nom du compte";
            login.AccessibleDescription = loginHint.Text;
        }
        var passwordLabel = LoginWindowStyle.Line("&Mot de passe", size: 10F, bold: true); passwordLabel.UseMnemonic = true;
        passwordLabel.Margin = new Padding(0, 0, 0, 4);
        passwordFields.Controls.Add(passwordLabel);
        var row = new TableLayoutPanel { AutoSize = true, ColumnCount = 2, Dock = DockStyle.Top, Margin = new Padding(0, 0, 0, 4) };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        secret.Anchor = AnchorStyles.Left | AnchorStyles.Right; secret.Margin = new Padding(0, 0, 8, 0);
        secret.BorderStyle = BorderStyle.FixedSingle; secret.Font = new Font("Consolas", 12F); secret.AccessibleName = "Mot de passe";
        reveal.Dock = DockStyle.None; reveal.Margin = Padding.Empty;
        secret.TabIndex = 0; reveal.TabIndex = 1;
        var secretInput = LoginWindowStyle.Input(secret); secretInput.TabIndex = 0; secretInput.TabStop = false;
        secretInput.Margin = new Padding(0, 0, 10, 0);
        row.Controls.Add(secretInput, 0, 0); row.Controls.Add(reveal, 1, 0); passwordFields.Controls.Add(row);
        var caps = LoginWindowStyle.Line("", LoginVisualRole.Warning, 9F);
        caps.AccessibleName = "État du verrouillage majuscule"; caps.Visible = false;
        passwordFields.Controls.Add(caps);
        void UpdateCaps()
        {
            var locked = Control.IsKeyLocked(Keys.CapsLock);
            caps.Text = locked ? "Verr. Maj activé : les lettres sont saisies en majuscules." : "";
            if (caps.Visible != locked) { caps.Visible = locked; LoginWindowStyle.Refit(this); }
        }
        secret.KeyUp += (_, _) => UpdateCaps(); secret.Enter += (_, _) => UpdateCaps();
        login.KeyUp += (_, _) => UpdateCaps(); Activated += (_, _) => UpdateCaps();
        var revealHint = LoginWindowStyle.Line("Masquez le mot de passe avant de valider.", LoginVisualRole.Warning, 9F);
        revealHint.Visible = false; layout.Controls.Add(revealHint);
        var canStore = vault.Available && (request.OfferVaultSave || !request.CanEditLogin && !request.VaultTargets.IsEmpty);
        string? loadedVaultAccount = null;
        CredentialVaultChoice? VaultChoice() => request.CanEditLogin && request.SavedVault is { } saved
            ? CredentialVaultChoice.Read(request.LoginDomain, login.Text, saved, vault.Available) : null;
        CredentialVaultTarget? LoadTarget() => request.CanEditLogin ? VaultChoice()?.Target : request.VaultTargets.FirstOrDefault();
        var load = LoginWindowStyle.Action("Utiliser le coffre Windows"); load.Enabled = canStore && (request.CanEditLogin ? VaultChoice()?.Available == true : request.CanUseVault); load.TabIndex = 2;
        load.Visible = canStore;
        var vaultActions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, WrapContents = true, Margin = Padding.Empty };
        load.Dock = DockStyle.None; vaultActions.Controls.Add(load); layout.Controls.Add(vaultActions);
        var forget = LoginWindowStyle.Action("Supprimer ce compte du coffre"); forget.TabIndex = 3;
        forget.Visible = canStore && request.AllowNativeVaultDelete; forget.Enabled = request.AllowNativeVaultDelete && load.Enabled && vault is IAccountsCredentialVaultMutations;
        forget.Dock = DockStyle.None; vaultActions.Controls.Add(forget);
        remember.Enabled = canStore; remember.Visible = canStore; remember.TabIndex = 3; remember.Margin = new Padding(0, 0, 0, 8); layout.Controls.Add(remember);
        status.Margin = Padding.Empty;
        status.Text = VaultChoice()?.Reason ?? request.VaultReason ?? (canStore ? "La mémorisation est facultative et propre à ce compte et à cet usage." : "");
        layout.Controls.Add(status);
        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Top, Margin = Padding.Empty, TabIndex = 1 };
        var cancel = LoginWindowStyle.Action("Annuler"); cancel.DialogResult = DialogResult.Cancel;
        accept.TabIndex = 0; cancel.TabIndex = 1;
        accept.Dock = DockStyle.None; cancel.Dock = DockStyle.None;
        accept.MinimumSize = new Size(140, 44); cancel.MinimumSize = new Size(100, 44);
        accept.Margin = new Padding(10, 0, 0, 0); cancel.Margin = Padding.Empty;
        buttons.Controls.Add(accept); buttons.Controls.Add(cancel); document.Controls.Add(buttons);
        themeButton.TabIndex = 4; themeButton.Margin = new Padding(0, 12, 0, 0);
        document.Controls.Add(themeButton); document.Controls.Add(themeFeedback);
        LoginWindowStyle.Mount(this, document); AcceptButton = accept; CancelButton = cancel; accept.Enabled = false;
        void CheckInput()
        {
            accept.Enabled = GuiElementPolicies.Allows(policy.GuiPolicy, "BtnLogin")
                && request.CanSubmit(login.Text, secret.SecretLength, secret.Revealed);
            if (request.CanEditLogin)
            {
                loginHint.Text = DirectoryLogin.Hint(login.Text, request.LoginDomain);
                if (GuiElementPolicies.Allows(policy.GuiPolicy, "TxtLogin")) { login.AccessibleDescription = loginHint.Text; }
            }
            if (revealHint.Visible != secret.Revealed) { revealHint.Visible = secret.Revealed; LoginWindowStyle.Refit(this); }
        }
        secret.SecretChanged += (_, _) => CheckInput();
        secret.RevealChanged += (_, _) => { reveal.Text = secret.Revealed ? "Masquer" : "Afficher"; CheckInput(); };
        login.TextChanged += (_, _) =>
        {
            if (loadedVaultAccount is not null) { loadedVaultAccount = null; secret.Wipe(); }
            if (request.CanEditLogin) { var choice = VaultChoice(); load.Enabled = GuiElementPolicies.Allows(policy.GuiPolicy, "BtnLoginVaultUse") && canStore && choice?.Available == true; forget.Enabled = GuiElementPolicies.Allows(policy.GuiPolicy, "BtnLoginVaultForget") && request.AllowNativeVaultDelete && load.Enabled && vault is IAccountsCredentialVaultMutations; status.Text = choice?.Reason ?? ""; }
            CheckInput();
        };
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
                var target = LoadTarget(); if (target is null) return;
                using var stored = vault.Read(target);
                if (stored is null) { status.Text = "Aucun mot de passe mémorisé pour ce compte et cet usage."; return; }
                if (stored.Length > CredentialRules.MaxPasswordLength) { status.Text = "Le secret mémorisé dépasse la limite de saisie de cette version."; return; }
                // A short-name match is presentation only. Always submit the exact identity owning this vault key.
                if (request.CanEditLogin) login.Text = target.Account;
                secret.Assign(stored); loadedVaultAccount = target.Account; secret.Revealed = false; reveal.Text = "Afficher"; conceal.Stop(); CheckInput();
                status.Text = "Compte exact du coffre et mot de passe chargés. Modifier l’identifiant efface cette saisie. Cliquez sur Valider pour un seul essai.";
                secret.Focus();
            }
            catch (DomeniaOperationException error) { status.Text = error.Message; }
        };
        forget.Click += async (_, _) =>
        {
            var target = LoadTarget(); if (!request.AllowNativeVaultDelete || target is null || vault is not IAccountsCredentialVaultMutations mutations) return;
            if (MessageBox.Show(this, "Supprimer le mot de passe mémorisé pour ce compte et cet usage ? La session actuelle sera conservée.",
                "Domenia — Coffre Windows", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            try { var removed = mutations.Delete(target); if (request.VaultDeleted is { } forgotten) await forgotten(target); if (IsDisposed) return; status.Text = removed ? "Compte supprimé du coffre. La session est conservée." : "Ce compte n’était plus présent dans le coffre."; load.Enabled = false; forget.Enabled = false; }
            catch (Exception error) when (error is DomeniaOperationException or IOException or InvalidOperationException or UnauthorizedAccessException) { status.Text = "La suppression ou sa mémorisation locale n’a pas pu être confirmée. La session est conservée."; }
        };
        accept.Click += (_, _) =>
        {
            CheckInput(); if (!accept.Enabled) { return; }
            if (request.CanEditLogin && DirectoryLogin.Resolve(login.Text, request.LoginDomain) is null)
            { status.Text = DirectoryLogin.Hint(login.Text, request.LoginDomain) + " Aucun essai envoyé."; return; }
            accepted?.Dispose(); accepted = new(secret.CopySecret(), remember.Enabled && remember.Checked, request.CanEditLogin ? login.Text.Trim() : request.Login)
            { RememberLogin = request.OfferRememberLogin && rememberLogin.Enabled && rememberLogin.Checked };
            DialogResult = DialogResult.OK; Close();
        };
        NativeGuiPolicy.Apply(login, "TxtLogin", policy); NativeGuiPolicy.Apply(secret, "PwdLogin", policy);
        NativeGuiPolicy.Apply(reveal, "BtnRevealLogin", policy); NativeGuiPolicy.Apply(remember, "ChkRemember", policy);
        NativeGuiPolicy.Apply(rememberLogin, "ChkRemember", policy);
        NativeGuiPolicy.Apply(load, "BtnLoginVaultUse", policy); NativeGuiPolicy.Apply(forget, "BtnLoginVaultForget", policy); NativeGuiPolicy.Apply(status, "LblLoginError", policy);
        NativeGuiPolicy.Apply(accept, "BtnLogin", policy); NativeGuiPolicy.Apply(cancel, "BtnCancel", policy, cancellation: true);
        LoginWindowStyle.TrackText(this, status); LoginWindowStyle.TrackText(this, caps);
        LoginWindowStyle.TrackText(this, loginHint);
        CheckInput();
        Shown += (_, _) =>
        {
            LoginWindowStyle.Bound(this);
            UpdateCaps();
            if (request.CanEditLogin && login.Enabled && login.Visible) { login.Focus(); login.SelectAll(); }
            else if (secret.Enabled && secret.Visible) { secret.Focus(); }
            else { cancel.Focus(); }
        };
        FormClosed += (_, _) => { conceal.Stop(); secret.Wipe(); };
    }

    internal CredentialWindowEntry? TakeEntry()
    { var result = accepted; accepted = null; return result; }
    protected override void Dispose(bool disposing)
    { if (disposing) { conceal.Dispose(); accepted?.Dispose(); accepted = null; } base.Dispose(disposing); }
}
