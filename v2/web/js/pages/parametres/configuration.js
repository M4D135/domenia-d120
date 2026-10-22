// Paramètres › Configuration (PAR-042 to PAR-046): the effective value of every setting of Domenia.config.json, its default
// and its provenance (default, file, file brought back into its bounds, unreadable value), the feature switches, the
// security settings, the network budgets and the central policy of the interface elements. Read only: the administrator
// edits the file next to Domenia.exe; it applies at the next start.
import {
  esc, glyph, card, notes, sectionHead, switchLabel, paint, skeleton, errorBlock, emptyState, pill, int, tone,
} from './common.js';
import { reveal } from '../../ui.js';

const HEAD = { title: 'Configuration', lead: 'Les réglages de l’administrateur, lus dans Domenia.config.json à côté de l’exécutable : valeur en vigueur, défaut et provenance, chacun borné.', icon: 'tools', tone: 'off' };
const STATES = { read: ['ok', 'Fichier lu', 'check'], absent: ['off', 'Fichier absent : valeurs par défaut', 'info'], invalid: ['alert', 'Fichier illisible : valeurs par défaut', 'alert'] };
const SETTING_OF = { Features: 'features', Security: 'security', Remote: 'remote', Async: 'async' };
const USE_TONES = { applied: 'ok', byConstruction: 'accent', planned: 'off' };

const show = (v) => (v === 'true' ? 'Oui' : v === 'false' ? 'Non' : v);

function sectionCard(s, onlyFile) {
  const entries = onlyFile ? s.entries.filter((e) => e.source !== 'default') : s.entries;
  const rows = entries.map((e, n) => `<tr data-j="${n}" data-source="${esc(e.source)}">
      <th scope="row"><b>${esc(e.label)}</b><span class="pr-sub mono">${esc(`${e.section}.${e.key}`)}</span><span class="pr-sub">${esc(e.effect)}</span></th>
      <td><span class="pr-value${e.value === 'true' ? ' yes' : e.value === 'false' ? ' no' : ''}">${esc(show(e.value))}</span>${e.value !== e.default ? `<span class="pr-sub">défaut ${esc(show(e.default))}</span>` : ''}</td>
      <td>${pill(tone(e.tone), e.sourceLabel, { size: 'sm' })}${e.bounds ? `<span class="pr-sub">${esc(e.bounds)}</span>` : ''}</td>
      <td>${pill(USE_TONES[e.use] ?? 'off', e.useLabel, { size: 'sm' })}</td></tr>`).join('');
  return `<details class="card pr-card pr-config reveal" data-config="${esc(s.id)}"${SETTING_OF[s.id] ? ` data-setting="${SETTING_OF[s.id]}"` : ''}${s.fromFile || s.id === 'Security' || s.id === 'Features' ? ' open' : ''}>
    <summary class="pr-card-head"><span class="pr-card-icon">${glyph(s.id === 'Security' ? 'shield' : s.id === 'Features' ? 'zap' : s.id === 'Remote' ? 'wifi' : s.id === 'Async' ? 'gauge' : s.id === 'Auth' ? 'key' : 'settings')}</span>
      <div class="pr-card-titles"><h3>${esc(s.label)}</h3><span class="pr-card-sub">${esc(s.description)}</span></div>
      <span class="pr-config-count">${s.fromFile ? pill('info', `${int(s.fromFile)} du fichier`, { size: 'sm' }) : pill('off', 'Valeurs par défaut', { size: 'sm' })}<span class="pr-chev">${glyph('chevronDown')}</span></span></summary>
    <div class="pr-card-body">${rows ? `<div class="pr-table-wrap"><table class="pr-table pr-config-table"><thead><tr><th>Réglage</th><th>Valeur en vigueur</th><th>Provenance</th><th>Dans Domenia 2</th></tr></thead><tbody>${rows}</tbody></table></div>` : '<p class="pr-sub">Aucune valeur de cette section ne vient du fichier.</p>'}</div>
  </details>`;
}

function markup(v, onlyFile) {
  const [toneName, label, iconName] = STATES[v.fileState] ?? STATES.read;
  const file = card({
    id: 'file', title: 'Fichier de configuration', sub: v.fileLabel, iconName: 'file',
    body: `<div class="pr-verdict" data-tone="${toneName}" data-setting="config"><span class="pr-verdict-ico">${glyph(iconName)}</span><b>${esc(label)}</b><span>${v.problem ? esc(v.problem) : `${int(v.fromFile)} valeur${v.fromFile > 1 ? 's' : ''} venant du fichier`}</span></div>
      <div class="pr-config-tools">${switchLabel('only-file', 'Seulement les valeurs du fichier', onlyFile)}${pill(v.allowExpertProfile ? 'ok' : 'warn', v.allowExpertProfile ? 'Profil Expert autorisé' : 'Profil Expert masqué', { size: 'sm', icon: 'tools' })}</div>
      ${notes(v.notes)}
      ${v.unknownSections.length ? `<p class="pr-hint">${glyph('info')}<span>Sections conservées, non lues par Domenia 2 : ${esc(v.unknownSections.join(', '))}.</span></p>` : ''}`,
  });
  const gui = card({
    id: 'gui', title: 'Politique des éléments d’interface', sub: 'Section GuiElementPolicy : Default, Disabled ou Hidden', iconName: 'eyeOff',
    body: v.guiPolicy.length
      ? `<ul class="pr-lines">${v.guiPolicy.map((g) => `<li>${pill(g.valid ? (g.policy === 'Hidden' ? 'warn' : g.policy === 'Disabled' ? 'info' : 'ok') : 'alert', g.policy || 'inconnue', { size: 'sm' })} <span class="mono">${esc(g.element)}</span> · ${esc(g.text)}</li>`).join('')}</ul>`
      : emptyState('eye', 'Aucune politique', 'Aucun élément n’est grisé ni masqué par l’administrateur. Les droits et la lecture seule restent prioritaires.'),
  });
  return `${sectionHead(HEAD)}<div class="pr-grid">${file}${gui}</div><div class="pr-config-list">${v.sections.map((s) => sectionCard(s, onlyFile)).join('')}</div>`;
}

export function mount(host, sctx) {
  let view = null;
  let onlyFile = false;
  let alive = true;
  host.innerHTML = `${sectionHead(HEAD)}${skeleton(3)}`;

  function draw() {
    host.innerHTML = markup(view, onlyFile);
    paint(host);
    reveal(host);
  }

  async function load() {
    try {
      view = await sctx.call('settings.config');
      if (!alive) return;
      draw();
    } catch (err) {
      if (!alive) return;
      host.innerHTML = `${sectionHead(HEAD)}${errorBlock(err)}`;
    }
  }

  const onChange = (e) => {
    if (e.target instanceof HTMLInputElement && e.target.dataset.toggle === 'only-file') {
      onlyFile = e.target.checked;
      host.querySelector('.pr-config-list').innerHTML = view.sections.map((s) => sectionCard(s, onlyFile)).join('');
      paint(host);
      reveal(host);
    }
  };
  const onClick = (e) => {
    if (e.target instanceof Element && e.target.closest('[data-act="retry"]')) load();
  };
  host.addEventListener('change', onChange);
  host.addEventListener('click', onClick);
  load();

  return {
    destroy() {
      alive = false;
      host.removeEventListener('change', onChange);
      host.removeEventListener('click', onClick);
    },
  };
}
