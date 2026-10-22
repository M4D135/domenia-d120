using System.Runtime.InteropServices;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.App.Poste;

/// <summary>
/// The secure window of one secret (Domenia 1 Update-DomeniaSecretsView, BitLockerKeyCard, PST-055 to PST-058): above the main
/// window, out of the taskbar, excluded from screen captures; the value alone (eight numbered blocks for a recovery key, one
/// character per box for a password), its identifier to compare with the screen of the workstation, a 30 s countdown, one
/// extension, « Masquer maintenant », and a protected copy. It masks the value when it loses the focus (shown again by a click,
/// without a new read) and wipes it at the deadline or when it closes. System colours: the Windows theme and high contrast
/// apply as they are.
/// </summary>
internal sealed partial class SecretWindowForm : Form
{
    private const char Dot = '•';

    private readonly Func<string, bool> copy;
    private readonly Action<SecretWindowForm> changed;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 250 };
    private readonly List<(Label Label, string Text)> values = [];
    private readonly Label countdown = new() { AutoSize = true };
    private readonly ProgressBar bar = new() { Minimum = 0, Maximum = 1000, Height = 8, Dock = DockStyle.Top, Style = ProgressBarStyle.Continuous };
    private readonly Label maskedNote = new() { AutoSize = true, Visible = false };
    private readonly Button copyButton = new() { AutoSize = true };
    private readonly Button extendButton = new() { AutoSize = true };
    private readonly Button showButton = new() { AutoSize = true, Visible = false };
    private readonly Button hideButton = new() { AutoSize = true };
    private int total;

    public SecretWindowForm(SecretReading secret, Func<string, bool> copy, Action<SecretWindowForm> changed)
    {
        ArgumentNullException.ThrowIfNull(secret);
        Secret = secret;
        this.copy = copy ?? throw new ArgumentNullException(nameof(copy));
        this.changed = changed ?? throw new ArgumentNullException(nameof(changed));
        ExtensionsLeft = secret.Extensions;
        total = Math.Max(1, secret.RevealSeconds);
        Until = DateTimeOffset.UtcNow.AddSeconds(total);

        var laps = secret.Kind == "laps";
        Text = "Domenia · " + (laps ? "mot de passe LAPS" : "clé de récupération BitLocker") + " · " + secret.Computer;
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 10F);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(18);
        BackColor = SystemColors.Window;
        ForeColor = SystemColors.WindowText;

        var layout = new TableLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, Padding = new Padding(0), Margin = new Padding(0) };
        var title = new Label
        {
            AutoSize = true,
            Font = new Font("Segoe UI Semibold", 13F),
            Text = (laps ? "Mot de passe LAPS de " : "Clé de récupération BitLocker de ") + secret.Computer,
            Margin = new Padding(0, 0, 0, 4),
        };
        var identity = new Label
        {
            AutoSize = true,
            MaximumSize = new Size(560, 0),
            ForeColor = SystemColors.GrayText,
            Text = laps
                ? "Compte " + secret.Identifier + ". Dictez caractère par caractère ; les chiffres sont en bleu, les symboles en orange."
                : "Identifiant de récupération" + FrenchText.Colon + (secret.KeyGuid ?? secret.Identifier) + Environment.NewLine
                  + "Comparez-le avec l’écran de récupération du poste avant de dicter la clé.",
            Margin = new Padding(0, 0, 0, 12),
        };
        layout.Controls.Add(title);
        layout.Controls.Add(identity);
        layout.Controls.Add(laps ? PasswordPanel(secret.Value ?? "") : BlocksPanel(secret.Blocks));
        layout.Controls.Add(maskedNote);
        maskedNote.Text = "Valeur masquée : la fenêtre a perdu le focus. « Réafficher » la montre de nouveau sans nouvelle lecture.";
        maskedNote.ForeColor = SystemColors.GrayText;
        maskedNote.MaximumSize = new Size(560, 0);

        var timing = new Panel { Height = 34, Dock = DockStyle.Top, Margin = new Padding(0, 12, 0, 0), Width = 560 };
        countdown.Dock = DockStyle.Right;
        countdown.Font = new Font("Segoe UI Semibold", 10F);
        timing.Controls.Add(bar);
        timing.Controls.Add(countdown);
        layout.Controls.Add(timing);

        var notice = new Label
        {
            AutoSize = true,
            MaximumSize = new Size(560, 0),
            ForeColor = secret.Simulated ? SystemColors.HotTrack : SystemColors.GrayText,
            Text = (secret.Simulated ? "Valeur fictive de la simulation. " : "") + secret.Notice + " " + secret.ClipboardLimit,
            Margin = new Padding(0, 8, 0, 12),
        };
        layout.Controls.Add(notice);

        copyButton.Text = "Copier (presse-papiers vidé après " + FrenchText.Integer(SecretPolicy.ClipboardClearSeconds) + " s)";
        extendButton.Text = "Prolonger de " + FrenchText.Integer(secret.ExtensionSeconds) + " s";
        extendButton.Enabled = ExtensionsLeft > 0;
        showButton.Text = "Réafficher";
        hideButton.Text = "Masquer maintenant";
        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = true, Margin = new Padding(0) };
        buttons.Controls.AddRange([copyButton, extendButton, showButton, hideButton]);
        layout.Controls.Add(buttons);
        Controls.Add(layout);

        copyButton.Click += (_, _) => Copy();
        extendButton.Click += (_, _) => Extend();
        showButton.Click += (_, _) => SetMasked(false);
        hideButton.Click += (_, _) => Close();
        timer.Tick += (_, _) => Tick();
        Deactivate += (_, _) => SetMasked(true);
        // Échap answers « Masquer maintenant ».
        CancelButton = hideButton;
        UpdateCountdown();
        timer.Start();
    }

    /// <summary>The secret shown (never journalled, never sent to the page).</summary>
    public SecretReading Secret { get; }

    public DateTimeOffset Until { get; private set; }

    public int ExtensionsLeft { get; private set; }

    public bool Masked { get; private set; }

    /// <summary>True when the window closed because the 30 s ran out (not on « Masquer »).</summary>
    public bool ExpiredAtDeadline { get; private set; }

    private Control PasswordPanel(string value)
    {
        var panel = new FlowLayoutPanel { AutoSize = true, WrapContents = true, MaximumSize = new Size(560, 0), Margin = new Padding(0), AccessibleName = "Mot de passe affiché" };
        var mono = new Font("Consolas", 20F);
        foreach (var ch in value)
        {
            var text = ch.ToString();
            var label = new Label
            {
                AutoSize = true,
                Font = mono,
                Text = text,
                Margin = new Padding(1),
                Padding = new Padding(2, 2, 2, 2),
                ForeColor = char.IsAsciiDigit(ch) ? SystemColors.HotTrack : char.IsLetter(ch) ? SystemColors.WindowText : Color.DarkOrange,
                BackColor = SystemColors.Control,
            };
            values.Add((label, text));
            panel.Controls.Add(label);
        }
        return panel;
    }

    private Control BlocksPanel(System.Collections.Immutable.ImmutableArray<SecretBlock> blocks)
    {
        var grid = new TableLayoutPanel { AutoSize = true, ColumnCount = 4, RowCount = 2, Margin = new Padding(0), AccessibleName = "Clé de récupération en huit blocs" };
        var mono = new Font("Consolas", 18F);
        foreach (var block in blocks)
        {
            var cell = new TableLayoutPanel { AutoSize = true, ColumnCount = 1, Margin = new Padding(4), Padding = new Padding(8, 4, 8, 6), BackColor = SystemColors.Control };
            cell.Controls.Add(new Label { AutoSize = true, Text = block.Label, ForeColor = SystemColors.GrayText, Font = new Font("Segoe UI", 8.5F), Anchor = AnchorStyles.Top });
            var digits = new Label { AutoSize = true, Font = mono, Text = block.Digits, Anchor = AnchorStyles.Top };
            values.Add((digits, block.Digits));
            cell.Controls.Add(digits);
            grid.Controls.Add(cell);
        }
        return grid;
    }

    private string ValueText() => Secret.CopyText();

    private void Copy()
    {
        if (Masked)
        {
            return;
        }
        copyButton.Text = copy(ValueText()) ? "Copié : vidé après " + FrenchText.Integer(SecretPolicy.ClipboardClearSeconds) + " s" : "Copie refusée par le presse-papiers";
    }

    private void Extend()
    {
        if (ExtensionsLeft <= 0)
        {
            return;
        }
        ExtensionsLeft--;
        var now = DateTimeOffset.UtcNow;
        Until = (Until > now ? Until : now).AddSeconds(Secret.ExtensionSeconds);
        total = Math.Max(1, (int)Math.Ceiling((Until - now).TotalSeconds));
        extendButton.Enabled = false;
        extendButton.Text = "Prolongation utilisée";
        UpdateCountdown();
        changed(this);
    }

    private void SetMasked(bool masked)
    {
        if (Masked == masked || IsDisposed)
        {
            return;
        }
        Masked = masked;
        foreach (var (label, text) in values)
        {
            label.Text = masked ? new string(Dot, text.Length) : text;
        }
        maskedNote.Visible = masked;
        showButton.Visible = masked;
        copyButton.Enabled = !masked;
        changed(this);
    }

    private void Tick()
    {
        var left = Until - DateTimeOffset.UtcNow;
        if (left <= TimeSpan.Zero)
        {
            ExpiredAtDeadline = true;
            Close();
            return;
        }
        UpdateCountdown();
    }

    private void UpdateCountdown()
    {
        var left = Math.Max(0, (Until - DateTimeOffset.UtcNow).TotalSeconds);
        var seconds = (int)Math.Ceiling(left);
        countdown.Text = FrenchText.Integer(seconds) + " s";
        countdown.ForeColor = seconds <= 5 ? Color.Firebrick : SystemColors.WindowText;
        bar.Value = Math.Clamp((int)Math.Round(1000 * left / total), 0, 1000);
    }

    protected override void OnLoad(EventArgs e)
    {
        base.OnLoad(e);
        // Centred on the main window (StartPosition.CenterParent only works for modal dialogs).
        var area = Owner is { } owner ? owner.Bounds : Screen.FromControl(this).WorkingArea;
        Location = new Point(area.Left + Math.Max(0, (area.Width - Width) / 2), area.Top + Math.Max(0, (area.Height - Height) / 3));
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        // Excluded from screen captures and screen sharing (Windows 10 2004 and later), else only shown on the local monitor.
        if (!SetWindowDisplayAffinity(Handle, ExcludeFromCapture) && !SetWindowDisplayAffinity(Handle, MonitorOnly))
        {
            TechnicalLog.Warning("Fenêtre sécurisée : exclusion des captures d’écran non appliquée par Windows.");
        }
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        timer.Stop();
        // The value is wiped from the controls before they are released.
        foreach (var (label, _) in values)
        {
            label.Text = "";
        }
        values.Clear();
        base.OnFormClosed(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            timer.Dispose();
        }
        base.Dispose(disposing);
    }

    private const uint ExcludeFromCapture = 0x11;
    private const uint MonitorOnly = 0x1;

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowDisplayAffinity(IntPtr window, uint affinity);
}
