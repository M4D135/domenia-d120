using System.ComponentModel;
using System.Drawing.Drawing2D;
using Domenia.Core;
using Microsoft.Win32;

namespace Domenia.App.Secrets;

// Native counterparts of web/css/tokens.css and the existing 24 px logo in web/js/icons.js.
internal sealed record LoginColors(Color Background, Color Surface, Color Input, Color Text, Color Muted,
    Color Border, Color ControlBorder, Color Accent, Color OnAccent, Color AccentText, Color AccentHover,
    Color Hover, Color Warning, bool Contrast, bool Dark)
{
    internal static LoginColors For(string theme)
    {
        if (SystemInformation.HighContrast)
            return new(SystemColors.Window, SystemColors.Window, SystemColors.Window, SystemColors.WindowText,
                SystemColors.WindowText, SystemColors.WindowText, SystemColors.WindowText, SystemColors.Highlight,
                SystemColors.HighlightText, SystemColors.WindowText, SystemColors.Highlight, SystemColors.Window,
                SystemColors.WindowText, true, SystemColors.Window.GetBrightness() < .5F);
        if (theme == "system") theme = WindowsTheme();
        if (theme == "contrast")
            return new(Color.Black, Color.Black, Color.Black, Color.White, Color.White, Color.White, Color.White,
                Color.FromArgb(26, 235, 255), Color.Black, Color.Yellow, Color.Yellow, Color.FromArgb(26, 26, 26), Color.Yellow, true, true);
        return theme == "light"
            ? new(C(0xf3f6fb), C(0xffffff), C(0xffffff), C(0x17243a), C(0x52627b), C(0xd7dee9), C(0x8392a8),
                C(0x066ddb), Color.White, C(0x075ebd), C(0x0a5fbf), C(0xf0f6ff), C(0x8a5300), false, false)
            : new(C(0x0d1625), C(0x172437), C(0x13203a), C(0xedf4ff), C(0xbfcee2), C(0x2b3d57), C(0x64809f),
                C(0x2470d6), Color.White, C(0x8bbeff), C(0x1f6fd1), C(0x1d3050), C(0xfcd34d), false, true);
    }
    private static string WindowsTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", writable: false);
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0 ? "dark" : "light";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            TechnicalLog.Warning("Thème Windows non lisible ; affichage clair utilisé pour cette fenêtre native.");
            return "light";
        }
    }
    private static Color C(int value) => Color.FromArgb((value >> 16) & 255, (value >> 8) & 255, value & 255);
}

internal sealed class LoginCard : TableLayoutPanel
{
    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Color BorderColor { get; set; }
    internal LoginCard()
    {
        DoubleBuffered = true; AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        ColumnCount = 1; ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Dock = DockStyle.Top; Padding = new Padding(16); Margin = new Padding(0, 0, 0, 12);
    }
    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(Parent?.BackColor ?? BackColor);
        if (Width < 2 || Height < 2) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var shape = LoginBrandMark.Rounded(new RectangleF(.5F, .5F, Width - 1, Height - 1), 14 * DeviceDpi / 96F);
        using var fill = new SolidBrush(BackColor); using var border = new Pen(BorderColor, Math.Max(1, DeviceDpi / 96F));
        e.Graphics.FillPath(fill, shape); e.Graphics.DrawPath(border, shape);
    }
}

