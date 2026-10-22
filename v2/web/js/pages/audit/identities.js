// Audit AD · « Identités »: analysis of the identities of one OU (AUD-009): duplicates (mail, logon name, employee number),
// shared DNS names, AD and DNS names that diverge, names recycled or objects recreated compared with the local copy. Every
// finding is « À revoir »: nothing is merged, renamed or deleted. The whole domain with its sub-OUs is refused.
import { glyph } from '../../kit/glyphs.js';
import { createGrid } from '../../kit/grid.js';
import { esc } from '../../ui.js';
import { debounce } from '../../kit/util.js';
import { num, plural, when, statusMarkup, emptyMarkup, skeletonMarkup, paint, reported, gridHeight } from './shared.js';

const CATEGORY_ICONS = {
  'Valeur en double': 'copy', 'Nom DNS partagé': 'domain', 'Nom AD et nom DNS divergents': 'split', 'Nom recyclé ou objet recréé': 'history',
};
const CATEGORIES = Object.keys(CATEGORY_ICONS);

/**
 * @param {HTMLElement} panel
 * @param {any} app  Page context.
 */
export function createIdentitiesTab(panel, app) {
  const st = { scope: null, subtree: true, result: null, busy: false, error: null, hits: [], category: null };
  let grid = null;
  const cleanups = [];

  panel.innerHTML = `<div class="aud-ids">
    <div class="card aud-ids-scope">
      <div class="aud-ids-scope-main">
        <span class="aud-ids-ico" aria-hidden="true">${glyph('ou')}</span>
        <div class="aud-ids-scope-text"><span class="aud-k">Périmètre</span><b class="aud-ids-ou">—</b><small class="aud-ids-path"></small></div>
      </div>
      <div class="aud-ids-pick">
        <label class="aud-search-field">${glyph('search')}<input class="input" type="search" data-ou-search placeholder="Chercher une autre OU…" aria-label="Chercher une OU" autocomplete="off"></label>
        <ul class="aud-find-list aud-ou-hits" role="listbox" aria-label="OU trouvées" hidden></ul>
      </div>
      <label class="aud-switch"><input class="switch" type="checkbox" data-subtree checked><span>Inclure les sous-OU</span></label>
      <button class="btn primary is-net" type="button" data-scan>${glyph('users')}<span>Analyser les identités de l’OU</span><span class="k-cmd-net" aria-hidden="true"></span></button>
    </div>
    <div class="aud-ids-body"></div>
  </div>`;
  const body = panel.querySelector('.aud-ids-body');
  const searchInput = panel.querySelector('[data-ou-search]');
  const hits = panel.querySelector('.aud-ou-hits');

  function renderScope() {
    panel.querySelector('.aud-ids-ou').textContent = st.scope?.label ?? 'Aucune OU';
    panel.querySelector('.aud-ids-path').textContent = st.scope?.path ?? 'Choisissez une OU : jamais le domaine entier avec ses sous-OU.';
    panel.querySelector('[data-subtree]').checked = st.subtree;
    const scan = panel.querySelector('[data-scan]');
    const tooWide = st.scope?.root && st.subtree;
    scan.setAttribute('aria-disabled', String(!st.scope || st.busy || Boolean(tooWide)));
    scan.dataset.tip = !st.scope ? 'Choisissez d’abord une OU.' : tooWide ? 'Le domaine entier n’est pas analysé : choisissez une OU, ou décochez « Inclure les sous-OU ».'
      : 'Lit les utilisateurs et postes de l’OU (5 000 au plus), puis compare leurs noms avec la base locale. Lecture réseau sur ce clic.';
    scan.innerHTML = `${st.busy ? '<span class="k-spin" aria-hidden="true"></span>' : glyph('users')}<span>${st.busy ? 'Analyse en cours…' : 'Analyser les identités de l’OU'}</span><span class="k-cmd-net" aria-hidden="true"></span>`;
  }

  function renderBody() {
    grid?.destroy();
    grid = null;
    if (st.busy && !st.result) { body.innerHTML = `<div class="card">${skeletonMarkup(6)}</div>`; return; }
    if (!st.result) {
      body.innerHTML = `<div class="card">${emptyMarkup({
        icon: 'users', title: st.error ? 'Analyse impossible' : 'Identités non analysées', tone: st.error ? 'alert' : 'accent',
        text: st.error ?? 'Relève les doublons (adresse, nom de connexion, matricule), les noms DNS partagés, les noms AD et DNS divergents et les noms recyclés par rapport à la base locale. Chaque constat est à revoir : rien n’est fusionné, renommé ni supprimé.',
      })}<ul class="aud-intro-list" role="list">${CATEGORIES.map((c, n) => `<li data-i="${n}">${glyph(CATEGORY_ICONS[c])}<span>${esc(c)}</span></li>`).join('')}</ul></div>`;
      paint(body);
      return;
    }
    const r = st.result;
    const counts = Object.fromEntries(r.categories.map((c) => [c.category, c.count]));
    const tiles = CATEGORIES.map((c, n) => `<button type="button" class="aud-id-cat card spot reveal${counts[c] ? '' : ' zero'}" data-cat="${esc(c)}" aria-pressed="${st.category === c}" data-i="${n}">
      <span class="aud-id-cat-ico" aria-hidden="true">${glyph(CATEGORY_ICONS[c])}</span><b data-count="${counts[c] ?? 0}">${num(counts[c] ?? 0)}</b><span>${esc(c)}</span></button>`).join('');
    body.innerHTML = `${statusMarkup(`${r.summary} Lu sur ${r.controller}.`, r.findings.length ? 'warn' : 'ok')}
      <div class="aud-id-meta">${glyph('ou')}<span>${esc(r.path)}</span><span class="sep">·</span><span>${plural(r.objects, 'objet lu', 'objets lus')}${r.truncated ? ` (borné à ${num(r.limit)})` : ''}</span><span class="sep">·</span>${when(r.readAt)}</div>
      <div class="aud-id-cats" role="group" aria-label="Filtrer par catégorie">${tiles}</div>
      ${r.findings.length ? '<div class="aud-grid-host" data-grid="ids"></div>' : `<div class="card">${emptyMarkup({ icon: 'check', title: 'Aucun constat à revoir', text: 'Aucun doublon, nom partagé ou recyclé dans ce périmètre. Une absence dans un périmètre borné ne prouve rien ailleurs.', tone: 'ok' })}</div>`}`;
    paint(body);
    app.reveal(body);
    if (r.findings.length) {
      grid = createGrid(body.querySelector('[data-grid="ids"]'), {
        key: 'audit.identites', label: 'Constats d’identité à revoir', rowId: (f) => f.id, selection: 'single', height: gridHeight(r.findings.length),
        columns: [
          { id: 'category', label: 'Catégorie', width: 230, html: (v) => `<span class="aud-obj">${glyph(CATEGORY_ICONS[v] ?? 'info')}${esc(v)}</span>` },
          { id: 'element', label: 'Élément', width: 360 },
          { id: 'objectsText', label: 'Objets', width: 260 },
          { id: 'conclusion', label: 'Conclusion', width: 120, type: 'enum', options: [{ value: 'À revoir', label: 'À revoir', tone: 'warn' }] },
          { id: 'limit', label: 'Limite', width: 420 },
        ],
        onActivate: (f) => { if (f.objects[0]?.dn) app.target(f.objects[0].dn); },
        contextMenu: ({ row }) => [
          ...(row?.objects ?? []).filter((o) => o.dn).slice(0, 4).map((o) => ({ label: `Auditer ${o.name}`, icon: 'shield', run: () => app.target(o.dn) })),
          ...(row?.objects ?? []).filter((o) => o.dn).slice(0, 2).map((o) => ({ label: `Ouvrir la fiche de ${o.name}`, icon: 'object', run: () => app.ctx.navigate('fiche', { dn: o.dn }) })),
        ],
      });
      grid.setRows(filtered());
    }
  }

  const filtered = () => (st.result?.findings ?? []).filter((f) => !st.category || f.category === st.category);

  async function scan() {
    if (!st.scope || st.busy || (st.scope.root && st.subtree)) return;
    const token = app.guard.next('identities');
    st.busy = true;
    st.error = null;
    app.busy('identities', true);
    renderScope();
    renderBody();
    try {
      const r = await app.ctx.call('audit.identities.scan', { dn: st.scope.dn, subtree: st.subtree });
      if (!app.alive() || !app.guard.current(token)) return;
      st.result = r;
      st.category = null;
      app.toast(`Identités de ${st.scope.label} : ${plural(r.findings.length, 'constat à revoir', 'constats à revoir')}.`, { tone: r.findings.length ? 'warn' : 'ok' });
    } catch (err) {
      if (!app.alive() || !app.guard.current(token)) return;
      st.error = reported(err);
      app.toast(st.error, { tone: err?.code === 'audit.scopeTooWide' ? 'warn' : 'alert' });
    } finally {
      if (app.alive() && app.guard.current(token)) {
        st.busy = false;
        app.busy('identities', false);
        renderScope();
        renderBody();
      }
    }
  }

  async function loadScope() {
    try {
      const s = await app.ctx.call('session.info');
      if (!app.alive()) return;
      if (s?.scope?.dn) {
        const root = s.domain?.rootDn && s.scope.dn.toLowerCase() === s.domain.rootDn.toLowerCase();
        st.scope = { dn: s.scope.dn, label: s.scope.label, path: root ? `Domaine ${s.domain.dnsName}` : `OU de travail · ${s.scope.label}`, root };
        st.subtree = root ? false : s.scope.subtree !== false;
      }
    } catch (err) {
      console.error(err);
    }
    renderScope();
  }

  // OU search (same read as the « Choisir l’OU » panel: local index in simulation, a bounded network read in directory mode).
  const searchOu = debounce(async () => {
    const text = searchInput.value.trim();
    if (!text) { st.hits = []; renderHits(); return; }
    const token = app.guard.next('ou-search');
    try {
      const found = await app.ctx.call('directory.ou.search', { text: text.slice(0, 100) });
      if (!app.alive() || !app.guard.current(token)) return;
      st.hits = found.slice(0, 12);
      renderHits();
    } catch (err) {
      app.toast(reported(err), { tone: 'warn' });
    }
  }, 250);
  function renderHits() {
    hits.hidden = !st.hits.length;
    hits.innerHTML = st.hits.map((o) => `<li role="option" aria-selected="false" class="aud-hit" data-ou="${esc(o.dn)}" data-label="${esc(o.name)}" data-path="${esc(o.path)}">
      <span class="aud-hit-ico">${glyph('ou')}</span><span class="aud-hit-text"><b>${esc(o.name)}</b><small>${esc(o.path)} · ${plural(o.counts.users, 'utilisateur', 'utilisateurs')}, ${plural(o.counts.computers, 'ordinateur', 'ordinateurs')}</small></span></li>`).join('');
  }

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    if (t.closest('[data-scan]')) { scan(); return; }
    const ou = t.closest('[data-ou]');
    if (ou) {
      st.scope = { dn: ou.dataset.ou, label: ou.dataset.label, path: ou.dataset.path, root: false };
      st.hits = [];
      searchInput.value = '';
      renderHits();
      renderScope();
      app.setParams({ ou: st.scope.dn });
      return;
    }
    const cat = t.closest('[data-cat]');
    if (cat && st.result) {
      st.category = st.category === cat.dataset.cat ? null : cat.dataset.cat;
      body.querySelectorAll('[data-cat]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.cat === st.category)));
      grid?.setRows(filtered());
    }
  };
  const onChange = (e) => {
    if (e.target instanceof HTMLInputElement && e.target.matches('[data-subtree]')) { st.subtree = e.target.checked; renderScope(); }
  };
  const onKey = (e) => { if (e.key === 'Escape' && st.hits.length) { e.stopPropagation(); st.hits = []; renderHits(); } };
  panel.addEventListener('click', onClick);
  panel.addEventListener('change', onChange);
  searchInput.addEventListener('input', searchOu);
  searchInput.addEventListener('keydown', onKey);
  cleanups.push(() => {
    panel.removeEventListener('click', onClick);
    panel.removeEventListener('change', onChange);
    searchInput.removeEventListener('input', searchOu);
    searchInput.removeEventListener('keydown', onKey);
  });

  renderScope();
  renderBody();
  const ready = loadScope();

  return {
    /** Gesture by the address (?lancer=1): analyses the working OU (or ?ou=<DN>). */
    async launch(ouDn) {
      await ready;
      if (ouDn) st.scope = { dn: ouDn, label: ouDn.split(',')[0].replace(/^OU=/i, ''), path: ouDn, root: false };
      renderScope();
      await scan();
    },
    sections() {
      if (!st.result) return [{ title: 'Identités', summary: 'Identités non analysées : rien à copier.' }];
      return [{ title: `Identités · ${st.result.path}`, summary: st.result.summary, columns: [
        { label: 'Catégorie', get: (f) => f.category }, { label: 'Élément', get: (f) => f.element }, { label: 'Objets', get: (f) => f.objectsText },
        { label: 'Conclusion', get: (f) => f.conclusion }, { label: 'Limite', get: (f) => f.limit },
      ], rows: filtered() }];
    },
    destroy() {
      grid?.destroy();
      cleanups.forEach((fn) => fn());
    },
  };
}

