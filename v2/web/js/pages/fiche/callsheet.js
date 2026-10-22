// Call sheet of a user (Domenia 1 lot R40, Domenia-CallSheet): what a technician needs during a phone call, built without
// any network read from the fiche and the reads already done; each explicit read has its button (4740, password policy,
// presence, sessions, quick triage of a slow workstation). Every fact says its source, its date and its state; an unknown
// value stays unknown. « Copier pour le ticket » gives the plain text, masked by the secret rule of the journal.
import { glyph, pill, writeClipboard, NBSP, int } from '../../kit/index.js';
import { esc, errorText, toast, announce, applyVars } from '../../ui.js';
import { factRows, failure, skeleton, emptyNote, factTone, nobr } from './common.js';

/**
 * @param {HTMLElement} panel
 * @param {any} S
 */
export function mountCallSheet(panel, S) {
  let sheet = null;
  let running = '';
  let token = 0;
  let chosenComputer = null;
  let pendingFocus = null;

  const readButton = (read, label, icon) => `<button class="btn sm fi-net" type="button" data-read="${read}"${running ? ' disabled' : ''}${running === read ? ' aria-busy="true"' : ''}>${glyph(icon)}${esc(label)}</button>`;

  function computersMarkup(s) {
    if (!s.computers.length) return emptyNote('monitor', 'Aucun poste associé', s.computersText);
    return `<div class="fi-table-wrap"><table class="fi-table fi-cs-computers"><thead><tr><th>Poste</th><th>Lien</th><th>Présence</th><th>Console</th><th><abbr title="Sessions du compte sur ce poste">Sessions</abbr></th></tr></thead><tbody>
      ${s.computers.map((c, n) => {
        const selected = (chosenComputer ?? s.triageComputerDn) === c.dn;
        return `<tr data-dn="${esc(c.dn)}" data-j="${n}" class="${selected ? 'selected' : ''}" tabindex="0" aria-selected="${selected}" data-tip="${esc(c.detail)}">
          <td><span class="fi-cs-pc"><b class="fi-nobr">${esc(c.computer)}</b>${c.primary ? `<span class="fi-primary">${glyph('star')}</span>` : ''}</span><span class="fi-faint fi-block">${esc(c.associatedText)}</span></td>
          <td>${esc(c.qualification)}</td>
          <td>${pill(c.presenceState === 'known' ? (c.presenceValue === 'En ligne' ? 'ok' : 'warn') : factTone(c.presenceState), c.presenceValue, { size: 'sm' })}<span class="fi-faint fi-block">${esc(c.presenceDate || c.presenceStateLabel)}</span></td>
          <td>${esc(c.consoleValue)}${c.consoleState !== 'known' ? ` ${pill(factTone(c.consoleState), c.consoleStateLabel, { size: 'sm' })}` : ''}</td>
          <td>${esc(c.sessionValue)}<span class="fi-faint fi-block">${esc(c.sessionDate || c.sessionStateLabel)}</span></td></tr>`;
      }).join('')}</tbody></table></div><p class="fi-note">${glyph('info')}${esc(s.computersText)} Choisissez une ligne pour changer le poste du tri.</p>`;
  }

  function markup(s) {
    // Points of attention as an aligned list (two columns when there are many), never pills of uneven widths.
    const attention = s.attention.length
      ? `<ul class="fi-cs-attn${s.attention.length > 3 ? ' two' : ''}">${s.attention.map((a, n) => `<li data-j="${n}">${glyph('alert')}<span>${nobr(a)}</span></li>`).join('')}</ul>`
      : `<p class="fi-cs-calm">${glyph('check')}Rien de particulier relevé sur ce compte.</p>`;
    const template = s.templateSource === 'Configuration' ? 'modèle CallSheet.TicketTemplate de Domenia.config.json' : 'modèle par défaut';
    return `<div class="fi-cs">
      <section class="fi-cs-top card fi-card fi-enter" data-j="0">
        <div class="fi-cs-who"><span class="card-icon" data-tone="${s.attention.length ? 'warn' : 'ok'}">${glyph('lifebuoy')}</span>
          <div><h3>Fiche d’appel · ${esc(s.subject.displayName)}</h3><p class="fi-card-sub"><span class="mono">${esc(s.subject.login)}</span>${s.subject.upn ? ` · <span class="mono">${esc(s.subject.upn)}</span>` : ''}</p></div>
          <div class="fi-cs-tools"><button class="btn sm ghost" type="button" data-cs="recompute">${glyph('refresh')}Recalculer</button>
            <button class="btn sm primary" type="button" data-cs="ticket">${glyph('copy')}Copier pour le ticket</button></div></div>
        <div class="fi-cs-attn-wrap"><span class="fi-cs-attn-title">${glyph('eye')}Points d’attention${s.attention.length ? `<span class="chip warn">${int(s.attention.length)}</span>` : ''}</span>${attention}</div>
        <p class="fi-note">${glyph(s.originState === 'known' ? 'database' : 'alert')}${esc(s.origin)} Lecture seule${NBSP}: rien n’est lu sur le réseau sans un clic sur un des boutons de lecture.</p>
      </section>
      <div class="fi-cs-grid">
        <div class="fi-cs-col">
          <section class="card fi-card fi-enter" data-j="1"><div class="card-head"><span class="card-icon">${glyph('user')}</span><div class="fi-card-titles"><h3>Compte et restrictions</h3>
              <p class="fi-card-sub">Chaque valeur dit sa source et sa date</p></div></div>
            ${factRows(s.account, { section: true, selectable: true })}
            <div class="fi-card-foot">${readButton('lockouts', 'Lire les verrouillages (4740)', 'history')}${readButton('policy', 'Lire la stratégie de mot de passe', 'key')}</div></section>
          <section class="card fi-card fi-enter" data-j="2"><div class="card-head"><span class="card-icon">${glyph('shield')}</span><div class="fi-card-titles"><h3>Opérations Domenia sur ce compte</h3>
              <p class="fi-card-sub">Reçus durables dont la cible est ce compte</p></div></div>
            ${factRows([s.operations])}
            ${s.receipts.length ? `<ul class="fi-cs-receipts">${s.receipts.map((r, n) => `<li data-j="${n}" class="${r.pending ? 'pending' : ''}"><span class="mono">${esc(r.date)}</span><b>${esc(r.operation)}</b><span class="fi-faint">${esc(r.stage)}</span></li>`).join('')}</ul>` : ''}
            <div class="fi-card-foot"><button class="btn sm ghost" type="button" data-cs="recompute">${glyph('refresh')}Relire les reçus</button></div></section>
        </div>
        <div class="fi-cs-col">
          <section class="card fi-card fi-enter" data-j="3"><div class="card-head"><span class="card-icon">${glyph('monitor')}</span><div class="fi-card-titles"><h3>Postes habituels et sessions</h3>
              <p class="fi-card-sub">Présence et console${NBSP}: valeurs instantanées, périmées après 15${NBSP}min</p></div></div>
            ${computersMarkup(s)}
            <div class="fi-card-foot">${s.computers.length ? `${readButton('presence', 'Vérifier la présence', 'wifi')}${readButton('sessions', 'Lire les sessions', 'users')}
              <button class="btn sm ghost" type="button" data-cs="openComputer">${glyph('object')}Ouvrir le poste</button>` : ''}</div></section>
          <section class="card fi-card fi-enter" data-j="4"><div class="card-head"><span class="card-icon">${glyph('group')}</span><div class="fi-card-titles"><h3>Groupes</h3>
              <p class="fi-card-sub">Groupes directs, privilégiés d’abord${NBSP}; changements vus pendant la session</p></div></div>
            ${factRows(s.groupFacts)}
            ${s.groups.length ? `<div class="fi-cs-groups">${s.groups.slice(0, 18).map((g, n) => `<span class="chip${g.privileged ? ' alert' : g.removed ? ' warn' : ''}" data-j="${n}" data-tip="${esc(g.dn)}">${glyph(g.privileged ? 'shield' : 'group')}${esc(g.name)}${g.change ? ` · ${esc(g.change)}` : ''}</span>`).join('')}${s.groups.length > 18 ? `<span class="chip">+${int(s.groups.length - 18)}</span>` : ''}</div>` : ''}
            <div class="fi-card-foot"><button class="btn sm ghost" type="button" data-cs="groups">${glyph('group')}Voir les appartenances</button>
              <button class="btn sm ghost fi-net" type="button" data-cs="compare">${glyph('split')}Comparer les droits avec…</button></div></section>
          <section class="card fi-card fi-enter" data-card="triage" data-j="5"><div class="card-head"><span class="card-icon">${glyph('gauge')}</span><div class="fi-card-titles"><h3>Poste lent${NBSP}: tri rapide</h3>
              <p class="fi-card-sub">${s.triageComputer ? `Poste <span class="fi-nobr">${esc(s.triageComputer)}</span> · inventaire rapide (CIM/WMI, droits d’administration du poste)` : 'Aucun poste associé : tri non disponible.'}</p></div></div>
            ${s.triageComputer ? factRows(s.triage) : emptyNote('gauge', 'Tri non disponible')}
            <div class="fi-card-foot">${s.triageComputer ? readButton('triage', 'Trier la lenteur du poste', 'zap') : ''}</div></section>
        </div>
      </div>
      <section class="card fi-card fi-cs-ticket fi-enter" data-j="6"><div class="card-head"><span class="card-icon">${glyph('file')}</span><div class="fi-card-titles"><h3>Texte pour le ticket</h3>
          <p class="fi-card-sub">Texte brut, sans secret, construit depuis le ${esc(template)}${s.ticketMasked ? ' · valeurs masquées' : ''}${s.ticketTruncated ? ' · tronqué' : ''}</p></div>
          <span class="meta"><button class="btn sm" type="button" data-cs="ticket">${glyph('copy')}Copier</button></span></div>
        ${s.templateWarning ? `<p class="fi-note warn">${glyph('alert')}${esc(s.templateWarning)}</p>` : ''}
        <pre class="fi-ticket mono" tabindex="0">${esc(s.ticket)}</pre></section>
    </div>`;
  }

  function render() {
    panel.innerHTML = markup(sheet);
    applyVars(panel);
  }

  async function load(args = {}) {
    const my = ++token;
    if (!sheet) panel.innerHTML = `<div class="fi-cards fi-cards-2"><section class="card fi-card">${skeleton(8)}</section><section class="card fi-card">${skeleton(6)}</section></div>`;
    try {
      const s = await S.ctx.call('fiche.callSheet', { dn: S.sheet.identity.dn, ...args });
      if (my !== token || !S.alive) return;
      sheet = s;
      render();
      if (pendingFocus) { const what = pendingFocus; pendingFocus = null; highlight(what); }
    } catch (err) {
      if (my !== token) return;
      panel.innerHTML = `<section class="card fi-card">${failure(err, { title: 'Fiche d’appel non calculée' })}</section>`;
    }
  }

  async function read(what) {
    if (running) return;
    running = what;
    if (sheet) render();
    try {
      const args = { dn: S.sheet.identity.dn, read: what };
      if (chosenComputer && (what === 'presence' || what === 'sessions' || what === 'triage')) args.computer = chosenComputer;
      sheet = await S.ctx.call('fiche.callSheet.read', args);
      announce('Fiche d’appel mise à jour.');
    } catch (err) {
      toast(`Lecture non aboutie : ${errorText(err)} Les valeurs gardent la date de leur dernière lecture réussie.`, { tone: 'warn' });
    } finally {
      running = '';
      if (S.alive && sheet) render();
    }
  }

  function highlight(what) {
    const card = panel.querySelector(`[data-card="${CSS.escape(what)}"]`);
    card?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    card?.classList.remove('fi-focus');
    void card?.offsetWidth;
    card?.classList.add('fi-focus');
    card?.querySelector(`[data-read="${CSS.escape(what)}"]`)?.focus({ preventScroll: true });
  }

  const onClick = async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const r = t.closest('[data-read]');
    if (r) { read(r.dataset.read); return; }
    const row = t.closest('.fi-cs-computers tr[data-dn]');
    if (row) {
      chosenComputer = row.dataset.dn;
      load({ computer: chosenComputer });
      return;
    }
    const c = t.closest('[data-cs]');
    if (!c) { if (t.closest('[data-retry]')) load(); return; }
    switch (c.dataset.cs) {
      case 'recompute': load(); break;
      case 'ticket': {
        const ok = await writeClipboard(sheet?.ticket ?? '');
        toast(ok ? 'Fiche d’appel copiée pour le ticket.' : 'Copie impossible.', { tone: ok ? 'ok' : 'warn', life: 2600 });
        break;
      }
      case 'groups': S.selectTab('groupes'); break;
      case 'compare': S.act('compare'); break;
      case 'openComputer': {
        const dn = chosenComputer ?? sheet?.triageComputerDn ?? sheet?.computers?.[0]?.dn;
        if (dn) S.open(dn);
        break;
      }
      default: break;
    }
  };
  const onKey = (e) => {
    const row = e.target instanceof Element ? e.target.closest('.fi-cs-computers tr[data-dn]') : null;
    if (row && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); chosenComputer = row.dataset.dn; load({ computer: chosenComputer }); }
  };
  panel.addEventListener('click', onClick);
  panel.addEventListener('keydown', onKey);
  load();
  return {
    read,
    /** Gesture: read now; route state: show and highlight the card and its button only. */
    focus(what, { run = true } = {}) {
      if (run) { read(what); return; }
      if (!sheet) { pendingFocus = what; return; }
      highlight(what);
    },
    update() {},
    refresh() { load(); },
    destroy() { panel.removeEventListener('click', onClick); panel.removeEventListener('keydown', onKey); },
  };
}
