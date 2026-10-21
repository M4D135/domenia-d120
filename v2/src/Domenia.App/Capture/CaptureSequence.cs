using System.Collections.Immutable;
using System.Diagnostics;

namespace Domenia.App.Capture;

/// <summary>One gesture of a step: an optional constant script, then a constant condition awaited until it is true.</summary>
/// <param name="Description">French label used in capture.log when the gesture fails or times out.</param>
/// <param name="Script">Constant script returning true once applied (retried while it returns anything else).</param>
/// <param name="Condition">Constant script returning true when the page shows the expected state.</param>
internal sealed record CaptureAction(string Description, string? Script, string Condition);

/// <summary>One image of the sequence: its file name (without .png) and the gestures that prepare it.</summary>
internal sealed record CaptureStep(string Name, string Label, ImmutableArray<CaptureAction> Actions);

/// <summary>
/// The fixed capture sequence (docs/CAPTURE.md). Every script given to WebView2 is a compile-time constant of this
/// class: nothing from the command line or from the page is ever executed.
/// </summary>
internal static class CaptureSequence
{
    /// <summary>Viewport of the page, in CSS pixels (device pixels at 100 %).</summary>
    public static readonly Size Viewport = new(1600, 1000);

    /// <summary>One budget for the whole start: environment, control and profile preparation together.</summary>
    public static readonly TimeSpan StartupLimit = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan StepLimit = TimeSpan.FromSeconds(20);
    public static readonly TimeSpan Poll = TimeSpan.FromMilliseconds(100);

    /// <summary>Pause between the expected state and the image, so the last frame is painted.</summary>
    public static readonly TimeSpan Settle = TimeSpan.FromMilliseconds(400);

    /// <summary>Last resort: the process ends with code 2 even if WebView2 or the window never answers again.</summary>
    public static TimeSpan Watchdog => StartupLimit + (StepLimit * Steps.Length) + TimeSpan.FromSeconds(30);

    /// <summary>What is left of the startup budget begun at <paramref name="began"/> (a Stopwatch timestamp).</summary>
    public static TimeSpan StartupLeft(long began)
    {
        var left = StartupLimit - Stopwatch.GetElapsedTime(began);
        return left > TimeSpan.Zero ? left : TimeSpan.Zero;
    }

    /// <summary>
    /// Runs before any script of the page, in the capture profile only (never the operator's): dark theme, reduced
    /// animations, menu unfolded. Same key and values as web/js/app.js and web/js/boot.js.
    /// </summary>
    public const string PresetPreferences = """try { localStorage.setItem('domenia.prefs.v1', JSON.stringify({ theme: 'dark', motion: 'reduced', navCollapsed: false })); } catch (err) { console.error(err); }""";

    /// <summary>Viewport seen by the page: [width, height, devicePixelRatio].</summary>
    public const string ViewportProbe = "[innerWidth, innerHeight, devicePixelRatio]";

    /// <summary>
    /// True when the screen shows an error instead of some content (the image is kept, with a warning): error card,
    /// any alert region (failed list of a screen being ported), widget that could not be displayed.
    /// </summary>
    public const string ErrorProbe = "document.querySelector('.main .error-card, .main [role=\"alert\"], .main .is-broken') !== null";

    // Readiness: the router sets <html data-ready="<route>"> once the route is rendered and its data loaded.
    private const string Loaded = "document.readyState === 'complete' && document.fonts.status === 'loaded' && document.documentElement.dataset.ready === ";
    private const string HomeReady = Loaded + "'accueil'";
    private const string SearchReady = Loaded + "'rechercher'";
    private const string MotionReduced = "document.documentElement.dataset.motion === 'reduced'";

    private const string ClickDark = """(() => { const b = document.querySelector('.theme-switch button[data-set="dark"]'); if (!b) return false; b.click(); return true; })()""";
    private const string ClickLight = """(() => { const b = document.querySelector('.theme-switch button[data-set="light"]'); if (!b) return false; b.click(); return true; })()""";
    private const string ClickContrast = """(() => { const b = document.querySelector('.theme-switch button[data-set="contrast"]'); if (!b) return false; b.click(); return true; })()""";
    private const string IsDark = "document.documentElement.dataset.theme === 'dark'";
    private const string IsLight = "document.documentElement.dataset.theme === 'light'";
    private const string IsContrast = "document.documentElement.dataset.theme === 'contrast'";

