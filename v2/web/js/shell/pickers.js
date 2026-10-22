// Shared pickers of the shell (TRV-242 to TRV-246): the OU picker (tree read on expansion, search by name with the path of
// each OU, favourite OUs of the domain told apart, the initial OU or a favourite revealed parent by parent, scope with or
// without sub-OUs, summary before validation, DN and GUID re-checked, choice refused when the session changed), the embedded
// object picker (users, workstations, OUs; at least 2 characters, 100 results; DN and GUID re-checked, a moved object shown
// and confirmed) and the embedded file picker (open and save modes; local folders, network shares only on request, 500
// entries; « Remplacer » bound to the size and date of the file). Every read follows an explicit gesture.
import { icon } from '../icons.js';
import { esc, errorText, announce, copyText } from '../ui.js';
import { openDrawer, createTree } from '../kit/index.js';
import { state, trackedCall, setFavourites, sessionMark } from './store.js';

const NBSP = '\u00A0';
const KIND_LABELS = { user: 'Utilisateurs', computer: 'Postes', ou: 'OU' };
const KIND_ICONS = { user: 'user', computer: 'monitor', ou: 'folder' };
/** OUs found by a search of the picker at most (Domenia 1: 100 results). */
export const OU_SEARCH_LIMIT = 100;

function call(op, args) { return trackedCall(op, args); }

// ---------- Pure rules (tests/web/shell/pickers.test.mjs) ----------

/** Components of a DN, escapes kept (« CN=Dupont\, Jean,OU=… » gives two components). */
export function dnParts(dn) {
  return String(dn ?? '').split(/(?<!\\),/).map((p) => p.trim()).filter(Boolean);
}

/** Value of a component, escapes removed (« OU=R\&D » gives « R&D »). */
function partValue(part) {
  const at = part.indexOf('=');
  return (at < 0 ? part : part.slice(at + 1)).replace(/\\([0-9a-f]{2})/gi, (_, h) => String.fromCharCode(parseInt(h, 16))).replace(/\\(.)/g, '$1');
}

/** First value of a DN (« OU=Postes,DC=… » gives « Postes »). */
export function rdn(dn) {
  const first = dnParts(dn)[0];
  return first ? partValue(first) : String(dn ?? '');
}

/** OU and container names of a DN from the leaf upward, DC components left out (Domenia 1 Get-DomeniaOuPathNames). */
export function ouPathNames(dn) {
  return dnParts(dn).filter((p) => !/^dc=/i.test(p)).map(partValue);
}

/** « Postes › Paris » from the top (domain components left out). */
export function ouDisplayPath(dn) {
  return [...ouPathNames(dn)].reverse().join(' › ');
}

/**
 * Labels that tell apart OUs of the same name (Domenia 1 Get-DomeniaOuDistinctLabels): « Postes (Lyon) » and
 * « Postes (Paris) », widened one parent at a time; the full path when the names stay equal up to the domain. Display only.
 * @param {string[]} dns
 * @returns {Array<{ dn: string, label: string, path: string, ambiguous: boolean }>}
 */
export function distinctOuLabels(dns) {
  const entries = [];
  const seen = new Set();
  for (const value of dns ?? []) {
    const dn = String(value ?? '').trim();
    if (!dn || seen.has(dn.toLowerCase())) continue;
    seen.add(dn.toLowerCase());
    const names = ouPathNames(dn);
    const leaf = names[0] ?? dn;
    entries.push({ dn, names, leaf, label: leaf, path: ouDisplayPath(dn), ambiguous: false });
  }
  const groups = new Map();
  for (const e of entries) {
    const k = e.leaf.toLowerCase();
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(e);
  }
  for (const group of groups.values()) {
    if (group.length < 2) continue;
    let unique = false;
    for (let depth = 1; depth <= 64; depth += 1) {
      let exhausted = true;
      const counts = new Map();
      for (const e of group) {
        e.ambiguous = true;
        const count = Math.min(depth, e.names.length - 1);
        if (e.names.length - 1 > depth) exhausted = false;
        const qualifier = count > 0 ? e.names.slice(1, count + 1).reverse().join(' / ') : 'racine du domaine';
        e.label = `${e.leaf} (${qualifier})`;
        const f = e.label.toLowerCase();
        counts.set(f, (counts.get(f) ?? 0) + 1);
      }
      unique = [...counts.values()].every((n) => n === 1);
      if (unique || exhausted) break;
    }
    if (!unique) for (const e of group) e.label = `${e.leaf} (${e.path})`;
  }
  return entries.map(({ dn, label, path, ambiguous }) => ({ dn, label, path, ambiguous }));
}

