// Paramètres › Budgets réseau (PAR-037 to PAR-041): usage profile, freshness per family, collection window (text and a
// weekly grid to paint, improvement of PAR-040), budgets of the surveys and of the widget collections. These values only
// bound what later reads may do; nothing here reads the network.
import {
  esc, glyph, card, row, notes, sectionHead, select, button, paint, skeleton, errorBlock, reported, pill, NBSP, COLON, isOff, radioKeys,
} from './common.js';
import { reveal } from '../../ui.js';
import { debounce } from '../../kit/util.js';

const DAYS = ['Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche'];
const HEAD = { title: 'Budgets réseau', lead: 'Combien de temps une mesure reste fraîche, quand les travaux de fond peuvent lire le réseau, et jusqu’où va un relevé. Réglages lus au début de chaque relevé.', icon: 'wifi', tone: 'warn' };

function profileCards(v) {
  return `<div class="pr-profiles" role="radiogroup" aria-label="Profil de collecte" data-setting="profile">${v.profiles.map((p, n) => `<button type="button" class="pr-profile" role="radio" aria-checked="${p.active}" tabindex="${p.active ? 0 : -1}" data-profile="${esc(p.id)}" data-j="${n}">
      <span class="pr-profile-ico">${glyph(p.id === 'slowNetwork' ? 'clock' : p.id === 'troubleshooting' ? 'zap' : 'wifi')}</span>
      <b>${esc(p.label)}</b><span>${esc(p.description)}</span><span class="pr-profile-win">${glyph('calendar')}${esc(p.windowLabel)}</span>
      <span class="pr-theme-check" aria-hidden="true">${glyph('check')}</span></button>`).join('')}</div>`;
}

function freshnessRows(v) {
  return v.freshness.map((f, n) => `<div class="pr-fresh" data-j="${n}">
      <div class="pr-row-text"><span class="pr-row-label">${esc(f.label)}</span><span class="pr-row-desc">${esc(f.effect)}</span></div>
      <div class="pr-fresh-ctl">${select(`fresh:${f.family}`, f.label, f.choices.map((c) => ({ value: c.value, label: c.label })), f.seconds)}
        ${f.source === 'custom' ? pill('accent', 'Personnalisé', { size: 'sm', tip: `Profil : ${f.profileDuration}` }) : pill('off', 'Profil', { size: 'sm' })}</div>
    </div>`).join('');
}

/** The week painted in half hours; the scale uses the same grid as the cells (12 columns of 4 half hours), « 24 » at the end. */
function gridMarkup(grid) {
  const hours = Array.from({ length: 12 }, (_, n) => `<span>${String(n * 2).padStart(2, '0')}</span>`).join('');
  return `<div class="pr-week" aria-hidden="true">
      <div class="pr-week-hours"><span class="pr-week-day"></span><span class="pr-week-scale">${hours}<span class="pr-week-end">24</span></span></div>
      ${grid.map((day, d) => `<div class="pr-week-row" data-day="${d}"><span class="pr-week-day">${DAYS[d].slice(0, 3)}.</span><span class="pr-week-cells">${day.map((on, h) => `<i class="pr-cell${on ? ' on' : ''}" data-d="${d}" data-h="${h}"></i>`).join('')}</span></div>`).join('')}
    </div>`;
}

function windowCard(v) {
  const w = v.window;
  return card({
    id: 'window', title: 'Fenêtre de collecte', sub: `Travaux de fond tenus : ${v.windowSources.join(', ').toLowerCase()}`, iconName: 'calendar', cls: 'pr-wide',
    body: `<div class="pr-window" data-setting="window">
        <label class="pr-window-text"><span>Règle</span><input class="input mono" type="text" data-window maxlength="400" value="${esc(w.text)}" placeholder="toujours" spellcheck="false" autocomplete="off" aria-describedby="pr-window-help">
        </label>
        <p class="pr-sub" id="pr-window-help">« lun-ven 07:30-12:00 13:30-18:00; sam », « toujours » ou « jamais ». Une plage dont la fin précède le début continue le lendemain. Ou peignez la grille ci-dessous.</p>
        <div class="pr-window-state" data-slot="window-state"></div>
        <div data-slot="grid">${gridMarkup(w.grid)}</div>
        <div class="pr-actions">${button('window-save', 'Enregistrer la fenêtre', 'check', { kind: 'primary' })}${button('window-default', 'Revenir à la fenêtre du profil', 'undo', { disabled: !v.windowCustom, reason: v.windowCustom ? '' : 'La fenêtre du profil s’applique déjà.' })}
          ${button('window-always', 'Toujours ouverte', 'sun', { kind: 'ghost' })}${button('window-never', 'Jamais', 'pause', { kind: 'ghost' })}</div>
      </div>`,
  });
}

