using System.Security;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.App.Secrets;

/// <summary>
/// Secure window of the password reset (Domenia 1 PwdUserNew, PwdUserConfirm, BtnRevealUserNew, BtnUserGenPassword, FIC-014 and
/// FIC-050): a native modal window above the application, outside the web page. The operator types the new password twice (each
/// field can be revealed) or generates one of the configured length (four classes, no ambiguous character), which is revealed so
/// that it can be read once, and may be copied (the clipboard is emptied after Security.AutoClearSecretClipboardSeconds). The value
/// lives in <see cref="SecureEntry"/> fields only; <see cref="TakeEntry"/> hands a read-only SecureString to the engine and wipes
/// the fields. Colours follow the theme of the page; high contrast uses the system colours.
/// </summary>
internal sealed class PasswordWindow : Form
{
    private const string Nbsp = " ";
    private const int MinAdvisedLength = 8;

    private readonly FichePasswordRequest request;
    private readonly Palette palette;
    private readonly SecureEntry first = new();
    private readonly SecureEntry second = new();
    private readonly Button revealFirst = new();
    private readonly Button revealSecond = new();
    private readonly Label matchCheck = new();
    private readonly Label lengthCheck = new();
    private readonly Label classesCheck = new();
    private readonly Panel generatedPanel = new();
    private readonly Label generatedValue = new();
    private readonly Label generatedNote = new();
    private readonly Button copyButton = new();
    private readonly Button generateButton = new();
    private readonly Button okButton = new();
    private readonly Button cancelButton = new();
    private bool generatedActive;

    public PasswordWindow(FichePasswordRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        this.request = request;
        palette = Palette.For(request.Theme);
        Text = "Domenia" + Nbsp + "— mot de passe de " + request.TargetName;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Font = new Font("Segoe UI", 10F);
        BackColor = palette.Background;
        ForeColor = palette.Text;
        Padding = new Padding(28, 24, 28, 22);
        KeyPreview = true;
        Build();
        AcceptButton = okButton;
        CancelButton = cancelButton;
        Load += (_, _) =>
        {
            if (request.Generate)
            {
                Generate();
            }
            else
            {
                first.Focus();
            }
        };
        FormClosed += (_, _) => WipeAll();
    }

    /// <summary>The password given (read-only copy, owned by the caller); the fields are wiped. Null unless the window was accepted.</summary>
    public FichePasswordEntry? TakeEntry()
    {
        if (DialogResult != DialogResult.OK || first.SecretLength == 0 || !first.SameAs(second))
        {
            WipeAll();
            return null;
        }
        var entry = new FichePasswordEntry(first.CopySecret(), generatedActive);
        WipeAll();
        return entry;
    }

    private void Build()
    {
        var layout = new TableLayoutPanel
        {
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 1,
            Dock = DockStyle.Fill,
            BackColor = palette.Background,
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 520));

        var eyebrow = Caption("FENÊTRE SÉCURISÉE DE DOMENIA", palette.Accent, bold: true);
        eyebrow.Margin = new Padding(0, 0, 0, 4);
        layout.Controls.Add(eyebrow);
        var title = new Label
        {
            Text = "Mot de passe de " + request.TargetName,
            Font = new Font("Segoe UI Semibold", 16F),
            AutoSize = true,
            MaximumSize = new Size(520, 0),
            ForeColor = palette.Text,
            Margin = new Padding(0, 0, 0, 2),
        };
        layout.Controls.Add(title);
        layout.Controls.Add(Caption(request.TargetLogin, palette.Muted));

        var notice = Notice(
            "Le mot de passe ne passe ni par la page, ni par le plan, ni par le reçu, ni par le journal" + Nbsp + ": il reste en mémoire protégée (SecureString) jusqu’à l’écriture, puis il est effacé.",
            palette.InfoBack, palette.InfoBorder);
        layout.Controls.Add(notice);
        if (request.Protected)
        {
            layout.Controls.Add(Notice(
                "Compte à privilèges (adminCount = 1)" + Nbsp + ": le plan demandera la saisie exacte de son nom avant l’envoi.",
                palette.WarnBack, palette.WarnBorder));
        }

        layout.Controls.Add(FieldLabel("Nouveau mot de passe"));
        layout.Controls.Add(FieldRow(first, revealFirst));
        layout.Controls.Add(FieldLabel("Confirmation"));
        layout.Controls.Add(FieldRow(second, revealSecond));

