using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Domenia.E2E.Driver;

/// <summary>
/// Scripts the harness evaluates in the page through the DevTools protocol. Every script is a constant; a value that
/// comes from a scenario (selector, text, route…) never becomes script text: it is passed as one JSON argument to a
/// constant function (<see cref="Call"/>), with an encoder that escapes quotes, angle brackets, « &amp; », « + », non
/// ASCII characters and line separators.
/// </summary>
internal static class PageScripts
{
    private static readonly JsonSerializerOptions ArgumentOptions = new() { Encoder = JavaScriptEncoder.Default, WriteIndented = false };

    /// <summary>Shared helpers, placed at the top of each function body (compile-time constant).</summary>
    private const string Prelude = """
        const norm = (s) => String(s ?? '').replace(/[\s  ]+/g, ' ').trim();
        const squash = (s) => String(s ?? '').replace(/[\s  ]+/g, '');
        // innerText applies CSS text-transform (table headers, captions in capitals): the visible text is compared without
        // case, while the exact case is still required in the DOM text (textContent), so a label must be written as asked.
        const fold = (s) => norm(s).toLocaleLowerCase('fr');
        const visibleHas = (el, text) => {
          const shownText = norm(el.innerText);
          const want = norm(text);
          if (shownText.includes(want)) return true;
          return fold(shownText).includes(fold(want)) && squash(el.textContent).includes(squash(text));
        };
        // Displayed, not visibility:hidden, non-empty box. As in Playwright, opacity does not hide: a card waiting for its
        // entrance animation below the fold (.reveal) is there, and scrolling to it plays the animation.
        const shown = (el) => {
          if (!(el instanceof Element) || !el.isConnected) return false;
          if (typeof el.checkVisibility === 'function' && !el.checkVisibility({ visibilityProperty: true })) return false;
          const r = el.getBoundingClientRect();
          return r.width > 0 && r.height > 0;
        };
        const describe = (el) => {
          if (!(el instanceof Element)) return el === null ? 'rien' : String(el);
          let d = el.tagName.toLowerCase();
          if (el.id) d += '#' + el.id;
          const cls = [...el.classList].slice(0, 3);
          if (cls.length) d += '.' + cls.join('.');
          const t = norm(el.getAttribute('aria-label') || el.innerText || '').slice(0, 60);
          return t ? d + ' « ' + t + ' »' : d;
        };
        const scopeOf = (spec) => (spec.within ? [...document.querySelectorAll(spec.within)].filter(shown) : [document.documentElement]);
        const find = (spec) => {
          const roots = scopeOf(spec);
          if (!roots.length) return { roots, found: [] };
          const sel = spec.selector || '*';
          const pool = new Set();
          for (const r of roots) {
            if (r.matches(sel)) pool.add(r);
            r.querySelectorAll(sel).forEach((e) => pool.add(e));
          }
          let found;
          if (typeof spec.text === 'string') {
            const want = norm(spec.text);
            const flat = squash(spec.text);
            found = [...pool].filter((el) => {
              const label = el.getAttribute('aria-label');
              if (label !== null && norm(label) === want) return shown(el);
              if (!squash(el.textContent).includes(flat)) return false;
              return (norm(el.innerText) === want || fold(el.innerText) === fold(want)) && shown(el);
            });
            // Deepest matches only: a parent whose whole text is its child's text is the same target.
            if (!spec.selector) found = found.filter((el) => !found.some((o) => o !== el && el.contains(o)));
          } else {
            found = [...pool].filter(shown);
          }
          return { roots, found };
        };
        """;

