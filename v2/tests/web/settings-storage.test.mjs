import { test, eq, ok } from './harness.mjs';
import { mount } from '../../web/js/pages/parametres/donnees.js';
import { paintStorageAlert } from '../../web/js/pages/parametres/alerts.js';
import { setLayoutStore } from '../../web/js/kit/util.js';

const settle = async () => { for (let n = 0; n < 40; n++) await Promise.resolve(); };
const base = () => ({ available: true, simulated: false, revision: 1, schema: '11/1', tiles: [], backups: [], catalog: [], never: [], limits: [], retention: [], purge: [], policy: {}, content: 'Base locale',
  location: { text: 'Base du domaine test.local · 4 Mo · jamais sauvegardée', path: 'C:\\Domenia\\Domenia.db', pathLabel: 'C:\\Domenia\\Domenia.db', alert: false },
  writer: { text: 'Enregistré', tone: 'ok', unsaved: '', canResume: false }, space: { label: 'Normal', text: 'Espace disponible', tone: 'ok' }, maintenance: { text: 'Prête', tone: 'ok' } });
async function page(view, tab = 'apercu', answer = () => { throw new Error('Appel inattendu'); }) {
  const host = document.createElement('section'); host.className = 'pr-page'; document.body.append(host);
  const calls = [], messages = []; setLayoutStore({ read() {}, write() {} });
  const ctl = mount(host, { badge() {}, address() {}, refreshStorage() {}, toast: (text, options) => messages.push({ text, options }), async call(op, args) { calls.push({ op, args }); return op === 'settings.storage' ? view : answer(op, args); } }, { tab });
  await settle();
  return { host, calls, messages, close() { ctl.destroy(); host.remove(); setLayoutStore(null); } };
}

test('Données : la carte de sauvegarde affiche preuves, échéance et erreur et enregistre les trois choix', async () => {
  const view = base(); Object.assign(view, { exports: [], policy: { automaticBackup: true, backupHours: 24, backupKeep: 7 }, schedule: { lines: [
    'Dernière sauvegarde vérifiée : 21/10/2026 à 18:26 (contrôle SQLite réussi, 4 Mo, empreinte SHA-256 aaaaaaaaaaaa…).',
    'Prochaine sauvegarde : au plus tôt le 22/10/2026 à 18:26, si Domenia est ouvert.',
    'Dernier échec (cette session) : 21/10/2026 à 19:00 : Disque indisponible.',
  ] } });
  const p = await page(view, 'sauvegardes', (op, args) => {
    if (op !== 'settings.storage.backup.schedule.set') throw new Error(op);
    return view;
  });
  try {
    for (const line of view.schedule.lines) ok(p.host.textContent.includes(line), 'chaque information reçue reste visible');
    const enabled = p.host.querySelector('[data-toggle="schedule-enabled"]');
    ok(enabled, 'commande de planification réelle présente'); enabled.checked = false;
    p.host.querySelector('[data-select="schedule-hours"]').value = '48';
    p.host.querySelector('[data-select="schedule-keep"]').value = '3';
    p.host.querySelector('[data-act="schedule-save"]').click(); await settle();
    eq(p.calls.find(c => c.op === 'settings.storage.backup.schedule.set')?.args, { enabled: false, hours: 48, keep: 3 }, 'choix exacts transmis sans déclencher une copie');
    ok(!p.calls.some(c => c.op.includes('backup.plan')), 'enregistrer une fréquence ne sauvegarde pas immédiatement');
  } finally { p.close(); }
});

test('Données : arrêt pour date future et absence de sauvegarde sont lisibles dans la vraie carte', async () => {
  for (const message of ['Dernière sauvegarde datée après l’horloge du poste : planification arrêtée, vérifiez la date du poste.', 'Aucune sauvegarde vérifiée enregistrée pour cette base.']) {
    const view = base(); Object.assign(view, { exports: [], policy: { automaticBackup: true, backupHours: 24, backupKeep: 7 }, schedule: { lines: [message] } });
    const p = await page(view, 'sauvegardes');
    try { ok(p.host.textContent.includes(message), 'état présenté sans succès inventé'); eq(p.calls.length, 1, 'ouverture en lecture seule'); }
    finally { p.close(); }
  }
});

