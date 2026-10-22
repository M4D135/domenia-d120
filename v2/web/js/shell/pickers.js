// Shared pickers of the shell (TRV-242 to TRV-246): the OU picker (tree read on expansion, search by name, favourite OUs of
// the domain, scope with or without sub-OUs, summary before validation, re-check of the choice), the embedded object picker
// (users, workstations, OUs; at least 2 characters, 100 results, re-check of DN and GUID before the choice is handed over)
// and the embedded file picker (local folders only, 500 entries, nothing created). Every read follows an explicit gesture.
import { icon } from '../icons.js';
import { esc, errorText, announce, copyText } from '../ui.js';
import { openDrawer, createTree } from '../kit/index.js';
import { state, trackedCall, setFavourites } from './store.js';

const NBSP = ' ';
const KIND_LABELS = { user: 'Utilisateurs', computer: 'Postes', ou: 'OU' };
const KIND_ICONS = { user: 'user', computer: 'monitor', ou: 'folder' };

function call(op, args) { return trackedCall(op, args); }

// ---------- OU picker ----------

/**
 * Opens the OU picker. Resolves { dn, name, path, subtree } once the operator validates (re-checked first), or null.
 * @param {{ title?: string, effect?: string, subtree?: 'choice'|'forced'|'none', initial?: string, allowRoot?: boolean }} [o]
 */
