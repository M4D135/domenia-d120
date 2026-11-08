using System.Collections.Immutable;
using System.Diagnostics;
using System.Text.Json;

namespace Domenia.App.Capture;

/// <summary>One gesture of a step: an optional constant script, then a constant condition awaited until it is true.</summary>
/// <param name="Description">French label used in capture.log when the gesture fails or times out.</param>
/// <param name="Script">Constant script returning true once applied (retried while it returns anything else).</param>
/// <param name="Condition">Constant script returning true when the page shows the expected state.</param>
internal sealed record CaptureAction(string Description, string? Script, string Condition);

/// <summary>
/// One image of the sequence: its file name (without .png) and the gestures that prepare it. A step with
/// <paramref name="SkipWhen"/> is optional: when that constant condition is true (a page that does not scroll for a
/// « bas » image), no image is expected and the step is reported as « sans objet ».
/// </summary>
internal sealed record CaptureStep(string Name, string Label, ImmutableArray<CaptureAction> Actions, string? SkipWhen = null);

/// <summary>Builds the script of a constant function applied to JSON-encoded arguments (never concatenated as text).</summary>
internal static class CaptureScript
{
    /// <summary>
    /// « (function)("arg") »: each argument is a JSON string literal (quotes, backslashes, angle brackets and non-ASCII
    /// characters escaped by the encoder), so a value can only ever be data for the constant function.
    /// </summary>
    public static string Call(string function, params ReadOnlySpan<string> arguments)
    {
        ArgumentException.ThrowIfNullOrEmpty(function);
        var encoded = new string[arguments.Length];
        for (var i = 0; i < arguments.Length; i++)
        {
            encoded[i] = JsonSerializer.Serialize(arguments[i]);
        }
        return "(" + function + ")(" + string.Join(", ", encoded) + ")";
    }
}

/// <summary>
/// Steps of one capture run: the default sequence, then one image per extra screen and theme (« ecran-&lt;écran&gt;-&lt;thème&gt; »)
/// with its optional « milieu » variant (page taller than two screens) and « bas » variant (page that scrolls), so the
/// middle of a long page is never missing from the images (docs/CAPTURE.md § 2).
/// </summary>
internal sealed class CapturePlan
{
    private CapturePlan(ImmutableArray<CaptureStep> steps) => Steps = steps;

    public static CapturePlan Default { get; } = new(CaptureSequence.Steps);

    public ImmutableArray<CaptureStep> Steps { get; }

    /// <summary>Last resort: the process ends with code 2 even if WebView2 or the window never answers again.</summary>
    public TimeSpan Watchdog => CaptureSequence.StartupLimit + (CaptureSequence.StepLimit * Steps.Length) + TimeSpan.FromSeconds(30);