test('Données : ligne compacte, copie exacte et ouverture de la base active depuis la vraie section', async () => {
  const original = Object.getOwnPropertyDescriptor(navigator, 'clipboard'); let copied;
  Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { async writeText(text) { copied = text; } } });
  const view = base(); const p = await page(view, 'apercu', op => { if (op === 'settings.folder.open') return {}; throw new Error(op); });
  try {
    ok(!p.host.textContent.includes(view.location.path), 'chemin complet seulement en infobulle');
    eq(p.host.querySelector('.pr-location-text b').dataset.tip, view.location.path, 'chemin accessible');
    p.host.querySelector('[data-act="copy-path"]').click(); await settle();
    eq(copied, view.location.path, 'chemin du snapshot copié sans substitution');
    ok(p.messages.some(m => m.text === 'Chemin de la base copié.'), 'succès visible');
    p.host.querySelector('[data-act="open-base"]').click(); await settle();
    eq(p.calls.at(-1), { op: 'settings.folder.open', args: { folder: 'base' } }, 'aucun chemin arbitraire transmis par la page');
  } finally { p.close(); if (original) Object.defineProperty(navigator, 'clipboard', original); else delete navigator.clipboard; }
});

test('Données : échec des deux voies de copie annoncé, aucun faux succès', async () => {
  const original = Object.getOwnPropertyDescriptor(navigator, 'clipboard'), command = document.execCommand;
  Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { async writeText() { throw new Error('refus'); } } });
  document.execCommand = () => false;
  const p = await page(base());
  try {
    p.host.querySelector('[data-act="copy-path"]').click(); await settle();
    ok(p.messages.some(m => m.text.includes('presse-papiers indisponible') && m.options.tone === 'warn'), 'refus présenté');
    ok(!p.messages.some(m => m.text === 'Chemin de la base copié.'), 'pas de succès inventé');
  } finally { p.close(); document.execCommand = command; if (original) Object.defineProperty(navigator, 'clipboard', original); else delete navigator.clipboard; }
});

test('Données : base absente ou fictive refuse copie et Explorateur, diagnostic visible sans action dangereuse', async () => {
  for (const simulated of [false, true]) {
    const view = base(); view.simulated = simulated;
    if (!simulated) {
      Object.assign(view, { available: false, unavailableReason: 'Marqueur incohérent : fichiers conservés', location: { text: 'Aucune base locale pour ce domaine.', path: null, pathLabel: '' }, integrity: { verdict: 'Défaut', tone: 'alert', failed: 1, lines: ['Contrôle interrompu', 'Aucun remplacement', 'Lecture seule'], checks: [{ label: 'Bascule', status: 'failed', statusLabel: 'Défaut', tone: 'alert', detail: 'Marqueur incohérent' }] } });
    }
    const p = await page(view);
    try {
      for (const action of ['copy-path', 'open-base']) {
        const b = p.host.querySelector(`[data-act="${action}"]`); eq(b.getAttribute('aria-disabled'), 'true', `${action} refusé avec raison`); b.click();
      }
      await settle(); eq(p.calls.length, 1, 'aucune ouverture ni appel après action refusée');
      if (!simulated) { ok(p.host.textContent.includes('Marqueur incohérent'), 'cause réelle visible'); ok(!p.host.querySelector('[data-act="restore"], [data-act="resume"], [data-act="writer-resume"]'), 'aucune reprise sous identité douteuse'); }
    } finally { p.close(); }
  }
});

