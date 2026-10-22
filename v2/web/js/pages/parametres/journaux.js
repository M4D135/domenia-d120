// Paramètres › Journaux (PAR-003 and the journals of the session): end of the technical journal with the reading options of
// Domenia 1 (follow, errors only, wrap, text size; wrap and size remembered), the raw view of the Expert profile, literal
// search, copy with names masked (preview before copying), and the operations journal of the session. Display only: every
// level stays recorded. « Effacer l’affichage » keeps a stable mark (time and text of the last line seen), never a position
// in the sliding window of the 600 last records.
import {
  esc, glyph, card, notes, sectionHead, switchLabel, select, segmented, button, paint, pressSegment, radioKeys, skeleton, errorBlock, reported, pill, int, count, size, when, NBSP, COLON,
} from './common.js';
import { reveal, copyText } from '../../ui.js';
import { timeline, bindTimeline } from '../../kit/timeline.js';
import { openDialog } from '../../kit/dialog.js';
import { readingPrefs, saveReadingPrefs } from './interface.js';
import { maskNames, markOf, linesAfter } from './pure.js';

const SIZES = [10, 11, 12, 14, 16, 18];
const FOLLOW_MS = 4000;
const HEAD = { title: 'Journaux', lead: 'Le journal technique de ce poste et le fil des opérations de la session. Lecture seule : les filtres n’enlèvent rien de ce qui est enregistré.', icon: 'file', tone: 'info' };
const LEVELS = { ERREUR: { tone: 'alert', label: 'Erreur', icon: 'alert' }, ATTENTION: { tone: 'warn', label: 'Attention', icon: 'alert' }, INFO: { tone: 'info', label: 'Info', icon: 'info' } };
const timeFmt = new Intl.DateTimeFormat('fr-FR', { hour: '2-digit', minute: '2-digit', second: '2-digit' });

function lineText(l) {
  return `${l.at ?? ''} [${l.level}] ${l.text}${l.more?.length ? `\n${l.more.join('\n')}` : ''}`;
}