    /// <summary>
    /// Finds the element of a locator (selector and/or visible text, optional scope and index), scrolls it into view,
    /// checks that it holds still for 60 ms, is enabled (when asked) and is the element really under its centre (when
    /// asked), and returns its centre in CSS pixels of the viewport. States: ok, missing, scope, ambiguous, nth, moving,
    /// offscreen, disabled, covered.
    /// </summary>
    public const string Target = "async (spec) => {" + Prelude + """
          const { roots, found } = find(spec);
          if (!roots.length) return { state: 'scope', count: 0 };
          if (!found.length) return { state: 'missing', count: 0 };
          let el;
          if (typeof spec.nth === 'number') {
            if (spec.nth >= found.length) return { state: 'nth', count: found.length };
            el = found[spec.nth];
          } else if (found.length > 1) {
            return { state: 'ambiguous', count: found.length, sample: found.slice(0, 4).map(describe) };
          } else {
            el = found[0];
          }
          el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          const r1 = el.getBoundingClientRect();
          await new Promise((resolve) => setTimeout(resolve, 60));
          if (!el.isConnected) return { state: 'missing', count: 0 };
          const r = el.getBoundingClientRect();
          const what = describe(el);
          const still = Math.abs(r1.left - r.left) < 0.5 && Math.abs(r1.top - r.top) < 0.5 && Math.abs(r1.width - r.width) < 0.5 && Math.abs(r1.height - r.height) < 0.5;
          if (!still) return { state: 'moving', count: found.length, what };
          const x = r.left + r.width / 2;
          const y = r.top + r.height / 2;
          if (x < 0 || y < 0 || x > innerWidth || y > innerHeight) return { state: 'offscreen', count: found.length, what };
          if (spec.enabled && el.closest(':disabled, [aria-disabled="true"], [inert]') !== null) return { state: 'disabled', count: found.length, what };
          if (spec.hit) {
            const hit = document.elementFromPoint(x, y);
            const through = hit !== null && hit.contains(el) && hit !== document.documentElement && hit !== document.body && getComputedStyle(el).pointerEvents === 'none';
            if (!(hit !== null && (hit === el || el.contains(hit) || through))) return { state: 'covered', count: found.length, what, by: describe(hit) };
          }
          return { state: 'ok', count: found.length, what, x, y, left: r.left + scrollX, top: r.top + scrollY, width: r.width, height: r.height };
        }
        """;

    /// <summary>
    /// Facts for expect and wait: number of visible matches of the locator, scope found, substring present, property or
    /// attribute of the single (or nth) match, readiness of the screen. The harness decides; the page only reports.
    /// </summary>
    public const string Probe = "(spec) => {" + Prelude + """
          const out = {
            scope: true, count: 0, sample: [], contains: null, hasValue: false, value: null,
            ready: document.documentElement.dataset.ready ?? null,
            complete: document.readyState === 'complete' && document.fonts.status === 'loaded',
            origin: performance.timeOrigin,
          };
          if (typeof spec.selector === 'string' || typeof spec.text === 'string') {
            const { roots, found } = find(spec);
            out.scope = roots.length > 0;
            out.count = found.length;
            out.sample = found.slice(0, 4).map(describe);
            const el = typeof spec.nth === 'number' ? (found[spec.nth] ?? null) : (found.length === 1 ? found[0] : null);
            if (el && typeof spec.property === 'string') {
              const v = el[spec.property];
              out.value = v === null || v === undefined || ['string', 'number', 'boolean'].includes(typeof v) ? (v ?? null) : String(v);
              out.hasValue = true;
            } else if (el && typeof spec.attribute === 'string') {
              out.value = el.getAttribute(spec.attribute);
              out.hasValue = true;
            }
          }
          if (typeof spec.contains === 'string') {
            const roots = scopeOf(spec);
            out.scope = out.scope && roots.length > 0;
            out.contains = roots.some((r) => visibleHas(r, spec.contains));
          }
          return out;
        }
        """;

    /// <summary>
    /// Goes to a route of the hash router. The readiness mark is removed first, so a mark left by the previous screen is
    /// never taken for the new one; the router sets it again once the screen is mounted and quiet (docs/CAPTURE.md § 5).
    /// </summary>
    public const string Go = """
        (route) => {
          const target = '#/' + route;
          if (location.hash === target) return 'same';
          delete document.documentElement.dataset.ready;
          location.hash = target;
          return 'navigated';
        }
        """;

    /// <summary>
    /// Run before any script of each new document (Page.addScriptToEvaluateOnNewDocument): theme and animation preferences
    /// of the page (same key as web/js/app.js), in the emptied E2E profile only.
    /// </summary>
    public const string PresetPreferences = """
        (prefs) => {
          try {
            const key = 'domenia.prefs.v1';
            const current = JSON.parse(localStorage.getItem(key) || '{}') || {};
            localStorage.setItem(key, JSON.stringify(Object.assign(current, prefs)));
          } catch (e) {
            console.warn('Préférences E2E non appliquées : ' + e);
          }
        }
        """;

    /// <summary>Location of the page (path and hash only), for the report.</summary>
    public const string Where = "() => location.pathname + location.hash";

    /// <summary>« (function)(argument) »: the argument is JSON text, safe as a JavaScript expression.</summary>
    public static string Call(string function, JsonNode? argument) =>
        "(" + function + ")(" + (argument is null ? "null" : argument.ToJsonString(ArgumentOptions)) + ")";
}