test('Données : prévisualisations montrent anciens relevés conservés et cible vide à réinitialiser', async () => {
  const view = base(); view.purge = [{ id: 'index', label: 'Index', purgeable: true, rows: 0, detail: 'Repère de lecture à réinitialiser' }];
  const p = await page(view, 'conservation', op => {
    if (op === 'settings.storage.retention.preview') return { at: '2026-11-01', families: [], nothingToDo: true, totalRows: 0, lines: ['3 anciens relevés non migrés conservés', 'Toujours conservés', 'Sauvegarde avant', 'Place réutilisable'] };
    if (op === 'settings.storage.purge.preview') return { targets: [{ label: 'Index', table: 'sync_state', action: 'reset', rows: 0 }], refused: [], lines: ['Repère de lecture réinitialisé'], nothingToDo: false, totalRows: 0 };
    throw new Error(op);
  });
  try {
    p.host.querySelector('[data-act="retention-preview"]').click(); await settle();
    ok(p.host.querySelector('[data-slot="retention-preview"]').textContent.includes('3 anciens relevés non migrés'), 'l’explication supplémentaire reste visible');
    const choice = p.host.querySelector('[data-purge="index"]'); choice.checked = true;
    p.host.querySelector('[data-act="purge-preview"]').click(); await settle();
    ok(p.host.querySelector('[data-slot="purge-preview"]').textContent.includes('Réinitialisé'), 'zéro ligne avec repère est une action réelle');
    ok(p.host.querySelector('[data-act="purge-apply"]').getAttribute('aria-disabled') !== 'true', 'plan disponible même avec compteur de suppression nul');
    choice.checked = false; choice.dispatchEvent(new Event('change', { bubbles: true }));
    eq(p.host.querySelector('[data-act="purge-apply"]').getAttribute('aria-disabled'), 'true', 'modifier le choix invalide l’ancienne confirmation');
  } finally { p.close(); }
});


test('Avis stockage : une même suspension ne répète pas son annonce après chaque mesure', () => {
  const slot = document.createElement('div'); slot.setAttribute('role', 'alert'); document.body.append(slot);
  try {
    paintStorageAlert(slot, { space: { blocksCollections: true, label: 'Critique', text: 'Réserve insuffisante mesurée à 10 h' } });
    const first = slot.firstElementChild;
    ok(slot.textContent.includes('Espace disque critique'), 'avis réel visible');
    paintStorageAlert(slot, { space: { blocksCollections: true, label: 'Critique', text: 'Réserve insuffisante mesurée à 11 h' } });
    eq(slot.firstElementChild, first, 'aucune reconstruction du rôle alert à cause de la date');
    paintStorageAlert(slot, { space: { blocksCollections: false, label: 'Normal', text: 'Disponible' } });
    ok(slot.hidden, 'alerte retirée quand sa cause est levée');
    paintStorageAlert(slot, { writer: { state: 'suspended', canResume: true, text: 'Échec disque' } });
    ok(!slot.hidden && slot.querySelector('[data-alert-act="writer-resume"]'), 'nouvelle cause annoncée et action présente');
  } finally { slot.remove(); }
});


test('Purge : une réponse tardive ne réarme pas la confirmation après modification du choix', async () => {
  let resolve; const response = new Promise(done => { resolve = done; });
  const view = base(); view.purge = [{ id: 'index', label: 'Index', purgeable: true, rows: 0, detail: 'Repère' }];
  const p = await page(view, 'conservation', op => { if (op === 'settings.storage.purge.preview') return response; throw new Error(op); });
  try {
    const choice = p.host.querySelector('[data-purge="index"]'); choice.checked = true;
    p.host.querySelector('[data-act="purge-preview"]').click(); await settle();
    choice.checked = false; choice.dispatchEvent(new Event('change', { bubbles: true }));
    resolve({ targets: [{ label: 'Index', table: 'sync_state', action: 'reset', rows: 1 }], refused: [], lines: [], nothingToDo: false, totalRows: 0 }); await settle();
    eq(p.host.querySelector('[data-act="purge-apply"]').getAttribute('aria-disabled'), 'true', 'la réponse périmée ne réactive pas le bouton');
    ok(p.host.querySelector('[data-slot="purge-preview"]').hidden, 'aucun ancien aperçu présenté comme courant');
  } finally { p.close(); }
});

