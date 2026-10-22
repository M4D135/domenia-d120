using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.Json;
using Domenia.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Domenia.App.Settings;

/// <summary>
/// Zoom of the interface (Domenia 1 PAR-009) and geometry of the main window (PAR-051), kept in the local preferences of the
/// mode (« settings.zoom », « settings.window »). The zoom is the native zoom of WebView2 (the whole window, the media queries
/// of every screen follow it; Ctrl + wheel, Ctrl +, Ctrl − and Ctrl 0 of WebView2 work on every keyboard layout), kept between
/// 80 and 150 %. At the first idle moment of the UI thread, the remembered window comes back, brought onto a screen when its
/// monitor is gone, and the remembered zoom is applied. Never in a capture or an E2E run (fixed geometry, zoom 100 %), never
/// with memory-only preferences. Every failure is traced and leaves the window as it is.
/// </summary>
internal static class HostWindow
{
    private static readonly Lock Gate = new();
    private static IPreferenceStore? preferences;
    private static Task<(int Zoom, WindowPlacement? Placement)>? loading;
    private static Form? form;
    private static WebView2? view;
    private static int zoom = 100;
    private static WindowPlacement? remembered;
    private static bool forgotten;
    private static bool dirty;
    private static System.Windows.Forms.Timer? saveTimer;
    private static FormWindowState lastState = FormWindowState.Normal;

    /// <summary>Why the zoom cannot be set now, or null when it can.</summary>
    public static string? Unavailable
    {
        get
        {
            if (HostFacts.Unattended)
            {
                return "Capture ou scénario E2E en cours" + FrenchText.Colon + "le zoom reste à 100" + FrenchText.Nbsp + "%.";
            }
            lock (Gate)
            {
                return preferences is null
                    ? "Préférences en mémoire seulement" + FrenchText.Colon + "le zoom de la fenêtre n’est pas mémorisé dans cette session."
                    : view is null ? "Fenêtre pas encore prête" + FrenchText.Colon + "réessayez dans un instant." : null;
            }
        }
    }

    /// <summary>The zoom applied now (percent).</summary>
    public static int Zoom
    {
        get
        {
            lock (Gate)
            {
                return zoom;
            }
        }
    }

    /// <summary>The remembered placement of the window (null when none).</summary>
    public static WindowPlacement? Remembered
    {
        get
        {
            lock (Gate)
            {
                return forgotten ? null : remembered;
            }
        }
    }

    /// <summary>Called once at the composition, on the UI thread: reads the remembered values off that thread, then waits for the window.</summary>
    public static void Attach(IPreferenceStore store)
    {
        ArgumentNullException.ThrowIfNull(store);
        if (HostFacts.Unattended || !store.Persistent)
        {
            return;
        }
        lock (Gate)
        {
            if (preferences is not null)
            {
                return;
            }
            preferences = store;
            // The preferences document is read on first use: never on the UI thread.
            loading = Task.Run(() => (
                WindowRules.ReadZoom(store.TryGet(PreferenceApproval.ZoomKey, out var z) ? z : null),
                WindowRules.ReadPlacement(store.TryGet(PreferenceApproval.WindowKey, out var w) ? w : null)));
        }
        Application.Idle += OnIdle;
    }

