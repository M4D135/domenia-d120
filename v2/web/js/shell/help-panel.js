// Help panel (F1, « ? » of the top bar): a side panel beside the work, kept open from one screen to the next. « Sur cet
// élément » follows the pointer and the keyboard focus over the controls that have a help (data-help, data-tip, a greyed
// control with its reason); « Sur cet écran » gives the chapter of the guide (TRV-005) and the topics of the screen; the
// search goes through the 820 topics of the catalogue (TRV-004 improvement: full-text index).
import { icon } from '../icons.js';
import { esc, fold, highlight } from '../kit/util.js';
import { state, quietCall, setPrefs, on, emit } from './store.js';
import {
  loadHelp, topic, searchTopics, topicsOfArea, helpAreas, helpSource, helpLoaded, followRoute, ROUTES, DISABLED_REASONS,
} from './help.js';

const KIND_ICONS = { button: 'zap', input: 'search', secret: 'key', choice: 'check', status: 'info', tab: 'panel', list: 'database', zone: 'object' };
const KIND_LABELS = { button: 'Bouton', input: 'Champ', secret: 'Champ secret', choice: 'Case ou choix', status: 'État', tab: 'Onglet', list: 'Liste', zone: 'Zone' };

/** One topic of a list of the panel: icon of its kind, title, then the screen or the kind. */
function hit(t, title, sub) {
  return `<li><button type="button" class="sh-help-hit" data-topic="${esc(t.name)}">${icon(KIND_ICONS[t.kind] ?? 'info')}<span class="sh-help-hit-t">${title}</span><span class="sh-help-hit-a">${esc(sub)}</span>${icon('chevronRight', 'sh-help-hit-go')}</button></li>`;
}

let panel = null;
let pinned = false;
let lastFocusKey = '';

export function helpPanelOpen() { return !!panel && !panel.hidden; }

function markup() {
  return `<div class="sh-help-head">
      <span class="sh-help-mark">${icon('info')}</span>
      <div class="sh-help-titles"><h2 id="sh-help-title">Aide</h2><p class="sh-help-sub"></p></div>
      <button class="btn ghost icon sm" type="button" data-help-close aria-label="Fermer l’aide" data-tip="Fermer l’aide (Échap)">${icon('x')}</button>
    </div>
    <div class="sh-help-search">
      ${icon('search')}<input class="input" type="search" data-help-q placeholder="Chercher dans les 820 sujets d’aide…" aria-label="Chercher dans l’aide" autocomplete="off" spellcheck="false">
    </div>
    <div class="sh-help-scroll">
      <section class="sh-help-block" data-block="element" aria-live="polite">
        <h3>Sur cet élément</h3>
        <div class="sh-help-element"><p class="faint">Survolez un contrôle ou donnez-lui le focus au clavier : son aide s’affiche ici, avec le motif d’un bouton grisé.</p></div>
      </section>
      <section class="sh-help-block" data-block="results" hidden>
        <h3>Résultats <span class="sh-help-count"></span></h3>
        <ol class="sh-help-results"></ol>
      </section>
      <section class="sh-help-block" data-block="screen">
        <h3>Sur cet écran</h3>
        <div class="sh-help-guide"></div>
        <ol class="sh-help-topics"></ol>
      </section>
    </div>
    <div class="sh-help-foot">
      <button class="btn sm ghost" type="button" data-help-act="keys">${icon('command')}Raccourcis</button>
      <button class="btn sm ghost" type="button" data-help-act="centre">${icon('sparkles')}Centre d’aide</button>
      <label class="sh-help-tips"><input type="checkbox" class="switch sm" data-help-tips> Infobulles d’aide</label>
    </div>`;
}

let actions = { openShortcuts: () => {}, go: () => {} };

/** app.js hands the shortcut overlay and the navigation. */
export function setHelpActions(a) { actions = { ...actions, ...a }; }