function legacyView() {
  return { ...base(), exports: [], maintenance: { text: 'Prête', tone: 'ok', restore: true }, legacy: {
    state: 'available', tone: 'info', text: 'Sources conservées', location: 'C:\\Domenia\\data', blockers: [], steps: [], guards: [],
    database: { name: 'ADCC.db', path: 'C:\\Domenia\\data\\ADCC.db', schemaVersion: '11', revision: '1', domain: 'test.local', bytes: 4096, active: true, notice: 'Base ADCC adoptée sur place comme base active ; sauvegarde avant évolution.' },
    files: [{ label: 'Objets', path: 'C:\\Domenia\\data\\Index\\objets.tsv', rows: 1, bytesText: '1 Ko', rejected: 0, locked: true }],
  } };
}

test('Reprise : base active honnêtement identifiée, aperçu bloqué sans confirmation et fichier séparé choisi sans copie', async () => {
  const p = await page(legacyView(), 'reprise', op => {
    if (op === 'settings.storage.legacy.preview') return { fingerprint: 'refused', blockers: ['Domaine différent'], nothingToDo: false, writeCount: 0, lines: ['Domaine différent : aucune reprise.'] };
    throw new Error(op);
  });
  try {
    ok(p.host.textContent.includes('Base déjà active'), 'source et base active distinguées');
    ok(!p.host.textContent.includes('laissée intacte'), 'aucune fausse promesse pour une base adoptée');
    ok(p.host.textContent.includes('Lecture protégée'), 'verrou passé annoncé sans verrou permanent inventé');
    p.host.querySelector('[data-act="legacy-preview"]').click(); await settle();
    eq(p.host.querySelector('[data-act="legacy-apply"]').getAttribute('aria-disabled'), 'true', 'bloqueur interdit le plan même avec nothingToDo faux');
    p.host.querySelector('[data-act="legacy-base"]').click(); await settle();
    const dialog = document.querySelector('.k-dlg-layer:not(.leaving)');
    ok(dialog?.textContent.includes('nouveau fichier'), 'choix de source expose la copie sans écrasement');
    dialog.querySelector('[data-id="cancel"]').click(); await settle();
    ok(!p.calls.some(c => /\.plan$|write.execute/.test(c.op)), 'annuler le choix ne prépare ni n’exécute de bascule');
  } finally { document.querySelectorAll('.k-dlg-x').forEach(b => b.click()); p.close(); }
});

test('Reprise : copie ADCC après aperçu et confirmation seulement, fingerprint exact puis relecture', async () => {
  let published = false;
  const preview = () => ({ available: true, fingerprint: 'a'.repeat(64), copies: [{ id: 'adcc.theme.cfg', source: 'C:\\Domenia\\ADCC.theme.cfg', destination: 'C:\\Domenia\\Domenia.theme.cfg', state: published ? 'kept' : 'ready', notice: published ? 'Destination conservée.' : 'Original conservé, aucun remplacement.' }] });
  const p = await page(legacyView(), 'reprise', (op, args) => {
    if (op === 'shell.interface.compatibility.preview') return preview();
    if (op === 'shell.interface.compatibility.apply') { eq(args, { id: 'adcc.theme.cfg', fingerprint: 'a'.repeat(64) }, 'seul nom fermé et preuve envoyés'); published = true; return { applied: true, summary: 'Copie vérifiée et relue.' }; }
    throw new Error(op);
  });
  try {
    eq(p.calls.length, 1, 'ouvrir ne copie ni ne lit les réglages historiques');
    p.host.querySelector('[data-act="legacy-compatibility-preview"]').click(); await settle();
    p.host.querySelector('[data-act="legacy-copy:adcc.theme.cfg"]').click(); await settle();
    let dialog = document.querySelector('.k-dlg-layer:not(.leaving)');
    ok(dialog?.textContent.includes('Aucun fichier existant'), 'effet exact expliqué');
    dialog.querySelector('[data-id="cancel"]').click(); await settle();
    ok(!published, 'annulation sans publication');
    p.host.querySelector('[data-act="legacy-copy:adcc.theme.cfg"]').click(); await settle();
    dialog = document.querySelector('.k-dlg-layer:not(.leaving)'); dialog.querySelector('[data-id="ok"]').click(); await settle();
    eq(p.calls.filter(c => c.op === 'shell.interface.compatibility.apply').length, 1, 'une seule publication');
    ok(p.host.textContent.includes('Destination conservée.'), 'état réellement relu après copie');
    ok(!p.host.querySelector('[data-act="legacy-copy:adcc.theme.cfg"]'), 'destination ne propose plus de copie');
  } finally { document.querySelectorAll('.k-dlg-x').forEach(b => b.click()); p.close(); }
});

