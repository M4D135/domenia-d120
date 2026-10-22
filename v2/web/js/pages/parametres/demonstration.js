// Paramètres › Démonstration: how Domenia started (simulation or directory), the facts of the fictitious directory (seed,
// reference date, counts, overlay of the writes of the session), the guarantees of the simulation, and in simulation the
// demonstration scenarios of the fictitious base: a suspended writer, an interrupted switch, a base proven unreadable, a
// nearly full disk. Each scenario is a write of the circuit on the fictitious base (plan, confirmation, receipt « simulé »),
// so that the resumptions and restores of Données et cache can be tried without any real failure.
import {
  esc, glyph, card, facts, notes, sectionHead, paint, skeleton, errorBlock, pill, int, when, button, nobreak, reported,
} from './common.js';
import { reveal, countUp } from '../../ui.js';
import { runWrite } from '../../write-flow.js';

const HEAD = { title: 'Démonstration', lead: 'Comment Domenia a démarré et, en simulation, l’annuaire fictif : même graine, même date de référence, même annuaire, sans aucune connexion.', icon: 'play', tone: 'accent' };
const REASONS = {
  argument: 'Option --simulation', environment: 'Variable DOMENIA_SIMULATION=1', environmentOptOut: 'Variable DOMENIA_SIMULATION=0',
  configuration: 'Auth.DemoProvider de Domenia.config.json', notDomainJoined: 'Poste hors domaine', joinStateUnknown: 'Jonction illisible', domainJoined: 'Poste joint au domaine',
};
const SCENARIOS = [
  { id: 'writerSuspended', label: 'Enregistrement suspendu', icon: 'pause', text: 'Trois échecs d’écriture de suite : l’écrivain s’arrête, ce qui est collecté reste en mémoire. À essayer : « Reprendre les sauvegardes ».', try: ['donnees', 'apercu'] },
  { id: 'switchInterrupted', label: 'Bascule interrompue', icon: 'layers', text: 'Un déplacement arrêté entre la copie vérifiée et la bascule. À essayer : « Reprendre la bascule » ou « Revenir à la base précédente ».', try: ['donnees', 'assistant'] },
  { id: 'storeUnreadable', label: 'Base illisible', icon: 'alert', text: 'Contrôle SQLite en échec (SQLITE_CORRUPT 11) : seule la restauration d’une sauvegarde vérifiée est proposée.', try: ['donnees', 'diagnostic'] },
  { id: 'lowSpace', label: 'Disque presque plein', icon: 'disk', text: 'Moins de 512 Mo libres sur le volume de la base : les nouvelles collectes sont suspendues, l’alerte s’affiche.', try: ['donnees', 'diagnostic'] },
  { id: 'normal', label: 'État normal', icon: 'check', text: 'Écrivain actif, aucune bascule en attente, base lisible et espace suffisant.', try: null },
];

function scenarioCard(current) {
  return card({
    id: 'scenarios', title: 'Scénarios de démonstration', sub: 'Base fictive seulement ; chacun par le circuit d’écriture', iconName: 'zap', cls: 'pr-wide',
    body: `<div class="pr-scenarios" data-setting="scenarios">${SCENARIOS.map((s, n) => {
      const on = s.id === current;
      return `<div class="pr-scenario${on ? ' on' : ''}" data-j="${n}"><span class="pr-scenario-ico">${glyph(s.icon)}</span>
        <div><b>${esc(s.label)}</b><span>${esc(s.text)}</span></div>
        <div class="pr-scenario-actions">${on ? pill(s.id === 'normal' ? 'ok' : 'warn', 'État actuel', { size: 'sm', icon: 'check' }) : button(`scenario:${s.id}`, s.id === 'normal' ? 'Rétablir' : 'Jouer', s.id === 'normal' ? 'undo' : 'play', { write: true, kind: s.id === 'normal' ? 'primary' : '' })}
          ${on && s.try ? button(`try:${s.try.join(':')}`, 'Essayer', 'chevronRight', { kind: 'ghost' }) : ''}</div></div>`;
    }).join('')}</div>
      <p class="pr-hint accent">${glyph('sparkles')}<span>Aucun effet réel : seule la base fictive en mémoire change ; un nouveau lancement repart de la base générée. Les reçus sont marqués « simulé ».</span></p>`,
  });
}