/**
 * Ids of the tree from the domain root to a DN (lower case, as the picker builds its nodes), or null when the DN is not
 * inside the domain.
 */
export function revealPath(dn, rootDn) {
  const target = String(dn ?? '').trim().toLowerCase();
  const root = String(rootDn ?? '').trim().toLowerCase();
  if (!target || !root || (target !== root && !target.endsWith(`,${root}`))) return null;
  const parts = dnParts(target);
  const rootCount = dnParts(root).length;
  const path = [];
  for (let n = parts.length - rootCount; n >= 0; n -= 1) path.push(parts.slice(n).join(','));
  return path;
}

/** What the picker does with the answer of shell.lookup.verify (Domenia 1: « objet déplacé, recréé ou inaccessible »). */
export function verifyDecision(check) {
  const st = check?.state;
  if (st === 'ok') return { accept: true, confirm: false, tone: 'ok' };
  if (st === 'moved') return { accept: false, confirm: true, tone: 'warn' };
  return { accept: false, confirm: false, tone: 'alert' };
}

// ---------- OU picker ----------

/**
 * Opens the OU picker. Resolves { dn, name, path, subtree, objectGuid } once the operator validates (DN and GUID re-checked
 * first), or null.
 * @param {{ title?: string, effect?: string, subtree?: 'choice'|'forced'|'none', initial?: string, allowRoot?: boolean }} [o]
 */