export function pickOu(o = {}) {
  return new Promise((resolve) => {
    let chosen = null;
    let subtree = o.subtree !== 'none';
    let done = false;
    const favourites = () => state.engine?.ouFavourites ?? [];
    const body = document.createElement('div');
    body.className = 'sh-pick sh-pick-ou';
    body.innerHTML = `<p class="sh-pick-effect">${icon('info')}<span>${esc(o.effect ?? 'Choisissez une OU : seules les OU se choisissent, les conteneurs servent à naviguer.')}</span></p>
      <div class="sh-pick-row">
        <label class="sh-pick-find">${icon('search')}<span class="visually-hidden">Chercher une OU par nom</span>
          <input class="input" type="search" maxlength="100" placeholder="Chercher une OU par nom ou chemin (Entrée)" data-ou-q autocomplete="off" spellcheck="false"></label>
        <button class="btn sm subtle" type="button" data-ou-find>${icon('search')}Chercher</button>
      </div>
      <div class="sh-pick-favs" data-ou-favs></div>
      <div class="sh-pick-results" data-ou-results hidden></div>
      <div class="sh-pick-tree" data-ou-tree></div>
      <div class="sh-pick-summary" data-ou-summary aria-live="polite"></div>`;
    const panel = openDrawer({
      title: o.title ?? 'Choisir une OU',
      subtitle: state.session?.domain?.dnsName ? `Domaine ${state.session.domain.dnsName}` : 'Annuaire de la session',
      icon: 'folder', side: 'left', key: 'shell.pick.ou', width: 520, body,
      actions: [
        { id: 'cancel', label: 'Annuler', run: (p) => p.close() },
        { id: 'ok', label: 'Choisir cette OU', primary: true, run: () => validate() },
      ],
      onClose: () => { if (!done) { done = true; resolve(null); } },
    });
    const okButton = () => panel.foot?.querySelector('[data-id="ok"]');
    const summary = body.querySelector('[data-ou-summary]');
    const paintFavs = () => {
      const list = favourites();
      body.querySelector('[data-ou-favs]').innerHTML = list.length
        ? `<h3 class="sh-sub">${icon('star')}Favoris du domaine</h3><div class="sh-pick-chips">${list.map((dn) => `<button class="chip" type="button" data-ou-pick="${esc(dn)}" data-tip="${esc(dn)}">${icon('folder')}${esc(rdn(dn))}</button>`).join('')}</div>`
        : '';
    };
    const paintSummary = () => {
      const ok = okButton();
      if (!chosen) {
        summary.innerHTML = '<p class="faint">Aucune OU choisie pour l’instant.</p>';
        if (ok) { ok.disabled = true; }
        return;
      }
      if (ok) ok.disabled = false;
      const fav = favourites().some((d) => d.toLowerCase() === chosen.dn.toLowerCase());
      summary.innerHTML = `<div class="sh-pick-chosen">
          <div><span class="sh-pick-label">OU choisie</span><strong>${esc(chosen.name)}</strong><span class="sh-pick-path">${esc(chosen.path ?? chosen.dn)}</span></div>
          <div class="sh-pick-tools">
            <button class="btn ghost icon xs" type="button" data-ou-copy aria-label="Copier le chemin complet" data-tip="Copier le nom distinctif">${icon('copy')}</button>
            <button class="btn ghost icon xs" type="button" data-ou-fav aria-pressed="${fav}" aria-label="${fav ? 'Retirer des favoris' : 'Ajouter aux favoris'}" data-tip="${fav ? 'Retirer des favoris' : 'Ajouter aux favoris du domaine'}">${icon('star')}</button>
          </div>
        </div>
        ${o.subtree === 'forced' ? `<p class="faint">Portée imposée${NBSP}: l’OU et toutes ses sous-OU.</p>` : o.subtree === 'none' ? '' : `<label class="sh-pick-check"><input type="checkbox" data-ou-subtree${subtree ? ' checked' : ''}> Inclure les sous-OU</label>`}
        <p class="faint">${o.effect ? `${esc(`Effet${NBSP}: ${o.effect}`)} ` : ''}L’OU est revérifiée dans l’annuaire avant d’être appliquée.</p>`;
    };
    const choose = (node) => {
      chosen = { dn: node.dn, name: node.name, path: node.path };
      paintSummary();
      announce(`OU choisie${NBSP}: ${node.name}.`);
    };
    const tree = createTree(body.querySelector('[data-ou-tree]'), {
      label: 'Unités d’organisation',
      height: '320px',
      roots: async () => {
        const r = await call('directory.ou.children', { dn: null });
        const rootNode = { id: r.parent.dn, label: r.parent.name, icon: 'domain', selectable: o.allowRoot === true, data: { dn: r.parent.dn, name: r.parent.name, path: r.parent.path },
          children: r.children.map(node) };
        return [rootNode];
      },
      load: async (n) => (await call('directory.ou.children', { dn: n.data.dn })).children.map(node),
      onSelect: (n) => { if (n.selectable !== false) choose(n.data); },
      onActivate: (n) => { if (n.selectable !== false) { choose(n.data); validate(); } },
    });
    const search = async () => {
      const text = body.querySelector('[data-ou-q]').value.trim();
      const box = body.querySelector('[data-ou-results]');
      if (!text) { box.hidden = true; return; }
      box.hidden = false;
      box.innerHTML = '<p class="sh-loading" aria-busy="true"><span class="k-spin"></span>Recherche des OU…</p>';
      try {
        const found = await call('directory.ou.search', { text });
        box.innerHTML = found.length
          ? `<ol class="sh-pick-list">${found.map((n) => `<li><button type="button" class="sh-pick-item" data-ou-pick="${esc(n.dn)}" data-name="${esc(n.name)}" data-path="${esc(n.path)}">${icon('folder')}<span><strong>${esc(n.name)}</strong><span class="sh-pick-path">${esc(n.path)}</span></span><span class="k-badge">${n.counts.computers + n.counts.users}</span></button></li>`).join('')}</ol>${found.length >= 50 ? '<p class="faint">50 OU au plus : précisez la recherche pour voir les autres.</p>' : ''}`
          : '<p class="faint">Aucune OU ne contient ce texte.</p>';
      } catch (err) {
        box.innerHTML = `<p class="sh-pick-error">${esc(errorText(err))}</p>`;
      }
    };
    body.querySelector('[data-ou-find]').addEventListener('click', search);
    body.querySelector('[data-ou-q]').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); search(); } });
    body.addEventListener('click', (e) => {
      const t = e.target instanceof Element ? e.target : null;
      const pick = t?.closest('[data-ou-pick]');
      if (pick) { choose({ dn: pick.dataset.ouPick, name: pick.dataset.name ?? rdn(pick.dataset.ouPick), path: pick.dataset.path ?? pick.dataset.ouPick }); return; }
      if (t?.closest('[data-ou-copy]') && chosen) copyText(chosen.dn).then((ok) => announce(ok ? 'Nom distinctif copié.' : 'Copie impossible.'));
      if (t?.closest('[data-ou-fav]') && chosen) {
        const list = favourites();
        const has = list.some((d) => d.toLowerCase() === chosen.dn.toLowerCase());
        setFavourites(has ? list.filter((d) => d.toLowerCase() !== chosen.dn.toLowerCase()) : [...list, chosen.dn].slice(0, 20));
        paintFavs();
        paintSummary();
      }
    });
    body.addEventListener('change', (e) => { if (e.target instanceof HTMLInputElement && e.target.matches('[data-ou-subtree]')) subtree = e.target.checked; });
    async function validate() {
      if (!chosen) return;
      panel.setBusy(true);
      try {
        // Re-check: the OU must still exist (a children read answers ou.unknown otherwise).
        await call('directory.ou.children', { dn: chosen.dn });
        done = true;
        resolve({ ...chosen, subtree: o.subtree === 'forced' ? true : o.subtree === 'none' ? false : subtree });
        panel.close();
      } catch (err) {
        summary.insertAdjacentHTML('beforeend', `<p class="sh-pick-error">${esc(errorText(err))}</p>`);
      } finally {
        panel.setBusy(false);
      }
    }
    paintFavs();
    paintSummary();
    void tree;
  });
}

