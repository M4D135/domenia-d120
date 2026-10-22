// Comptes screen, tab « Droits et transports » (Domenia 1 CPT-019, CPT-020): the account, the right and the network access
// each operation needs (a right is never guessed: an unknown operation says so), consultable and exportable for the
// delegation teams, and the transport policy (what Domenia uses, what stays off and why). Local references: nothing is read
// on the network.
import { createGrid, createFilterBar, glyph, pill } from '../../kit/index.js';
import { esc, formatNumber, toast } from '../../ui.js';
import { plural, skeletonLines, errorSentence, emptyState } from './shared.js';

const FAMILY_TONES = { Annuaire: 'info', Postes: 'accent', Réseau: 'warn', Local: 'off' };
const EFFECT_TONES = { Read: 'ok', LocalWrite: 'info', DirectoryWrite: 'alert', RemoteMutation: 'warn', Unknown: 'off' };

export function mountDroits(panel, ctx) {
  let grid = null;
  let bar = null;
  let rows = [];
  const pressed = new Set();
  let alive = true;
  panel.innerHTML = `<div class="cpt-droits">
    <section class="card cpt-req reveal in" aria-labelledby="cpt-req-t">
      <div class="card-head"><span class="card-icon">${glyph('shield')}</span><div class="cpt-head-titles"><h3 id="cpt-req-t">Droits, comptes et accès réseau par opération</h3>
        <span>Dit avant tout appel et cité après un échec ; un droit n’est jamais deviné</span></div>
        <span class="meta"><button class="btn sm" type="button" data-export>${glyph('csv')}Exporter en CSV</button></span></div>
      <div class="cpt-req-fbar"></div>
      <div class="cpt-req-grid" aria-busy="true">${skeletonLines(6)}</div>
    </section>
    <section class="card cpt-transports reveal in" aria-labelledby="cpt-tr-t">
      <div class="card-head"><span class="card-icon">${glyph('wifi')}</span><div class="cpt-head-titles"><h3 id="cpt-tr-t">Politique de transport</h3><span>Ce que Domenia utilise, ce qui reste coupé et pourquoi</span></div></div>
      <div class="cpt-tr-body" aria-busy="true">${skeletonLines(5)}</div>
    </section>
  </div>`;

  const facets = () => ['Annuaire', 'Postes', 'Réseau', 'Local'].map((f) => ({ id: f, label: f, pressed: pressed.has(f), count: rows.filter((r) => r.family === f).length }));
  const shownRows = () => (pressed.size ? rows.filter((r) => pressed.has(r.family)) : rows);
  const apply = () => {
    grid.setRows(shownRows());
    bar.setFacets(facets());
    bar.setSummary(`${plural(shownRows().length, 'opération', 'opérations')}${pressed.size ? ` sur ${formatNumber(rows.length)}` : ''}`);
  };

  async function loadRequirements() {
    try {
      const table = await ctx.call('accounts.requirements');
      if (!alive) return;
      rows = table.rows;
      const host = panel.querySelector('.cpt-req-grid');
      host.removeAttribute('aria-busy');
      host.innerHTML = '';
      grid = createGrid(host, {
        key: 'comptes.droits',
        label: 'Droits requis par opération',
        rowId: (r) => r.id,
        selection: 'single',
        height: '520px',
        quickPlaceholder: 'Filtrer : opération, droit, port…',
        columns: [
          { id: 'label', label: 'Opération', required: true, width: 270, html: (v, r) => `<span class="cpt-op"><b>${esc(v)}</b><span class="mono">${esc(r.id)}</span></span>` },
          { id: 'family', label: 'Famille', type: 'enum', width: 120, options: Object.entries(FAMILY_TONES).map(([value, tone]) => ({ value, label: value, tone: tone === 'accent' ? 'info' : tone })) },
          { id: 'effectLabel', label: 'Effet', width: 170, html: (v, r) => pill(EFFECT_TONES[r.effect] ?? 'off', v, { size: 'sm' }) },
          { id: 'account', label: 'Compte utilisé', width: 220 },
          { id: 'right', label: 'Droit nécessaire', width: 460 },
          { id: 'access', label: 'Accès réseau', width: 360 },
          { id: 'resourceLabel', label: 'Ressource', width: 140, hidden: true },
          { id: 'id', label: 'Identifiant', mono: true, width: 200, hidden: true },
        ],
      });
      bar = createFilterBar(panel.querySelector('.cpt-req-fbar'), {
        label: 'Familles d’opérations',
        facets: facets(),
        onToggle: (id, on) => { if (on) pressed.add(id); else pressed.delete(id); apply(); },
        onClear: () => { pressed.clear(); apply(); },
      });
      apply();
      panel.querySelector('[data-export]').addEventListener('click', () => {
        grid.exportCsv('visible');
        toast(`Tableau copié en CSV (${plural(shownRows().length, 'ligne', 'lignes')}) : collez-le dans un tableur.`, { tone: 'ok' });
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
      body.innerHTML = `<div class="cpt-tr-consent" data-tone="${t.consentActive ? 'warn' : 'ok'}">${glyph(t.consentActive ? 'alert' : 'lock')}<span>${esc(t.consentText)}</span></div>
        <ul class="cpt-tr-list">${t.rows.map((r, n) => `<li data-tone="${esc(r.stateTone)}" data-j="${n}">
          <span class="cpt-tr-ico">${glyph(r.intrusive ? 'alert' : r.id === 'ldap' ? 'database' : 'wifi')}</span>
          <span class="cpt-tr-main"><b>${esc(r.transport)}</b><span>${esc(r.usage)}</span></span>
          <span class="cpt-tr-ports mono">${esc(r.ports)}</span>
          <span class="cpt-tr-state">${pill(r.stateTone, r.state, { size: 'sm' })}${r.intrusive ? pill('warn', 'Intrusif', { icon: 'alert', size: 'sm' }) : ''}</span>
          <span class="cpt-tr-rule">${esc(r.rule)}</span></li>`).join('')}</ul>
        <p class="cpt-small cpt-muted">${glyph('info')}${esc(t.note)} Réglages : ${esc(t.settingsSource)}.</p>`;
    } catch (err) {
      console.error(err);
      if (alive) panel.querySelector('.cpt-tr-body').innerHTML = emptyState({ iconName: 'alert', title: 'Politique indisponible', text: errorSentence(err), tone: 'alert' });
    }
  }

  loadRequirements();
  loadTransports();
  return { destroy: () => { alive = false; grid?.destroy(); bar?.destroy(); } };
}
