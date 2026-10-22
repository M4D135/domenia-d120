using System.Runtime.InteropServices;
using Domenia.Core;

namespace Domenia.App;

/// <summary>
/// Title and frame of the main window following the page (Domenia 1 TRV-011 and TRV-050): « Page · cible — Domenia — Simulation »,
/// the dark title bar of Windows (DWM) for the dark and high contrast themes, and on Windows 11 the caption colours of the theme.
/// Nothing global is changed; a refusal of DWM (older Windows) is ignored, never raised.
/// </summary>
internal static partial class WindowChrome
{
    private const int DwmUseImmersiveDarkMode = 20;
    private const int DwmUseImmersiveDarkModeBefore20H1 = 19;
    private const int DwmBorderColor = 34;
    private const int DwmCaptionColor = 35;
    private const int DwmTextColor = 36;

    private static readonly Lock Gate = new();
    private static string? baseTitle;

    /// <summary>Applies the page's title and theme on the UI thread of the main window; false when no window is open.</summary>
    public static bool Apply(string? page, bool writeActive, AppMode mode, bool dark, string? caption, string? text)
    {
        var form = Application.OpenForms.Count > 0 ? Application.OpenForms[0] : null;
        if (form is null || form.IsDisposed || !form.IsHandleCreated)
        {
            return false;
        }
        var captionColor = ShellTexts.ColorRef(caption);
        var textColor = ShellTexts.ColorRef(text);
        try
        {
            form.BeginInvoke(() =>
            {
                if (form.IsDisposed)
                {
                    return;
                }
                string title;
                lock (Gate)
                {
                    // The first title is the one the host set (« Domenia — Simulation », E2E suffix included): it stays the base.
                    baseTitle ??= form.Text;
                    title = ShellTexts.WindowTitle(page, baseTitle, writeActive, mode);
                }
                if (!string.Equals(form.Text, title, StringComparison.Ordinal))
                {
                    form.Text = title;
                }
                SetFrame(form.Handle, dark, captionColor, textColor);
            });
            return true;
        }
        catch (InvalidOperationException ex)
        {
            // The window closed between the check and the call (ObjectDisposedException included).
            TechnicalLog.Warning($"Barre de titre non mise à jour : fenêtre fermée ({ex.GetType().Name}).");
            return false;
        }
    }

    private static void SetFrame(IntPtr handle, bool dark, int? caption, int? text)
    {
        try
        {
            var value = dark ? 1 : 0;
            if (DwmSetWindowAttribute(handle, DwmUseImmersiveDarkMode, ref value, sizeof(int)) != 0)
            {
                _ = DwmSetWindowAttribute(handle, DwmUseImmersiveDarkModeBefore20H1, ref value, sizeof(int));
            }
            // Windows 11 only; older systems answer an error code that is ignored.
            if (caption is int captionValue)
            {
                _ = DwmSetWindowAttribute(handle, DwmCaptionColor, ref captionValue, sizeof(int));
                var border = captionValue;
                _ = DwmSetWindowAttribute(handle, DwmBorderColor, ref border, sizeof(int));
            }
            if (text is int textValue)
            {
                _ = DwmSetWindowAttribute(handle, DwmTextColor, ref textValue, sizeof(int));
            }
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            TechnicalLog.Warning($"Barre de titre : thème Windows non appliqué ({ex.GetType().Name}).");
        }
    }

    [LibraryImport("dwmapi.dll")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static partial int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}