export function pickOu(o = {}) {
  return new Promise((resolve) => {
    let chosen = null;
    let subtree = o.subtree !== 'none';
    let done = false;
    let rootDn = state.session?.domain?.rootDn ?? '';
    const mark = sessionMark();
    const favourites = () => state.engine?.ouFavourites ?? [];
    const body = document.createElement('div');
    body.className = 'sh-pick sh-pick-ou';
    body.innerHTML = `<p class="sh-pick-effect">${icon('info')}<span>${esc(o.effect ?? 'Choisissez une OU : seules les OU se choisissent, les conteneurs servent à naviguer.')}</span></p>
      <div class="sh-pick-row">
        <label class="sh-pick-find">${icon('search')}<span class="visually-hidden">Chercher une OU par nom</span>
          <input class="input" type="search" maxlength="100" placeholder="Chercher une OU par nom (Entrée)" data-ou-q autocomplete="off" spellcheck="false"></label>
        <button class="btn sm subtle" type="button" data-ou-find>${icon('search')}Chercher</button>
      </div>
      <div class="sh-pick-favs" data-ou-favs></div>
      <div class="sh-pick-results" data-ou-results hidden></div>
      <div class="sh-pick-tree" data-ou-tree></div>
      <div class="sh-pick-summary" data-ou-summary aria-live="polite"></div>`;
    const panel = openDrawer({
      title: o.title ?? 'Choisir une OU',
      subtitle: state.session?.domain?.dnsName ? `Domaine ${state.session.domain.dnsName}` : 'Annuaire de la session',
      icon: 'folder', side: 'left', key: 'shell.pick.ou', width: 540, body,
      actions: [
        { id: 'cancel', label: 'Annuler', run: (p) => p.close() },
        { id: 'ok', label: 'Choisir cette OU', primary: true, run: () => validate() },
      ],
      onClose: () => { if (!done) { done = true; resolve(null); } },
    });
    const okButton = () => panel.foot?.querySelector('[data-id="ok"]');
    const summary = body.querySelector('[data-ou-summary]');
    const paintFavs = () => {
      const list = distinctOuLabels(favourites());
      body.querySelector('[data-ou-favs]').innerHTML = list.length
        ? `<h3 class="sh-sub">${icon('star')}Favoris du domaine</h3><div class="sh-pick-chips">${list.map((f) => `<button class="chip" type="button" data-ou-fav-pick="${esc(f.dn)}" data-tip="${esc(f.path || f.dn)}">${icon('folder')}${esc(f.label)}</button>`).join('')}</div>`
        : '';
    };
    const paintSummary = (extra = '') => {
      const ok = okButton();
      if (!chosen) {
        summary.innerHTML = `<p class="faint">Aucune OU choisie pour l’instant.</p>${extra}`;
        if (ok) ok.disabled = true;
        return;
      }
      if (ok) ok.disabled = chosen.state === 'reading' || chosen.state === 'missing' || chosen.state === 'denied';
      const fav = favourites().some((d) => d.toLowerCase() === chosen.dn.toLowerCase());
      const status = { reading: ['info', 'OU en cours de relecture…'], ok: ['ok', 'OU relue : nom distinctif et GUID connus.'], missing: ['alert', chosen.message], denied: ['alert', chosen.message], unchecked: ['info', 'Relecture faite à la validation.'] }[chosen.state] ?? ['info', ''];
      summary.innerHTML = `<div class="sh-pick-chosen">
          <div><span class="sh-pick-label">OU choisie</span><strong>${esc(chosen.name)}</strong><span class="sh-pick-path">${esc(chosen.path ?? chosen.dn)}</span>
            <span class="sh-pick-state" data-tone="${status[0]}">${esc(status[1] ?? '')}</span></div>
          <div class="sh-pick-tools">
            <button class="btn ghost icon xs" type="button" data-ou-copy aria-label="Copier le chemin complet" data-tip="Copier le nom distinctif">${icon('copy')}</button>
            <button class="btn ghost icon xs" type="button" data-ou-fav aria-pressed="${fav}" aria-label="${fav ? 'Retirer des favoris' : 'Ajouter aux favoris'}" data-tip="${fav ? 'Retirer des favoris' : 'Ajouter aux favoris du domaine'}">${icon('star')}</button>
          </div>
        </div>
        ${o.subtree === 'forced' ? `<p class="faint">Portée imposée${NBSP}: l’OU et toutes ses sous-OU.</p>` : o.subtree === 'none' ? '' : `<label class="sh-pick-check"><input type="checkbox" data-ou-subtree${subtree ? ' checked' : ''}> Inclure les sous-OU</label>`}
        <p class="faint">${o.effect ? `${esc(`Effet${NBSP}: ${o.effect}`)} ` : ''}Le nom distinctif et le GUID de l’OU sont revérifiés dans l’annuaire avant qu’elle soit appliquée.</p>${extra}`;
    };
    // Reads the GUID of an OU chosen in the tree (the tree knows names and DNs only), after the gesture of the operator.
    const resolveGuid = async (pick) => {
      try {
        const r = await call('shell.ou.resolve', { dn: pick.dn });
        if (chosen !== pick) return;
        pick.state = r.state === 'ok' ? 'ok' : r.state;
        pick.message = r.message;
        if (r.item) { pick.objectGuid = r.item.objectGuid; pick.path = r.item.path ?? pick.path; }
      } catch (err) {
        if (chosen !== pick) return;
        // An engine without the operation (browser preview): the choice is re-read by its children at the validation.
        pick.state = err?.code === 'operation.unknown' ? 'unchecked' : 'missing';
        pick.message = errorText(err);
      }
      paintSummary();
    };
    const choose = (node) => {
      chosen = { dn: node.dn, name: node.name, path: node.path, objectGuid: node.objectGuid ?? null, state: node.objectGuid ? 'ok' : 'reading', message: '' };
      paintSummary();
      announce(`OU choisie${NBSP}: ${node.name}.`);
      if (!node.objectGuid) resolveGuid(chosen);
    };
    const tree = createTree(body.querySelector('[data-ou-tree]'), {
      label: 'Unités d’organisation',
      height: '320px',
      roots: async () => {
        const r = await call('directory.ou.children', { dn: null });
        rootDn = r.parent.dn;
        const rootNode = { id: r.parent.dn.toLowerCase(), label: r.parent.name, icon: 'domain', selectable: o.allowRoot === true, data: { dn: r.parent.dn, name: r.parent.name, path: r.parent.path },
          children: r.children.map(node) };
        if (o.initial) setTimeout(() => reveal(o.initial), 0);
        return [rootNode];
      },
      load: async (n) => (await call('directory.ou.children', { dn: n.data.dn })).children.map(node),
      onSelect: (n) => { if (n.selectable !== false) choose(n.data); },
      onActivate: (n) => { if (n.selectable !== false) { choose(n.data); validate(); } },
    });
    // Shows an OU in the tree by reading its parents one by one (current choice, favourite).
    async function reveal(dn) {
      const path = revealPath(dn, rootDn);
      if (!path) return false;
      try {
        const ok = await tree.reveal(path);
        if (!ok) announce('OU absente de l’arborescence lue : elle a peut-être été déplacée.');
        return ok;
      } catch (err) {
        console.warn(err);
        return false;
      }
    }
    const search = async () => {
      const text = body.querySelector('[data-ou-q]').value.trim();
      const box = body.querySelector('[data-ou-results]');
      if (!text) { box.hidden = true; return; }
      box.hidden = false;
      box.innerHTML = '<p class="sh-loading" aria-busy="true"><span class="k-spin"></span>Recherche des OU…</p>';
      let found;
      let truncated = false;
      try {
        try {
          const r = await call('shell.lookup', { text, kinds: ['ou'] });
          found = r.items.map((it) => ({ dn: it.dn, name: it.name, path: it.path, objectGuid: it.objectGuid }));
          truncated = r.truncated;
        } catch (err) {
          if (err?.code !== 'operation.unknown') throw err;
          found = (await call('directory.ou.search', { text })).map((n) => ({ dn: n.dn, name: n.name, path: n.path, objectGuid: null }));
          truncated = found.length >= 50;
        }
        box.innerHTML = found.length
          ? `<ol class="sh-pick-list">${found.map((n, i) => `<li><button type="button" class="sh-pick-item" data-ou-hit="${i}">${icon('folder')}<span><strong>${esc(n.name)}</strong><span class="sh-pick-path">${esc(n.path)}</span></span></button></li>`).join('')}</ol>${truncated ? `<p class="faint">${OU_SEARCH_LIMIT}${NBSP}OU au plus${NBSP}: précisez la recherche pour voir les autres.</p>` : ''}`
          : '<p class="faint">Aucune OU ne contient ce texte.</p>';
        box.onclick = (e) => {
          const b = e.target instanceof Element ? e.target.closest('[data-ou-hit]') : null;
          const n = b ? found[Number(b.dataset.ouHit)] : null;
          if (!n) return;
          choose(n);
          reveal(n.dn);
        };
      } catch (err) {
        box.innerHTML = `<p class="sh-pick-error">${esc(errorText(err))}</p>`;
      }
    };
    body.querySelector('[data-ou-find]').addEventListener('click', search);
    body.querySelector('[data-ou-q]').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); search(); } });
    body.addEventListener('click', (e) => {
      const t = e.target instanceof Element ? e.target : null;
      const fav = t?.closest('[data-ou-fav-pick]');
      if (fav) {
        const dn = fav.dataset.ouFavPick;
        choose({ dn, name: rdn(dn), path: ouDisplayPath(dn) });
        reveal(dn);
        return;
      }
      if (t?.closest('[data-ou-copy]') && chosen) copyText(chosen.dn).then((ok) => announce(ok ? 'Nom distinctif copié.' : 'Copie impossible.'));
      if (t?.closest('[data-ou-fav]') && chosen) {
        const list = favourites();
        const has = list.some((d) => d.toLowerCase() === chosen.dn.toLowerCase());
        setFavourites(has ? list.filter((d) => d.toLowerCase() !== chosen.dn.toLowerCase()) : [...list, chosen.dn].slice(0, 20));
        paintFavs();
        paintSummary();
      }
      const moved = t?.closest('[data-ou-moved]');
      if (moved && chosen?.moved) {
        const item = chosen.moved;
        if (moved.dataset.ouMoved === 'accept') { finish({ dn: item.dn, name: item.name, path: item.path, objectGuid: item.objectGuid }); return; }
        chosen = null;
        paintSummary();
      }
    });
    body.addEventListener('change', (e) => { if (e.target instanceof HTMLInputElement && e.target.matches('[data-ou-subtree]')) subtree = e.target.checked; });
    function finish(pick) {
      done = true;
      resolve({ dn: pick.dn, name: pick.name, path: pick.path, objectGuid: pick.objectGuid ?? null, subtree: o.subtree === 'forced' ? true : o.subtree === 'none' ? false : subtree });
      panel.close();
    }
    async function validate() {
      if (!chosen || chosen.state === 'reading') return;
      if (sessionMark() !== mark) {
        paintSummary(`<p class="sh-pick-error">${icon('alert')}La session a changé depuis l’ouverture du sélecteur${NBSP}: ce choix est refusé. Fermez le sélecteur et choisissez de nouveau.</p>`);
        return;
      }
      panel.setBusy(true);
      try {
        if (chosen.objectGuid) {
          const check = await call('shell.lookup.verify', { dn: chosen.dn, objectGuid: chosen.objectGuid });
          const d = verifyDecision(check);
          if (d.accept) { finish(chosen); return; }
          if (d.confirm && check.item) {
            chosen.moved = check.item;
            paintSummary(`<div class="sh-pick-warn" role="alert">${icon('alert')}<div><strong>OU déplacée ou renommée depuis votre choix.</strong><span>Nouvel emplacement${NBSP}: ${esc(check.item.path ?? check.item.dn)}</span>
              <div class="sh-pick-warn-actions"><button class="btn sm primary" type="button" data-ou-moved="accept">Choisir à ce nouvel emplacement</button><button class="btn sm ghost" type="button" data-ou-moved="other">Choisir une autre OU</button></div></div></div>`);
            return;
          }
          paintSummary(`<p class="sh-pick-error">${icon('alert')}${esc(check.message)}</p>`);
          return;
        }
        // No GUID known (older engine, browser preview): the OU must still exist (its children are read again).
        await call('directory.ou.children', { dn: chosen.dn });
        finish(chosen);
      } catch (err) {
        paintSummary(`<p class="sh-pick-error">${esc(errorText(err))}</p>`);
      } finally {
        panel.setBusy(false);
      }
    }
    paintFavs();
    paintSummary();
  });
}