function markup(v, scenario) {
  const f = v.facts;
  const mode = card({
    id: 'mode', title: 'Mode de démarrage', sub: nobreak(REASONS[v.reason] ?? v.reason), iconName: v.active ? 'sparkles' : 'server', toneName: v.active ? 'accent' : 'info', cls: 'pr-wide',
    body: `<div class="pr-mode" data-setting="mode"><span class="pr-mode-art" aria-hidden="true">${glyph(v.active ? 'sparkles' : 'server')}</span>
        <div><b>${esc(v.modeLabel)}</b><span>${esc(nobreak(v.detail))}</span></div>
        ${pill(v.active ? 'accent' : 'ok', v.active ? 'Aucun effet réel' : 'Annuaire réel', { icon: v.active ? 'sparkles' : 'shield' })}</div>
      <h4 class="pr-h4">${v.active ? 'Revenir à l’annuaire' : 'Essayer sans Active Directory'}</h4>
      <ul class="pr-lines">${v.howTo.map((l, n) => `<li data-j="${n}">${esc(nobreak(l))}</li>`).join('')}</ul>`,
  });
  const world = f ? card({
    id: 'world', title: 'Annuaire fictif', sub: `${f.domain} · ${f.controller}`, iconName: 'tree',
    body: `<div class="pr-world">${[['ou', 'OU', f.organizationalUnits], ['user', 'Utilisateurs', f.users], ['monitor', 'Ordinateurs', f.computers], ['users', 'Groupes', f.groups]].map(([ic, label, n], j) =>
      `<div class="pr-world-tile" data-i="${j}">${glyph(ic)}<b data-count="${n}">${int(n)}</b><span>${esc(label)}</span></div>`).join('')}</div>
      ${facts([
        ['Graine', String(f.seed)], ['Date de référence', when(f.reference), f.weekend ? 'Week-end' : 'Jour ouvré'], ['Fuseau', f.timeZoneLabel ?? f.timeZone],
        ['Compte de la session', f.operator], ['Délais', f.realisticLatency ? 'Réalistes, annulables' : 'Aucun'],
        ['Écritures de la session', f.overlayChangedObjects ? `${int(f.overlayChangedObjects)} objet${f.overlayChangedObjects > 1 ? 's' : ''} changé${f.overlayChangedObjects > 1 ? 's' : ''} en mémoire` : 'Aucune', `Version de la surcouche ${int(f.overlayVersion)}`],
        ['Relevés de présence', f.presenceRound ? `${int(f.presenceRound)} manche${f.presenceRound > 1 ? 's' : ''}` : 'État initial'],
        ['Empreinte de l’annuaire généré', `${f.fingerprint.slice(0, 16)}…`, 'SHA-256 : même graine, même annuaire, à l’octet près'],
      ])}`,
  }) : '';
  const guarantees = card({
    id: 'guarantees', title: 'Garanties de la simulation', sub: 'Reprises du mode démonstration de Domenia 1', iconName: 'shield',
    body: notes(v.guarantees),
  });
  return `${sectionHead(HEAD)}<div class="pr-grid">${mode}${world}${guarantees}${v.active && scenario ? scenarioCard(scenario) : ''}</div>`;
}

export function mount(host, sctx) {
  let alive = true;
  let view = null;
  let scenario = null;
  host.innerHTML = `${sectionHead(HEAD)}${skeleton(2)}`;

  function draw() {
    host.innerHTML = markup(view, scenario);
    paint(host);
    reveal(host);
    host.querySelectorAll('.pr-world-tile b[data-count]').forEach((el, n) => countUp(el, Number(el.dataset.count), { delay: n * 80 }));
  }

  async function load() {
    try {
      view = await sctx.call('settings.demo');
      if (!alive) return;
      if (view.active) {
        try { scenario = (await sctx.call('settings.storage')).scenario ?? 'normal'; } catch { scenario = null; }
      }
      if (!alive) return;
      draw();
    } catch (err) {
      if (!alive) return;
      host.innerHTML = `${sectionHead(HEAD)}${errorBlock(err)}`;
    }
  }

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (t?.closest('[data-act="retry"]')) { load(); return; }
    const act = t?.closest('[data-act]')?.dataset.act ?? '';
    if (act.startsWith('scenario:')) {
      runWrite({ call: sctx.call }, {
        plan: 'settings.demo.scenario.plan', args: { scenario: act.slice(9) },
        onDone: () => { load(); sctx.refreshStorage?.(); },
      }).catch((err) => sctx.toast(reported(err), { tone: 'warn' }));
    } else if (act.startsWith('try:')) {
      const [, section, tab] = act.split(':');
      sctx.go(section, { tab });
    }
  };
  host.addEventListener('click', onClick);
  load();
  return { destroy() { alive = false; host.removeEventListener('click', onClick); } };
}
