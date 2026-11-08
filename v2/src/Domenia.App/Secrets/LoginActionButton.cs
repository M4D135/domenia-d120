using System.Drawing.Drawing2D;

namespace Domenia.App.Secrets;

// Button retains its native HWND, keyboard handling, dialog semantics and accessibility object.
internal sealed class LoginActionButton : Button
{
    private LoginColors colors = LoginColors.For("light");
    private readonly Font? primaryFont;
    private bool hovered;
    private bool pressed;

    internal LoginActionButton(bool primary)
    {
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        UseVisualStyleBackColor = false;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        if (primary) { primaryFont = new Font("Segoe UI", 10.5F, FontStyle.Bold); Font = primaryFont; }
    }

    public override Size GetPreferredSize(Size proposedSize)
    {
        var unit = DeviceDpi / 96F;
        var horizontal = (int)Math.Round((Tag is LoginVisualRole.Primary ? 83 : 33) * unit);
        var width = proposedSize.Width > horizontal && proposedSize.Width < int.MaxValue ? proposedSize.Width - horizontal : int.MaxValue;
        var measured = TextRenderer.MeasureText(Text, Font, new Size(width, int.MaxValue), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
        return new Size(Math.Max(MinimumSize.Width, measured.Width + horizontal),
            Math.Max(MinimumSize.Height, measured.Height + (int)Math.Round(16 * unit)));
    }

    internal void SetColors(LoginColors value) { colors = value; Invalidate(); }
    protected override void OnMouseEnter(EventArgs e) { hovered = true; base.OnMouseEnter(e); Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { hovered = false; pressed = false; base.OnMouseLeave(e); Invalidate(); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) pressed = true; base.OnMouseDown(e); Invalidate(); }
    protected override void OnMouseUp(MouseEventArgs e) { pressed = false; base.OnMouseUp(e); Invalidate(); }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Space) pressed = true; base.OnKeyDown(e); Invalidate(); }
    protected override void OnKeyUp(KeyEventArgs e) { pressed = false; base.OnKeyUp(e); Invalidate(); }
    protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
    protected override void OnLostFocus(EventArgs e) { pressed = false; base.OnLostFocus(e); Invalidate(); }
    protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (Width < 2 || Height < 2) return;
        var g = e.Graphics;
        g.Clear(Parent?.BackColor ?? colors.Surface);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var unit = DeviceDpi / 96F;
        var primary = Tag is LoginVisualRole.Primary;
        var quiet = Tag is LoginVisualRole.Quiet;
        var inset = 4 * unit;
        var box = new RectangleF(inset, inset, Math.Max(1, Width - 2 * inset - 1), Math.Max(1, Height - 2 * inset - 1));
        using var shape = LoginBrandMark.Rounded(box, 11 * unit);
        var ink = Enabled ? primary ? colors.OnAccent : quiet ? colors.Muted : colors.Text : colors.Muted;
        var fill = primary ? colors.Accent : quiet ? Parent?.BackColor ?? colors.Surface : colors.Surface;
        if (!Enabled) fill = colors.Hover;
        else if (hovered || pressed) fill = primary ? colors.AccentHover : colors.Hover;
        if (primary && Enabled && !colors.Contrast)
        {
            using var gradient = new LinearGradientBrush(box,
                Color.FromArgb(hovered || pressed ? 6 : 7, hovered || pressed ? 78 : 95, hovered || pressed ? 171 : 197),
                hovered || pressed ? Color.FromArgb(73, 55, 193) : Color.FromArgb(91, 73, 214), 15F);
            g.FillPath(gradient, shape);
        }
        else { using var background = new SolidBrush(fill); g.FillPath(background, shape); }
        if (!quiet || colors.Contrast || hovered)
        {
            using var border = new Pen(colors.Contrast ? colors.ControlBorder : primary && Enabled ? Color.Transparent : colors.Border, Math.Max(1, unit));
            g.DrawPath(border, shape);
        }
        var textBox = Rectangle.Round(box);
        textBox.Inflate(-(int)Math.Round(12 * unit), 0);
        if (primary)
        {
            using var icon = new Pen(ink, 1.6F * unit) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
            var middle = box.Top + box.Height / 2;
            var left = box.Left + 17 * unit;
            g.DrawLines(icon, [new PointF(left, middle - 5 * unit), new PointF(left + 6 * unit, middle - 8 * unit),
                new PointF(left + 12 * unit, middle - 5 * unit), new PointF(left + 11 * unit, middle + 3 * unit),
                new PointF(left + 6 * unit, middle + 8 * unit), new PointF(left + unit, middle + 3 * unit), new PointF(left, middle - 5 * unit)]);
            g.DrawLines(icon, [new PointF(left + 3 * unit, middle), new PointF(left + 5 * unit, middle + 2 * unit), new PointF(left + 9 * unit, middle - 2 * unit)]);
            var right = box.Right - 21 * unit;
            g.DrawLines(icon, [new PointF(right, middle - 4 * unit), new PointF(right + 4 * unit, middle), new PointF(right, middle + 4 * unit)]);
            textBox.X += (int)Math.Round(28 * unit); textBox.Width -= (int)Math.Round(50 * unit);
        }
        TextRenderer.DrawText(g, Text, Font, textBox, ink,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
        if (Focused && ShowFocusCues)
        {
            using var outline = LoginBrandMark.Rounded(new RectangleF(unit, unit, Width - 2 * unit - 1, Height - 2 * unit - 1), 14 * unit);
            using var focus = new Pen(colors.Contrast ? colors.Text : colors.AccentText, 2 * unit);
            g.DrawPath(focus, outline);
        }
    }
    protected override void Dispose(bool disposing)
    { if (disposing) primaryFont?.Dispose(); base.Dispose(disposing); }
}