function node(n) {
  return { id: n.dn.toLowerCase(), label: n.name, icon: 'folder', hint: n.counts ? String(n.counts.computers + n.counts.users) : '', leaf: !n.hasChildren, data: { dn: n.dn, name: n.name, path: n.path } };
}

// ---------- Object picker ----------

/**
 * Opens the embedded object picker. Resolves the re-checked object { kind, name, dn, objectGuid, detail, path } or null. An
 * object moved or renamed since the search is shown with its new place and handed over only once the operator confirms it.
 * @param {{ kinds?: Array<'user'|'computer'|'ou'>, title?: string, effect?: string }} [o]
 */
export function pickObject(o = {}) {
  const allowed = (o.kinds?.length ? o.kinds : ['user', 'computer', 'ou']).filter((k) => KIND_LABELS[k]);
  return new Promise((resolve) => {
    let done = false;
    const mark = sessionMark();
    const kinds = new Set(allowed);
    let items = [];
    let moved = null;
    const body = document.createElement('div');
    body.className = 'sh-pick sh-pick-object';
    body.innerHTML = `<p class="sh-pick-effect">${icon('info')}<span>${esc(o.effect ?? 'Recherche sur tout le domaine, indépendante des filtres de l’écran : le choix est revérifié avant d’être transmis.')}</span></p>
      <div class="sh-pick-row">
        <label class="sh-pick-find">${icon('search')}<span class="visually-hidden">Nom, compte, mail ou nom DNS</span>
          <input class="input" type="search" maxlength="160" placeholder="Nom, compte, mail ou nom DNS (2 caractères au moins)" data-obj-q autocomplete="off" spellcheck="false"></label>
        <button class="btn sm primary" type="button" data-obj-find>${icon('search')}Chercher</button>
      </div>
      <div class="sh-pick-kinds" role="group" aria-label="Types d’objets">${allowed.map((k) => `<button class="k-facet" type="button" data-obj-kind="${k}" aria-pressed="true">${icon(KIND_ICONS[k])}${esc(KIND_LABELS[k])}</button>`).join('')}</div>
      <div class="sh-pick-results" data-obj-results><div class="sh-empty-mini">${icon('search')}<p><strong>Rien n’est lu avant votre recherche.</strong></p><p class="faint">Entrée lance la recherche${NBSP}; 100 résultats au plus.</p></div></div>
      <div class="sh-pick-summary" data-obj-summary aria-live="polite"></div>`;
    const panel = openDrawer({
      title: o.title ?? 'Choisir un objet',
      subtitle: allowed.map((k) => KIND_LABELS[k]).join(', '),
      icon: 'search', key: 'shell.pick.objet', width: 560, body,
      actions: [{ id: 'cancel', label: 'Annuler', run: (p) => p.close() }],
      onClose: () => { if (!done) { done = true; resolve(null); } },
    });
    const results = body.querySelector('[data-obj-results]');
    const summary = body.querySelector('[data-obj-summary]');
    const finish = (item) => { done = true; resolve(item); panel.close(); };
    const search = async () => {
      const text = body.querySelector('[data-obj-q]').value.trim();
      const minimum = kinds.size === 1 && kinds.has('ou') ? 1 : 2;
      moved = null;
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
      const m = t?.closest('[data-obj-moved]');
      if (m && moved) {
        if (m.dataset.objMoved === 'accept') { finish(moved); return; }
        moved = null;
        summary.innerHTML = '<p class="faint">Choisissez un autre objet dans la liste ou lancez une nouvelle recherche.</p>';
        return;
      }
      const pick = t?.closest('[data-obj-i]');
      if (!pick) return;
      const it = items[Number(pick.dataset.objI)];
      if (!it) return;
      if (sessionMark() !== mark) {
        summary.innerHTML = `<p class="sh-pick-error">${icon('alert')}La session a changé depuis l’ouverture du sélecteur${NBSP}: ce choix est refusé.</p>`;
        return;
      }
      panel.setBusy(true);
      try {
        const check = await call('shell.lookup.verify', { dn: it.dn, objectGuid: it.objectGuid });
        const d = verifyDecision(check);
        if (d.accept) { finish(check.item ?? it); return; }
        if (d.confirm && check.item) {
          // Visible, never only announced: the operator decides whether the object at its new place is still the right one.
          moved = check.item;
          summary.innerHTML = `<div class="sh-pick-warn" role="alert">${icon('alert')}<div><strong>Objet déplacé, renommé ou recréé depuis votre recherche.</strong>
            <span>${esc(check.message)}</span><span class="mono">${esc(check.item.path ?? check.item.dn)}</span>
            <div class="sh-pick-warn-actions"><button class="btn sm primary" type="button" data-obj-moved="accept">Choisir cet objet à son nouvel emplacement</button><button class="btn sm ghost" type="button" data-obj-moved="other">Choisir un autre objet</button></div></div></div>`;
          summary.querySelector('[data-obj-moved="accept"]')?.focus({ preventScroll: true });
          return;
        }
        summary.innerHTML = `<p class="sh-pick-error">${icon('alert')}${esc(check.message)}</p>`;
      } catch (err) {
        summary.innerHTML = `<p class="sh-pick-error">${esc(errorText(err))}</p>`;
      } finally {
        panel.setBusy(false);
      }
    });
  });
}