test('Reprise : la session est rafraîchie après le reçu vérifié et la réapplication des préférences, jamais avant', async () => {
  const motion = document.documentElement.dataset.motion; document.documentElement.dataset.motion = 'reduced';
  let finishPreferences; const preferences = new Promise(resolve => { finishPreferences = resolve; });
  const seen = []; const changed = () => seen.push('session'); window.addEventListener('domenia:session-changed', changed);
  const now = new Date().toISOString(); const target = { kind: 'localStore', kindLabel: 'Base locale', name: 'Domenia.db', dn: 'C:\\Domenia\\Domenia.db' };
  const plan = { id: 'legacy-base-test', kind: 'storage.restore', title: 'Reprendre une base', summary: 'Copie vérifiée.', target, simulated: false,
    changes: [], risks: [], confirmation: { typedNameRequired: false, reason: 'Original conservé' }, reversibility: { reversible: true, label: 'Retour', detail: 'Original conservé' },
    operator: 'TEST\\operator', controller: 'local', details: 'Copie locale', createdAt: now, expiresAt: new Date(Date.now() + 300000).toISOString() };
  const receipt = { id: 'legacy-base-receipt', kind: 'storage.restore', result: 'applied', verification: 'verified', title: plan.title, label: plan.title, target,
    tone: 'ok', verificationLabel: 'Vérifiée', resultLabel: 'Appliquée', summary: 'Copie relue', simulated: false, pending: false, details: [], controller: 'local', operator: plan.operator,
    sentAt: now, verifiedAt: now, plan: { fingerprint: 'a'.repeat(64), details: plan.details } };
  const p = await page(legacyView(), 'reprise', (op, args) => {
    if (op === 'settings.storage.restore.plan') { eq(args, { file: 'C:\\Historique\\Domenia.db' }, 'source séparée au vrai parcours'); return { plan, token: 'test' }; }
    if (op === 'write.execute') return receipt;
    if (op === 'settings.storage.restore.preferences') { seen.push('preferences'); return preferences; }
    throw new Error(op);
  });
  try {
    p.host.querySelector('[data-act="legacy-base"]').click(); await settle();
    let dialog = document.querySelector('.k-dlg-layer:not(.leaving)'); dialog.querySelector('[data-restore-file]').value = 'C:\\Historique\\Domenia.db';
    dialog.querySelector('[data-id="ok"]').click(); await settle();
    document.querySelector('.k-drw-layer [data-wf="confirm"]').click(); await settle();
    dialog = document.querySelector('.k-dlg-layer:not(.leaving)'); dialog.querySelector('[data-id="confirm"]').click(); await settle();
    eq(seen, ['preferences'], 'préférences encore en cours : aucun changement de page annoncé');
    finishPreferences({ summary: 'Préférences relues.', failed: [] }); await settle();
    eq(seen, ['preferences', 'session'], 'rafraîchissement après réapplication terminée');
    eq(p.calls.filter(c => c.op === 'write.execute').length, 1, 'aucun double envoi');
  } finally {
    finishPreferences({ summary: 'Fin', failed: [] }); window.removeEventListener('domenia:session-changed', changed);
    document.querySelectorAll('.k-dlg-x, .k-drw-x').forEach(b => b.click()); p.close();
    if (motion === undefined) delete document.documentElement.dataset.motion; else document.documentElement.dataset.motion = motion;
  }
});