    private static void OnIdle(object? sender, EventArgs e)
    {
        Task<(int Zoom, WindowPlacement? Placement)>? pending;
        lock (Gate)
        {
            pending = loading;
        }
        if (pending is null || !pending.IsCompleted || Application.OpenForms.Count == 0)
        {
            return;
        }
        var candidate = Application.OpenForms[0];
        if (candidate is null || candidate.IsDisposed || !candidate.IsHandleCreated)
        {
            return;
        }
        var webView = candidate.Controls.OfType<WebView2>().FirstOrDefault();
        if (webView is null)
        {
            return;
        }
        Application.Idle -= OnIdle;
        var (storedZoom, placement) = pending.IsCompletedSuccessfully ? pending.Result : (100, null);
        if (!pending.IsCompletedSuccessfully)
        {
            TechnicalLog.Warning("Zoom et fenêtre mémorisés illisibles : valeurs par défaut.");
        }
        try
        {
            lock (Gate)
            {
                form = candidate;
                view = webView;
                zoom = storedZoom;
                remembered = placement;
            }
            if (placement is not null)
            {
                Restore(candidate, placement);
            }
            lastState = candidate.WindowState;
            webView.ZoomFactor = storedZoom / 100.0;
            webView.ZoomFactorChanged += OnZoomChanged;
            candidate.ResizeEnd += (_, _) => MarkDirty();
            candidate.SizeChanged += (_, _) =>
            {
                if (candidate.WindowState != lastState)
                {
                    lastState = candidate.WindowState;
                    MarkDirty();
                }
            };
            candidate.FormClosing += (_, _) => SaveNow(wait: true);
            var timer = new System.Windows.Forms.Timer { Interval = 800 };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                SaveNow(wait: false);
            };
            saveTimer = timer;
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or Win32Exception or COMException)
        {
            TechnicalLog.Warning($"Zoom ou fenêtre mémorisés non appliqués ({ex.GetType().Name}).");
        }
    }

    /// <summary>The remembered window, brought onto a screen when its monitor is gone (Restore-DomeniaWindowGeometry).</summary>
    private static void Restore(Form target, WindowPlacement placement)
    {
        var screens = Screen.AllScreens.Select(s => new ScreenArea(s.WorkingArea.X, s.WorkingArea.Y, s.WorkingArea.Width, s.WorkingArea.Height)).ToList();
        var primary = Screen.PrimaryScreen?.WorkingArea ?? target.Bounds;
        var fit = WindowRules.Fit(placement, screens, new ScreenArea(primary.X, primary.Y, primary.Width, primary.Height));
        target.WindowState = FormWindowState.Normal;
        target.StartPosition = FormStartPosition.Manual;
        target.Bounds = new Rectangle(fit.X, fit.Y, fit.Width, fit.Height);
        if (fit.Maximized)
        {
            target.WindowState = FormWindowState.Maximized;
        }
    }

    /// <summary>Applies a zoom chosen in Paramètres (UI thread through the window); false when the window is not there.</summary>
    public static bool SetZoom(int percent)
    {
        Form? target;
        WebView2? webView;
        lock (Gate)
        {
            target = form;
            webView = view;
            // Remembered first: the change event that follows sees nothing new and does not write again.
            zoom = WindowRules.ClampZoom(percent);
        }
        if (target is null || webView is null || target.IsDisposed)
        {
            return false;
        }
        try
        {
            target.BeginInvoke(() =>
            {
                if (!webView.IsDisposed)
                {
                    webView.ZoomFactor = percent / 100.0;
                }
            });
            return true;
        }
        catch (InvalidOperationException ex)
        {
            TechnicalLog.Warning($"Zoom non appliqué : fenêtre fermée ({ex.GetType().Name}).");
            return false;
        }
    }

    /// <summary>Forgets the remembered window: default size and place at the next start, nothing saved until then.</summary>
    public static void Forget()
    {
        lock (Gate)
        {
            forgotten = true;
            remembered = null;
            dirty = false;
        }
    }

    // Ctrl + wheel and Ctrl +/−/0 of WebView2: kept between 80 and 150 %, then remembered.
    private static void OnZoomChanged(object? sender, EventArgs e)
    {
        if (sender is not WebView2 webView)
        {
            return;
        }
        var raw = webView.ZoomFactor * 100;
        var clamped = WindowRules.ClampZoom(raw);
        if (Math.Abs(raw - clamped) > 0.5)
        {
            webView.ZoomFactor = clamped / 100.0;
            return;
        }
        lock (Gate)
        {
            if (clamped == zoom)
            {
                return;
            }
            zoom = clamped;
        }
        Persist(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(clamped), wait: false);
    }

    private static void MarkDirty()
    {
        lock (Gate)
        {
            if (forgotten)
            {
                return;
            }
            dirty = true;
        }
        saveTimer?.Stop();
        saveTimer?.Start();
    }

    private static void SaveNow(bool wait)
    {
        Form? target;
        lock (Gate)
        {
            if (!dirty || forgotten || form is null)
            {
                return;
            }
            dirty = false;
            target = form;
        }
        if (target.WindowState == FormWindowState.Minimized)
        {
            return;
        }
        var bounds = target.WindowState == FormWindowState.Maximized ? target.RestoreBounds : target.Bounds;
        var placement = new WindowPlacement(bounds.X, bounds.Y, bounds.Width, bounds.Height, target.WindowState == FormWindowState.Maximized);
        lock (Gate)
        {
            remembered = placement;
        }
        Persist(PreferenceApproval.WindowKey, WindowRules.ToJson(placement), wait);
    }

    private static void Persist(string key, JsonElement value, bool wait)
    {
        IPreferenceStore? store;
        lock (Gate)
        {
            store = preferences;
        }
        if (store is null)
        {
            return;
        }
        var write = Task.Run(async () =>
        {
            try
            {
                await store.SetAsync(key, value, CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // The value holds for the session; the next change writes again.
                TechnicalLog.Warning($"Préférence {key} non enregistrée ({ex.GetType().Name}).");
            }
        });
        if (wait && !write.Wait(TimeSpan.FromSeconds(1)))
        {
            TechnicalLog.Warning($"Préférence {key} encore en cours d’écriture à la fermeture.");
        }
    }
}
