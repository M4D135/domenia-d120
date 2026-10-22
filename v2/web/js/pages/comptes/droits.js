// Comptes screen, tab « Droits et transports » (Domenia 1 CPT-019, CPT-020): the account, the right and the network access
// each operation needs (a right is never guessed: an unknown operation says so), consultable and exportable for the
// delegation teams, and the transport policy (what Domenia uses, what stays off and why, settings Remote.* of
// Domenia.config.json and the intervention consent in force). Local references: nothing is read on the network.
// Long texts are never cut without a way to read them: every cell carries its full text as a tip, and the active operation
// is shown in full beside the table.
import { createGrid, createFilterBar, glyph, pill, NBSP } from '../../kit/index.js';
import { esc, formatNumber, toast } from '../../ui.js';
import { plural, skeletonLines, errorSentence, emptyState } from './shared.js';

const FAMILY_TONES = { Annuaire: 'info', Postes: 'accent', Réseau: 'warn', Local: 'off' };
const EFFECT_TONES = { Read: 'ok', LocalWrite: 'info', DirectoryWrite: 'alert', RemoteMutation: 'warn', Unknown: 'off' };
const EFFECT_ICONS = { Read: 'eye', LocalWrite: 'disk', DirectoryWrite: 'edit', RemoteMutation: 'zap', Unknown: 'info' };

/** A cell whose text may be long: one line with an ellipsis, the full text as a tip (keyboard reachable in the detail). */
const wrapCell = (v) => `<span class="cpt-cell-clip" data-tip="${esc(v ?? '')}">${esc(v ?? '')}</span>`;