internal sealed class LoginBrandMark : Control
{
    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal LoginColors Colors { get; set; } = LoginColors.For("dark");
    internal LoginBrandMark()
    { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true); TabStop = false; AccessibleRole = AccessibleRole.Graphic; AccessibleName = "Logo Domenia"; }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (Width < 2 || Height < 2) return;
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        var box = new RectangleF(0, 0, Width - 1, Height - 1);
        using var shape = Rounded(box, Width * .3F);
        if (!Colors.Contrast)
        {
            var saved = g.Save(); g.SetClip(shape);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(ProductBrand.Mark, box); g.Restore(saved); return;
        }
        using var solid = new SolidBrush(Colors.Accent); g.FillPath(solid, shape);
        var state = g.Save(); var scale = Width * .72F / 24;
        g.TranslateTransform(Width * .14F, Height * .14F); g.ScaleTransform(scale, scale);
        using var outline = new GraphicsPath();
        outline.AddLine(6, 4, 11.5F, 4);
        outline.AddBezier(11.5F, 4, 16.7F, 4, 20, 7.2F, 20, 12);
        outline.AddBezier(20, 12, 20, 16.8F, 16.7F, 20, 11.5F, 20);
        outline.AddLine(11.5F, 20, 6, 20); outline.CloseFigure();
        using var pen = new Pen(Colors.OnAccent, 3.2F) { LineJoin = LineJoin.Round };
        g.DrawPath(pen, outline);
        using var branch = new Pen(Colors.OnAccent, 1.2F) { LineJoin = LineJoin.Round };
        g.DrawLine(branch, 12, 9, 12, 12);
        PointF[] branchPoints = [new(9, 15), new(9, 12), new(15, 12), new(15, 15)]; g.DrawLines(branch, branchPoints);
        using var ink = new SolidBrush(Colors.OnAccent);
        g.FillEllipse(ink, 10.5F, 7, 3, 3); g.FillEllipse(ink, 7.5F, 14, 3, 3); g.FillEllipse(ink, 13.5F, 14, 3, 3);
        g.Restore(state);
    }
    internal static GraphicsPath Rounded(RectangleF box, float radius)
    {
        var path = new GraphicsPath(); var diameter = Math.Min(radius * 2, Math.Min(box.Width, box.Height));
        path.AddArc(box.Left, box.Top, diameter, diameter, 180, 90);
        path.AddArc(box.Right - diameter, box.Top, diameter, diameter, 270, 90);
        path.AddArc(box.Right - diameter, box.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(box.Left, box.Bottom - diameter, diameter, diameter, 90, 90); path.CloseFigure(); return path;
    }
}

internal sealed class LoginIdentityIcon : Control
{
    private LoginColors colors = LoginColors.For("light");
    internal LoginIdentityIcon()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        Size = new Size(44, 48); Margin = new Padding(0, 0, 14, 0); TabStop = false;
        AccessibleRole = AccessibleRole.Graphic; AccessibleName = "Compte Windows";
    }
    internal void SetColors(LoginColors value) { colors = value; Invalidate(); }
    protected override void OnPaint(PaintEventArgs e)
    {
        if (Width < 2 || Height < 2) return;
        var g = e.Graphics; g.Clear(Parent?.BackColor ?? colors.Background); g.SmoothingMode = SmoothingMode.AntiAlias;
        using var shape = LoginBrandMark.Rounded(new RectangleF(.5F, .5F, Width - 1, Height - 1), 11 * DeviceDpi / 96F);
        using var fill = new SolidBrush(colors.Surface); using var border = new Pen(colors.Border);
        g.FillPath(fill, shape); g.DrawPath(border, shape);
        var unit = DeviceDpi / 96F;
        var state = g.Save(); g.TranslateTransform(Width / 2F - 12 * unit, Height / 2F - 12 * unit); g.ScaleTransform(unit, unit);
        using var ink = new Pen(colors.AccentText, 1.6F) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        g.DrawEllipse(ink, 8, 3, 8, 8); g.DrawArc(ink, 5, 12, 14, 18, 180, 180); g.Restore(state);
    }
}

internal sealed class LoginIdentityText : Control
{
    private readonly StringFormat format = new(StringFormat.GenericDefault) { Trimming = StringTrimming.None };
    private readonly Font identityFont = new("Segoe UI", 10.5F, FontStyle.Bold);
    internal LoginIdentityText(string identity)
    {
        Text = identity; AccessibleName = "Identité de la session Windows"; AccessibleDescription = identity; AccessibleRole = AccessibleRole.StaticText;
        AutoSize = true; Dock = DockStyle.Top; Margin = Padding.Empty; TabStop = false;
        Font = identityFont;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }
    public override Size GetPreferredSize(Size proposedSize)
    {
        var width = proposedSize.Width is > 0 and < int.MaxValue ? proposedSize.Width
            : Parent is null ? 350 : Parent.ClientSize.Width - Parent.Padding.Horizontal - Margin.Horizontal;
        width = Math.Max(1, width > 0 ? width : 350);
        // Measuring must not create the native handle before the form and its theme hooks are ready.
        using var surface = new Bitmap(1, 1); surface.SetResolution(DeviceDpi, DeviceDpi);
        using var graphics = Graphics.FromImage(surface);
        var measured = graphics.MeasureString(Text, Font, width, format);
        return new Size(width, Math.Max(Font.Height, (int)Math.Ceiling(measured.Height)));
    }
    protected override void OnTextChanged(EventArgs e)
    { base.OnTextChanged(e); Parent?.PerformLayout(this, nameof(Text)); Invalidate(); }
    protected override void OnFontChanged(EventArgs e)
    { base.OnFontChanged(e); Parent?.PerformLayout(this, nameof(Font)); Invalidate(); }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(BackColor);
        using var ink = new SolidBrush(ForeColor); e.Graphics.DrawString(Text, Font, ink, ClientRectangle, format);
    }
    protected override void Dispose(bool disposing)
    { if (disposing) { format.Dispose(); identityFont.Dispose(); } base.Dispose(disposing); }
}