function ensure() {
  if (panel) return panel;
  panel = document.createElement('aside');
  panel.className = 'sh-help';
  panel.setAttribute('aria-labelledby', 'sh-help-title');
  panel.hidden = true;
  panel.innerHTML = markup();
  document.body.appendChild(panel);
  const q = panel.querySelector('[data-help-q]');
  let t = 0;
  q.addEventListener('input', () => { clearTimeout(t); t = setTimeout(() => search(q.value), 160); });
  q.addEventListener('keydown', (e) => { if (e.key === 'Escape' && q.value) { e.preventDefault(); e.stopPropagation(); q.value = ''; search(''); } });
  panel.querySelector('[data-help-close]').addEventListener('click', () => closeHelpPanel(true));
  panel.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !e.defaultPrevented) { e.preventDefault(); closeHelpPanel(true); } });
  panel.addEventListener('click', (e) => {
    const el = e.target instanceof Element ? e.target : null;
    const item = el?.closest('[data-topic]');
    if (item) { showTopic(item.dataset.topic); return; }
    const route = el?.closest('[data-route]');
    if (route) { followRoute(route.dataset.route); return; }
    const act = el?.closest('[data-help-act]')?.dataset.helpAct;
    if (act === 'keys') actions.openShortcuts();
    if (act === 'centre') actions.go('shell', { onglet: 'aide' });
    if (act === 'guide') openGuide();
  });
  const tips = panel.querySelector('[data-help-tips]');
  tips.checked = state.prefs.helpTips !== false;
  tips.addEventListener('change', () => setPrefs({ helpTips: tips.checked }));
  // « Sur cet élément » follows the pointer and the focus (not inside the panel itself).
  document.addEventListener('pointerover', onHover, { passive: true });
  document.addEventListener('focusin', onFocus);
  on('page', () => { if (helpPanelOpen()) paintScreen(); });
  return panel;
}

function helpTarget(node) {
  if (!(node instanceof Element) || panel.contains(node)) return null;
  return node.closest('[data-help], [data-reason], [data-tip], [aria-disabled="true"]');
}

let hoverTimer = 0;
function onHover(e) {
  if (!helpPanelOpen()) return;
  const el = helpTarget(e.target);
  if (!el) return;
  clearTimeout(hoverTimer);
  hoverTimer = setTimeout(() => showElement(el), 120);
}

function onFocus(e) {
  if (!helpPanelOpen()) return;
  const el = helpTarget(e.target);
  if (el && e.target === el) showElement(el);
}

async function showElement(el) {
  const box = panel.querySelector('.sh-help-element');
  const key = el.dataset.help ?? '';
  const disabled = el.getAttribute('aria-disabled') === 'true' || el.disabled === true;
  const reason = disabled ? (el.dataset.reason || '') : '';
  const signature = `${key}|${reason}|${el.dataset.tip ?? ''}`;
  if (signature === lastFocusKey) return;
  lastFocusKey = signature;
  let title = el.getAttribute('aria-label') || el.textContent.trim().slice(0, 80) || 'Élément';
  let text = el.dataset.tip || el.getAttribute('aria-description') || '';
  let kind = '';
  if (key) {
    const t = await topic(key);
    title = t.title;
    text = t.text;
    kind = t.name ? `Catalogue · ${t.name}` : '';
  }
  const route = disabled && el.dataset.reasonCode ? DISABLED_REASONS[el.dataset.reasonCode]?.route : '';
  box.innerHTML = `<h4>${esc(title)}</h4>${text ? `<p>${esc(text)}</p>` : ''}
    ${reason ? `<p class="sh-help-reason">${icon('lock')}<span>${esc(reason)}</span></p>` : ''}
    ${route && ROUTES[route] ? `<button class="btn xs subtle" type="button" data-route="${esc(route)}">${icon('chevronRight')}Aller à ${esc(ROUTES[route].label)}</button>` : ''}
    ${kind ? `<p class="sh-help-src faint mono">${esc(kind)}</p>` : ''}`;
}

async function showTopic(key) {
  const t = await topic(key);
  const box = panel.querySelector('.sh-help-element');
  lastFocusKey = `topic|${key}`;
  box.innerHTML = `<h4>${esc(t.title)}</h4><p>${esc(t.text)}</p><p class="sh-help-src faint mono">${esc(areaLabel(t.area))} · ${esc(t.name)}</p>`;
  panel.querySelector('[data-block="element"]').scrollIntoView({ block: 'nearest' });
}