        var checks = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Margin = new Padding(0, 10, 0, 4), BackColor = palette.Background };
        foreach (var check in new[] { matchCheck, lengthCheck, classesCheck })
        {
            check.AutoSize = true;
            check.Margin = new Padding(0, 2, 0, 2);
            check.Font = new Font("Segoe UI", 9.5F);
            checks.Controls.Add(check);
        }
        layout.Controls.Add(checks);

        BuildGenerated();
        layout.Controls.Add(generatedPanel);

        var foot = new TableLayoutPanel { AutoSize = true, ColumnCount = 3, Dock = DockStyle.Fill, Margin = new Padding(0, 18, 0, 0), BackColor = palette.Background };
        foot.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        foot.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foot.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        Style(generateButton, "Générer un mot de passe", secondary: true);
        generateButton.Click += (_, _) => Generate();
        foot.Controls.Add(generateButton, 0, 0);
        var right = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Margin = Padding.Empty, BackColor = palette.Background };
        Style(cancelButton, "Annuler", secondary: true);
        cancelButton.DialogResult = DialogResult.Cancel;
        Style(okButton, "Utiliser ce mot de passe", secondary: false);
        okButton.Click += (_, _) =>
        {
            if (Ready())
            {
                DialogResult = DialogResult.OK;
                Close();
            }
        };
        right.Controls.Add(cancelButton);
        right.Controls.Add(okButton);
        foot.Controls.Add(right, 2, 0);
        layout.Controls.Add(foot);

        Controls.Add(layout);
        first.SecretChanged += (_, _) => Edited();
        second.SecretChanged += (_, _) => Edited();
        revealFirst.Click += (_, _) => Toggle(first, revealFirst);
        revealSecond.Click += (_, _) => Toggle(second, revealSecond);
        copyButton.Click += (_, _) => CopyGenerated();
        UpdateChecks(updateGenerated: false);
    }

    private void BuildGenerated()
    {
        generatedPanel.AutoSize = true;
        generatedPanel.Visible = false;
        generatedPanel.Margin = new Padding(0, 10, 0, 0);
        generatedPanel.Padding = new Padding(16, 12, 16, 12);
        generatedPanel.BackColor = palette.Surface;
        generatedPanel.Dock = DockStyle.Fill;
        var inner = new TableLayoutPanel { AutoSize = true, ColumnCount = 2, Dock = DockStyle.Fill, BackColor = palette.Surface };
        inner.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        inner.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var heading = Caption("MOT DE PASSE GÉNÉRÉ, À LIRE MAINTENANT", palette.Ok, bold: true);
        inner.Controls.Add(heading, 0, 0);
        inner.SetColumnSpan(heading, 2);
        generatedValue.AutoSize = true;
        generatedValue.Font = new Font(FontFamily.Families.Any(f => f.Name == "Cascadia Mono") ? "Cascadia Mono" : "Consolas", 17F, FontStyle.Bold);
        generatedValue.ForeColor = palette.Text;
        generatedValue.Margin = new Padding(0, 6, 12, 6);
        generatedValue.UseMnemonic = false;
        inner.Controls.Add(generatedValue, 0, 1);
        Style(copyButton, "Copier", secondary: true);
        copyButton.Anchor = AnchorStyles.Right;
        inner.Controls.Add(copyButton, 1, 1);
        generatedNote.AutoSize = true;
        generatedNote.MaximumSize = new Size(480, 0);
        generatedNote.ForeColor = palette.Muted;
        generatedNote.Font = new Font("Segoe UI", 9F);
        inner.Controls.Add(generatedNote, 0, 2);
        inner.SetColumnSpan(generatedNote, 2);
        generatedPanel.Controls.Add(inner);
    }

    private void Generate()
    {
        using var password = TemporaryPassword.Generate(request.GeneratedLength);
        first.Assign(password);
        second.Assign(password);
        generatedActive = true;
        first.Revealed = true;
        second.Revealed = false;
        revealFirst.Text = "Masquer";
        revealSecond.Text = "Afficher";
        UpdateChecks(updateGenerated: true);
        okButton.Focus();
    }

    private void Edited()
    {
        // Any change after the generation makes it a typed password (the plan says so).
        if (generatedActive && !(first.SecretLength == request.GeneratedLength && first.SameAs(second)))
        {
            generatedActive = false;
        }
        UpdateChecks(updateGenerated: true);
    }

    private void UpdateChecks(bool updateGenerated)
    {
        var same = first.SecretLength > 0 && first.SameAs(second);
        var longEnough = first.SecretLength >= MinAdvisedLength;
        var classes = first.Classes();
        Check(matchCheck, same, first.SecretLength == 0 ? "Saisissez le mot de passe deux fois" : same ? "Les deux saisies correspondent" : "Les deux saisies diffèrent", mandatory: true);
        Check(lengthCheck, longEnough, "Au moins " + MinAdvisedLength + " caractères (" + first.SecretLength + " saisis)", mandatory: false);
        Check(classesCheck, classes >= 3, "Trois types de caractères sur quatre" + Nbsp + ": majuscules, minuscules, chiffres, symboles (le contrôleur décide)", mandatory: false);
        okButton.Enabled = same;
        if (!updateGenerated)
        {
            return;
        }
        generatedPanel.Visible = generatedActive;
        if (generatedActive)
        {
            generatedValue.Text = first.Revealed ? first.Text : new string('●', first.SecretLength);
            generatedNote.Text = "Lisez-le ou dictez-le maintenant" + Nbsp + ": il ne sera plus affiché après la fermeture de cette fenêtre. "
                + "Une copie est retirée du presse-papiers après " + request.ClipboardSeconds + Nbsp + "s.";
        }
        else
        {
            generatedValue.Text = "";
        }
    }

    private bool Ready() => first.SecretLength > 0 && first.SameAs(second);

    private void Check(Label label, bool ok, string text, bool mandatory)
    {
        label.Text = (ok ? "✓  " : mandatory ? "✕  " : "•  ") + text;
        label.ForeColor = ok ? palette.Ok : mandatory && first.SecretLength > 0 ? palette.Danger : palette.Muted;
    }

    private static void Toggle(SecureEntry entry, Button button)
    {
        entry.Revealed = !entry.Revealed;
        button.Text = entry.Revealed ? "Masquer" : "Afficher";
        entry.Focus();
    }

    private void CopyGenerated()
    {
        if (!generatedActive || first.SecretLength == 0)
        {
            return;
        }
        var wasRevealed = first.Revealed;
        first.Revealed = true;
        var text = first.Text;
        first.Revealed = wasRevealed;
        Clipboard.SetText(text);
        ClipboardGuard.ClearLater(text, request.ClipboardSeconds, Owner);
        copyButton.Text = "Copié";
    }

    private void WipeAll()
    {
        first.Wipe();
        second.Wipe();
        generatedValue.Text = "";
    }

    private Control FieldRow(SecureEntry entry, Button reveal)
    {
        var row = new TableLayoutPanel { AutoSize = true, ColumnCount = 2, Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 2), BackColor = palette.Background };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        entry.Dock = DockStyle.Fill;
        entry.BorderStyle = BorderStyle.FixedSingle;
        entry.BackColor = palette.Input;
        entry.ForeColor = palette.Text;
        entry.Font = new Font("Consolas", 12F);
        entry.Margin = new Padding(0, 0, 8, 0);
        row.Controls.Add(entry, 0, 0);
        Style(reveal, "Afficher", secondary: true);
        reveal.Margin = Padding.Empty;
        row.Controls.Add(reveal, 1, 0);
        return row;
    }

    private Label FieldLabel(string text) => new()
    {
        Text = text,
        AutoSize = true,
        Font = new Font("Segoe UI Semibold", 10F),
        ForeColor = palette.Text,
        Margin = new Padding(0, 14, 0, 6),
    };

    private Label Caption(string text, Color color, bool bold = false) => new()
    {
        Text = text,
        AutoSize = true,
        MaximumSize = new Size(520, 0),
        Font = new Font(bold ? "Segoe UI Semibold" : "Segoe UI", bold ? 8.5F : 9.5F),
        ForeColor = color,
        Margin = new Padding(0),
        UseMnemonic = false,
    };

    private Control Notice(string text, Color back, Color border)
    {
        var panel = new Panel { AutoSize = true, Dock = DockStyle.Fill, BackColor = border, Padding = new Padding(3, 0, 0, 0), Margin = new Padding(0, 14, 0, 0) };
        var label = new Label
        {
            Text = text,
            AutoSize = true,
            MaximumSize = new Size(500, 0),
            BackColor = back,
            ForeColor = palette.Text,
            Padding = new Padding(12, 9, 12, 9),
            Dock = DockStyle.Fill,
            UseMnemonic = false,
        };
        panel.Controls.Add(label);
        return panel;
    }

    private void Style(Button button, string text, bool secondary)
    {
        button.Text = text;
        button.AutoSize = true;
        button.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        button.Padding = new Padding(14, 6, 14, 6);
        button.Margin = new Padding(8, 0, 0, 0);
        button.Font = new Font("Segoe UI Semibold", 10F);
        button.UseMnemonic = false;
        if (palette.System)
        {
            return;
        }
        button.FlatStyle = FlatStyle.Flat;
        button.Cursor = Cursors.Hand;
        button.BackColor = secondary ? palette.Surface : palette.Accent;
        button.ForeColor = secondary ? palette.Text : Color.White;
        button.FlatAppearance.BorderColor = secondary ? palette.Border : palette.Accent;
        button.FlatAppearance.MouseOverBackColor = secondary ? palette.Hover : ControlPaint.Light(palette.Accent, 0.15F);
    }

    /// <summary>Colours of the window, close to the tokens of the page (dark, light) or the system colours (high contrast).</summary>
    private sealed record Palette(bool System, Color Background, Color Surface, Color Input, Color Border, Color Hover, Color Text, Color Muted, Color Accent,
        Color Ok, Color Danger, Color InfoBack, Color InfoBorder, Color WarnBack, Color WarnBorder)
    {
        public static Palette For(string theme) => theme switch
        {
            "light" => new(false, Color.FromArgb(246, 248, 252), Color.White, Color.White, Color.FromArgb(214, 220, 232), Color.FromArgb(238, 242, 250),
                Color.FromArgb(15, 23, 42), Color.FromArgb(91, 100, 120), Color.FromArgb(37, 99, 235), Color.FromArgb(5, 150, 105), Color.FromArgb(220, 38, 38),
                Color.FromArgb(232, 240, 255), Color.FromArgb(37, 99, 235), Color.FromArgb(255, 247, 230), Color.FromArgb(217, 119, 6)),
            "contrast" => new(true, SystemColors.Window, SystemColors.Window, SystemColors.Window, SystemColors.WindowText, SystemColors.Highlight,
                SystemColors.WindowText, SystemColors.WindowText, SystemColors.Highlight, SystemColors.WindowText, SystemColors.WindowText,
                SystemColors.Window, SystemColors.WindowText, SystemColors.Window, SystemColors.WindowText),
            _ => new(false, Color.FromArgb(11, 18, 32), Color.FromArgb(20, 28, 46), Color.FromArgb(14, 21, 37), Color.FromArgb(41, 53, 79), Color.FromArgb(30, 40, 64),
                Color.FromArgb(230, 234, 242), Color.FromArgb(154, 167, 189), Color.FromArgb(79, 140, 255), Color.FromArgb(52, 211, 153), Color.FromArgb(248, 113, 113),
                Color.FromArgb(18, 34, 64), Color.FromArgb(79, 140, 255), Color.FromArgb(48, 36, 16), Color.FromArgb(245, 158, 11)),
        };
    }
}

/// <summary>
/// Clipboard of a copied secret (Domenia 1 Start-SecretClipboardAutoClear): emptied after the configured delay if it still holds the
/// same text (compared by its SHA-256, the text itself is not kept).
/// </summary>
internal static class ClipboardGuard
{
    public static void ClearLater(string text, int seconds, Form? owner)
    {
        ArgumentNullException.ThrowIfNull(text);
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        var target = owner;
        _ = Task.Delay(TimeSpan.FromSeconds(Math.Clamp(seconds, 5, 300))).ContinueWith(_ =>
        {
            if (target is null || target.IsDisposed)
            {
                return;
            }
            try
            {
                target.BeginInvoke(() =>
                {
                    if (Clipboard.ContainsText() && SHA256.HashData(Encoding.UTF8.GetBytes(Clipboard.GetText())).AsSpan().SequenceEqual(hash))
                    {
                        Clipboard.Clear();
                    }
                });
            }
            catch (InvalidOperationException ex)
            {
                // The main window closed meanwhile: the clipboard is left as it is; traced without its content.
                TechnicalLog.Warning("Presse-papiers non effacé après la copie d’un mot de passe : fenêtre fermée (" + ex.GetType().Name + ").");
            }
        }, TaskScheduler.Default);
    }
}