// The account row used to live in nested auto-sized tables. Those tables probe preferred
// height at a few pixels wide, keep the wrapped height, and then center only the icon.
// This card measures the caption and the account at the width the row actually has.
internal sealed class LoginIdentityCard : Panel
{
    private readonly LoginIdentityIcon icon = new() { Dock = DockStyle.None, Anchor = AnchorStyles.None };
    private readonly Label caption = new()
    {
        AutoSize = false, Dock = DockStyle.None, Anchor = AnchorStyles.None, UseMnemonic = false, TabStop = false,
        Margin = new Padding(0, 0, 0, 5), Tag = LoginVisualRole.Muted
    };
    private readonly LoginIdentityText identity;
    private readonly Font captionFont = new("Segoe UI", 8.5F);
    private bool arranging;

    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Color BorderColor { get; set; }

    internal LoginIdentityCard(string account, string title)
    {
        identity = new LoginIdentityText(account) { Dock = DockStyle.None, Anchor = AnchorStyles.None, AutoSize = false };
        caption.Text = title; caption.Font = captionFont; caption.AccessibleName = title;
        caption.Disposed += (_, _) => captionFont.Dispose();
        DoubleBuffered = true; AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
        Dock = DockStyle.Top; Padding = new Padding(18); Margin = new Padding(0, 0, 0, 18);
        TabStop = false; AccessibleName = "Compte Windows de la session";
        Controls.Add(icon); Controls.Add(caption); Controls.Add(identity);
    }

    public override Size GetPreferredSize(Size proposedSize)
    {
        var outer = OuterWidth(proposedSize);
        return new Size(outer, OuterHeight(outer));
    }

    protected override void OnLayout(LayoutEventArgs e)
    {
        if (arranging) return;
        arranging = true;
        try
        {
            var outer = Width > 1 ? Width : OuterWidth(Size.Empty);
            Place(outer);
            var height = OuterHeight(outer);
            if (height > 0 && Height != height) Height = height;
        }
        finally { arranging = false; }
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(Parent?.BackColor ?? BackColor);
        if (Width < 2 || Height < 2) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var shape = LoginBrandMark.Rounded(new RectangleF(.5F, .5F, Width - 1, Height - 1), 14 * DeviceDpi / 96F);
        using var fill = new SolidBrush(BackColor);
        using var border = new Pen(BorderColor, Math.Max(1, DeviceDpi / 96F));
        e.Graphics.FillPath(fill, shape); e.Graphics.DrawPath(border, shape);
    }

    private int OuterWidth(Size proposed)
    {
        if (Parent is Control parent)
        {
            var available = parent.ClientSize.Width - parent.Padding.Horizontal - Margin.Horizontal;
            if (available > 1) return available;
        }
        if (Width > 1) return Width;
        if (proposed.Width > 1) return proposed.Width;
        return Math.Max(1, (int)Math.Round(440F * DeviceDpi / 96F));
    }

    private int TextWidth(int outer)
    {
        var reserved = icon.Margin.Left + icon.Width + icon.Margin.Right;
        return Math.Max(1, outer - Padding.Horizontal - reserved);
    }

    private (int Caption, int Account, int Block) Measure(int outer)
    {
        var textWidth = TextWidth(outer);
        // A maximum height of zero is unlimited for other labels, but this fixed caption was collapsed
        // to nothing when the dense layout applied that size. Measure and pin the real text height.
        var flags = TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl;
        var captionSize = TextRenderer.MeasureText(caption.Text, caption.Font, new Size(textWidth, int.MaxValue), flags);
        var captionHeight = Math.Max(caption.Font.Height, captionSize.Height);
        var accountHeight = Math.Max(identity.Font.Height, identity.GetPreferredSize(new Size(textWidth, 0)).Height);
        var text = caption.Margin.Top + captionHeight + caption.Margin.Bottom + accountHeight + identity.Margin.Vertical;
        var picture = icon.Margin.Top + icon.Height + icon.Margin.Bottom;
        return (captionHeight, accountHeight, Math.Max(picture, text));
    }

