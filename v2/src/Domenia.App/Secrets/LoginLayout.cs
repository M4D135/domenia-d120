using System.Drawing;

namespace Domenia.App.Secrets;

internal static class LoginLayout
{
    internal static Size Minimum(Size area, Size chrome, int dpi) => new(
        Math.Min(area.Width, Scale(640, dpi) + chrome.Width), Math.Min(area.Height, Scale(440, dpi) + chrome.Height));
    internal static bool Compact(Size client, int dpi) => client.Width < Scale(820, dpi) || client.Height < Scale(540, dpi);
    internal static Point Position(Rectangle area, Size size, Point desired) => new(
        Math.Clamp(desired.X, area.Left, Math.Max(area.Left, area.Right - size.Width)),
        Math.Clamp(desired.Y, area.Top, Math.Max(area.Top, area.Bottom - size.Height)));
    private static int Scale(int value, int dpi) => (int)Math.Round(value * Math.Clamp(dpi, 96, 768) / 96d);
}
