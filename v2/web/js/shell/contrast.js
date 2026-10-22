// Visual contract (TRV-009, TRV-010): WCAG 2.x contrast of the colour pairs the interface really paints, measured on the
// tokens of the theme shown (tokens.css). Ratios are truncated, never rounded up (a displayed 4,50 means at least 4.5).
// Domenia 1 Get-DomeniaContrastRatio, Test-DomeniaPaletteContrast, Get-DomeniaSuiteContrastPairs.

/** Parses #rgb, #rrggbb, #rrggbbaa, rgb()/rgba() (both syntaxes) and color(srgb …); null when it is not a colour. */
export function parseColor(text) {
  const t = String(text ?? '').trim().toLowerCase();
  let m = /^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/.exec(t);
  if (m) {
    let h = m[1];
    if (h.length === 3) h = h.split('').map((c) => c + c).join('');
    const n = (i) => parseInt(h.slice(i, i + 2), 16);
    return { r: n(0), g: n(2), b: n(4), a: h.length === 8 ? n(6) / 255 : 1 };
  }
  m = /^rgba?\(([^)]+)\)$/.exec(t);
  if (m) {
    const parts = m[1].replace(/\//g, ' ').split(/[\s,]+/).filter(Boolean);
    if (parts.length < 3) return null;
    const ch = (p) => (p.endsWith('%') ? (parseFloat(p) * 255) / 100 : parseFloat(p));
    const alpha = parts[3] === undefined ? 1 : parts[3].endsWith('%') ? parseFloat(parts[3]) / 100 : parseFloat(parts[3]);
    const c = { r: ch(parts[0]), g: ch(parts[1]), b: ch(parts[2]), a: alpha };
    return [c.r, c.g, c.b, c.a].every(Number.isFinite) ? c : null;
  }
  m = /^color\(srgb\s+([^)]+)\)$/.exec(t);
  if (m) {
    const parts = m[1].replace(/\//g, ' ').split(/\s+/).filter(Boolean).map(parseFloat);
    if (parts.length < 3 || !parts.slice(0, 3).every(Number.isFinite)) return null;
    return { r: parts[0] * 255, g: parts[1] * 255, b: parts[2] * 255, a: Number.isFinite(parts[3]) ? parts[3] : 1 };
  }
  return null;
}

/** A translucent colour painted over an opaque one. */
export function composite(fg, bg) {
  const a = fg.a ?? 1;
  return { r: fg.r * a + bg.r * (1 - a), g: fg.g * a + bg.g * (1 - a), b: fg.b * a + bg.b * (1 - a), a: 1 };
}