    private int OuterHeight(int outer) => Padding.Vertical + Measure(outer).Block;

    private void Place(int outer)
    {
        var measured = Measure(outer);
        var textWidth = TextWidth(outer);
        var textHeight = caption.Margin.Top + measured.Caption + caption.Margin.Bottom + measured.Account + identity.Margin.Vertical;
        var top = Padding.Top;
        var iconY = top + icon.Margin.Top + Math.Max(0, (measured.Block - (icon.Margin.Vertical + icon.Height)) / 2);
        var textY = top + Math.Max(0, (measured.Block - textHeight) / 2);
        icon.SetBounds(Padding.Left + icon.Margin.Left, iconY, icon.Width, icon.Height);
        var textX = icon.Right + icon.Margin.Right;
        var captionY = textY + caption.Margin.Top;
        caption.MinimumSize = new Size(textWidth, measured.Caption);
        caption.MaximumSize = new Size(textWidth, measured.Caption);
        caption.SetBounds(textX, captionY, textWidth, measured.Caption);
        identity.SetBounds(textX, caption.Bottom + caption.Margin.Bottom, textWidth, measured.Account);
    }
}

internal sealed class LoginInput : Panel
{
    private readonly Control field;
    private LoginColors colors = LoginColors.For("light");
    internal LoginInput(Control value)
    {
        field = value; DoubleBuffered = true; Dock = DockStyle.Top; Height = 44; Margin = new Padding(0, 0, 0, 8); TabStop = false;
        if (field is TextBoxBase text) text.BorderStyle = BorderStyle.None;
        field.Dock = DockStyle.None; field.Margin = Padding.Empty;
        Controls.Add(field); field.GotFocus += FocusChanged; field.LostFocus += FocusChanged;
    }
    internal void SetColors(LoginColors value) { colors = value; Invalidate(); }
    private void FocusChanged(object? sender, EventArgs e) => Invalidate();
    protected override void OnLayout(LayoutEventArgs e)
    {
        base.OnLayout(e); var inset = (int)Math.Round(12 * DeviceDpi / 96F);
        field.SetBounds(inset, Math.Max(0, (Height - field.PreferredSize.Height) / 2), Math.Max(1, Width - 2 * inset), field.PreferredSize.Height);
    }
    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(Parent?.BackColor ?? colors.Surface);
        if (Width < 2 || Height < 2) return;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var shape = LoginBrandMark.Rounded(new RectangleF(1, 1, Width - 3, Height - 3), 10 * DeviceDpi / 96F);
        using var fill = new SolidBrush(colors.Input);
        using var border = new Pen(field.Focused ? colors.AccentText : colors.ControlBorder, (field.Focused ? 2 : 1) * DeviceDpi / 96F);
        e.Graphics.FillPath(fill, shape); e.Graphics.DrawPath(border, shape);
    }
}

