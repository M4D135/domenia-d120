// Utilisateurs et postes · « Comparer »: groups of two users side by side (Domenia 1 R40 « Droits comparés », FIC-004 to
// FIC-006): organisation attributes (service, function, company, office, manager), groups only on one side or common, with
// both origins (direct, nested, primary), level, DN, path and privileges, each column filtered and sorted on its own, limits
// of the read, and the text for a ticket. Read only: nothing is applied from one user to the other. A result that comes back
// after a newer request (another pair, another subject) is ignored.
import { glyph } from '../../kit/glyphs.js';
import { writeClipboard } from '../../kit/util.js';
import { applyVars, countUp, reveal, toast } from '../../ui.js';
import { avatar, esc, int, nouns, NBSP, errText, empty, sk } from './model.js';

const ORIGINS = { direct: 'Direct', nested: 'Imbriqué', primary: 'Principal', none: '' };
const SORTS = [
  { id: 'name', label: 'Nom' },
  { id: 'priv', label: 'Privilèges d’abord' },
  { id: 'depth', label: 'Niveau' },
];

/**
 * Creates the « Comparer » tab in panel.
 * @param {HTMLElement} panel
 * @param {object} app  Controller of the screen (ctx, simulated, remember).
 */
export function createCompareTab(panel, app) {
  const stops = [];
  panel.innerHTML = `<div class="rel-cmp">
    <section class="card rel-cmp-form reveal" aria-label="Comptes à comparer">
      <div class="rel-cmp-sides">
        <label class="rel-cmp-side a"><span class="rel-cmp-k">${glyph('user')}Premier compte (A)</span>
          <input class="input mono" type="text" name="a" autocomplete="off" spellcheck="false" maxlength="2048" placeholder="DN ou identifiant (ex. j.martin)"></label>
        <span class="rel-cmp-vs" aria-hidden="true">${glyph('split')}</span>
        <label class="rel-cmp-side b"><span class="rel-cmp-k">${glyph('user')}Second compte (B)</span>
          <input class="input mono" type="text" name="b" autocomplete="off" spellcheck="false" maxlength="2048" placeholder="Identifiant, DOMAINE\\compte, UPN ou DN"></label>
        <button class="btn primary rel-cmp-go" type="button">${glyph('split')}Comparer</button>
      </div>
      <p class="rel-cmp-note">${glyph('info')}Le second compte est résolu exactement dans la copie de l’annuaire. Lecture seule${NBSP}: aucune différence n’est appliquée.</p>
    </section>
    <div class="rel-cmp-out" aria-live="polite"></div>
  </div>`;
  const aInput = panel.querySelector('input[name="a"]');
  const bInput = panel.querySelector('input[name="b"]');
  const out = panel.querySelector('.rel-cmp-out');
  const go = panel.querySelector('.rel-cmp-go');
  stops.push(reveal(panel));
  const idle = () => {
    out.innerHTML = `<section class="card rel-cmp-idle">${empty('split', 'Comparez les groupes de deux comptes',
      'Groupes directs, imbriqués et principal de chaque côté, avec le chemin d’appartenance et les groupes à privilèges signalés. Idéal pour « faire comme son collègue » sans rien copier à l’aveugle.')}</section>`;
  };
  idle();

  let request = 0;
  let running = false;
  let result = null;
  const view = { a: { q: '', sort: 'name' }, c: { q: '', sort: 'name' }, b: { q: '', sort: 'name' } };

  async function resolveLeft(text) {
    if (text.includes('=')) return text;
    const res = await app.ctx.call('relations.subjects.search', { text: text.slice(0, 100) });
    const exact = res.results.find((m) => m.kind === 'user' && m.login.toLowerCase() === text.toLowerCase());
    return exact?.dn ?? null;
  }

  async function run() {
    if (running) return;
    const a = aInput.value.trim();
    const b = bInput.value.trim();
    if (!a || !b) {
      out.querySelector('.rel-cmp-msg')?.remove();
      out.insertAdjacentHTML('afterbegin', `<p class="rel-note warn rel-cmp-msg">${glyph('alert')}Indiquez les deux comptes à comparer.</p>`);
      (a ? bInput : aInput).focus();
      return;
    }
    const my = ++request;
    running = true;
    go.disabled = true;
    out.innerHTML = `<section class="card rel-cmp-loading" aria-busy="true">${sk('w40')}<div class="rel-cmp-venn skeleton"></div>${sk('w85')}${sk('w70')}</section>`;
    try {
      const leftDn = await resolveLeft(a);
      if (my !== request || !app.alive) return;
      if (!leftDn) throw Object.assign(new Error(`Aucun compte « ${a} » dans l’index local : saisissez son DN.`), { code: 'relation.compareUnresolved' });
      const res = await app.ctx.call('relations.compare', { dn: leftDn, other: b });
      if (my !== request || !app.alive) return;
      result = res;
      show();
      app.remember({ a, b });
    } catch (err) {
      if (my !== request || !app.alive) return;
      result = null;
      out.innerHTML = `<section class="card rel-error" role="alert">${empty('alert', 'Comparaison impossible', errText(err))}</section>`;
    } finally {
      if (my === request) { running = false; go.disabled = false; }
    }
  }

  function originTag(side, origin) {
    if (!origin || origin === 'none') return '';
    return `<span class="rel-tag" data-origin="${esc(origin)}" data-tip="${esc(`${side === 'a' ? 'Chez A' : 'Chez B'} : ${ORIGINS[origin].toLowerCase()}`)}"><i>${side.toUpperCase()}</i>${esc(ORIGINS[origin])}</span>`;
  }

  function groupItem(g, j, column) {
    const origins = column === 'c'
      ? `${originTag('a', g.leftOrigin)}${originTag('b', g.rightOrigin)}`
      : originTag(column, column === 'a' ? g.leftOrigin : g.rightOrigin);
    return `<li class="rel-grp${g.privileged ? ' priv' : ''}" data-j="${Math.min(j, 30)}">
      <details><summary>
        <span class="rel-grp-ico">${glyph(g.privileged ? 'shield' : 'group')}</span>
        <span class="rel-grp-text"><b>${esc(g.name)}</b>${g.path ? `<span class="rel-grp-path">${esc(g.path)}</span>` : ''}</span>
        <span class="rel-grp-tags">${origins}<span class="rel-tag lvl" data-tip="Niveau d’imbrication : 1 = groupe direct">${glyph('layers')}${int(g.depth)}</span>${g.privileged ? `<span class="rel-tag priv" data-tip="${esc(g.alert ?? '')}">${glyph('alert')}Privilèges</span>` : ''}</span>
      </summary>
      <dl class="rel-grp-more"><dt>DN</dt><dd class="mono">${esc(g.dn)}</dd>${g.path ? `<dt>Chemin</dt><dd>${esc(g.path)}</dd>` : ''}<dt>Niveau</dt><dd>${int(g.depth)}${g.primary ? ' · groupe principal' : ''}</dd>${g.alert ? `<dt>Alerte</dt><dd>${esc(g.alert)}</dd>` : ''}</dl></details></li>`;
  }

  function sorted(groups, sort) {
    const list = [...groups];
    const byName = (x, y) => x.name.localeCompare(y.name, 'fr', { sensitivity: 'base' });
    if (sort === 'priv') list.sort((x, y) => Number(y.privileged) - Number(x.privileged) || byName(x, y));
    else if (sort === 'depth') list.sort((x, y) => x.depth - y.depth || byName(x, y));
    else list.sort(byName);
    return list;
  }

  const fold = (t) => String(t ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

  function columnBody(key, groups, emptyText) {
    const v = view[key];
    const needle = fold(v.q.trim());
    const shown = sorted(groups, v.sort).filter((g) => !needle || fold(`${g.name} ${g.path ?? ''} ${g.dn}`).includes(needle));
    if (!groups.length) return `<p class="rel-quiet">${glyph('check')}${esc(emptyText)}</p>`;
    return `${shown.length ? `<ul class="rel-grp-list">${shown.map((g, j) => groupItem(g, j, key)).join('')}</ul>` : `<p class="rel-quiet">${glyph('search')}Aucun groupe ne correspond au filtre.</p>`}
      ${needle ? `<p class="rel-cmp-count">${esc(`${int(shown.length)} sur ${int(groups.length)}`)}</p>` : ''}`;
  }

  function column(title, key, groups, emptyText) {
    return `<section class="card rel-cmp-col ${key} reveal" aria-label="${esc(title)}" data-col="${key}">
      <header><span class="rel-cmp-col-k">${esc(title)}</span><b class="num">${int(groups.length)}</b></header>
      ${groups.length > 6 ? `<div class="rel-cmp-tools"><label class="rel-cmp-filter"><span class="visually-hidden">Filtrer ${esc(title)}</span>${glyph('search')}<input class="input sm" type="search" data-filter="${key}" placeholder="Filtrer…" maxlength="80" value="${esc(view[key].q)}"></label>
        <label class="rel-cmp-sort"><span class="visually-hidden">Trier ${esc(title)}</span><select class="input sm" data-sort="${key}">${SORTS.map((s) => `<option value="${s.id}"${s.id === view[key].sort ? ' selected' : ''}>${esc(s.label)}</option>`).join('')}</select></label></div>` : ''}
      <div class="rel-cmp-col-body" data-body="${key}">${columnBody(key, groups, emptyText)}</div>
    </section>`;
  }

  function groupsOf(key) {
    if (!result) return [];
    const category = key === 'a' ? 'onlyLeft' : key === 'b' ? 'onlyRight' : 'common';
    return result.groups.filter((g) => g.category === category);
  }
  const emptyOf = { a: 'Aucun groupe propre à A.', c: 'Aucun groupe commun.', b: 'Aucun groupe propre à B.' };

  function show() {
    const res = result;
    const onlyA = groupsOf('a');
    const onlyB = groupsOf('b');
    const common = groupsOf('c');
    const total = Math.max(1, res.groups.length);
    const diffAttrs = res.attributes.filter((x) => !x.same).length;
    out.innerHTML = `<section class="card rel-cmp-head reveal">
        <div class="rel-cmp-who">
          <div class="rel-cmp-person a">${avatar('user', res.left.name, 'lg')}<div><span class="rel-cmp-k">A</span><b>${esc(res.left.name)}</b><span class="mono">${esc(res.left.login)}</span></div></div>
          <div class="rel-cmp-venn" role="img" aria-label="${esc(res.summary)}">
            <span class="rel-venn a" data-p="${(onlyA.length / total).toFixed(3)}"></span><span class="rel-venn b" data-p="${(onlyB.length / total).toFixed(3)}"></span>
            <span class="rel-venn-n a"><b data-count="${onlyA.length}">0</b><small>seulement A</small></span>
            <span class="rel-venn-n c"><b data-count="${common.length}">0</b><small>communs</small></span>
            <span class="rel-venn-n b"><b data-count="${onlyB.length}">0</b><small>seulement B</small></span>
          </div>
          <div class="rel-cmp-person b">${avatar('user', res.right.name, 'lg')}<div><span class="rel-cmp-k">B</span><b>${esc(res.right.name)}</b><span class="mono">${esc(res.right.login)}</span></div></div>
        </div>
        <p class="rel-cmp-summary">${esc(res.summary)}</p>
        <div class="rel-cmp-actions">
          ${res.counts.privilegedDifferences > 0 ? `<span class="chip alert">${glyph('alert')}${esc(nouns(res.counts.privilegedDifferences, 'écart à privilèges', 'écarts à privilèges'))}</span>` : `<span class="chip ok">${glyph('shield')}Aucun écart sur un groupe à privilèges</span>`}
          <span class="chip ${diffAttrs ? 'warn' : 'ok'}">${glyph('object')}${esc(diffAttrs ? nouns(diffAttrs, 'attribut différent', 'attributs différents') : 'Organisation identique')}</span>
          <span class="spacer"></span>
          <button class="btn" type="button" data-ticket>${glyph('copy')}Copier pour le ticket</button>
        </div>
      </section>
      <section class="card rel-cmp-attrs reveal" aria-label="Organisation">
        <h3>${glyph('object')}Organisation</h3>
        <table class="rel-attr-table"><thead><tr><th scope="col">Attribut</th><th scope="col">A · ${esc(res.left.login)}</th><th scope="col">B · ${esc(res.right.login)}</th><th scope="col"><span class="visually-hidden">Écart</span></th></tr></thead>
        <tbody>${res.attributes.map((x) => `<tr class="${x.same ? 'same' : 'diff'}"><th scope="row">${esc(x.label)}</th><td>${x.left ? esc(x.left) : '<span class="rel-none">—</span>'}</td><td>${x.right ? esc(x.right) : '<span class="rel-none">—</span>'}</td>
          <td>${x.same ? `<span class="rel-same" data-tip="Identique">${glyph('check')}</span>` : `<span class="rel-diff" data-tip="Différent">${glyph('x')}</span>`}</td></tr>`).join('')}</tbody></table>
      </section>
      <div class="rel-cmp-cols">
        ${column(`Seulement chez ${res.left.label}`, 'a', onlyA, emptyOf.a)}
        ${column('Communs', 'c', common, emptyOf.c)}
        ${column(`Seulement chez ${res.right.label}`, 'b', onlyB, emptyOf.b)}
      </div>
      ${res.limits.length ? `<section class="card rel-cmp-limits reveal">${res.limits.map((l) => `<p class="rel-note warn">${glyph('alert')}${esc(l)}</p>`).join('')}</section>` : ''}
      <p class="rel-cmp-foot">${glyph('lock')}${esc(res.note)}</p>`;
    applyVars(out);
    out.querySelectorAll('[data-count]').forEach((el, n) => countUp(el, Number(el.dataset.count), { delay: 120 + n * 90 }));
    stops.push(reveal(out));
  }

  function repaintColumn(key) {
    const host = out.querySelector(`[data-body="${key}"]`);
    if (!host) return;
    host.innerHTML = columnBody(key, groupsOf(key), emptyOf[key]);
    applyVars(host);
  }

  out.addEventListener('input', (e) => {
    const input = e.target instanceof HTMLInputElement ? e.target : null;
    if (!input?.dataset.filter) return;
    view[input.dataset.filter].q = input.value;
    repaintColumn(input.dataset.filter);
  });
  out.addEventListener('change', (e) => {
    const select = e.target instanceof HTMLSelectElement ? e.target : null;
    if (!select?.dataset.sort) return;
    view[select.dataset.sort].sort = select.value;
    repaintColumn(select.dataset.sort);
  });
  out.addEventListener('click', async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-ticket]') : null;
    if (!b || !result) return;
    const ok = await writeClipboard(result.ticket);
    toast(ok ? 'Texte du ticket copié : comptes, date, écarts et groupes par catégorie.' : 'Copie impossible : le presse-papiers est indisponible. Rien n’a été copié.', { tone: ok ? 'ok' : 'warn' });
  });

  go.addEventListener('click', run);
  // Entrée in a field runs the comparison only when the button would (never twice, never during a read).
  [aInput, bInput].forEach((i) => i.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); if (!go.disabled) run(); } }));

  return {
    /** Prefills A (and B), and runs at once when the comparison is a local read (simulation). */
    prefill(a, b, auto) {
      if (a) aInput.value = a;
      if (b) bInput.value = b;
      if (auto && a && b) run();
      else if (a && !b) bInput.focus();
    },
    /** Puts the tab back to its first state (session change): a result on its way is ignored. */
    reset() {
      request++;
      running = false;
      go.disabled = false;
      result = null;
      aInput.value = '';
      bInput.value = '';
      idle();
    },
    destroy() { request++; stops.forEach((fn) => fn()); },
  };
}