function node(n) {
  return { id: n.dn, label: n.name, icon: 'folder', hint: n.counts ? String(n.counts.computers + n.counts.users) : '', leaf: !n.hasChildren, data: { dn: n.dn, name: n.name, path: n.path } };
}

function rdn(dn) {
  const m = /^[A-Za-z]+=((?:\\.|[^,])+)/.exec(String(dn ?? ''));
  return m ? m[1].replace(/\\(.)/g, '$1') : String(dn ?? '');
}

// ---------- Object picker ----------

/**
 * Opens the embedded object picker. Resolves the re-checked object { kind, name, dn, objectGuid, detail, path } or null.
 * @param {{ kinds?: Array<'user'|'computer'|'ou'>, title?: string, effect?: string }} [o]
 */
export function pickObject(o = {}) {
  const allowed = (o.kinds?.length ? o.kinds : ['user', 'computer', 'ou']).filter((k) => KIND_LABELS[k]);
  return new Promise((resolve) => {
    let done = false;
    const kinds = new Set(allowed);
    let items = [];
    const body = document.createElement('div');
    body.className = 'sh-pick sh-pick-object';
    body.innerHTML = `<p class="sh-pick-effect">${icon('info')}<span>${esc(o.effect ?? 'Recherche sur tout le domaine, indépendante des filtres de l’écran : le choix est revérifié avant d’être transmis.')}</span></p>
      <div class="sh-pick-row">
        <label class="sh-pick-find">${icon('search')}<span class="visually-hidden">Nom, compte, mail ou nom DNS</span>
          <input class="input" type="search" maxlength="160" placeholder="Nom, compte, mail ou nom DNS (2 caractères au moins)" data-obj-q autocomplete="off" spellcheck="false"></label>
        <button class="btn sm primary" type="button" data-obj-find>${icon('search')}Chercher</button>
      </div>
      <div class="sh-pick-kinds" role="group" aria-label="Types d’objets">${allowed.map((k) => `<button class="k-facet" type="button" data-obj-kind="${k}" aria-pressed="true">${icon(KIND_ICONS[k])}${esc(KIND_LABELS[k])}</button>`).join('')}</div>
      <div class="sh-pick-results" data-obj-results><div class="sh-empty-mini">${icon('search')}<p><strong>Rien n’est lu avant votre recherche.</strong></p><p class="faint">Entrée lance la recherche ; 100 résultats au plus.</p></div></div>
      <div class="sh-pick-summary" data-obj-summary aria-live="polite"></div>`;
    const panel = openDrawer({
      title: o.title ?? 'Choisir un objet',
      subtitle: allowed.map((k) => KIND_LABELS[k]).join(', '),
      icon: 'search', key: 'shell.pick.objet', width: 540, body,
      actions: [{ id: 'cancel', label: 'Annuler', run: (p) => p.close() }],
      onClose: () => { if (!done) { done = true; resolve(null); } },
    });
    const results = body.querySelector('[data-obj-results]');
    const summary = body.querySelector('[data-obj-summary]');
    const search = async () => {
      const text = body.querySelector('[data-obj-q]').value.trim();
      const minimum = kinds.size === 1 && kinds.has('ou') ? 1 : 2;
      if (text.length < minimum) { summary.innerHTML = `<p class="faint">Saisissez au moins ${minimum} caractère${minimum > 1 ? 's' : ''}.</p>`; return; }
      if (!kinds.size) { summary.innerHTML = '<p class="faint">Choisissez au moins un type d’objet.</p>'; return; }
      results.innerHTML = '<p class="sh-loading" aria-busy="true"><span class="k-spin"></span>Recherche…</p>';
      try {
        const r = await call('shell.lookup', { text, kinds: [...kinds] });
        items = r.items;
        results.innerHTML = items.length
          ? `<ol class="sh-pick-list">${items.map((it, i) => `<li><button type="button" class="sh-pick-item${it.enabled ? '' : ' disabled-account'}" data-obj-i="${i}">${icon(KIND_ICONS[it.kind] ?? 'object')}<span><strong>${esc(it.name)}</strong><span class="sh-pick-path">${esc(it.detail ?? '')}${it.detail ? ' · ' : ''}${esc(it.path)}</span></span>${it.enabled ? '' : '<span class="k-badge">désactivé</span>'}</button></li>`).join('')}</ol>`
          : '<div class="sh-empty-mini"><p><strong>Aucun résultat</strong> dans le périmètre interrogé.</p><p class="faint">Un objet masqué pour ce compte ne peut pas apparaître ici.</p></div>';
        summary.innerHTML = `<p class="faint">${esc(r.summary)}</p>`;
      } catch (err) {
        results.innerHTML = `<p class="sh-pick-error">${esc(errorText(err))}</p>`;
      }
    };
    body.querySelector('[data-obj-find]').addEventListener('click', search);
    body.querySelector('[data-obj-q]').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); search(); } });
    body.addEventListener('click', async (e) => {
      const t = e.target instanceof Element ? e.target : null;
      const k = t?.closest('[data-obj-kind]');
      if (k) {
        const on = k.getAttribute('aria-pressed') !== 'true';
        k.setAttribute('aria-pressed', String(on));
        if (on) kinds.add(k.dataset.objKind); else kinds.delete(k.dataset.objKind);
        return;
      }
      const pick = t?.closest('[data-obj-i]');
      if (!pick) return;
      const it = items[Number(pick.dataset.objI)];
      if (!it) return;
      panel.setBusy(true);
      try {
        const check = await call('shell.lookup.verify', { dn: it.dn, objectGuid: it.objectGuid });
        if (check.state === 'ok' || check.state === 'moved') {
          done = true;
          resolve(check.item ?? it);
          if (check.state === 'moved') announce(check.message);
          panel.close();
        } else {
          summary.innerHTML = `<p class="sh-pick-error">${icon('alert')}${esc(check.message)}</p>`;
        }
      } catch (err) {
        summary.innerHTML = `<p class="sh-pick-error">${esc(errorText(err))}</p>`;
      } finally {
        panel.setBusy(false);
      }
    });
  });
}

