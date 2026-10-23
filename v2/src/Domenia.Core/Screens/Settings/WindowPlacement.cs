using System.Globalization;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>A working area of a screen of this workstation, in device pixels (taskbar excluded).</summary>
public sealed record ScreenArea(int X, int Y, int Width, int Height);

/// <summary>Size, position and state of the main window (Domenia 1 Save-DomeniaWindowGeometry), in device pixels.</summary>
public sealed record WindowPlacement(int X, int Y, int Width, int Height, bool Maximized);

/// <summary>Result of settings.window: the zoom of the interface and the remembered window.</summary>
public sealed record WindowSettingsView(int Zoom, int Minimum, int Maximum, int Step, bool Native, bool Available, string? Reason, bool Remembered, string Window, string Text);

/// <summary>
/// Pure rules of the zoom of the interface (PAR-009) and of the geometry of the window (PAR-051): bounds and steps of the
/// zoom, stored forms, and the placement brought back onto a screen when the monitor it was on is gone
/// (Restore-DomeniaWindowGeometry). No WinForms here: the host gives the working areas of its screens.
/// </summary>
public static class WindowRules
{
    /// <summary>Zoom step of the buttons and of the keyboard of the page (Domenia 1: 10 %).</summary>
    public const int ZoomStep = 10;

    /// <summary>Smallest window of Domenia (MainForm.MinimumSize).</summary>
    public const int MinWidth = 640;
    public const int MinHeight = 420;

    /// <summary>Part of the title bar that must stay on a screen for the window to be reachable.</summary>
    public const int VisibleStrip = 120;
    public const int TitleHeight = 32;

    /// <summary>The stored zoom, or 100 % when absent or unreadable (never a guessed value).</summary>
    public static int ReadZoom(JsonElement? stored) =>
        stored is JsonElement value && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var zoom) && zoom is >= PreferenceApproval.ZoomMinimum and <= PreferenceApproval.ZoomMaximum
            ? zoom
            : 100;

    /// <summary>A zoom brought into its bounds (80 to 150 %).</summary>
    public static int ClampZoom(double percent) =>
        double.IsFinite(percent) ? (int)Math.Clamp(Math.Round(percent), PreferenceApproval.ZoomMinimum, PreferenceApproval.ZoomMaximum) : 100;

    /// <summary>The stored placement, or null when absent or unreadable.</summary>
    public static WindowPlacement? ReadPlacement(JsonElement? stored)
    {
        if (stored is not JsonElement root || root.ValueKind != JsonValueKind.Object)
        {
            return null;
        }
        static int? Number(JsonElement root, string name) =>
            root.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n) ? n : null;
        var x = Number(root, "x");
        var y = Number(root, "y");
        var width = Number(root, "width");
        var height = Number(root, "height");
        if (x is null || y is null || width is null || height is null || width < MinWidth / 2 || height < MinHeight / 2 || width > 32_768 || height > 32_768
            || Math.Abs((long)x.Value) > 65_536 || Math.Abs((long)y.Value) > 65_536)
        {
            return null;
        }
        var maximized = root.TryGetProperty("maximized", out var m) && m.ValueKind == JsonValueKind.True;
        return new WindowPlacement(x.Value, y.Value, width.Value, height.Value, maximized);
    }

    /// <summary>Stored form of a placement (fixed order).</summary>
    public static JsonElement ToJson(WindowPlacement placement)
    {
        ArgumentNullException.ThrowIfNull(placement);
        return JsonSerializer.SerializeToElement(new Dictionary<string, object>
        {
            ["x"] = placement.X,
            ["y"] = placement.Y,
            ["width"] = placement.Width,
            ["height"] = placement.Height,
            ["maximized"] = placement.Maximized,
        });
    }

    /// <summary>
    /// Where the window goes back: the screen containing its title bar, with the whole window brought into that area;
    /// otherwise (monitor removed, resolution changed, a gap in an L-shaped layout) centered on the
    /// primary screen. The maximized state is kept.
    /// </summary>
    public static WindowPlacement Fit(WindowPlacement saved, IReadOnlyList<ScreenArea> areas, ScreenArea primary)
    {
        ArgumentNullException.ThrowIfNull(saved);
        ArgumentNullException.ThrowIfNull(areas);
        ArgumentNullException.ThrowIfNull(primary);
        ScreenArea? host = null;
        foreach (var area in areas)
        {
            var left = Math.Max(saved.X, area.X);
            var right = Math.Min(saved.X + saved.Width, area.X + area.Width);
            var top = Math.Max(saved.Y, area.Y);
            var bottom = Math.Min(saved.Y + TitleHeight, area.Y + area.Height);
            if (right - left >= VisibleStrip && bottom - top >= TitleHeight / 2)
            {
                host = area;
                break;
            }
        }
        var target = host ?? primary;
        var width = Math.Min(Math.Max(saved.Width, Math.Min(MinWidth, target.Width)), target.Width);
        var height = Math.Min(Math.Max(saved.Height, Math.Min(MinHeight, target.Height)), target.Height);
        if (host is null)
        {
            return new WindowPlacement(target.X + (target.Width - width) / 2, target.Y + (target.Height - height) / 2, width, height, saved.Maximized);
        }
        var x = Math.Clamp(saved.X, target.X, target.X + target.Width - width);
        var y = Math.Clamp(saved.Y, target.Y, target.Y + target.Height - height);
        return new WindowPlacement(x, y, width, height, saved.Maximized);
    }

    /// <summary>« 1 440 × 900 px, agrandie » (or « …, position 120 ; 80 ») for the page, or a sentence when nothing is remembered.</summary>
    public static string Describe(WindowPlacement? placement) =>
        placement is null
            ? "Taille et position par défaut (aucune fenêtre mémorisée)."
            : FrenchText.Integer(placement.Width) + " × " + FrenchText.Integer(placement.Height) + FrenchText.Nbsp + "px"
              + (placement.Maximized ? ", agrandie" : ", position " + placement.X.ToString(CultureInfo.InvariantCulture) + FrenchText.Nbsp + "; " + placement.Y.ToString(CultureInfo.InvariantCulture));
}
