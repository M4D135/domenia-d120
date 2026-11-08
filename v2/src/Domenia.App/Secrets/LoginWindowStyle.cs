using Domenia.Core;

namespace Domenia.App.Secrets;

internal enum LoginVisualRole { Normal, Muted, Accent, Warning, Primary, Secondary, Quiet }

internal static class LoginWindowStyle
{
    internal static void Configure(Form form, int width = 1024)
    {
        ProductBrand.Apply(form);
        form.AutoScaleDimensions = new SizeF(96, 96);
        form.AutoScaleMode = AutoScaleMode.Dpi;
        var font = new Font("Segoe UI", 10F); form.Font = font; form.Disposed += (_, _) => font.Dispose();
        form.Padding = Padding.Empty;
        form.ClientSize = new Size(width, 660);
        form.FormBorderStyle = FormBorderStyle.Sizable;
        form.MaximizeBox = false; form.MinimizeBox = false; form.ShowInTaskbar = false;
        form.StartPosition = FormStartPosition.CenterParent;
        form.AutoScroll = false;
        form.Load += (_, _) => Bound(form);
        form.Resize += (_, _) => { if (form.Visible) Bound(form); };
        form.DpiChanged += (_, _) => form.BeginInvoke(() => { if (!form.IsDisposed) Bound(form); });
    }

    internal static TableLayoutPanel Stack() => new()
    {
        AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1,
        Dock = DockStyle.Top, Margin = Padding.Empty,
        ColumnStyles = { new ColumnStyle(SizeType.Percent, 100) }
    };

