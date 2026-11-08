// Rechercher · side preview of the selected object: card with its state and destinations at once (from the row), then
// the stored fiche read from the local base (search.preview: identity, directory attributes, presence, console user,
// inventory, addresses, each value with its own date). A detail of another selection is never shown. Several selected
// rows: their statement and the collective actions. Domenia 1 RCH-001, RCH-124, RCH-129.
import { glyph } from '../../kit/glyphs.js';
import { kvSection, bindKv } from '../../kit/kv.js';
import { pill } from '../../kit/status.js';
import { copyButton, bindCopy } from '../../kit/copy.js';
import { readLayout, writeLayout, debounce } from '../../kit/util.js';
import { relTime, announce, errorText } from '../../ui.js';
import { esc, int, count, COLON, NBSP, KINDS, dateText, selectionText, ticketOuPath, parentDn } from './text.js';

const TONE = { ok: 'ok', warn: 'warn', alert: 'alert', info: 'info', off: undefined };

/**
 * @param {HTMLElement} host
 * @param {any} ctx
 * @param {{ onOpen: (row: any) => void, onGo: (route: string, row: any) => void, onRecheck: (row: any) => void, onCompare: (rows: any[]) => void,
 *   onTicket: (rows: any[]) => void, onSurvey: (mode: string, rows: any[]) => void, onBrowse: (dn: string) => void, onSearchAssociated: (row: any) => void,
 *   onToggle: (folded: boolean) => void, readOnly: () => boolean, onUnlock: (row: any) => void }} o
 */