// ---------- File picker ----------

/** True for « \\serveur\partage… » (a network share, listed only on request). */
export function isSharePath(path) {
  return /^\\\\[A-Za-z0-9._-]+\\[^\\/:*?"<>|]+/.test(String(path ?? '').trim());
}

/** Entry of the listing with the same name (case ignored), or null: the save mode then asks « Remplacer ». */
export function conflictOf(entries, name) {
  const n = String(name ?? '').trim().toLowerCase();
  return n ? (entries ?? []).find((e) => e.kind === 'file' && String(e.name).toLowerCase() === n) ?? null : null;
}

/** A file name typed in the save mode (Windows rules, extension of the kind; same rule as ShellFileNames.IsSafe). */
export function safeFileName(name, kind) {
  const n = String(name ?? '');
  if (!n || n.length > 120 || /[\\/:*?"<>|\u0000-\u001f]/.test(n) || /[ .]$/.test(n)) return false;
  if (!n.toLowerCase().endsWith(`.${kind}`) || n.length === kind.length + 1) return false;
  const stem = n.slice(0, n.indexOf('.')).trim();
  return !!stem && !/^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i.test(stem);
}

/**
 * Opens the embedded file picker. Open mode (default) resolves { path, name, share } or null; save mode
 * ({ mode: 'save', filter: 'csv'|'json', name }) resolves { folder, name, replace } where replace is the { size, at } of
 * the file to replace (« Remplacer » clicked) or null. Local folders only for saving; a network share is listed only when
 * the operator asks for it (« Interroger ce partage »).
 * @param {{ filter?: 'csv'|'json'|'all', title?: string, mode?: 'open'|'save', name?: string }} [o]
 */
export function pickFile(o = {}) {
  const save = o.mode === 'save';
  const filter = save ? (o.filter === 'json' ? 'json' : 'csv') : (o.filter ?? 'all');
  return new Promise((resolve) => {
    let done = false;
    let listing = null;
    let selected = null;
    let replace = null;
    const body = document.createElement('div');
    body.className = `sh-pick sh-pick-file${save ? ' save' : ''}`;
    body.innerHTML = `<div class="sh-pick-row">
        <button class="btn ghost icon sm" type="button" data-file-up aria-label="Dossier parent" data-tip="Dossier parent">${icon('arrowUp')}</button>
        <div class="sh-pick-where" data-file-where></div>
      </div>
      <div class="sh-pick-row">
        <label class="sh-pick-find">${icon('folder')}<span class="visually-hidden">Chemin complet</span>
          <input class="input mono" type="text" maxlength="1024" placeholder="${save ? 'Ou saisissez le chemin complet d’un dossier local (Entrée)' : 'Ou saisissez un chemin complet, local ou \\\\serveur\\partage (Entrée)'}" data-file-path autocomplete="off" spellcheck="false"></label>
        <button class="btn sm ghost" type="button" data-file-share hidden>${icon('wifi')}Interroger ce partage</button>
      </div>
      <div class="sh-pick-results" data-file-list></div>
      ${save ? `<div class="sh-pick-save"><label class="k-field"><span class="k-label">Nom du fichier</span><input class="input mono" type="text" maxlength="120" data-file-name value="${esc(o.name ?? '')}" autocomplete="off" spellcheck="false"></label><div class="sh-pick-conflict" data-file-conflict aria-live="polite"></div></div>` : ''}
      <div class="sh-pick-summary" data-file-summary aria-live="polite"></div>`;
    const panel = openDrawer({
      title: o.title ?? (save ? 'Enregistrer sous' : 'Choisir un fichier'),
      subtitle: filter === 'csv' ? 'Fichiers CSV' : filter === 'json' ? 'Fichiers JSON' : 'Fichiers CSV et JSON',
      icon: save ? 'download' : 'file', key: save ? 'shell.pick.enregistrer' : 'shell.pick.fichier', width: 580, body,
      actions: [
        { id: 'cancel', label: 'Annuler', run: (p) => p.close() },
        { id: 'ok', label: save ? 'Enregistrer ici' : 'Ouvrir', primary: true, run: () => accept() },
      ],
      onClose: () => { if (!done) { done = true; resolve(null); } },
    });
    const list = body.querySelector('[data-file-list]');
    const summary = body.querySelector('[data-file-summary]');
    const pathInput = body.querySelector('[data-file-path]');
    const shareButton = body.querySelector('[data-file-share]');
    const nameInput = body.querySelector('[data-file-name]');
    const conflictBox = body.querySelector('[data-file-conflict]');
    const ok = () => panel.foot?.querySelector('[data-id="ok"]');
    const syncOk = () => {
      const b = ok();
      if (!b) return;
      if (!save) { b.disabled = !selected; return; }
      const name = nameInput.value.trim();
      const conflict = listing?.folder && !listing.share ? conflictOf(listing.entries, name) : null;
      if (conflict && (!replace || replace.name.toLowerCase() !== conflict.name.toLowerCase())) replace = null;
      conflictBox.innerHTML = !listing?.folder ? `<p class="faint">Ouvrez d’abord un dossier.</p>`
        : listing.share ? `<p class="sh-pick-error">${icon('alert')}Enregistrement sur un partage refusé${NBSP}: choisissez un dossier local.</p>`
          : !safeFileName(name, filter) ? `<p class="faint">Nom attendu${NBSP}: lettres, chiffres, espaces et tirets, terminé par .${filter} (sans \\ / : * ? " &lt; &gt; |).</p>`
            : conflict ? (replace ? `<p class="sh-pick-replace">${icon('alert')}Le fichier existant sera remplacé${NBSP}; s’il change d’ici l’enregistrement, rien ne sera écrit.</p>`
              : `<div class="sh-pick-warn">${icon('alert')}<div><strong>Un fichier de ce nom existe déjà.</strong><span>${esc(conflict.name)}</span><div class="sh-pick-warn-actions"><button class="btn sm danger" type="button" data-file-replace>Remplacer</button></div></div></div>`)
              : `<p class="faint">Nouveau fichier dans ${esc(listing.label ?? 'ce dossier')}.</p>`;
      b.disabled = !listing?.folder || !!listing.share || !safeFileName(name, filter) || (!!conflict && !replace);
    };
    const browse = async (folder, share = false) => {
      list.innerHTML = '<p class="sh-loading" aria-busy="true"><span class="k-spin"></span>Lecture du dossier…</p>';
      selected = null;
      replace = null;
      syncOk();
      try {
        listing = share ? await call('shell.files.share', { folder, filter }) : await call('shell.files.browse', { folder: folder ?? null, filter });
        body.querySelector('[data-file-where]').textContent = listing.label ?? 'Emplacements';
        body.querySelector('[data-file-up]').disabled = !listing.folder || (listing.share && !listing.parent);
        list.innerHTML = listing.entries.length
          ? `<ol class="sh-pick-list">${listing.entries.map((en, i) => `<li><button type="button" class="sh-pick-item${save && en.kind === 'file' ? ' existing' : ''}" data-file-i="${i}">${icon(en.kind === 'file' ? 'file' : 'folder')}<span><strong>${esc(en.name)}</strong>${en.kind === 'file' ? `<span class="sh-pick-path">${esc(sizeText(en.size))}</span>` : ''}</span></button></li>`).join('')}</ol>${listing.truncated ? '<p class="faint">500 entrées au plus : saisissez le chemin complet pour atteindre les autres.</p>' : ''}`
          : `<div class="sh-empty-mini"><p><strong>${listing.folder ? 'Dossier vide' : 'Aucun emplacement'}</strong></p><p class="faint">${esc(listing.note ?? 'Seuls les fichiers du type attendu sont listés.')}</p></div>`;
        if (listing.share && listing.note) summary.innerHTML = `<p class="faint">${icon('wifi')}${esc(listing.note)}</p>`;
      } catch (err) {
        list.innerHTML = `<p class="sh-pick-error">${esc(errorText(err))}</p>`;
      }
      syncOk();
    };
    body.querySelector('[data-file-up]').addEventListener('click', () => browse(listing?.parent ?? null, !!listing?.share && !!listing?.parent));
    pathInput.addEventListener('input', () => { shareButton.hidden = save || !isSharePath(pathInput.value); });
    pathInput.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return;
      e.preventDefault();
      const path = e.target.value.trim();
      if (!path) return;
      if (isSharePath(path)) {
        // A share is never queried by Entrée alone: the button says what will happen.
        shareButton.hidden = save;
        summary.innerHTML = save
          ? `<p class="sh-pick-error">${icon('alert')}Enregistrement sur un partage refusé${NBSP}: choisissez un dossier local.</p>`
          : `<p class="faint">${icon('wifi')}Chemin réseau${NBSP}: cliquez sur «${NBSP}Interroger ce partage${NBSP}» pour le lire (15${NBSP}s au plus).</p>`;
        return;
      }
      if (!save && /\.(csv|json)$/i.test(path)) { selected = { path, name: path.split('\\').pop(), share: false }; accept(); } else browse(path);
    });
    shareButton.addEventListener('click', () => browse(pathInput.value.trim().replace(/\\+$/, ''), true));
    list.addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-file-i]') : null;
      const en = b ? listing?.entries[Number(b.dataset.fileI)] : null;
      if (!en) return;
      if (en.kind !== 'file') { browse(en.path, !!listing?.share); return; }
      list.querySelectorAll('[aria-current]').forEach((x) => x.removeAttribute('aria-current'));
      b.setAttribute('aria-current', 'true');
      if (save) {
        nameInput.value = en.name;
        replace = null;
        syncOk();
        return;
      }
      selected = { path: en.path, name: en.name, share: !!listing?.share };
      syncOk();
      summary.innerHTML = `<p>${icon('file')}<strong>${esc(en.name)}</strong> <span class="faint">${esc(sizeText(en.size))}</span></p>`;
    });
    list.addEventListener('dblclick', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-file-i]') : null;
      const en = b ? listing?.entries[Number(b.dataset.fileI)] : null;
      if (en?.kind === 'file' && !save) { selected = { path: en.path, name: en.name, share: !!listing?.share }; accept(); }
    });
    nameInput?.addEventListener('input', syncOk);
    conflictBox?.addEventListener('click', (e) => {
      if (!(e.target instanceof Element) || !e.target.closest('[data-file-replace]')) return;
      const conflict = conflictOf(listing?.entries, nameInput.value.trim());
      if (!conflict) return;
      // « Remplacer » is bound to the file as listed: its size and date travel with the request and are checked again.
      replace = { name: conflict.name, size: conflict.size, at: conflict.at };
      syncOk();
      announce('Remplacement demandé : le fichier sera remplacé à l’enregistrement s’il n’a pas changé.');
    });
    function accept() {
      if (save) {
        const name = nameInput.value.trim();
        if (!listing?.folder || listing.share || !safeFileName(name, filter)) return;
        const conflict = conflictOf(listing.entries, name);
        if (conflict && !replace) return;
        done = true;
        resolve({ folder: listing.folder, name, replace: replace ? { size: replace.size, at: replace.at } : null });
        panel.close();
        return;
      }
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