internal sealed class LoginFrame : Panel
{
    internal TableLayoutPanel Document { get; }
    internal readonly Dictionary<Control, LoginSpacing> LayoutDefaults = [];
    internal bool OverflowReported;
    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal bool Fitting { get; set; }
    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal bool Positioned { get; set; }
    private bool compact;
    private bool expandedContent;
    private bool layingOut;
    private readonly LoginBrandPanel brand = new() { Margin = Padding.Empty };
    private readonly Label overflowNotice = new()
    {
        Text = "Agrandissez la fenêtre pour afficher tous les contrôles.", Visible = false,
        Tag = LoginVisualRole.Warning, TextAlign = ContentAlignment.MiddleCenter, UseMnemonic = false,
        AccessibleRole = AccessibleRole.Alert, AutoSize = false, TabStop = false
    };
    internal LoginFrame(TableLayoutPanel document)
    {
        Document = document; document.Controls[0].Visible = false;
        Dock = DockStyle.Fill; Margin = Padding.Empty; DoubleBuffered = true;
        document.Dock = DockStyle.None; document.Margin = Padding.Empty;
        Controls.Add(brand); Controls.Add(document); Controls.Add(overflowNotice);
    }
    internal void SetCompactBrand(bool value) { compact = value; brand.SetCompact(value); PerformLayout(); }
    internal void SetExpandedContent(bool value) { expandedContent = value; PerformLayout(); }
    internal void ShowOverflowNotice(bool value)
    { overflowNotice.Visible = value; if (value) overflowNotice.BringToFront(); PerformLayout(); }
    private int ContentWidth(int width)
    {
        var unit = DeviceDpi / 96F;
        var available = compact ? width : width - (int)Math.Round(width * .44F);
        var usable = available - (int)Math.Round((compact ? 48 : 72) * unit);
        return Math.Max(1, expandedContent ? usable : Math.Min((int)Math.Round(440 * unit), usable));
    }
    private int MeasureDocument(int width)
    {
        Document.MinimumSize = new Size(width, 0); Document.MaximumSize = new Size(width, 0);
        Document.Width = width; Document.PerformLayout();
        return Document.GetPreferredSize(new Size(width, 0)).Height;
    }
    public override Size GetPreferredSize(Size proposedSize)
    {
        var width = proposedSize.Width > 0 ? proposedSize.Width : Width;
        return new Size(width, MeasureDocument(ContentWidth(width)) + (int)Math.Round((compact ? 80 : 64) * DeviceDpi / 96F));
    }
    protected override void OnLayout(LayoutEventArgs e)
    {
        base.OnLayout(e); if (layingOut || Width < 1) return; layingOut = true;
        try
        {
            var band = compact ? (int)Math.Round(56 * DeviceDpi / 96F) : 0;
            var split = compact ? 0 : (int)Math.Round(Width * .44F);
            brand.Bounds = compact ? new Rectangle(0, 0, Width, band) : new Rectangle(0, 0, split, Height);
            var width = ContentWidth(Width); var height = MeasureDocument(width);
            Document.Bounds = new Rectangle(split + (Width - split - width) / 2, band + Math.Max(0, (Height - band - height) / 2), width, height);
            var noticeHeight = (int)Math.Round(32 * DeviceDpi / 96F);
            overflowNotice.Bounds = new Rectangle(split, Math.Max(0, Height - noticeHeight), Width - split, noticeHeight);
        }
        finally { layingOut = false; }
    }
}

internal sealed record LoginSpacing(Padding Margin, Padding Padding, Size MinimumSize, Size Size, float Unit);

