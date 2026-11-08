// Real popover, keyed DOM updates and shared scheduler, with local response/clock barriers only.
import { test, eq, ok } from './harness.mjs';
import { openActivity, setJournalOpener } from '../../web/js/shell/panels.js';
import { popoverOpen } from '../../web/js/shell/popover.js';
import { createPulse } from '../../web/js/shell/pulse.js';

const settle = async () => { for (let n = 0; n < 30; n++) await Promise.resolve(); };
const task = (id) => ({ id: String(id), label: `Lecture ${id}`, kindLabel: 'Lecture', state: 'running', stateLabel: 'En cours',
  tone: 'info', startedAt: '2026-10-25T12:00:00Z', durationText: '0:00', canStop: true, detail: 'Phase locale', access: 'Compte de session' });
function fixture({ tasks = [task(0)], reads = [], read = null } = {}) {
  let now = Date.parse('2026-10-25T12:00:00Z'), timerId = 0, visible = true, faults = 0;
  const timers = new Map(), events = new Set(), calls = [];
  const state = { center: { open: tasks }, queue: { reads, waiting: reads.length, limit: 32 },
    activity: { tasks: { running: tasks.length }, receipts: { available: true, pending: 0, total: 0 }, detail: 'État local', journal: [] } };
  const clock = createPulse({ now: () => now, setTimer: (run, delay) => { timers.set(++timerId, { run, at: now + delay }); return timerId; }, clearTimer: (id) => timers.delete(id) });
  const call = async (op, args) => {
    calls.push({ op, args });
    if (read) { const answer = read(op, args, state); if (answer !== undefined) return answer; }
    if (op === 'shell.activity') return state.activity;
    if (op === 'operations.center') return state.center;
    if (op === 'operations.queue.read') return state.queue;
    throw new Error(`Appel inattendu : ${op}`);
  };
  const anchor = document.createElement('button'); document.body.append(anchor);
  const ctl = openActivity(anchor, () => call('shell.activity'), { call, now: () => now, visible: () => visible,
    events: (name, handler) => { eq(name, 'bridge.queue.changed', 'événement local déclaré'); events.add(handler); return () => events.delete(handler); },
    clock: { every: (owner, interval, run) => clock.every(owner, interval, run, { onError: () => { faults++; } }) } });
  return { ctl, state, clock, calls, events, timers, get faults() { return faults; },
    notify(event) { events.forEach((run) => run(event)); },
    visible(value) { visible = value; clock.setState({ visible: value }); },
    async advance(ms) {
      now += ms;
      for (let pass = 0; pass < 30; pass++) {
        const due = [...timers].find(([, timer]) => timer.at <= now);
        if (due) { timers.delete(due[0]); due[1].run(); }
        await settle();
      }
    },
    close() { ctl.close(); },
    destroy() { ctl.close(); ctl.el.remove(); anchor.remove(); clock.dispose(); window.getSelection()?.removeAllRanges(); setJournalOpener(() => {}); },
  };
}

const taskRows = (x) => x.ctl.body.querySelectorAll('[data-activity-key^="engine:"], [data-activity-key^="queue:"], [data-activity-key^="ui:"]');

test('Activité : toutes les tâches bornées restent accessibles sur des pages locales de 64 lignes', async () => {
  const reads = Array.from({ length: 32 }, (_, n) => ({ requestId: `q${n}`, label: `Attente ${n}`, waitedSeconds: n }));
  const x = fixture({ tasks: Array.from({ length: 64 }, (_, n) => task(n)), reads });
  try {
    await settle();
    eq(taskRows(x).length, 64, '32 attentes et 32 tâches moteur dans la première page');
    ok(x.ctl.body.querySelector('[data-engine-stop="7"]'), 'huitième tâche autrefois cachée désormais visible');
    const calls = x.calls.length;
    x.ctl.body.querySelector('[data-task-page="1"]').click();
    eq(taskRows(x).length, 32, 'seconde page bornée');
    ok(x.ctl.body.querySelector('[data-engine-stop="63"]'), 'dernière tâche moteur accessible');
    eq(x.calls.length, calls, 'pagination purement locale');
    x.ctl.body.querySelector('[data-task-page="-1"]').click();
    eq(taskRows(x).length, 64, 'retour sans perdre les lectures en file');
  } finally { x.destroy(); }
});

test('Activité : durée, compteurs et arrêt évoluent sans remplacer la ligne, le focus ni le texte sélectionné', async () => {
  const x = fixture({ tasks: [task(1), task(2)] });
  try {
    await settle();
    const row = x.ctl.body.querySelector('[data-activity-key="engine:2"]');
    const button = row.querySelector('button'); button.focus();
    const text = row.querySelector('.sh-task-l').firstChild;
    window.getSelection().setBaseAndExtent(text, 0, text, text.length);
    const selected = window.getSelection().toString();
    eq(selected, 'Lecture 2', 'précondition de sélection sur la vraie ligne');
    x.state.center.open[1] = { ...task(2), state: 'stopRequested', stateLabel: 'Arrêt demandé', progress: { done: 2, total: 5 } };
    await x.advance(1000);
    ok(x.ctl.body.querySelector('[data-activity-key="engine:2"]') === row, 'même objet DOM');
    ok(document.activeElement === button, 'même bouton encore focalisé');
    eq(window.getSelection().toString(), selected, 'texte sélectionné conservé');
    eq(row.querySelector('.sh-task-t').textContent, '0:01', 'durée rafraîchie à une seconde');
    ok(row.textContent.includes('Arrêt demandé') && row.textContent.includes('2/5'), 'état et progression réels mis à jour');
    x.state.center.open[1] = { ...x.state.center.open[1], state: 'cleanup', stateLabel: 'Nettoyage', canStop: false, stopReason: 'Fin physique en cours' };
    await x.advance(1000);
    ok(!row.querySelector('[data-engine-stop]') && row.textContent.includes('Nettoyage'), 'nettoyage conservé et arrêt non proposé');
    ok(row.querySelector('.sh-task-l').dataset.tip.includes('Compte de session'), 'accès requis présent sans payload');
  } finally { x.destroy(); }
});