/** WCAG 2.x relative luminance (linearised sRGB, Rec. 709 weights). */
export function luminance(c) {
  const lin = (v) => {
    const x = v / 255;
    return x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

/** Contrast ratio from 1 to 21 (the background must be opaque). */
export function contrastRatio(fg, bg) {
  const front = (fg.a ?? 1) < 1 ? composite(fg, bg) : fg;
  const l1 = luminance(front);
  const l2 = luminance(bg);
  return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
}

/** Truncated display « 4,53 ». */
export function ratioText(ratio) {
  return (Math.floor(ratio * 100) / 100).toFixed(2).replace('.', ',');
}

/** Pairs really painted: [label, foreground token, background token, kind]. Text = 4,5:1, large text and graphics = 3:1. */
export const CONTRAST_PAIRS = Object.freeze([
  ['Texte sur le fond', '--text', '--bg', 'text'],
  ['Texte sur une carte', '--text', '--bg-elevated', 'text'],
  ['Texte saisi', '--text', '--bg-input', 'text'],
  ['Texte secondaire sur une carte', '--text-muted', '--bg-elevated', 'text'],
  ['Texte secondaire sur le fond', '--text-muted', '--bg', 'text'],
  ['Légende discrète sur une carte', '--text-faint', '--bg-elevated', 'text'],
  ['Lien et accent', '--accent-text', '--bg-elevated', 'text'],
  ['Accent sur pastille', '--accent-text', '--accent-soft', 'text'],
  ['Pastille confirmée', '--ok', '--ok-soft', 'text'],
  ['Pastille attention', '--warn', '--warn-soft', 'text'],
  ['Pastille erreur', '--alert', '--alert-soft', 'text'],
  ['Pastille information', '--info', '--info-soft', 'text'],
  ['Pastille neutre', '--off', '--off-soft', 'text'],
  ['Statut confirmé sur une carte', '--ok', '--bg-elevated', 'text'],
  ['Statut attention sur une carte', '--warn', '--bg-elevated', 'text'],
  ['Statut erreur sur une carte', '--alert', '--bg-elevated', 'text'],
  ['Ligne survolée', '--text', '--bg-hover', 'text'],
  ['Ligne sélectionnée', '--text', '--bg-selected', 'text'],
  ['Bouton principal', '--text-on-accent', '--accent', 'text'],
  ['Marque et icônes sur la marque', '--on-brand', '--brand-1', 'large'],
  ['Menu latéral', '--text', '--nav-bg', 'text'],
  ['Menu latéral secondaire', '--text-muted', '--nav-bg', 'text'],
  ['Infobulle', '--bg', '--text', 'text'],
  ['Bordure de saisie', '--border-strong', '--bg-input', 'graphic'],
  ['Anneau de focus', '--accent', '--bg', 'graphic'],
  ['Marque confirmée', '--ok-mark', '--bg-elevated', 'graphic'],
  ['Marque attention', '--warn-mark', '--bg-elevated', 'graphic'],
  ['Marque erreur', '--alert-mark', '--bg-elevated', 'graphic'],
  ['Marque information', '--info-mark', '--bg-elevated', 'graphic'],
]);

/** Categorical chart series (pastels; state colours stay reserved) and their edge. */
export const CHART_SERIES = Object.freeze([
  ['--c1', 'Bleu'], ['--c2', 'Violet'], ['--c3', 'Sarcelle'], ['--c4', 'Rose'],
  ['--c5', 'Ciel'], ['--c6', 'Pêche'], ['--c7', 'Lilas'], ['--c8', 'Sauge'],
]);

/**
 * Resolves design tokens to colours as the theme shown paints them (color-mix included), through a hidden probe element.
 * @param {string[]} tokens
 * @returns {Map<string, {r:number,g:number,b:number,a:number}|null>}
 */
export function resolveTokens(tokens) {
  // The computed value of a custom property already has its var() references substituted: plain colours parse directly.
  // Only a value the parser does not know (color-mix, keywords) goes through the probe, whose computed colour is sRGB.
  const root = getComputedStyle(document.documentElement);
  const out = new Map();
  const unknown = [];
  for (const token of tokens) {
    const direct = parseColor(root.getPropertyValue(token));
    if (direct) out.set(token, direct);
    else unknown.push(token);
  }
  if (!unknown.length) return out;
  const probe = document.createElement('span');
  probe.className = 'visually-hidden';
  probe.setAttribute('aria-hidden', 'true');
  document.body.appendChild(probe);
  try {
    for (const token of unknown) {
      if (!root.getPropertyValue(token).trim()) { out.set(token, null); continue; }
      probe.style.setProperty('color', `var(${token})`);
      out.set(token, parseColor(getComputedStyle(probe).color));
    }
  } finally {
    probe.remove();
  }
  return out;
}

/**
 * Measures every pair on the theme shown. A translucent background is laid over the card colour (that is how soft tones are
 * painted); a missing colour fails, never skips.
 * @returns {{ passed: boolean, results: Array<{ label: string, fg: string, bg: string, kind: string, ratio: number, text: string, required: number, passed: boolean, reason: string }>, minimum: number, failures: number }}
 */
export function measureContrast(pairs = CONTRAST_PAIRS) {
  const tokens = new Set(['--bg-elevated', '--bg']);
  for (const [, fg, bg] of pairs) { tokens.add(fg); tokens.add(bg); }
  const colours = resolveTokens([...tokens]);
  const card = colours.get('--bg-elevated') ?? { r: 255, g: 255, b: 255, a: 1 };
  const results = pairs.map(([label, fgToken, bgToken, kind]) => {
    const required = kind === 'text' ? 4.5 : 3;
    const fg = colours.get(fgToken);
    let bg = colours.get(bgToken);
    if (!fg || !bg) return { label, fg: fgToken, bg: bgToken, kind, ratio: 0, text: '—', required, passed: false, reason: 'Couleur absente du thème.' };
    if ((bg.a ?? 1) < 1) bg = composite(bg, card.a < 1 ? { r: 255, g: 255, b: 255, a: 1 } : card);
    const ratio = contrastRatio(fg, bg);
    const passed = ratio >= required;
    return { label, fg: fgToken, bg: bgToken, kind, ratio, text: ratioText(ratio), required, passed, reason: passed ? '' : `Contraste ${ratioText(ratio)} : 1 inférieur à ${String(required).replace('.', ',')} : 1.` };
  });
  const measured = results.filter((r) => r.ratio > 0).map((r) => r.ratio);
  const failures = results.filter((r) => !r.passed).length;
  return { passed: results.length > 0 && failures === 0, results, minimum: measured.length ? Math.min(...measured) : 0, failures };
}
