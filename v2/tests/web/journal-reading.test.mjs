import { test, eq, ok } from './harness.mjs';
import { mount } from '../../web/js/pages/parametres/journaux.js';
import { maskNames, readableLogPhrase } from '../../web/js/pages/parametres/pure.js';
import { acknowledgeJournal, unreadJournalErrors, copyJournal, journalMaskNames } from '../../web/js/shell/journal-reading.js';
import { installJournalHealth } from '../../web/js/shell/journal-health.js';
import { setLayoutStore } from '../../web/js/kit/util.js';
import { notify, unreadCount, clearNotes, correlateIncident, supportText, bannerPlan } from '../../web/js/shell/notify.js';
import { swallowed, handledErrors } from '../../web/js/shell/guards.js';

const settle = async () => { for (let n = 0; n < 60; n++) await Promise.resolve(); };
const line = (n, text, level = 'INFO') => ({ at: `2026-11-01T10:00:${String(n).padStart(2, '0')}Z`, level, text, more: [] });
const view = (lines) => ({ file: { label: 'domenia.log', exists: true, bytes: 1000, records: lines.length, errors: lines.filter(l => l.level === 'ERREUR').length, warnings: 0, sessionStart: '2026-11-01T10:00:00Z', sessionErrors: lines.filter(l => l.level === 'ERREUR').length }, lines, session: [], rules: [] });

test('Incident UI : empreinte seule envoyée, code du moteur conservé dans la bannière et le support', async () => {
  const n = { code: '', tone: 'alert', message: 'Erreur sur PC-prive avec password=example-secret', detail: '', source: 'accueil', at: Date.now(), count: 1 };
  const calls = [], code = 'INC-' + 'A'.repeat(32);
  await correlateIncident(n, async (op, args) => { calls.push({ op, args }); return { code }; });
  eq(calls.length, 1, 'un signalement'); eq(calls[0].op, 'shell.incident', 'raccord réel');
  eq(Object.keys(calls[0].args).sort(), ['fingerprint', 'route'], 'aucun texte libre envoyé');
  ok(/^[0-9a-f]{64}$/.test(calls[0].args.fingerprint), 'vrai SHA-256');
  ok(!JSON.stringify(calls).includes('PC-prive') && !JSON.stringify(calls).includes('example-secret'), 'pas de cible ni secret dans la demande');
  eq(n.code, code, 'code retourné conservé'); ok(supportText(n).includes(code), 'même code au support');
  ok(!supportText(n).includes('example-secret'), 'copie support masquée');
  eq(bannerPlan('alert', `Échec ${code}`).code, code, 'code long non tronqué');
  await correlateIncident(n, () => { throw new Error('ne doit pas rappeler'); });
  const failed = { ...n, code: '' };
  await correlateIncident(failed, async () => { throw new Error('journal indisponible'); });
  eq(failed.code, '', 'aucun faux code si le moteur n’a pas pu écrire');
});

test('Journal réel : phrases bornées, détails conservés, recherche circulaire et vue brute', async () => {
  const host = document.createElement('section'); document.body.append(host);
  let data = view([line(1, 'Trouver début'), line(1, 'Technique : Trouver début'), line(2, 'Intermédiaire'), line(3, 'Trouver fin ' + 'z'.repeat(400)), line(4, 'synthèse', 'TRACE')]);
  let tick, stopped = 0; const badges = [];
  setLayoutStore({ read() {}, write() {} });
  const ctl = mount(host, { expert: () => true, badge: (...args) => badges.push(args), prefs: { on: () => () => {} }, toast() {}, call: async () => data, journalStatus: async () => null,
    ctx: { pulse: { every: (_, __, fn) => { tick = fn; return () => { stopped++; }; } } } });
  try {
    await settle();
    eq(host.querySelectorAll('.pr-log-line').length, 3, 'écho Technique et TRACE masqués seulement en lisible');
    const long = host.querySelector('[data-n="2"] .pr-log-text');
    eq(long.firstChild.textContent.length, 280, 'phrase de 280 caractères');
    ok(long.querySelector('details pre').textContent.endsWith('z'.repeat(400)), 'texte complet conservé dans le détail');
    const input = host.querySelector('[data-find]'); input.value = 'Trouver'; input.dispatchEvent(new Event('input', { bubbles: true })); input.focus();
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    eq(host.querySelector('.found').dataset.n, '0', 'première occurrence');
    ok(stopped > 0 && !host.querySelector('[data-toggle="follow"]').checked, 'suivi suspendu après recherche');
    ok(document.activeElement === input, 'Entrée conserve le champ actif');
    const next = host.querySelector('[data-act="find-next"]'); next.focus(); next.click();
    eq(host.querySelector('.found').dataset.n, '2', 'suivant atteint seconde occurrence');
    ok(document.activeElement === next, 'navigation clavier sur le bouton conservée');
    next.click(); eq(host.querySelector('.found').dataset.n, '0', 'boucle vers la première');
    host.querySelector('[data-seg="view"] [data-value="raw"]').click();
    eq(host.querySelectorAll('.pr-log-raw').length, 5, 'brut garde toutes les lignes et la trace');
    next.click(); ok(host.querySelector('.pr-log-raw.found'), 'recherche fonctionne en brut');
    data = view([...data.lines, line(5, 'Information sans annonce')]); await ctl.reload();
    eq(host.querySelector('[data-log-announcement]').textContent, '', 'aucune annonce des informations');
    data = view([...data.lines, line(6, 'Erreur visible', 'ERREUR')]); await ctl.reload();
    ok(host.querySelector('[data-log-announcement]').textContent.includes('Erreur visible'), 'nouvelle erreur annoncée');
    const announcement = host.querySelector('[data-log-announcement]').textContent;
    await ctl.reload(); eq(host.querySelector('[data-log-announcement]').textContent, announcement, 'pas de répétition sur relecture identique');
    host.querySelector('[data-act="clear"]').click();
    eq(badges.at(-1), ['journaux', '', 'off'], 'pastille acquittée sans effacement du fichier');
    await ctl.reload(); eq(badges.at(-1)[1], '', 'relecture ne rétablit pas une ancienne alarme');
    data = view([...data.lines, line(7, 'Nouvel échec', 'ERREUR')]); await ctl.reload();
    eq(badges.at(-1)[1], 1, 'seule la nouvelle erreur devient non lue');
  } finally { ctl.destroy(); host.remove(); setLayoutStore(null); }
});