function stateMarkup(w) {
  const toneName = !w.valid ? 'alert' : w.open ? 'ok' : 'warn';
  return `<span class="pr-window-dot" data-tone="${toneName}"></span><b>${esc(w.sentence)}</b>${w.errors?.length ? `<ul class="pr-errors">${w.errors.map((e) => `<li>${esc(e)}</li>`).join('')}</ul>` : ''}`;
}

function markup(v) {
  const profile = card({
    id: 'profile', title: 'Profil de collecte', sub: `Actif : ${v.profile.label}`, iconName: 'sliders', cls: 'pr-wide',
    body: profileCards(v),
  });
  const freshness = card({
    id: 'freshness', title: 'Durées de fraîcheur', sub: `Profil ${v.profile.label} · de 0 à 7 jours par famille`, iconName: 'clock',
    actions: button('fresh-reset', 'Durées du profil', 'undo', { kind: 'ghost', disabled: !v.freshnessCustom, reason: v.freshnessCustom ? '' : 'Les durées du profil s’appliquent déjà.' }),
    body: `<div data-setting="freshness">${freshnessRows(v)}</div>`,
  });
  const budgets = card({
    id: 'budgets', title: 'Budgets des relevés', sub: 'Concurrence, réutilisation, plafonds et nouveaux essais', iconName: 'gauge',
    body: `<div data-setting="budgets">${v.budgets.map((b) => row({ label: b.label, desc: b.effect, control: select(`budget:${b.id}`, b.label, b.choices.map((c) => ({ value: c.value, label: c.label })), b.value) })).join('')}</div>`,
  });
  return `${sectionHead(HEAD, `<span class="pr-head-pill">${pill(v.window.open ? 'ok' : 'warn', v.window.open ? 'Fenêtre ouverte' : 'Fenêtre fermée', { icon: 'calendar' })}</span>`)}
    ${v.warnings.length ? `<p class="pr-hint warn reveal">${glyph('alert')}<span>${esc(v.warnings.join(' '))}</span></p>` : ''}
    <div class="pr-grid">${profile}${freshness}${budgets}${windowCard(v)}
      <div class="pr-footnote reveal">${notes(v.rules)}</div></div>`;
}