function areaLabel(id) { return helpAreas().find(([a]) => a === id)?.[1] ?? id; }

async function search(raw) {
  const block = panel.querySelector('[data-block="results"]');
  const list = panel.querySelector('.sh-help-results');
  const q = raw.trim();
  if (!q) { block.hidden = true; return; }
  try { await loadHelp(); } catch { /* the registered topics stay searchable */ }
  const { total, items } = searchTopics(q, { limit: 30 });
  const f = fold(q);
  block.hidden = false;
  panel.querySelector('.sh-help-count').textContent = total ? `· ${total}` : '';
  list.innerHTML = items.length
    ? items.map((t) => hit(t, highlight(t.title, f), areaLabel(t.area))).join('')
    : '<li class="faint sh-help-none">Aucun sujet ne contient tous ces mots.</li>';
}

let guide = null;

async function paintScreen() {
  const page = state.page;
  panel.querySelector('.sh-help-sub').textContent = page ? `Écran ${page.label}` : '';
  const box = panel.querySelector('.sh-help-guide');
  box.innerHTML = '<p class="faint">Chapitre du guide…</p>';
  guide = null;
  const id = page?.id && /^[a-z][a-z0-9-]*$/.test(page.id) ? page.id : 'accueil';
  try { guide = await quietCall('shell.guide.info', { page: id }); } catch (err) { console.warn(err); }
  box.innerHTML = guide
    ? `<p class="sh-help-chapter">${icon('file')}<span>${esc(guide.text)}</span></p>
       <button class="btn xs subtle" type="button" data-help-act="guide"${guide.found ? '' : ` aria-disabled="true" data-reason="${esc(guide.message)}"`}>${icon('external')}Ouvrir le guide</button>
       ${guide.found ? '' : `<p class="faint">${esc(guide.message)}</p>`}`
    : '<p class="faint">Guides : disponibles dans le pack, dossier DOC.</p>';
  try { await loadHelp(); } catch { /* registered topics only */ }
  const area = page?.id === 'shell' || !page ? 'interface' : page.id;
  const topics = topicsOfArea(area, 8);
  panel.querySelector('.sh-help-topics').innerHTML = topics.length
    ? topics.map((t) => hit(t, esc(t.title), KIND_LABELS[t.kind] ?? 'Zone')).join('')
    : `<li class="faint">${helpLoaded() ? `${helpSource()?.count ?? 820} sujets dans le catalogue : cherchez par mot ci-dessus.` : 'Catalogue en cours de lecture…'}</li>`;
}

async function openGuide() {
  if (!guide?.found) return;
  try {
    const result = await quietCall('shell.guide.open', { page: guide.page || 'accueil' });
    const box = panel.querySelector('.sh-help-guide');
    if (result) box.insertAdjacentHTML('beforeend', `<p class="faint">${esc(result.message)}</p>`);
  } catch (err) {
    console.warn(err);
  }
}

/** Opens the help panel; with a key, shows that topic at once (ctx.help.open(key)). */
export function openHelpPanel(key = '', focus = true) {
  ensure();
  const wasOpen = helpPanelOpen();
  panel.hidden = false;
  document.querySelector('.shell')?.classList.add('has-help');
  pinned = true;
  if (!wasOpen) {
    panel.classList.remove('leaving');
    emit('help', true);
    paintScreen();
    if (!state.prefs.helpIntroSeen) setPrefs({ helpIntroSeen: true });
  }
  if (key) showTopic(key);
  else {
    const active = document.activeElement;
    const el = active instanceof Element ? helpTarget(active) : null;
    if (el) showElement(el);
  }
  if (focus) requestAnimationFrame(() => panel.querySelector('[data-help-q]')?.focus({ preventScroll: true }));
}

export function closeHelpPanel(focusBack = false) {
  if (!helpPanelOpen()) return;
  pinned = false;
  document.querySelector('.shell')?.classList.remove('has-help');
  panel.hidden = true;
  lastFocusKey = '';
  emit('help', false);
  if (focusBack) document.getElementById('main')?.focus({ preventScroll: true });
}

export function toggleHelpPanel() { if (helpPanelOpen()) closeHelpPanel(true); else openHelpPanel(); }

export function helpPinned() { return pinned; }