    public static CapturePlan For(IReadOnlyList<CaptureRoute> routes, IReadOnlyList<CaptureTheme> themes)
    {
        ArgumentNullException.ThrowIfNull(routes);
        ArgumentNullException.ThrowIfNull(themes);
        if (routes.Count == 0)
        {
            return Default;
        }
        var steps = ImmutableArray.CreateBuilder<CaptureStep>(CaptureSequence.Steps.Length + (routes.Count * themes.Count * 3));
        steps.AddRange(CaptureSequence.Steps);
        foreach (var route in routes)
        {
            foreach (var theme in themes)
            {
                var name = "ecran-" + route.FileStem + "-" + CaptureThemes.FileSuffix(theme);
                var label = $"Écran {route.Value}, {CaptureThemes.Label(theme)}";
                steps.Add(new CaptureStep(name, label, CaptureSequence.RouteActions(route, theme)));
                steps.Add(new CaptureStep(name + "-milieu", label + ", défilé jusqu’au milieu", CaptureSequence.MiddleActions, CaptureSequence.NoMiddle));
                steps.Add(new CaptureStep(name + "-bas", label + ", défilé jusqu’en bas", CaptureSequence.BottomActions, CaptureSequence.NotScrollable));
            }
        }
        return new CapturePlan(steps.ToImmutable());
    }
}

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
    private const string ScrollMiddle = "(() => { const m = document.querySelector('.main'); if (!m) return false; m.scrollTo({ top: Math.round((m.scrollHeight - m.clientHeight) / 2), behavior: 'instant' }); return true; })()";
    private const string AtMiddle = "(() => { const m = document.querySelector('.main'); return !!m && Math.abs(m.scrollTop - Math.round((m.scrollHeight - m.clientHeight) / 2)) <= 1; })()";
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
    private const string Unfold = "(() => { const t = document.querySelector('.nav-toggle'); const s = document.querySelector('.shell'); if (!t || !s) return false; if (s.classList.contains('nav-collapsed')) t.click(); return true; })()";
    private const string Unfolded = "document.querySelector('.shell')?.classList.contains('nav-collapsed') === false";

    // Extra screens (--capture-routes, --capture-themes): constant functions, applied by CaptureScript.Call to the
    // JSON-encoded route or theme. Routes are checked by CaptureRoute.Pattern before they get here.
    // Leaving a route clears data-ready at once: the condition can never see the readiness of the previous screen.
    private const string GoRouteFunction = "(route) => { const target = '#/' + route; if (location.hash !== target) { delete document.documentElement.dataset.ready; location.hash = target; } return true; }";
    private const string RouteReadyFunction = "(name) => " + Loaded + "name";
    private const string ClickThemeFunction = "(theme) => { const b = Array.from(document.querySelectorAll('.theme-switch button[data-set]')).find((x) => x.dataset.set === theme); if (!b) return false; b.click(); return true; }";
    private const string IsThemeFunction = "(theme) => document.documentElement.dataset.theme === theme";

    /// <summary>True when the screen does not scroll: its « bas » image would repeat the first one.</summary>
    public const string NotScrollable = "(() => { const m = document.querySelector('.main'); return !!m && m.scrollHeight - m.clientHeight <= 1; })()";

    /// <summary>True when the screen is at most two viewports tall: its top and bottom images already show all of it.</summary>
    public const string NoMiddle = "(() => { const m = document.querySelector('.main'); return !!m && m.scrollHeight <= 2 * m.clientHeight; })()";

    private static readonly CaptureAction WaitHome = new("attente de l’écran Accueil et de ses données", null, HomeReady);
    private static readonly CaptureAction WaitMotion = new("vérification des animations réduites", null, MotionReduced);
    private static readonly CaptureAction Dark = new("passage au thème sombre", ClickDark, IsDark);
    private static readonly CaptureAction Light = new("passage au thème clair", ClickLight, IsLight);
    private static readonly CaptureAction Contrast = new("passage au contraste élevé", ClickContrast, IsContrast);
    private static readonly CaptureAction Bottom = new("défilement en bas de l’écran", ScrollEnd, AtEnd);
    private static readonly CaptureAction Middle = new("défilement au milieu de l’écran", ScrollMiddle, AtMiddle);
    private static readonly CaptureAction Top = new("retour en haut de l’écran", ScrollTop, AtTop);
    private static readonly CaptureAction Palette = new("ouverture de la palette de commandes", OpenPalette, PaletteOpen);
    private static readonly CaptureAction PaletteAway = new("fermeture de la palette de commandes", ClosePalette, PaletteClosed);
    private static readonly CaptureAction Search = new("ouverture de l’écran Rechercher et de ses données", GoSearch, SearchReady);
    private static readonly CaptureAction Fold = new("repli du menu", Collapse, Collapsed);
    private static readonly CaptureAction Unfolding = new("dépliage du menu", Unfold, Unfolded);

    /// <summary>« bas » image of an extra screen: scrolled to the bottom (taken only when the screen scrolls).</summary>
    public static ImmutableArray<CaptureAction> BottomActions { get; } = [Bottom];

    /// <summary>« milieu » image of an extra screen: scrolled half way (taken only when the screen is over two viewports).</summary>
    public static ImmutableArray<CaptureAction> MiddleActions { get; } = [Middle];

    /// <summary>First image of an extra screen in a theme: menu unfolded, screen ready with its data, theme, top.</summary>
    public static ImmutableArray<CaptureAction> RouteActions(CaptureRoute route, CaptureTheme theme)
    {
        ArgumentNullException.ThrowIfNull(route);
        var id = CaptureThemes.Id(theme);
        return
        [
            Unfolding,
            new($"ouverture de l’écran {route.Name} et de ses données", CaptureScript.Call(GoRouteFunction, route.Value), CaptureScript.Call(RouteReadyFunction, route.Name)),
            new($"passage au {CaptureThemes.Label(theme)}", CaptureScript.Call(ClickThemeFunction, id), CaptureScript.Call(IsThemeFunction, id)),
            Top,
        ];
    }

    /// <summary>The eight images, in order; each step starts from the state left by the previous one.</summary>
    public static ImmutableArray<CaptureStep> Steps { get; } =
    [
        new("accueil-sombre", "Accueil, thème sombre", [WaitHome, WaitMotion, Dark]),
        new("accueil-clair", "Accueil, thème clair", [Light]),
        new("accueil-contraste", "Accueil, contraste élevé", [Contrast]),
        new("accueil-milieu", "Accueil défilé jusqu’au milieu (parc de l’OU), thème sombre", [Dark, Middle]),
        new("accueil-bas", "Accueil défilé jusqu’en bas, thème sombre", [Bottom]),
        new("palette", "Palette de commandes ouverte sur l’Accueil", [Top, Palette]),
        new("page-a-porter", "Écran Rechercher (en cours de portage)", [PaletteAway, Search]),
        new("menu-replie", "Menu replié sur l’écran Rechercher", [Fold]),
    ];
}