test('Activité : masquage suspend ticks et événements, fermeture libère le suivi sans arrêter de tâche', async () => {
  const x = fixture();
  try {
    await settle(); eq(x.calls.length, 3, 'précondition : trois lectures locales initiales');
    x.visible(false); x.notify(); await x.advance(10_000);
    eq(x.calls.length, 3, 'aucune lecture masquée même sur événement');
    x.visible(true); await x.advance(0);
    eq(x.calls.length, 6, 'rattrapage local unique au retour visible');
    x.close(); eq(x.clock.count, 0, 'abonnement libéré'); eq(x.events.size, 0, 'événement détaché');
    await x.advance(10_000);
    eq(x.calls.length, 6, 'fermeture sans appel stop ni lecture résiduelle');
  } finally { x.destroy(); }
});

test('Activité : une réponse lente et une faute ne créent pas de lectures orphelines ; fermeture ignore la fin tardive', async () => {
  let release, centerReads = 0;
  const x = fixture({ read: (op) => {
    if (op === 'operations.center' && ++centerReads === 2) return new Promise((resolve) => { release = resolve; });
    if (op === 'operations.queue.read' && centerReads === 2) return Promise.reject(new Error('Lecture locale refusée'));
    return undefined;
  } });
  try {
    await settle(); await x.advance(1000);
    ok(release, 'barrière réelle atteinte dans la deuxième lecture');
    x.notify(); x.notify(); await x.advance(10_000);
    eq(centerReads, 2, 'aucun nouveau lecteur malgré faute et notifications');
    const before = x.ctl.body.innerHTML;
    x.close(); release({ open: [{ ...task(9), label: 'Réponse tardive' }] }); await settle(); await x.advance(1000);
    eq(x.ctl.body.innerHTML, before, 'aucune publication après fermeture');
    eq(centerReads, 2, 'aucun rattrapage orphelin'); eq(x.clock.count, 0, 'aucun réabonnement');
  } finally { x.destroy(); }
});

test('Activité : trois fautes de suivi arrêtent le battement et le retour visible ne le relance pas', async () => {
  let fail = false;
  const x = fixture({ read: (op) => fail && op === 'operations.center' ? Promise.reject(new Error('État indisponible')) : undefined });
  try {
    await settle(); ok(x.ctl.body.querySelector('[data-engine-stop="0"]'), 'setup positif avant les fautes');
    fail = true;
    await x.advance(1000); await x.advance(1000); await x.advance(1000);
    eq(x.faults, 3, 'trois passages distincts en échec'); eq(x.clock.count, 0, 'suivi arrêté');
    const calls = x.calls.length;
    x.visible(false); x.visible(true); await x.advance(10_000);
    eq(x.calls.length, calls, 'aucune reprise implicite après la troisième faute');
  } finally { x.destroy(); }
});

test('Activité : retirer une demande déjà partie affiche le refus exact, sans arrêt moteur ni rejeu', async () => {
  let release;
  const reads = [{ requestId: 'owned-request', label: 'Lecture en file', waitedSeconds: 1 }];
  const x = fixture({ reads, read: (op) => op === 'operations.queue.cancel' ? new Promise((resolve) => { release = resolve; }) : undefined });
  try {
    await settle();
    const button = x.ctl.body.querySelector('[data-queue-cancel]'); button.click(); button.click();
    eq(x.calls.filter((c) => c.op === 'operations.queue.cancel').length, 1, 'un seul retrait tant que sa réponse manque');
    eq(x.calls.find((c) => c.op === 'operations.queue.cancel').args, { requestId: 'owned-request' }, 'identifiant exact transmis');
    x.state.queue = { reads: [], waiting: 0, limit: 32 };
    release({ removed: false, state: 'notQueued', message: 'Déjà partie : aucun arrêt confirmé.' }); await settle();
    ok(document.querySelector('.live-polite').textContent.includes('Déjà partie : aucun arrêt confirmé.'), 'refus du moteur annoncé tel quel');
    eq(x.calls.filter((c) => !['shell.activity', 'operations.center', 'operations.queue.read', 'operations.queue.cancel'].includes(c.op)).length, 0, 'aucun appel distant, aucun stop moteur ni rejeu');
  } finally { x.destroy(); }
});

test('Activité : Journal ferme le panneau avant le raccourci commun de la coque', async () => {
  const x = fixture(); let invoked = 0;
  setJournalOpener(() => { invoked++; ok(!popoverOpen(), 'panneau fermé avant la route partagée avec Ctrl+L'); });
  try {
    await settle(); x.ctl.body.querySelector('[data-go="journal"]').click();
    eq(invoked, 1, 'un seul passage par le raccourci de la coque'); eq(x.clock.count, 0, 'suivi fermé avec le panneau');
  } finally { x.destroy(); }
});


test('Panneau activité réel : ses propres admissions ne créent aucune boucle de relecture', async () => {
  const x = fixture({ tasks: [] });
  try {
    await settle(); const before = x.calls.length;
    for (const operation of ['shell.activity', 'operations.center', 'operations.queue.read']) x.notify({ operation });
    await settle(); eq(x.calls.length, before, 'aucune relecture provoquée par les trois propres requêtes du panneau');
    x.notify({ operation: 'search.run' }); await settle();
    eq(x.calls.length, before + 3, 'un véritable autre travail provoque un rafraîchissement complet unique');
  } finally { x.destroy(); }
});
