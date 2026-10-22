// Paramètres › Démonstration: how Domenia started (simulation or directory), the facts of the fictitious directory (seed,
// reference date, counts, overlay of the writes of the session) and the guarantees of the simulation. Read only.
import {
  esc, glyph, card, facts, notes, sectionHead, paint, skeleton, errorBlock, pill, int, when,
} from './common.js';
import { reveal, countUp } from '../../ui.js';

const HEAD = { title: 'Démonstration', lead: 'Le mode de démarrage et, en simulation, l’annuaire fictif : même graine, même date de référence, même annuaire, sans aucune connexion.', icon: 'play', tone: 'accent' };
const REASONS = {
  argument: 'Option --simulation', environment: 'Variable DOMENIA_SIMULATION=1', environmentOptOut: 'Variable DOMENIA_SIMULATION=0',
  configuration: 'Auth.DemoProvider de Domenia.config.json', notDomainJoined: 'Poste hors domaine', joinStateUnknown: 'Jonction illisible', domainJoined: 'Poste joint au domaine',
};

function markup(v) {
  const f = v.facts;
  const mode = card({
    id: 'mode', title: 'Mode de démarrage', sub: REASONS[v.reason] ?? v.reason, iconName: v.active ? 'sparkles' : 'server', toneName: v.active ? 'accent' : 'info', cls: 'pr-wide',
    body: `<div class="pr-mode" data-setting="mode"><span class="pr-mode-art" aria-hidden="true">${glyph(v.active ? 'sparkles' : 'server')}</span>
        <div><b>${esc(v.modeLabel)}</b><span>${esc(v.detail)}</span>${v.banner ? `<p class="pr-sub">${esc(v.banner)}</p>` : ''}</div>
        ${pill(v.active ? 'accent' : 'ok', v.active ? 'Aucun effet réel' : 'Annuaire réel', { icon: v.active ? 'sparkles' : 'shield' })}</div>
      <h4 class="pr-h4">${v.active ? 'Revenir à l’annuaire' : 'Essayer sans Active Directory'}</h4>
      <ul class="pr-lines">${v.howTo.map((l, n) => `<li data-j="${n}">${esc(l)}</li>`).join('')}</ul>`,
  });
  const world = f ? card({
    id: 'world', title: 'Annuaire fictif', sub: `${f.domain} · ${f.controller}`, iconName: 'tree',
    body: `<div class="pr-world">${[['ou', 'OU', f.organizationalUnits], ['user', 'Utilisateurs', f.users], ['monitor', 'Ordinateurs', f.computers], ['group', 'Groupes', f.groups]].map(([ic, label, n], j) =>
      `<div class="pr-world-tile" data-i="${j}">${glyph(ic)}<b data-count="${n}">${int(n)}</b><span>${esc(label)}</span></div>`).join('')}</div>
      ${facts([
        ['Graine', String(f.seed)], ['Date de référence', when(f.reference), f.weekend ? 'Week-end' : 'Jour ouvré'], ['Fuseau', f.timeZone],
        ['Compte de la session', f.operator], ['Délais', f.realisticLatency ? 'Réalistes, annulables' : 'Aucun'],
        ['Écritures de la session', f.overlayChangedObjects ? `${int(f.overlayChangedObjects)} objet${f.overlayChangedObjects > 1 ? 's' : ''} changé${f.overlayChangedObjects > 1 ? 's' : ''} en mémoire` : 'Aucune', `Version de la surcouche ${int(f.overlayVersion)}`],
        ['Relevés de présence', f.presenceRound ? `${int(f.presenceRound)} manche${f.presenceRound > 1 ? 's' : ''}` : 'État initial'],
        ['Empreinte de l’annuaire généré', `${f.fingerprint.slice(0, 16)}…`, 'SHA-256 : même graine, même annuaire, à l’octet près'],
      ])}`,
  }) : '';
  const guarantees = card({
    id: 'guarantees', title: 'Garanties de la simulation', sub: 'Reprises du mode démonstration de Domenia 1', iconName: 'shield',
    body: notes(v.guarantees),
  });
  return `${sectionHead(HEAD)}<div class="pr-grid">${mode}${world}${guarantees}</div>`;
}

export function mount(host, sctx) {
  let alive = true;
  host.innerHTML = `${sectionHead(HEAD)}${skeleton(2)}`;
  async function load() {
    try {
      const v = await sctx.call('settings.demo');
      if (!alive) return;
      host.innerHTML = markup(v);
      paint(host);
      reveal(host);
      host.querySelectorAll('.pr-world-tile b[data-count]').forEach((el, n) => countUp(el, Number(el.dataset.count), { delay: n * 80 }));
    } catch (err) {
      if (!alive) return;
      host.innerHTML = `${sectionHead(HEAD)}${errorBlock(err)}`;
    }
  }
  const onClick = (e) => { if (e.target instanceof Element && e.target.closest('[data-act="retry"]')) load(); };
  host.addEventListener('click', onClick);
  load();
  return { destroy() { alive = false; host.removeEventListener('click', onClick); } };
}