export function mount(host, sctx) {
  let view = null;
  let alive = true;
  let timer = 0;
  let mark = null;
  let found = -1;
  const reading = readingPrefs();
  const state = {
    follow: true,
    errorsOnly: false,
    wrap: reading.logWrap === true,
    size: SIZES.includes(reading.logSize) ? reading.logSize : 11,
    // The raw view belongs to the Expert profile (Domenia 1 TabLog): never left selected when the profile goes back.
    raw: false,
    query: '',
  };
  host.innerHTML = `${sectionHead(HEAD)}${skeleton(2)}`;

  function visible() {
    const lines = linesAfter(view?.lines ?? [], mark);
    return state.errorsOnly ? lines.filter((l) => l.level === 'ERREUR' || l.level === 'ATTENTION') : lines;
  }

  function lineMarkup(l, n) {
    const lv = LEVELS[l.level] ?? LEVELS.INFO;
    const t = l.at ? timeFmt.format(new Date(l.at)) : '—';
    const recent = view?.file?.sessionStart && l.at && Date.parse(l.at) >= Date.parse(view.file.sessionStart);
    if (state.raw) return `<li class="pr-log-raw" data-n="${n}" data-level="${esc(l.level)}"><code>${esc(lineText(l))}</code></li>`;
    return `<li class="pr-log-line${recent ? ' session' : ''}" data-n="${n}" data-level="${esc(l.level)}" data-tone="${lv.tone}">
      <time datetime="${esc(l.at ?? '')}" data-tip="${esc(when(l.at))}">${esc(t)}</time>
      <span class="pr-log-level">${glyph(lv.icon)}<span>${esc(lv.label)}</span></span>
      <span class="pr-log-text">${esc(l.text)}${l.more?.length ? `<details class="pr-log-more"><summary>${count(l.more.length, 'ligne de détail', 'lignes de détail')}</summary><pre>${esc(l.more.join('\n'))}</pre></details>` : ''}</span></li>`;
  }

  function paintMeta(list) {
    const meta = host.querySelector('[data-slot="log-meta"]');
    if (!meta || !view) return;
    const f = view.file;
    const session = f.sessionErrors ?? 0;
    const earlier = Math.max(0, f.errors - session);
    meta.innerHTML = `<span>${glyph('file')}<span class="mono">${esc(f.label)}</span></span><span>${esc(f.exists ? size(f.bytes) : 'pas encore écrit')}</span><span>${int(list.length)} affichées sur ${int(f.records)}</span>
      ${session ? pill('alert', `${count(session, 'erreur', 'erreurs')} dans cette session`, { size: 'sm' }) : pill('ok', 'Aucune erreur dans cette session', { size: 'sm' })}
      ${earlier ? pill('off', `${count(earlier, 'erreur plus ancienne', 'erreurs plus anciennes')}`, { size: 'sm', tip: 'Lancements précédents : de l’historique, pas une alarme' }) : ''}
      ${f.warnings ? pill('warn', count(f.warnings, 'alerte', 'alertes'), { size: 'sm' }) : ''}${f.truncated ? pill('off', 'Fin du fichier seulement', { size: 'sm', tip: '256 Ko lus depuis la fin' }) : ''}
      ${mark ? `<button type="button" class="btn sm ghost" data-act="unclear">${glyph('undo')}<span>Tout réafficher</span></button>` : ''}`;
    paint(meta);
  }

  function paintLines({ keepScroll = false } = {}) {
    const box = host.querySelector('.pr-log');
    if (!box) return;
    const list = visible();
    const atEnd = box.scrollTop + box.clientHeight >= box.scrollHeight - 24;
    box.classList.toggle('wrap', state.wrap);
    box.classList.toggle('raw', state.raw);
    box.style.setProperty('--log-size', `${state.size}px`);
    box.querySelector('ol').innerHTML = list.length
      ? list.map(lineMarkup).join('')
      : `<li class="pr-log-empty">${esc(mark ? 'Affichage vidé : les nouvelles lignes apparaîtront ici.' : state.errorsOnly ? 'Aucune erreur ni alerte dans la fin du journal.' : 'Journal vide pour l’instant.')}</li>`;
    paint(box);
    paintMeta(list);
    if (state.follow && (!keepScroll || atEnd)) box.scrollTop = box.scrollHeight;
  }

  function paintSession() {
    const slot = host.querySelector('[data-slot="session"]');
    if (!slot || !view) return;
    const events = view.session.map((e) => ({ when: e.at, title: e.label, tone: e.tone === 'off' ? 'info' : e.tone, icon: e.tone === 'alert' || e.tone === 'warn' ? 'alert' : 'dot' }));
    slot.innerHTML = timeline(events, { label: 'Opérations de la session', empty: 'Aucune opération dans cette session.' });
    bindTimeline(slot);
  }

  function toolbar(expert) {
    return `<div class="pr-log-bar" data-setting="reading">
        <div class="pr-log-row">
          ${expert ? segmented('view', 'Vue du journal', [{ value: 'readable', label: 'Lisible', icon: 'eye' }, { value: 'raw', label: 'Brut', icon: 'hash' }], state.raw ? 'raw' : 'readable') : ''}
          ${switchLabel('follow', 'Suivre', state.follow)}
          ${switchLabel('errors', 'Erreurs seulement', state.errorsOnly)}
          ${switchLabel('wrap', 'Retour à la ligne', state.wrap)}
          <label class="pr-check"><span>Taille</span>${select('size', 'Taille du texte', SIZES.map((s) => ({ value: s, label: `${s}${NBSP}px` })), state.size)}</label>
        </div>
        <div class="pr-log-row">
          <span class="pr-log-search">${glyph('search')}<input type="search" class="input" data-find placeholder="Rechercher dans le journal" aria-label="Rechercher dans le journal affiché" spellcheck="false"></span>
          ${button('find-next', 'Suivant', 'arrowDown', { kind: 'ghost' })}<span class="pr-log-found" data-slot="found" aria-live="polite"></span>
        </div>
      </div>`;
  }

  function build() {
    const expert = sctx.expert();
    if (!expert) state.raw = false;
    const technical = card({
      id: 'technical', title: 'Journal technique', sub: state.raw ? 'Vue brute (profil Expert)' : 'Vue lisible', iconName: 'file', cls: 'pr-wide',
      actions: `${button('refresh', 'Actualiser', 'refresh', { kind: 'ghost' })}${button('copy', 'Copier…', 'copy')}${button('clear', 'Effacer l’affichage', 'x', { kind: 'ghost' })}${button('open-logs', 'Ouvrir le dossier', 'folder', { kind: 'ghost' })}`,
      body: `<div data-setting="technical">${toolbar(expert)}</div><div class="pr-log-meta" data-slot="log-meta"></div><div class="pr-log" tabindex="0" role="log" aria-label="Journal technique" aria-live="off"><ol></ol></div>
        ${notes(view.rules)}`,
    });
    const session = card({
      id: 'session', title: 'Opérations de la session', sub: 'Mêmes lignes que « Dernières opérations » de l’Accueil', iconName: 'activity', cls: 'pr-wide',
      body: '<div data-slot="session"></div>',
    });
    host.innerHTML = `${sectionHead(HEAD)}<div class="pr-grid pr-grid-logs">${technical}${session}</div>`;
    paint(host);
    reveal(host);
    paintLines();
    paintSession();
  }

  function badge() {
    const errors = view?.file?.sessionErrors ?? 0;
    sctx.badge('journaux', errors || '', errors ? 'alert' : 'off');
  }

  async function load({ quiet = false } = {}) {
    try {
      const next = await sctx.call('settings.logs');
      if (!alive) return;
      const first = !view;
      view = next;
      if (first) build(); else { paintLines({ keepScroll: true }); paintSession(); }
      badge();
      if (!quiet && !first) sctx.toast('Journal relu.', { tone: 'ok', life: 1800 });
    } catch (err) {
      if (!alive) return;
      if (!view) host.innerHTML = `${sectionHead(HEAD)}${errorBlock(err)}`;
      else sctx.toast(reported(err), { tone: 'warn' });
    }
  }

  function schedule() {
    clearInterval(timer);
    if (state.follow) timer = setInterval(() => { if (document.visibilityState === 'visible') load({ quiet: true }); }, FOLLOW_MS);
  }

  function findNext() {
    const q = state.query.toLowerCase();
    const out = host.querySelector('[data-slot="found"]');
    const lines = visible();
    if (!q) { if (out) out.textContent = 'Saisissez un texte.'; return; }
    for (let k = 1; k <= lines.length; k++) {
      const n = (found + k) % lines.length;
      if (lineText(lines[n]).toLowerCase().includes(q)) {
        found = n;
        if (state.follow) { state.follow = false; const f = host.querySelector('[data-toggle="follow"]'); if (f) f.checked = false; schedule(); }
        const li = host.querySelector(`.pr-log [data-n="${n}"]`);
        host.querySelectorAll('.pr-log .found').forEach((x) => x.classList.remove('found'));
        li?.classList.add('found');
        li?.scrollIntoView({ block: 'center' });
        if (out) out.textContent = `Ligne ${n + 1} · suivi en pause`;
        return;
      }
    }
    if (out) out.textContent = 'Aucune occurrence.';
  }

  async function copy() {
    const text = visible().map(lineText).join('\n');
    const body = `<label class="pr-check pr-mask"><input type="checkbox" class="k-checkbox" data-mask checked><span>Masquer les noms (DN, comptes, UPN, adresses, noms DNS)</span></label>
      <p class="pr-sub">Masquage au mieux${COLON}relisez avant d’envoyer. Aucun secret n’est jamais écrit dans ce journal.</p>
      <pre class="pr-copy-preview" data-preview></pre>`;
    const d = openDialog({ title: 'Copier le journal affiché', icon: 'copy', size: 'lg', body, actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'ok', label: 'Copier', primary: true }] });
    const preview = d.body.querySelector('[data-preview]');
    const mask = d.body.querySelector('[data-mask]');
    const refresh = () => { preview.textContent = (mask.checked ? maskNames(text) : text).slice(0, 20000) || 'Rien à copier.'; };
    mask.addEventListener('change', refresh);
    refresh();
    if (await d.result !== 'ok') return;
    const ok = await copyText(mask.checked ? maskNames(text) : text);
    sctx.toast(ok ? `Journal copié${COLON}${count(visible().length, 'ligne', 'lignes')}${mask.checked ? ', noms masqués' : ''}.` : `Copie impossible${COLON}presse-papiers indisponible.`, { tone: ok ? 'ok' : 'warn' });
  }

  const onChange = (e) => {
    const t = e.target;
    if (t instanceof HTMLInputElement && t.matches('[data-toggle]')) {
      const name = t.dataset.toggle;
      if (name === 'follow') { state.follow = t.checked; schedule(); if (t.checked) paintLines(); }
      else if (name === 'errors') { state.errorsOnly = t.checked; found = -1; paintLines(); }
      else if (name === 'wrap') { state.wrap = t.checked; saveReadingPrefs({ logWrap: t.checked }); paintLines({ keepScroll: true }); }
    } else if (t instanceof HTMLSelectElement && t.dataset.select === 'size') {
      state.size = Number(t.value);
      saveReadingPrefs({ logSize: state.size });
      paintLines({ keepScroll: true });
    }
  };
  const onInput = (e) => {
    if (e.target instanceof HTMLInputElement && e.target.matches('[data-find]')) { state.query = e.target.value; found = -1; }
  };
  const onKey = (e) => {
    if (radioKeys(e)) return;
    if (e.target instanceof HTMLInputElement && e.target.matches('[data-find]') && e.key === 'Enter') { e.preventDefault(); findNext(); }
  };
  const onClick = async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const seg = t?.closest('[data-seg="view"] button[data-value]');
    if (seg) {
      state.raw = seg.dataset.value === 'raw' && sctx.expert();
      pressSegment(seg.closest('.pr-seg'), state.raw ? 'raw' : 'readable');
      const sub = host.querySelector('[data-card="technical"] .pr-card-sub');
      if (sub) sub.textContent = state.raw ? 'Vue brute (profil Expert)' : 'Vue lisible';
      paintLines({ keepScroll: true });
      return;
    }
    const act = t?.closest('[data-act]')?.dataset.act;
    if (!act) return;
    if (act === 'retry' || act === 'refresh') load();
    else if (act === 'find-next') findNext();
    else if (act === 'copy') copy();
    else if (act === 'clear') {
      mark = markOf(view?.lines ?? []);
      found = -1;
      paintLines();
      sctx.toast('Affichage vidé ; le fichier du journal n’est pas modifié et les nouvelles lignes s’afficheront.', { tone: 'info', life: 2600 });
    } else if (act === 'unclear') { mark = null; paintLines(); }
    else if (act === 'open-logs') {
      try { await sctx.call('settings.folder.open', { folder: 'logs' }); } catch (err) { sctx.toast(reported(err), { tone: 'info' }); }
    }
  };
  // Profile changed elsewhere: the toolbar follows; a raw view is never left on in the Essentiel profile.
  const offPrefs = sctx.prefs.on(() => {
    if (!view || !alive) return;
    const expert = sctx.expert();
    const had = !!host.querySelector('[data-seg="view"]');
    if (had === expert && (expert || !state.raw)) return;
    if (!expert) state.raw = false;
    const slot = host.querySelector('[data-setting="technical"]');
    if (slot) { slot.innerHTML = toolbar(expert); paint(slot); }
    paintLines({ keepScroll: true });
  });
  host.addEventListener('change', onChange);
  host.addEventListener('input', onInput);
  host.addEventListener('keydown', onKey);
  host.addEventListener('click', onClick);
  load({ quiet: true }).then(schedule);

  return {
    reload: () => load({ quiet: true }),
    destroy() {
      alive = false;
      clearInterval(timer);
      offPrefs();
      host.removeEventListener('change', onChange);
      host.removeEventListener('input', onInput);
      host.removeEventListener('keydown', onKey);
      host.removeEventListener('click', onClick);
    },
  };
}