export function mount(host, sctx, { open } = {}) {
  let view = null;
  let alive = true;
  let draft = null;
  host.innerHTML = `${sectionHead(HEAD)}${skeleton(3)}`;

  function showState(w) {
    const slot = host.querySelector('[data-slot="window-state"]');
    if (slot) { slot.innerHTML = stateMarkup(w); paint(slot); }
  }

  function draw() {
    host.innerHTML = markup(view);
    paint(host);
    reveal(host);
    showState(view.window);
    draft = view.window;
  }

  async function load() {
    try {
      view = await sctx.call('settings.collection');
      if (!alive) return;
      draw();
      if (open === 'fenetre') {
        open = null;
        host.querySelector('[data-card="window"]')?.scrollIntoView({ block: 'start' });
      }
    } catch (err) {
      if (!alive) return;
      host.innerHTML = `${sectionHead(HEAD)}${errorBlock(err)}`;
    }
  }

  async function save(args, done) {
    try {
      view = await sctx.call('settings.collection.set', args);
      if (!alive) return;
      draw();
      sctx.toast(done, { tone: 'ok', life: 3000 });
    } catch (err) {
      sctx.toast(reported(err), { tone: err?.code === 'settings.windowInvalid' ? 'warn' : 'alert' });
    }
  }

  const check = debounce(async (args) => {
    try {
      draft = await sctx.call('settings.collection.window.check', args);
      if (!alive) return;
      showState(draft);
      const slot = host.querySelector('[data-slot="grid"]');
      if (slot && !painting) { slot.innerHTML = gridMarkup(draft.grid); }
      if (args.grid) { const input = host.querySelector('[data-window]'); if (input) input.value = draft.text || 'toujours'; }
    } catch (err) { console.error(err); }
  }, 260);

  // Painting the week: the first cell sets the mode (open or close), dragging paints, releasing analyses the grid.
  let painting = null;
  const gridValue = () => [...host.querySelectorAll('.pr-week-row')].map((r) => [...r.querySelectorAll('.pr-cell')].map((c) => c.classList.contains('on')));
  const onDown = (e) => {
    const cell = e.target instanceof Element ? e.target.closest('.pr-cell') : null;
    if (!cell) return;
    e.preventDefault();
    painting = !cell.classList.contains('on');
    cell.classList.toggle('on', painting);
  };
  const onOver = (e) => {
    if (painting === null) return;
    const cell = e.target instanceof Element ? e.target.closest('.pr-cell') : null;
    if (cell) cell.classList.toggle('on', painting);
  };
  const onUp = () => {
    if (painting === null) return;
    painting = null;
    check({ grid: gridValue() });
  };

  const onKey = (e) => { radioKeys(e); };
  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const profile = t?.closest('[data-profile]');
    if (profile && view) {
      if (profile.getAttribute('aria-checked') === 'true') return;
      const label = view.profiles.find((p) => p.id === profile.dataset.profile)?.label ?? '';
      save({ profile: profile.dataset.profile }, `Profil de collecte : ${label}. Les durées et la fenêtre de ce profil s’appliquent au prochain relevé.`);
      return;
    }
    const actBtn = t?.closest('[data-act]');
    if (isOff(actBtn) || !view) return;
    const act = actBtn.dataset.act;
    if (act === 'retry') load();
    else if (act === 'fresh-reset') save({ freshness: null }, 'Durées du profil rétablies.');
    else if (act === 'window-default') save({ window: null }, 'Fenêtre du profil rétablie.');
    else if (act === 'window-save') {
      const text = host.querySelector('[data-window]')?.value ?? '';
      save({ window: text }, `Fenêtre de collecte enregistrée${NBSP}: ${draft?.sentence ?? ''}`);
    } else if (act === 'window-always' || act === 'window-never') {
      const input = host.querySelector('[data-window]');
      if (input) input.value = act === 'window-always' ? 'toujours' : 'jamais';
      check({ text: input?.value ?? '' });
    }
  };
  const onChange = (e) => {
    const sel = e.target instanceof HTMLSelectElement ? e.target : null;
    if (!sel?.dataset.select || !view) return;
    const [kind, id] = sel.dataset.select.split(':');
    const value = Number(sel.value);
    if (kind === 'fresh') save({ freshness: { [id]: value } }, `Durée enregistrée pour ${view.freshness.find((f) => f.family === id)?.label.toLowerCase() ?? id}.`);
    else if (kind === 'budget') save({ budgets: { [id]: value } }, `${view.budgets.find((b) => b.id === id)?.label ?? id}${NBSP}: ${sel.selectedOptions[0]?.textContent ?? value}.`);
  };
  const onInput = (e) => {
    if (e.target instanceof HTMLInputElement && e.target.matches('[data-window]')) check({ text: e.target.value });
  };
  host.addEventListener('click', onClick);
  host.addEventListener('keydown', onKey);
  host.addEventListener('change', onChange);
  host.addEventListener('input', onInput);
  host.addEventListener('pointerdown', onDown);
  host.addEventListener('pointerover', onOver);
  window.addEventListener('pointerup', onUp);
  load();

  return {
    destroy() {
      alive = false;
      host.removeEventListener('click', onClick);
      host.removeEventListener('keydown', onKey);
      host.removeEventListener('change', onChange);
      host.removeEventListener('input', onInput);
      host.removeEventListener('pointerdown', onDown);
      host.removeEventListener('pointerover', onOver);
      window.removeEventListener('pointerup', onUp);
    },
  };
}