export function mountDroits(panel, ctx) {
  let grid = null;
  let bar = null;
  let rows = [];
  const pressed = new Set();
  let alive = true;
  panel.innerHTML = `<div class="cpt-droits">
    <section class="card cpt-req reveal in" aria-labelledby="cpt-req-t">
      <div class="card-head"><span class="card-icon">${glyph('shield')}</span><div class="cpt-head-titles"><h3 id="cpt-req-t">Droits, comptes et accès réseau par opération</h3>
        <span>Dit avant tout appel et cité après un échec${NBSP}; un droit n’est jamais deviné</span></div>
        <span class="meta"><button class="btn sm" type="button" data-export>${glyph('csv')}Copier en CSV</button></span></div>
      <div class="cpt-req-fbar"></div>
      <div class="cpt-req-body">
        <div class="cpt-req-grid" aria-busy="true">${skeletonLines(6)}</div>
        <aside class="cpt-req-detail" aria-live="polite" aria-label="Opération choisie"></aside>
      </div>
    </section>
    <section class="card cpt-transports reveal in" aria-labelledby="cpt-tr-t">
      <div class="card-head"><span class="card-icon">${glyph('wifi')}</span><div class="cpt-head-titles"><h3 id="cpt-tr-t">Politique de transport</h3><span>Ce que Domenia utilise, ce qui reste coupé et pourquoi</span></div></div>
      <div class="cpt-tr-body" aria-busy="true">${skeletonLines(5)}</div>
    </section>
  </div>`;

  const facets = () => ['Annuaire', 'Postes', 'Réseau', 'Local'].map((f) => ({ id: f, label: f, pressed: pressed.has(f), count: rows.filter((r) => r.family === f).length }));
  const shownRows = () => (pressed.size ? rows.filter((r) => pressed.has(r.family)) : rows);
  const apply = () => {
    grid.setRows(shownRows(), { keepSelection: true });
    bar.setFacets(facets());
    bar.setSummary(`${plural(shownRows().length, 'opération', 'opérations')}${pressed.size ? ` sur ${formatNumber(rows.length)}` : ''}`);
  };

  /** The active operation, every field in full (nothing is cut here). */
  function showDetail(r) {
    const box = panel.querySelector('.cpt-req-detail');
    if (!r) {
      box.innerHTML = `<div class="cpt-req-none">${glyph('info')}<span>Choisissez une opération${NBSP}: son droit, son compte et ses ports s’affichent ici en entier.</span></div>`;
      return;
    }
    box.innerHTML = `<div class="cpt-req-card" data-tone="${esc(EFFECT_TONES[r.effect] ?? 'off')}">
        <div class="cpt-req-card-head"><span class="cpt-req-card-ico">${glyph(EFFECT_ICONS[r.effect] ?? 'info')}</span>
          <div><b>${esc(r.label)}</b><span class="mono">${esc(r.id)}</span></div></div>
        <div class="cpt-req-pills">${pill(EFFECT_TONES[r.effect] ?? 'off', r.effectLabel, { size: 'sm' })}${pill(FAMILY_TONES[r.family] === 'accent' ? 'info' : (FAMILY_TONES[r.family] ?? 'off'), r.family, { size: 'sm' })}${r.known ? '' : pill('off', 'Non documenté', { icon: 'info', size: 'sm' })}</div>
        <dl>
          <div><dt>${glyph('user')}Compte utilisé</dt><dd>${esc(r.account)}</dd></div>
          <div><dt>${glyph('shield')}Droit nécessaire</dt><dd>${esc(r.right)}</dd></div>
          <div><dt>${glyph('wifi')}Accès réseau</dt><dd>${esc(r.access)}</dd></div>
          <div><dt>${glyph('database')}Ressource</dt><dd>${esc(r.resourceLabel)}</dd></div>
        </dl>
      </div>`;
  }

  async function loadRequirements() {
    try {
      const table = await ctx.call('accounts.requirements');
      if (!alive) return;
      rows = table.rows;
      const host = panel.querySelector('.cpt-req-grid');
      host.removeAttribute('aria-busy');
      host.innerHTML = '';
      grid = createGrid(host, {
        key: 'comptes.droits.v2',
        label: 'Droits requis par opération',
        rowId: (r) => r.id,
        selection: 'single',
        height: '560px',
        quickPlaceholder: `Filtrer${NBSP}: opération, droit, port…`,
        columns: [
          { id: 'label', label: 'Opération', required: true, width: 250, html: (v, r) => `<span class="cpt-op" data-tip="${esc(v)}"><b>${esc(v)}</b><span class="mono">${esc(r.id)}</span></span>` },
          { id: 'family', label: 'Famille', type: 'enum', width: 110, options: Object.entries(FAMILY_TONES).map(([value, tone]) => ({ value, label: value, tone: tone === 'accent' ? 'info' : tone })) },
          { id: 'effectLabel', label: 'Effet', width: 210, html: (v, r) => `<span class="cpt-effect">${pill(EFFECT_TONES[r.effect] ?? 'off', v, { size: 'sm' })}</span>` },
          { id: 'right', label: 'Droit nécessaire', width: 330, html: wrapCell },
          { id: 'access', label: 'Accès réseau', width: 280, html: wrapCell },
          { id: 'account', label: 'Compte utilisé', width: 200, html: wrapCell, hidden: true },
          { id: 'resourceLabel', label: 'Ressource', width: 140, hidden: true },
          { id: 'id', label: 'Identifiant', mono: true, width: 200, hidden: true },
        ],
        onActiveChange: (r) => showDetail(r),
        onActivate: (r) => showDetail(r),
      });
      bar = createFilterBar(panel.querySelector('.cpt-req-fbar'), {
        label: 'Familles d’opérations',
        facets: facets(),
        onToggle: (id, on) => { if (on) pressed.add(id); else pressed.delete(id); apply(); },
        onClear: () => { pressed.clear(); apply(); },
      });
      apply();
      showDetail(null);
      panel.querySelector('[data-export]').addEventListener('click', () => {
        grid.exportCsv('visible');
        toast(`Tableau copié en CSV (${plural(shownRows().length, 'ligne', 'lignes')})${NBSP}: collez-le dans un tableur.`, { tone: 'ok' });
      });
    } catch (err) {
      console.error(err);
      if (alive) panel.querySelector('.cpt-req-grid').innerHTML = emptyState({ iconName: 'alert', title: 'Table indisponible', text: errorSentence(err), tone: 'alert' });
    }
  }

  async function loadTransports() {
    try {
      const t = await ctx.call('accounts.transports');
      if (!alive) return;
      const body = panel.querySelector('.cpt-tr-body');
      body.removeAttribute('aria-busy');
      // One card per transport: name and use, state on the right; ports and rule below, in prose (never a fixed width font).
      body.innerHTML = `<div class="cpt-tr-consent" data-tone="${t.consentActive ? 'warn' : 'ok'}">${glyph(t.consentActive ? 'alert' : 'lock')}<span>${esc(t.consentText)}</span></div>
        <ul class="cpt-tr-list">${t.rows.map((r, n) => `<li data-tone="${esc(r.stateTone)}" data-j="${n}">
          <span class="cpt-tr-ico">${glyph(r.intrusive ? 'alert' : r.id === 'ldap' ? 'database' : 'wifi')}</span>
          <span class="cpt-tr-main"><b>${esc(r.transport)}</b><span>${esc(r.usage)}</span></span>
          <span class="cpt-tr-state">${pill(r.stateTone, r.state, { size: 'sm' })}${r.intrusive ? pill('warn', 'Intrusif', { icon: 'alert', size: 'sm' }) : ''}</span>
          <span class="cpt-tr-ports">${glyph('link')}<span>${esc(r.ports)}</span></span>
          <span class="cpt-tr-rule">${esc(r.rule)}</span></li>`).join('')}</ul>
        <p class="cpt-small cpt-muted">${glyph('info')}${esc(t.note)} Réglages${NBSP}: ${esc(t.settingsSource)}.</p>`;
      body.querySelectorAll('[data-j]').forEach((el) => el.style.setProperty('--j', el.dataset.j));
    } catch (err) {
      console.error(err);
      if (alive) panel.querySelector('.cpt-tr-body').innerHTML = emptyState({ iconName: 'alert', title: 'Politique indisponible', text: errorSentence(err), tone: 'alert' });
    }
  }

  loadRequirements();
  loadTransports();
  return { destroy: () => { alive = false; grid?.destroy(); bar?.destroy(); } };
}