internal sealed class LoginBrandPanel : Panel
{
    private readonly LoginBrandMark mark = new() { Size = new Size(48, 48), BackColor = Color.Transparent };
    private readonly Font title = new("Segoe UI", 18F, FontStyle.Bold);
    private readonly Font subtitle = new("Segoe UI", 9F);
    private LoginColors colors = LoginColors.For("light");
    private bool compact;
    internal LoginBrandPanel()
    { DoubleBuffered = true; Controls.Add(mark); AccessibleName = "Domenia, Active Directory"; TabStop = false; }
    internal void SetColors(LoginColors value) { colors = value; mark.Colors = value; mark.Invalidate(); Invalidate(); }
    internal void SetCompact(bool value) { compact = value; PerformLayout(); Invalidate(); }
    protected override void OnLayout(LayoutEventArgs e)
    {
        base.OnLayout(e); var unit = DeviceDpi / 96F;
        var size = (int)Math.Round((compact ? 36 : 48) * unit);
        mark.Bounds = new Rectangle((int)Math.Round((compact ? 24 : 40) * unit), (int)Math.Round((compact ? 10 : 42) * unit), size, size);
    }
    protected override void OnPaintBackground(PaintEventArgs e)
    {
        if (Width < 2 || Height < 2) return;
        if (colors.Contrast) { e.Graphics.Clear(colors.Background); return; }
        e.Graphics.Clear(Color.FromArgb(23, 59, 114));
        void Glow(RectangleF bounds, Color color)
        {
            using var path = new GraphicsPath(); path.AddEllipse(bounds);
            using var brush = new PathGradientBrush(path) { CenterColor = color, SurroundColors = [Color.FromArgb(0, color)] };
            e.Graphics.FillPath(brush, path);
        }
        Glow(new RectangleF(-Width * .9F, Height * .1F, Width * 2.1F, Height * 1.4F), Color.FromArgb(63, 132, 165));
        Glow(new RectangleF(Width * .05F, -Height * .85F, Width * 1.9F, Height * 1.9F), Color.FromArgb(93, 84, 173));
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e); var unit = DeviceDpi / 96F; var ink = colors.Contrast ? colors.Text : Color.White;
        var x = mark.Right + (int)Math.Round(13 * unit);
        TextRenderer.DrawText(e.Graphics, "Domenia", title, new Point(x, mark.Top - (int)Math.Round(2 * unit)), ink);
        TextRenderer.DrawText(e.Graphics, "Active Directory", subtitle, new Point(x + 1, mark.Top + (int)Math.Round(29 * unit)), colors.Contrast ? ink : Color.FromArgb(216, 229, 251));
        if (compact || Width < 220 * unit || Height < 320 * unit) return;
        DrawDirectory(e.Graphics, unit);
    }
    private void DrawDirectory(Graphics g, float unit)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var state = g.Save();
        var scale = Math.Min((Width - 64 * unit) / 370F, (Height - 180 * unit) / 260F);
        g.TranslateTransform((Width - 370 * scale) / 2, Math.Max(135 * unit, (Height - 230 * scale) / 2)); g.ScaleTransform(scale, scale);
        var line = colors.Contrast ? colors.Text : Color.FromArgb(110, 215, 232, 255);
        using (var orbit = new Pen(colors.Contrast ? line : Color.FromArgb(38, 255, 255, 255), 1))
        { var oval = g.Save(); g.TranslateTransform(185, 120); g.RotateTransform(-24); g.DrawEllipse(orbit, -147, -90, 294, 180); g.Restore(oval); }
        void Card(RectangleF bounds, float rotation, bool front)
        {
            var cardState = g.Save(); g.TranslateTransform(bounds.X, bounds.Y); g.RotateTransform(rotation);
            var box = new RectangleF(0, 0, bounds.Width, bounds.Height);
            using var shape = LoginBrandMark.Rounded(box, 16);
            using var fill = new SolidBrush(colors.Contrast ? colors.Background : front ? Color.FromArgb(39, 78, 127) : Color.FromArgb(28, 255, 255, 255));
            using var border = new Pen(line, 1); g.FillPath(fill, shape); g.DrawPath(border, shape);
            using var icon = new Pen(colors.Contrast ? colors.Text : Color.White, 1.7F) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
            using var rule = new Pen(colors.Contrast ? colors.Text : Color.FromArgb(95, 208, 226, 250), 5) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            if (front)
            {
                using var avatar = LoginBrandMark.Rounded(new RectangleF(22, 22, 44, 50), 11);
                using var shade = new SolidBrush(colors.Contrast ? colors.Background : Color.FromArgb(24, 255, 255, 255)); g.FillPath(shade, avatar);
                g.DrawEllipse(icon, 38, 33, 12, 12); g.DrawArc(icon, 33, 47, 22, 26, 180, 180);
                g.DrawLine(rule, 82, 33, 220, 33); g.DrawLine(rule, 82, 49, 196, 49); g.DrawLine(rule, 82, 65, 164, 65);
                using var badge = new SolidBrush(colors.Contrast ? colors.Accent : Color.FromArgb(213, 242, 233)); g.FillEllipse(badge, 275, 27, 34, 34);
                using var check = new Pen(colors.Contrast ? colors.OnAccent : Color.FromArgb(23, 91, 69), 2) { StartCap = LineCap.Round, EndCap = LineCap.Round };
                g.DrawLines(check, [new PointF(285, 44), new PointF(290, 49), new PointF(299, 39)]);
            }
            else
            {
                // Directory hierarchy: one root and two child units, not an authorization status.
                g.DrawRectangle(icon, 23, 19, 14, 11); g.DrawLine(icon, 30, 31, 30, 39); g.DrawLine(icon, 20, 39, 40, 39);
                g.DrawRectangle(icon, 15, 40, 10, 8); g.DrawRectangle(icon, 35, 40, 10, 8);
                g.DrawLine(rule, 23, 65, 199, 65); g.DrawLine(rule, 23, 80, 144, 80);
            }
            g.Restore(cardState);
        }
        Card(new RectangleF(102, 12, 250, 105), 6, false);
        Card(new RectangleF(8, 132, 333, 96), -4, true);
        g.Restore(state);
    }
    protected override void Dispose(bool disposing)
    { if (disposing) { title.Dispose(); subtitle.Dispose(); } base.Dispose(disposing); }
}