    // .main scrolls smoothly by default: the jump is explicit (behavior: 'instant').
    private const string ScrollEnd = "(() => { const m = document.querySelector('.main'); if (!m) return false; m.scrollTo({ top: m.scrollHeight, behavior: 'instant' }); return true; })()";
    private const string AtEnd = "(() => { const m = document.querySelector('.main'); return !!m && m.scrollHeight - m.clientHeight - m.scrollTop <= 1; })()";
    private const string ScrollTop = "(() => { const m = document.querySelector('.main'); if (!m) return false; m.scrollTo({ top: 0, behavior: 'instant' }); return true; })()";
    private const string AtTop = "(() => { const m = document.querySelector('.main'); return !!m && m.scrollTop <= 0; })()";

    // The search field of the top bar opens the palette exactly as Ctrl+K does, without toggling it closed.
    private const string OpenPalette = "(() => { const b = document.querySelector('.search-trigger'); if (!b) return false; b.click(); return true; })()";
    private const string PaletteOpen = "(() => { const p = document.querySelector('.palette-backdrop'); return !!p && !p.hidden && !p.classList.contains('closing') && p.querySelector('.results .item') !== null; })()";
    private const string ClosePalette = "(() => { const i = document.querySelector('.palette-backdrop input'); if (!i) return false; i.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); return true; })()";
    private const string PaletteClosed = "(() => { const p = document.querySelector('.palette-backdrop'); return !p || p.hidden; })()";

    private const string GoSearch = "(() => { location.hash = '#/rechercher'; return true; })()";

    // Clicked only while unfolded: the button toggles.
    private const string Collapse = "(() => { const t = document.querySelector('.nav-toggle'); const s = document.querySelector('.shell'); if (!t || !s) return false; if (!s.classList.contains('nav-collapsed')) t.click(); return true; })()";
    private const string Collapsed = "document.querySelector('.shell')?.classList.contains('nav-collapsed') === true";

    private static readonly CaptureAction WaitHome = new("attente de l’écran Accueil et de ses données", null, HomeReady);
    private static readonly CaptureAction WaitMotion = new("vérification des animations réduites", null, MotionReduced);
    private static readonly CaptureAction Dark = new("passage au thème sombre", ClickDark, IsDark);
    private static readonly CaptureAction Light = new("passage au thème clair", ClickLight, IsLight);
    private static readonly CaptureAction Contrast = new("passage au contraste élevé", ClickContrast, IsContrast);
    private static readonly CaptureAction Bottom = new("défilement en bas de l’écran", ScrollEnd, AtEnd);
    private static readonly CaptureAction Top = new("retour en haut de l’écran", ScrollTop, AtTop);
    private static readonly CaptureAction Palette = new("ouverture de la palette de commandes", OpenPalette, PaletteOpen);
    private static readonly CaptureAction PaletteAway = new("fermeture de la palette de commandes", ClosePalette, PaletteClosed);
    private static readonly CaptureAction Search = new("ouverture de l’écran Rechercher et de ses données", GoSearch, SearchReady);
    private static readonly CaptureAction Fold = new("repli du menu", Collapse, Collapsed);

    /// <summary>The seven images, in order; each step starts from the state left by the previous one.</summary>
    public static ImmutableArray<CaptureStep> Steps { get; } =
    [
        new("accueil-sombre", "Accueil, thème sombre", [WaitHome, WaitMotion, Dark]),
        new("accueil-clair", "Accueil, thème clair", [Light]),
        new("accueil-contraste", "Accueil, contraste élevé", [Contrast]),
        new("accueil-bas", "Accueil défilé jusqu’en bas, thème sombre", [Dark, Bottom]),
        new("palette", "Palette de commandes ouverte sur l’Accueil", [Top, Palette]),
        new("page-a-porter", "Écran Rechercher (en cours de portage)", [PaletteAway, Search]),
        new("menu-replie", "Menu replié sur l’écran Rechercher", [Fold]),
    ];
}