// ---------- File picker ----------

/**
 * Opens the embedded file picker (open only: files are written by Domenia in its exports folder, never elsewhere).
 * Resolves { path, name } or null.
 * @param {{ filter?: 'csv'|'json'|'all', title?: string }} [o]
 */
export function pickFile(o = {}) {
  const filter = o.filter ?? 'all';
  return new Promise((resolve) => {
    let done = false;
    let listing = null;
    let selected = null;
    const body = document.createElement('div');
    body.className = 'sh-pick sh-pick-file';
    body.innerHTML = `<div class="sh-pick-row">
        <button class="btn ghost icon sm" type="button" data-file-up aria-label="Dossier parent" data-tip="Dossier parent">${icon('arrowUp')}</button>
        <div class="sh-pick-where" data-file-where></div>
      </div>
      <label class="sh-pick-find">${icon('folder')}<span class="visually-hidden">Chemin complet</span>
        <input class="input mono" type="text" maxlength="1024" placeholder="Ou saisissez un chemin complet (Entrée)" data-file-path autocomplete="off" spellcheck="false"></label>
      <div class="sh-pick-results" data-file-list></div>
      <div class="sh-pick-summary" data-file-summary aria-live="polite"></div>`;
    const panel = openDrawer({
      title: o.title ?? 'Choisir un fichier',
      subtitle: filter === 'csv' ? 'Fichiers CSV' : filter === 'json' ? 'Fichiers JSON' : 'Fichiers CSV et JSON',
      icon: 'file', key: 'shell.pick.fichier', width: 560, body,
      actions: [
        { id: 'cancel', label: 'Annuler', run: (p) => p.close() },
        { id: 'ok', label: 'Ouvrir', primary: true, run: () => accept() },
      ],
      onClose: () => { if (!done) { done = true; resolve(null); } },
    });
    const list = body.querySelector('[data-file-list]');
    const summary = body.querySelector('[data-file-summary]');
    const ok = () => panel.foot?.querySelector('[data-id="ok"]');
    const browse = async (folder) => {
      list.innerHTML = '<p class="sh-loading" aria-busy="true"><span class="k-spin"></span>Lecture du dossier…</p>';
      selected = null;
      if (ok()) ok().disabled = true;
      try {
        listing = await call('shell.files.browse', { folder: folder ?? null, filter });
        body.querySelector('[data-file-where]').textContent = listing.label ?? 'Emplacements';
        body.querySelector('[data-file-up]').disabled = !listing.folder;
        list.innerHTML = listing.entries.length
          ? `<ol class="sh-pick-list">${listing.entries.map((en, i) => `<li><button type="button" class="sh-pick-item" data-file-i="${i}">${icon(en.kind === 'file' ? 'file' : 'folder')}<span><strong>${esc(en.name)}</strong>${en.kind === 'file' ? `<span class="sh-pick-path">${esc(sizeText(en.size))}</span>` : ''}</span></button></li>`).join('')}</ol>${listing.truncated ? '<p class="faint">500 entrées au plus : saisissez le chemin complet pour atteindre les autres.</p>' : ''}`
          : `<div class="sh-empty-mini"><p><strong>${listing.folder ? 'Dossier vide' : 'Aucun emplacement'}</strong></p><p class="faint">${esc(listing.note ?? 'Seuls les fichiers du type attendu sont listés.')}</p></div>`;
      } catch (err) {
        list.innerHTML = `<p class="sh-pick-error">${esc(errorText(err))}</p>`;
      }
    };
    body.querySelector('[data-file-up]').addEventListener('click', () => browse(listing?.parent ?? null));
    body.querySelector('[data-file-path]').addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return;
      e.preventDefault();
      const path = e.target.value.trim();
      if (/\.(csv|json)$/i.test(path)) { selected = { path, name: path.split('\\').pop() }; accept(); } else browse(path);
    });
    list.addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-file-i]') : null;
      const en = b ? listing?.entries[Number(b.dataset.fileI)] : null;
      if (!en) return;
      if (en.kind !== 'file') { browse(en.path); return; }
      list.querySelectorAll('[aria-current]').forEach((x) => x.removeAttribute('aria-current'));
      b.setAttribute('aria-current', 'true');
      selected = { path: en.path, name: en.name };
      if (ok()) ok().disabled = false;
      summary.innerHTML = `<p>${icon('file')}<strong>${esc(en.name)}</strong> <span class="faint">${esc(sizeText(en.size))}</span></p>`;
    });
    list.addEventListener('dblclick', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-file-i]') : null;
      const en = b ? listing?.entries[Number(b.dataset.fileI)] : null;
      if (en?.kind === 'file') { selected = { path: en.path, name: en.name }; accept(); }
    });
    function accept() {
      if (!selected) return;
      done = true;
      resolve(selected);
      panel.close();
    }
    browse(null);
  });
}

function sizeText(bytes) {
  if (!Number.isFinite(bytes)) return '';
  if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(1).replace('.', ',')}${NBSP}Mo`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)}${NBSP}Ko`;
  return `${bytes}${NBSP}octets`;
}
