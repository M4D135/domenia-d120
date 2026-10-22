// Utilisateurs et postes · « Comparer »: groups of two users side by side (Domenia 1 R40 « Droits comparés », FIC-004 to
// FIC-006): organisation attributes, groups only on one side or common, with origin (direct, nested, primary), path and
// privileges, limits of the read, and the text for a ticket. Read only: nothing is applied from one user to the other.
import { glyph } from '../../kit/glyphs.js';
import { writeClipboard } from '../../kit/util.js';
import { applyVars, countUp, reveal } from '../../ui.js';
import { avatar, esc, int, nouns, NBSP, errText, empty, sk } from './model.js';

const ORIGINS = { direct: 'Direct', nested: 'Imbriqué', primary: 'Principal', none: '' };

/**
 * Creates the « Comparer » tab in panel.
 * @param {HTMLElement} panel
 * @param {object} app  Controller of the screen (ctx, simulated, compareDefaults()).
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
  out.innerHTML = `<section class="card rel-cmp-idle">${empty('split', 'Comparez les groupes de deux comptes',
    'Groupes directs, imbriqués et principal de chaque côté, avec le chemin d’appartenance et les groupes à privilèges signalés. Idéal pour « faire comme son collègue » sans rien copier à l’aveugle.')}</section>`;

  let leftDn = null;

  async function resolveLeft(text) {
    if (text.includes('=')) return text;
    const res = await app.ctx.call('relations.subjects.search', { text: text.slice(0, 100) });
    const exact = res.results.find((m) => m.kind === 'user' && m.login.toLowerCase() === text.toLowerCase());
    return exact?.dn ?? null;
  }

  async function run() {
    const a = aInput.value.trim();
    const b = bInput.value.trim();
    if (!a || !b) {
      out.querySelector('.rel-cmp-msg')?.remove();
      out.insertAdjacentHTML('afterbegin', `<p class="rel-note warn rel-cmp-msg">${glyph('alert')}Indiquez les deux comptes à comparer.</p>`);
      (a ? bInput : aInput).focus();
      return;
    }
    go.disabled = true;
    out.innerHTML = `<section class="card rel-cmp-loading" aria-busy="true">${sk('w40')}<div class="rel-cmp-venn skeleton"></div>${sk('w85')}${sk('w70')}</section>`;
    try {
      leftDn = await resolveLeft(a);
      if (!leftDn) throw Object.assign(new Error(`Aucun compte « ${a} » dans l’index local : saisissez son DN.`), { code: 'relation.compareUnresolved' });
      const res = await app.ctx.call('relations.compare', { dn: leftDn, other: b });
      if (!app.alive) return;
      show(res);
      app.remember({ a, b });
    } catch (err) {
      out.innerHTML = `<section class="card rel-error" role="alert">${empty('alert', 'Comparaison impossible', errText(err))}</section>`;
    } finally {
      go.disabled = false;
    }
  }

  function groupItem(g, j) {
    const origins = [g.leftOrigin, g.rightOrigin].filter((x) => x && x !== 'none');
    const origin = origins.length ? ORIGINS[origins[0]] : '';
    return `<li class="rel-grp${g.privileged ? ' priv' : ''}" data-j="${Math.min(j, 30)}">
      <span class="rel-grp-ico">${glyph(g.privileged ? 'shield' : 'group')}</span>
      <div class="rel-grp-text"><b>${esc(g.name)}</b>${g.path ? `<span class="rel-grp-path" data-tip="${esc(g.path)}">${esc(g.path)}</span>` : ''}</div>
      <span class="rel-grp-tags">${origin ? `<span class="rel-tag" data-origin="${esc(origins[0])}">${esc(origin)}</span>` : ''}${g.privileged ? `<span class="rel-tag priv" data-tip="${esc(g.alert ?? '')}">${glyph('alert')}Privilèges</span>` : ''}</span></li>`;
  }

  function column(title, cls, groups, side) {
    return `<section class="card rel-cmp-col ${cls} reveal" aria-label="${esc(title)}">
      <header><span class="rel-cmp-col-k">${esc(title)}</span><b class="num">${int(groups.length)}</b></header>
      ${groups.length ? `<ul class="rel-grp-list">${groups.map(groupItem).join('')}</ul>` : `<p class="rel-quiet">${glyph('check')}${esc(side)}</p>`}
    </section>`;
  }

  function show(res) {
    const onlyA = res.groups.filter((g) => g.category === 'onlyLeft');
    const onlyB = res.groups.filter((g) => g.category === 'onlyRight');
    const common = res.groups.filter((g) => g.category === 'common');
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
        <table class="table rel-attr-table"><thead><tr><th scope="col">Attribut</th><th scope="col">A · ${esc(res.left.login)}</th><th scope="col">B · ${esc(res.right.login)}</th><th scope="col"><span class="visually-hidden">Écart</span></th></tr></thead>
        <tbody>${res.attributes.map((x) => `<tr class="${x.same ? '' : 'diff'}"><th scope="row">${esc(x.label)}</th><td>${x.left ? esc(x.left) : '<span class="rel-none">—</span>'}</td><td>${x.right ? esc(x.right) : '<span class="rel-none">—</span>'}</td>
          <td>${x.same ? `<span class="rel-same" data-tip="Identique">${glyph('check')}</span>` : `<span class="rel-diff" data-tip="Différent">${glyph('x')}</span>`}</td></tr>`).join('')}</tbody></table>
      </section>
      <div class="rel-cmp-cols">
        ${column(`Seulement chez ${res.left.label}`, 'a', onlyA, 'Aucun groupe propre à A.')}
        ${column('Communs', 'c', common, 'Aucun groupe commun.')}
        ${column(`Seulement chez ${res.right.label}`, 'b', onlyB, 'Aucun groupe propre à B.')}
      </div>
      ${res.limits.length ? `<section class="card rel-cmp-limits reveal">${res.limits.map((l) => `<p class="rel-note warn">${glyph('alert')}${esc(l)}</p>`).join('')}</section>` : ''}
      <p class="rel-cmp-foot">${glyph('lock')}${esc(res.note)}</p>`;
    applyVars(out);
    out.querySelectorAll('[data-count]').forEach((el, n) => countUp(el, Number(el.dataset.count), { delay: 120 + n * 90 }));
    out.querySelector('[data-ticket]').addEventListener('click', async () => {
      await writeClipboard(res.ticket);
    });
    stops.push(reveal(out));
  }

  go.addEventListener('click', run);
  [aInput, bInput].forEach((i) => i.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); run(); } }));

  return {
    /** Prefills A (and B), and runs at once when the comparison is a local read (simulation). */
    prefill(a, b, auto) {
      if (a) aInput.value = a;
      if (b) bInput.value = b;
      if (auto && a && b) run();
      else if (a && !b) bInput.focus();
    },
    destroy() { stops.forEach((fn) => fn()); },
  };
}