    internal static Label Line(string text, LoginVisualRole role = LoginVisualRole.Normal, float size = 10F, bool bold = false)
    {
        var label = new LoginText { Text = text, Tag = role, AutoSize = true, Dock = DockStyle.Top,
            Margin = new Padding(0, 0, 0, 8), MaximumSize = new Size(564, 0), UseMnemonic = false };
        var font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular);
        label.Font = font; label.Disposed += (_, _) => font.Dispose();
        return label;
    }

    internal static Button Action(string text, LoginVisualRole role = LoginVisualRole.Secondary) => new LoginActionButton(role == LoginVisualRole.Primary)
    {
        Text = text, Tag = role, AutoSize = true, Dock = DockStyle.Top,
        MinimumSize = new Size(0, 52), Padding = new Padding(16, 12, 16, 12),
        Margin = new Padding(0, 0, 0, 8), UseVisualStyleBackColor = false
    };

    internal static Control Input(Control field) => new LoginInput(field);

    internal static Control IdentityCard(string identity, string caption = "IDENTITÉ WINDOWS")
        => new LoginIdentityCard(identity, caption);

    internal static Control Brand()
    {
        var row = new TableLayoutPanel { AutoSize = true, ColumnCount = 2, Dock = DockStyle.Top,
            Margin = new Padding(0, 0, 0, 16) };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        row.Controls.Add(new LoginBrandMark { Size = new Size(48, 48), Margin = new Padding(0, 0, 14, 0) }, 0, 0);
        var name = Stack(); name.Padding = new Padding(0, 1, 0, 0);
        var title = Line("Domenia", size: 17F, bold: true); title.Margin = Padding.Empty;
        name.Controls.Add(title);
        var subtitle = Line("Active Directory", LoginVisualRole.Muted, 9F); subtitle.Margin = Padding.Empty;
        name.Controls.Add(subtitle); row.Controls.Add(name, 1, 0);
        return row;
    }

    internal static void Apply(Form form, string theme)
    {
        var colors = LoginColors.For(theme);
        void Paint(Control control, Color surface)
        {
            if (control is LoginBrandPanel brand) { brand.SetColors(colors); return; }
            var role = control.Tag is LoginVisualRole value ? value : LoginVisualRole.Normal;
            var background = control is LoginCard or LoginIdentityCard ? colors.Background : control is TextBoxBase or LoginInput ? colors.Input : surface;
            control.BackColor = background;
            control.ForeColor = role switch { LoginVisualRole.Muted => colors.Muted, LoginVisualRole.Accent => colors.AccentText,
                LoginVisualRole.Warning => colors.Warning, _ => colors.Text };
            if (control is LoginCard card) card.BorderColor = colors.Border;
            if (control is LoginIdentityCard account) account.BorderColor = colors.Border;
            if (control is LoginBrandMark mark) mark.Colors = colors;
            if (control is LoginIdentityIcon identity) identity.SetColors(colors);
            if (control is LoginInput input) input.SetColors(colors);
            if (control is Button button)
            {
                var primary = role == LoginVisualRole.Primary;
                var quiet = role == LoginVisualRole.Quiet;
                button.FlatStyle = FlatStyle.Flat;
                button.BackColor = primary ? colors.Accent : quiet ? surface : colors.Surface;
                button.ForeColor = primary ? colors.OnAccent : quiet ? colors.AccentText : colors.Text;
                button.FlatAppearance.BorderSize = quiet && !colors.Contrast ? 0 : 1;
                button.FlatAppearance.BorderColor = primary ? colors.Accent : colors.ControlBorder;
                button.FlatAppearance.MouseOverBackColor = primary ? colors.AccentHover : colors.Hover;
                button.FlatAppearance.MouseDownBackColor = primary ? colors.AccentHover : colors.Hover;
                if (button is LoginActionButton action) action.SetColors(colors);
            }
            foreach (Control child in control.Controls) Paint(child, background);
            control.Invalidate();
        }
        Paint(form, colors.Surface);
        if (form.IsHandleCreated) WindowChrome.SetFrame(form.Handle, colors.Dark, ColorTranslator.ToWin32(colors.Surface), ColorTranslator.ToWin32(colors.Text));
    }

    internal static Button ThemeButton(Form form, LoginAppearance appearance, Label feedback, CancellationToken token)
    {
        var theme = appearance.Theme;
        static string Caption(string value) => "Thème : " + (value == "light" ? "clair" : value == "contrast" ? "contraste élevé" : value == "system" ? "Windows" : "sombre");
        var button = Action(Caption(theme), LoginVisualRole.Quiet);
        button.Dock = DockStyle.None; button.MinimumSize = new Size(0, 32); button.Padding = new Padding(8, 4, 8, 4);
        button.AccessibleName = "Changer le thème de la connexion";
        button.AccessibleDescription = "Choisir le thème clair, sombre, à contraste élevé ou celui de Windows.";
        var menu = new ContextMenuStrip { ShowImageMargin = false, ShowCheckMargin = true };
        foreach (var (value, caption) in new[] { ("light", "Clair"), ("dark", "Sombre"), ("contrast", "Contraste élevé"), ("system", "Suivre Windows") })
        {
            var item = new ToolStripMenuItem(caption) { Checked = theme == value };
            item.Click += async (_, _) =>
            {
                theme = value; button.Text = Caption(theme); Apply(form, theme);
                foreach (ToolStripMenuItem entry in menu.Items) entry.Checked = entry == item;
                if (appearance.SaveTheme is null) { feedback.Text = "Thème de cette fenêtre uniquement."; return; }
                button.Enabled = false;
                try { await appearance.SaveTheme(theme, token).ConfigureAwait(true); if (!form.IsDisposed) feedback.Text = "Thème de connexion enregistré."; }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or OperationCanceledException or ObjectDisposedException)
                { if (!form.IsDisposed) feedback.Text = "Thème non enregistré ; seul l’affichage de cette fenêtre a changé."; }
                finally { if (!button.IsDisposed) button.Enabled = true; }
            };
            menu.Items.Add(item);
        }
        button.Click += (_, _) => menu.Show(button, new Point(0, button.Height));
        button.Disposed += (_, _) => menu.Dispose();
        form.HandleCreated += (_, _) => Apply(form, theme);
        form.SystemColorsChanged += (_, _) => Apply(form, theme);
        TrackText(form, feedback);
        return button;
    }

    internal static void TrackText(Form form, Control control) => control.TextChanged += (_, _) => Refit(form);
    internal static void Refit(Form form) { if (!form.IsDisposed && form.Visible) Bound(form); }

    internal static void Mount(Form form, TableLayoutPanel document)
    {
        var frame = new LoginFrame(document);
        form.Controls.Add(frame);
    }

    internal static void Bound(Form form)
    {
        var frame = form.Controls.OfType<LoginFrame>().FirstOrDefault();
        if (frame is null || frame.Fitting) return;
        frame.Fitting = true;
        try { Fit(form, frame); }
        finally { frame.Fitting = false; }
    }

    private static void Fit(Form form, LoginFrame frame)
    {
        var area = Screen.FromControl(form).WorkingArea;
        var unit = form.DeviceDpi / 96F;
        int U(int value) => (int)Math.Round(value * unit);
        var chrome = new Size(form.Width - form.ClientSize.Width, form.Height - form.ClientSize.Height);
        var minimum = LoginLayout.Minimum(area.Size, chrome, form.DeviceDpi);
        if (form.MinimumSize != minimum) form.MinimumSize = minimum;
        if (form.MaximumSize != area.Size) form.MaximumSize = area.Size;
        if (form.Width > area.Width || form.Height > area.Height)
            form.Size = new Size(Math.Min(form.Width, area.Width), Math.Min(form.Height, area.Height));
        form.AutoScroll = false;
        var compact = LoginLayout.Compact(form.ClientSize, form.DeviceDpi);
        frame.SetExpandedContent(false);
        frame.SetCompactBrand(compact);
        foreach (var control in Descendants(frame.Document))
            frame.LayoutDefaults.TryAdd(control, new(control.Margin, control.Padding, control.MinimumSize, control.Size, unit));
        void Density(int level)
        {
            foreach (var (control, original) in frame.LayoutDefaults)
            {
                if (control.IsDisposed) continue;
                var ratio = unit / original.Unit;
                int S(int value) => (int)Math.Round(value * ratio);
                Padding Scale(Padding value) => new(S(value.Left), S(value.Top), S(value.Right), S(value.Bottom));
                var margin = Scale(original.Margin);
                control.Margin = level == 0 ? margin : new Padding(Math.Min(margin.Left, U(level == 1 ? 10 : 4)),
                    Math.Min(margin.Top, U(level == 1 ? 8 : 4)), Math.Min(margin.Right, U(level == 1 ? 10 : 4)), Math.Min(margin.Bottom, U(level == 1 ? 8 : 4)));
                control.Padding = (control is LoginCard or LoginIdentityCard) && level > 0 ? new Padding(U(level == 1 ? 12 : 8)) : Scale(original.Padding);
                control.MinimumSize = new Size(S(original.MinimumSize.Width), S(original.MinimumSize.Height));
                if (control is LoginText text) text.SetDensity(level);
                if (control is LoginInput) control.Height = U(level == 0 ? 44 : level == 1 ? 38 : 34);
                if (control is LoginIdentityIcon) control.Size = new Size(U(level < 2 ? 44 : 36), U(level < 2 ? 48 : 40));
                if (control is Button button && level > 0)
                {
                    button.Padding = new Padding(U(level == 1 ? 12 : 8), U(level == 1 ? 8 : 5), U(level == 1 ? 12 : 8), U(level == 1 ? 8 : 5));
                    var target = button.Tag is LoginVisualRole.Quiet ? level == 1 ? 32 : 28 : level == 1 ? 46 : 40;
                    button.MinimumSize = new Size(button.MinimumSize.Width, Math.Min(button.MinimumSize.Height, U(target)));
                }
                if (control is TextBox { Multiline: true, ReadOnly: true }) control.Height = S(original.Size.Height);
            }
            form.PerformLayout(); frame.PerformLayout();
        }
        int RequiredHeight() => frame.GetPreferredSize(new Size(form.ClientSize.Width, 0)).Height;
        Density(compact ? 1 : 0);
        if (RequiredHeight() > form.ClientSize.Height) Density(2);
        if (RequiredHeight() > form.ClientSize.Height) frame.SetExpandedContent(true);
        // Diagnostic text is the only internally scrollable area; fields and actions remain outside it.
        foreach (var text in Descendants(frame.Document).OfType<TextBox>().Where(control => control.Multiline && control.ReadOnly && control.Visible))
        {
            var excess = RequiredHeight() - form.ClientSize.Height;
            if (excess <= 0) break;
            text.Height = Math.Max(U(40), text.Height - excess);
            frame.PerformLayout();
        }
        // Ordinary resize keeps the operator's size. A dense vault/debug/error state may need more
        // height after all compact layouts have been tried; preserve its fields, messages and actions.
        var required = RequiredHeight();
        if (required > form.ClientSize.Height)
        {
            var height = Math.Min(area.Height, required + chrome.Height);
            form.MinimumSize = new Size(minimum.Width, Math.Max(minimum.Height, height));
            form.Height = height; frame.PerformLayout();
        }
        var overflow = RequiredHeight() > form.ClientSize.Height;
        frame.ShowOverflowNotice(overflow);
        if (overflow && !frame.OverflowReported)
        {
            frame.OverflowReported = true;
            TechnicalLog.Warning($"Disposition de connexion : l’espace utile ne contient pas tous les contrôles ({RequiredHeight()} px requis, {form.ClientSize.Height} px disponibles, DPI {form.DeviceDpi}).");
        }
        if (!frame.Positioned)
        {
            var owner = form.Owner?.Bounds ?? area;
            form.Location = LoginLayout.Position(area, form.Size, new(owner.Left + (owner.Width - form.Width) / 2, owner.Top + (owner.Height - form.Height) / 2));
            frame.Positioned = true;
        }
        else if (form.Bottom > area.Bottom || form.Right > area.Right || form.Top < area.Top || form.Left < area.Left)
            form.Location = LoginLayout.Position(area, form.Size, form.Location);
    }

    private static IEnumerable<Control> Descendants(Control parent)
    {
        foreach (Control child in parent.Controls)
        { yield return child; foreach (var nested in Descendants(child)) yield return nested; }
    }

    private sealed class LoginText : Label
    {
        private Control? container;
        private Font? normalFont;
        private readonly Dictionary<int, Font> compactFonts = [];
        internal void SetDensity(int level)
        {
            normalFont ??= Font;
            if (level == 0) { Font = normalFont; return; }
            if (!compactFonts.TryGetValue(level, out var value))
            {
                var size = normalFont.SizeInPoints >= 17 ? Math.Min(normalFont.SizeInPoints, level == 1 ? 21 : 18)
                    : Math.Min(normalFont.SizeInPoints, level == 1 ? 10 : 9);
                value = new Font(normalFont.FontFamily, size, normalFont.Style); compactFonts.Add(level, value);
            }
            Font = value;
        }
        protected override void OnParentChanged(EventArgs e)
        {
            if (container is not null) container.ClientSizeChanged -= Fit;
            base.OnParentChanged(e); container = Parent;
            if (container is not null) container.ClientSizeChanged += Fit;
            Fit(this, EventArgs.Empty);
        }
        private void Fit(object? sender, EventArgs e)
        {
            if (container is null) return;
            var width = container.ClientSize.Width - container.Padding.Horizontal - Margin.Horizontal;
            if (width > 0 && MaximumSize.Width != width) MaximumSize = new Size(width, 0);
        }
        protected override void Dispose(bool disposing)
        { if (disposing) { if (container is not null) container.ClientSizeChanged -= Fit; foreach (var font in compactFonts.Values) font.Dispose(); } base.Dispose(disposing); }
    }
}