export function createPreview(host, ctx, o) {
  const pref = readLayout('rechercher.preview') ?? {};
  const st = { row: null, rows: [], gen: 0, detail: null, folded: pref.folded === true };
  host.innerHTML = `<div class="rch-prev-in">
    <header class="rch-panel-head">
      <span class="rch-panel-ico">${glyph('eye')}</span>
      <h2 class="rch-panel-title">Aperçu</h2>
      <span class="rch-prev-state"></span>
      <button class="btn ghost icon sm rch-prev-reread" type="button" aria-label="Relire la fiche dans l’annuaire" data-tip="Relire la fiche dans l’annuaire (lecture explicite)" hidden>${glyph('refresh')}</button>
      <button class="btn ghost icon sm rch-prev-fold" type="button" aria-expanded="${!st.folded}" aria-label="${st.folded ? 'Déplier l’aperçu' : 'Replier l’aperçu'}" data-tip="${st.folded ? 'Déplier l’aperçu' : 'Replier l’aperçu'}">${glyph('panel')}</button>
    </header>
    <button class="rch-rail" type="button" aria-label="Afficher l’aperçu"><span class="rch-rail-ico">${glyph('eye')}</span><span class="rch-rail-t">Aperçu</span></button>
    <div class="rch-prev-body" aria-live="polite"></div>
  </div>`;
  const body = host.querySelector('.rch-prev-body');
  const stateEl = host.querySelector('.rch-prev-state');
  const foldBtn = host.querySelector('.rch-prev-fold');
  const rereadBtn = host.querySelector('.rch-prev-reread');
  rereadBtn.addEventListener('click', () => { if (st.row) o.onReread?.(st.row); });
  const unbindCopy = bindCopy(body);
  let kv = null;

  function fold(on) {
    st.folded = on;
    writeLayout('rechercher.preview', { folded: on });
    foldBtn.setAttribute('aria-expanded', String(!on));
    const t = on ? 'Déplier l’aperçu' : 'Replier l’aperçu';
    foldBtn.setAttribute('aria-label', t);
    foldBtn.dataset.tip = t;
    o.onToggle(on);
  }
  foldBtn.addEventListener('click', () => fold(!st.folded));
  host.querySelector('.rch-rail').addEventListener('click', () => { if (st.folded) fold(false); o.onRail?.(); });

  function paintEmpty() {
    stateEl.innerHTML = '';
    rereadBtn.hidden = true;
    body.innerHTML = `<div class="rch-prev-empty">
      <span class="rch-prev-art" aria-hidden="true">${glyph('object')}</span>
      <h3>Aucune sélection</h3>
      <p>Choisissez une ligne pour voir sa fiche enregistrée, sans relire l’annuaire.</p>
      <ul class="rch-prev-keys"><li><kbd>Entrée</kbd> ouvre la fiche</li><li><kbd>Maj</kbd> <kbd>F10</kbd> menu de la ligne</li><li><kbd>Ctrl</kbd> <kbd>A</kbd> tout sélectionner</li></ul>
    </div>`;
  }

  const avatar = (row) => {
    if (row.kind === 'user' && row.display) {
      const initials = row.display.split(/[\s-]+/).filter(Boolean).slice(0, 2).map((w) => w[0]).join('').toUpperCase();
      return `<span class="rch-ava user">${esc(initials)}</span>`;
    }
    return `<span class="rch-ava ${esc(row.kind)}">${glyph(KINDS[row.kind]?.icon ?? 'object')}</span>`;
  };

  function destinations(row, loaded) {
    // Same contract for users and workstations (Domenia 1 Get-DomeniaSelectionPreview): each unavailable destination says why.
    const isPc = row.kind === 'computer';
    const linkable = row.kind === 'user' || isPc;
    const list = [
      { id: 'fiche', label: 'Ouvrir la fiche', icon: 'object', primary: true, ok: true },
      { id: 'relations', label: 'Relations', icon: 'link', ok: linkable, tip: 'Utilisateurs et postes : les postes de l’utilisateur ou les utilisateurs du poste', reason: 'Réservé aux utilisateurs et aux postes.' },
      { id: 'poste', label: 'Poste', icon: 'monitor', ok: isPc, reason: 'Réservé aux postes.' },
      { id: 'assistance', label: 'Assistance', icon: 'lifebuoy', ok: isPc, reason: 'Réservé aux postes.' },
    ];
    return list.map((d) => `<button class="btn sm${d.primary ? ' accent' : ' subtle'}" type="button" data-go="${d.id}"${d.ok ? (d.tip ? ` data-tip="${esc(d.tip)}"` : '') : ` disabled aria-disabled="true" data-tip="${esc(d.reason)}"`}>${glyph(d.icon)}<span>${esc(d.label)}</span></button>`).join('');
  }

  function facts(row) {
    const items = [];
    if (row.login) items.push({ label: row.kind === 'computer' ? 'Compte machine' : 'Compte', value: row.login, mono: true, copy: true });
    if (row.upn) items.push({ label: row.kind === 'computer' ? 'Nom DNS' : 'UPN', value: row.upn, mono: true, copy: true });
    if (row.mail) items.push({ label: 'Courriel', value: row.mail, copy: true });
    if (row.description) items.push({ label: 'Description', value: row.description, wide: true });
    if (row.kind === 'computer') {
      const p = row.presence;
      if (p) items.push({ label: 'Présence réseau', html: `<span class="rch-presence ${p.state === 'online' ? 'ok' : p.state === 'noReply' ? 'warn' : p.state === 'error' ? 'alert' : 'off'}"><span class="rch-dot${p.state === 'online' ? ' pulse' : ''}"></span>${esc(p.label)}</span>`, sub: p.checkedAt ? `Relevé ${relTime(p.checkedAt) ?? ''} · ${dateText(p.checkedAt)}` : 'Aucun relevé de moins de 30 jours', wide: true, tip: p.detail });
      if (row.console) items.push({ label: 'Utilisateur connecté', value: row.console.state === 'seen' ? row.console.user : row.console.label, sub: row.console.at ? `Console, relevé ${relTime(row.console.at) ?? ''}` : 'Console seulement : les sessions RDP ne sont pas recensées' });
      if (row.os) items.push({ label: 'Système', value: row.os, sub: row.osVersion ?? '' });
      if (row.address) items.push({ label: 'Adresse relevée', value: `${row.address.ip ?? '—'} · ${row.address.mac ?? '—'}`, mono: true, sub: row.address.notice });
    }
    if (row.association) items.push({ label: row.kind === 'user' ? 'Postes associés' : 'Association mémorisée', value: row.association.label, sub: `${row.association.qualification} · ${row.association.source}`, tip: row.association.note, wide: true });
    if (row.group) items.push({ label: 'Étendue', value: row.group.scopeLabel }, { label: 'Membres directs', value: row.group.members });
    if (row.lastLogon || row.kind === 'user' || row.kind === 'computer') items.push({ label: 'Dernière connexion', value: row.lastLogon ? dateText(row.lastLogon, false) : null, sub: row.lastLogon ? `${relTime(row.lastLogon) ?? ''} · à 14 jours près` : row.flags.neverLoggedOn ? 'Jamais connecté' : '' });
    items.push({ label: 'Modifié', value: row.changed ? dateText(row.changed) : null }, { label: 'Créé', value: row.created ? dateText(row.created, false) : null });
    return kvSection({ id: 'facts', title: 'L’essentiel', icon: 'zap', items });
  }

  function flagsHtml(row) {
    const f = row.flags ?? {};
    const out = [];
    // The state pill of the card already says locked, to check or expired: no second pill for the same fact.
    const state = row.state?.key;
    if (f.admin) out.push(pill('accent', 'Compte d’administration', { icon: 'shield', size: 'sm' }));
    if (f.locked && state !== 'locked') out.push(pill('alert', 'Verrouillé', { icon: 'lock', size: 'sm' }));
    if (f.lockToCheck && state !== 'lockCheck') out.push(pill('warn', 'Verrouillage à vérifier', { size: 'sm' }));
    if (f.passwordExpired && state !== 'expired') out.push(pill('warn', 'Mot de passe expiré', { icon: 'key', size: 'sm' }));
    if (f.mustChange) out.push(pill('info', 'Mot de passe à changer', { size: 'sm' }));
    if (f.passwordNeverExpires) out.push(pill('off', 'Mot de passe sans expiration', { size: 'sm' }));
    if (f.inactive) out.push(pill('warn', 'Inactif depuis 90 jours', { icon: 'clock', size: 'sm' }));
    if (f.neverLoggedOn) out.push(pill('info', 'Jamais connecté', { size: 'sm' }));
    if (f.accountExpiring) out.push(pill('warn', 'Compte expirant sous 30 jours', { size: 'sm' }));
    if (f.accountExpired) out.push(pill('alert', 'Compte expiré', { size: 'sm' }));
    return out.join('');
  }

  function paintRow(row) {
    const isPc = row.kind === 'computer';
    const ou = ticketOuPath(row.dn);
    body.innerHTML = `<article class="rch-obj" data-kind="${esc(row.kind)}">
      <div class="rch-obj-hero">
        ${avatar(row)}
        <div class="rch-obj-titles">
          <span class="rch-obj-kind">${glyph(KINDS[row.kind]?.icon ?? 'object')}${esc(row.kindLabel)}</span>
          <h3 class="rch-obj-name">${esc(row.name)}</h3>
          ${row.display && row.display !== row.name ? `<p class="rch-obj-display">${esc(row.display)}</p>` : ''}
        </div>
        ${pill(row.state.tone, row.state.label, { size: 'sm' })}
      </div>
      <p class="rch-obj-path" data-tip="${esc(row.dn)}">${glyph('ou')}<button type="button" class="rch-obj-parent" data-act="parent">${esc(ou || row.container)}</button>${copyButton(row.dn, { label: 'Copier le chemin LDAP (DN)', done: 'Chemin copié' })}</p>
      <div class="rch-obj-flags">${flagsHtml(row)}</div>
      <div class="rch-obj-go">${destinations(row)}</div>
      <div class="rch-obj-tools">
        ${isPc ? `<button class="btn sm" type="button" data-act="recheck"${row.flags.disabled ? ' disabled data-tip="Poste désactivé"' : ' data-tip="Un ping et l’utilisateur connecté de ce seul poste"'}>${glyph('wifi')}Revérifier ce poste<span class="rch-net-dot" aria-hidden="true"></span></button>` : ''}
        ${row.association?.dn ? `<button class="btn sm subtle" type="button" data-act="associated">${glyph('link')}${isPc ? 'Rechercher l’utilisateur' : 'Rechercher le poste'}</button>` : row.kind === 'user' && row.association ? `<button class="btn sm subtle" type="button" data-act="associated">${glyph('link')}Rechercher le poste</button>` : ''}
        <button class="btn sm subtle" type="button" data-act="ticket">${glyph('copy')}Copier pour un ticket</button>
        ${row.kind === 'user' && (row.flags.locked || row.flags.lockToCheck) ? `<button class="btn sm rch-write" type="button" data-act="unlock"${o.readOnly() ? ' disabled data-tip="Lecture seule"' : ' data-tip="Écriture : plan relu par le moteur, confirmation, reçu, puis relecture"'}>${glyph('lock')}Déverrouiller…<span class="k-cmd-mark" aria-hidden="true">${glyph('edit')}</span></button>` : ''}
      </div>
      <div class="rch-obj-sheet">${facts(row)}<div class="rch-obj-detail" aria-busy="true">${skeleton()}</div></div>
    </article>`;
    kv?.destroy();
    kv = bindKv(body, { key: 'rechercher.apercu' });
  }

  const skeleton = () => `<div class="sk-stack rch-prev-sk"><span class="skeleton sk sk-line w40"></span><span class="skeleton sk sk-line w85"></span><span class="skeleton sk sk-line w70"></span><span class="skeleton sk sk-line w55"></span></div>`;

  function paintDetail(preview) {
    const box = body.querySelector('.rch-obj-detail');
    if (!box) return;
    const sections = preview.sections.filter((s) => s.id !== 'identity').map((s) => kvSection({
      id: s.id, title: s.title, icon: { attributes: 'database', presence: 'wifi', console: 'user', inventory: 'chip', addresses: 'hash', association: 'link' }[s.id] ?? 'info',
      open: s.id !== 'attributes',
      items: s.items.map((it) => ({ label: it.label.replace(/^Attribut AD · /, ''), value: it.value, sub: it.date, mono: it.mono, tone: TONE[it.tone] ?? undefined, copy: it.mono ? it.value : false, wide: it.value.length > 46 })),
    }));
    box.removeAttribute('aria-busy');
    box.innerHTML = `${sections.join('')}<p class="rch-prev-src">${glyph('database')}Fiche enregistrée · ${esc(preview.source)} · ${count(preview.attributes, 'attribut', 'attributs')}${preview.truncated ? ' (affichage limité à 80)' : ''}. Aucune relecture de l’annuaire.</p>`;
    kv?.destroy();
    kv = bindKv(body, { key: 'rechercher.apercu' });
    stateEl.innerHTML = pill('ok', 'Fiche lue', { size: 'sm', tip: 'Fiche enregistrée de la base locale (ou de l’annuaire fictif), lue pour cette sélection.' });
  }

  const load = debounce(async (row, my) => {
    try {
      const preview = await ctx.call('search.preview', { id: row.id });
      if (my !== st.gen) return; // the detail of another selection is never shown
      st.detail = preview;
      paintDetail(preview);
    } catch (err) {
      if (my !== st.gen) return;
      const box = body.querySelector('.rch-obj-detail');
      if (box) {
        box.removeAttribute('aria-busy');
        const refused = /refus|denied/i.test(err?.message ?? '');
        box.innerHTML = `<p class="rch-prev-err">${glyph('alert')}${esc(refused ? 'Lecture refusée pour ce compte : la fiche n’est pas affichée.' : `Lecture en erreur${COLON}${errorText(err)}`)}</p><button class="btn sm" type="button" data-act="retry">${glyph('refresh')}Réessayer</button>`;
      }
      stateEl.innerHTML = pill('alert', 'Lecture en erreur', { size: 'sm' });
    }
  }, 160);

  function paintMany(rows) {
    stateEl.innerHTML = '';
    const pcs = rows.filter((r) => r.kind === 'computer');
    const kinds = new Set(rows.map((r) => r.kind));
    const comparable = rows.length >= 2 && rows.length <= 8 && kinds.size === 1 && (kinds.has('computer') || kinds.has('user'));
    const byKind = Object.entries(KINDS).map(([k, v]) => [v, rows.filter((r) => r.kind === k).length]).filter(([, n]) => n > 0);
    body.innerHTML = `<div class="rch-many">
      <div class="rch-many-stack" aria-hidden="true">${rows.slice(0, 4).map((r, n) => `<span class="rch-many-card" data-j="${n}">${avatar(r)}<b>${esc(r.name)}</b></span>`).join('')}</div>
      <h3>${esc(selectionText(rows.length, pcs.length))}</h3>
      <ul class="rch-many-kinds">${byKind.map(([k, n]) => `<li>${glyph(k.icon)}${esc(count(n, k.label.toLowerCase(), k.plural.toLowerCase()))}</li>`).join('')}</ul>
      <div class="rch-many-acts">
        <button class="btn sm accent" type="button" data-act="compare"${comparable ? '' : ' disabled data-tip="Comparez de deux à huit objets d’un même type (postes ou comptes)"'}>${glyph('split')}Comparer</button>
        <button class="btn sm" type="button" data-act="ping"${pcs.length ? '' : ' disabled data-tip="Aucun poste dans la sélection"'}>${glyph('wifi')}Pinger ${pcs.length ? int(pcs.length) : ''}<span class="rch-net-dot" aria-hidden="true"></span></button>
        <button class="btn sm" type="button" data-act="console"${pcs.length ? '' : ' disabled data-tip="Aucun poste dans la sélection"'}>${glyph('users')}Qui est connecté${NBSP}?<span class="rch-net-dot" aria-hidden="true"></span></button>
        <button class="btn sm subtle" type="button" data-act="ticket">${glyph('copy')}Copier pour un ticket</button>
      </div>
      <p class="rch-many-note">Les relevés portent sur les postes sélectionnés encore affichés ; confirmation chiffrée avant toute lecture.</p>
    </div>`;
    body.querySelectorAll('[data-j]').forEach((x) => x.style.setProperty('--j', x.dataset.j));
  }

  body.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const go = t.closest('[data-go]');
    const row = st.row;
    if (go && row) { if (go.dataset.go === 'fiche') o.onOpen(row); else o.onGo(go.dataset.go, row); return; }
    const act = t.closest('[data-act]')?.dataset.act;
    if (!act) return;
    if (act === 'recheck' && row) o.onRecheck(row);
    else if (act === 'associated' && row) o.onSearchAssociated(row);
    else if (act === 'unlock' && row) o.onUnlock(row);
    else if (act === 'ticket') o.onTicket(st.rows.length > 1 ? st.rows : row ? [row] : []);
    else if (act === 'parent' && row) o.onBrowse(parentDn(row.dn));
    else if (act === 'retry' && row) { show(row, true); }
    else if (act === 'compare') o.onCompare(st.rows);
    else if (act === 'ping') o.onSurvey('ping', st.rows);
    else if (act === 'console') o.onSurvey('console', st.rows);
  });

  function show(row, force = false) {
    if (!row) { st.row = null; st.gen++; load.cancel(); paintEmpty(); return; }
    if (!force && st.row?.id === row.id && st.rows.length <= 1) { st.row = row; return; }
    st.row = row;
    st.rows = [row];
    const my = ++st.gen;
    rereadBtn.hidden = false;
    paintRow(row);
    stateEl.innerHTML = pill('info', 'Chargement de la fiche', { size: 'sm', spin: true });
    body.querySelector('.rch-obj')?.classList.add('enter');
    load(row, my);
  }

  paintEmpty();
  if (st.folded) queueMicrotask(() => o.onToggle(true));

  return {
    show,
    /** Selection of several rows: statement and collective actions, never a detail. */
    showMany(rows) {
      if (!rows || rows.length <= 1) { show(rows?.[0] ?? null); return; }
      st.rows = rows;
      st.row = null;
      st.gen++;
      load.cancel();
      rereadBtn.hidden = true;
      paintMany(rows);
    },
    /** Refreshes the card after the row changed (survey, recheck), keeping the detail already read. */
    update(row) {
      if (!row || st.row?.id !== row.id) return;
      st.row = row;
      const detail = st.detail;
      paintRow(row);
      if (detail && detail.row?.id === row.id) paintDetail(detail);
      else { const my = ++st.gen; load(row, my); }
    },
    current: () => st.row,
    /** The fiche of the row was read again in the directory (RCH-129): its time shows in the state pill. */
    setFresh(row, at, source) {
      if (!row || st.row?.id !== row.id) return;
      stateEl.innerHTML = pill('ok', `Relue à ${dateText(at).slice(11)}`, { size: 'sm', tip: `Fiche relue dans ${source} pour cette sélection ; la ligne de la liste suit.` });
    },
    setBusy(on) { rereadBtn.classList.toggle('spinning', !!on); rereadBtn.disabled = !!on; },
    folded: () => st.folded,
    destroy() { load.cancel(); kv?.destroy(); unbindCopy(); host.replaceChildren(); },
  };
}