test('Masquage : session, objet et noms isolés, aperçu explicite et copie entière identique', async () => {
  const names = journalMaskNames({ session: { domain: { dnsName: 'exemple.local', netbiosName: 'EXEMPLE' }, controller: { dnsName: 'dc01.exemple.local' }, account: { login: 'EXEMPLE\\technicien' } }, subject: { name: 'PC-07' } });
  const source = 'EXEMPLE exemple.local dc01 technicien PC-07 Domenia.Core.dll';
  const masked = maskNames(source, names);
  for (const term of ['EXEMPLE', 'exemple.local', 'dc01', 'technicien', 'PC-07']) ok(!masked.includes(term), `${term} retiré`);
  ok(masked.includes('Domenia.Core.dll'), 'nom de bibliothèque conservé');
  eq(readableLogPhrase('a'.repeat(500)).length, 280, 'borne de phrase exacte');
  const original = Object.getOwnPropertyDescriptor(navigator, 'clipboard'); let copied = null;
  Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { async writeText(text) { copied = text; } } });
  try {
    const text = source + '\n' + 'x'.repeat(21000) + ' password=example-secret';
    const pending = copyJournal(text, () => {}, names); await settle();
    const dialog = document.querySelector('.pr-copy-preview')?.closest('.k-dlg');
    ok(dialog, 'le dialogue de copie du journal est monté');
    ok(dialog.querySelector('[data-preview-limit]').textContent.includes('20 000'), 'aperçu tronqué annoncé');
    ok(!dialog.querySelector('[data-preview]').textContent.includes('technicien'), 'aperçu déjà masqué');
    dialog.querySelector('[data-id="ok"]').click(); await pending;
    ok(copied.length > 20000 && copied.includes('x'.repeat(21000)), 'copie entière, pas seulement aperçu');
    ok(!copied.includes('example-secret') && !copied.includes('technicien'), 'secrets et identités masqués dans la copie');
  } finally { if (original) Object.defineProperty(navigator, 'clipboard', original); else delete navigator.clipboard; }
});

test('Acquittement du journal remet les non-lus à zéro et garde les nouvelles erreurs', () => {
  clearNotes(); notify('Erreur ancienne', { tone: 'alert' });
  const old = view([line(20, 'Erreur ancienne', 'ERREUR')]);
  acknowledgeJournal(old); eq(unreadCount(), 0, 'cloche acquittée'); eq(unreadJournalErrors(old), 0, 'journal acquitté');
  eq(unreadJournalErrors(view([...old.lines, line(21, 'Erreur nouvelle', 'ERREUR')])), 1, 'nouvelle erreur non masquée');
  clearNotes();
});

test('Santé du journal : vraie pastille, cause et chemin, une annonce par changement', async () => {
  const host = document.createElement('header'); document.body.append(host);
  let tick, status = { state: 'fallback', problem: 'Accès refusé', path: 'C:\\Temp\\domenia.log', pending: 2, dropped: 0 }; const notices = [], routes = [];
  const stop = installJournalHealth(host, (...args) => routes.push(args), { visible: () => true, call: async () => status,
    report: text => notices.push(text), clock: { every: (_, __, fn) => { tick = fn; return () => {}; } } });
  try {
    await tick(); const button = host.querySelector('button');
    ok(!button.hidden && button.title.includes(status.path) && button.title.includes('Accès refusé'), 'cause et emplacement réels');
    button.click(); eq(routes[0], ['parametres', { section: 'journaux' }], 'action vers la vraie section');
    await tick(); eq(notices.length, 1, 'pas de répétition');
    status = { state: 'active', pending: 0, dropped: 0 }; await tick(); ok(button.hidden, 'sain reste discret');
    status = { state: 'unavailable', pending: 0, dropped: 3, problem: 'Disque plein' }; await tick();
    ok(!button.hidden && button.title.includes('3 perdue'), 'perte visible'); eq(notices.length, 2, 'nouvel état annoncé');
  } finally { stop(); host.remove(); }
});

test('Erreurs prises en charge : anneau client borné, secret masqué avant conservation', () => {
  for (let i = 0; i < 205; i++) swallowed('test.handled', new Error('password=example-hidden'));
  const entries = handledErrors(); eq(entries.length, 200, 'borne client');
  ok(entries.every(e => !e.message.includes('example-hidden') && e.type === 'Error'), 'type et message masqué conservés');
});
