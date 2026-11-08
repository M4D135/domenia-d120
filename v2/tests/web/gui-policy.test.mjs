import { test, eq, ok } from './harness.mjs';
import { installGuiPolicy, guiCommandReason, guiPolicyProblems } from '../../web/js/shell/gui-policy.js';
import { judge, decide } from '../../web/js/shell/commands.js';
import { closeMenus } from '../../web/js/kit/menu.js';
import { createCommandBar } from '../../web/js/kit/commandbar.js';

const entry = (element, policy = 'Disabled', valid = true) => ({ element, policy, valid });
const frame = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
function fixture(html, entries) {
  const root = document.createElement('div'); root.innerHTML = html; document.body.append(root);
  const messages = []; const ctl = installGuiPolicy(root, () => entries, text => messages.push(text));
  return { root, messages, ctl, get: selector => root.querySelector(selector), close() { ctl.dispose(); root.remove(); } };
}

test('GUI : shell et boutons Paramètres réels sont restreints sans étendre les sélecteurs à une autre page', () => {
  const x = fixture('<button class="nav-toggle">Menu</button><div class="pr-page"><button data-act="backup">Copie</button></div><button data-act="backup" class="other">Autre</button>', [entry('BtnUxSidebarToggle', 'Hidden'), entry('BtnIndexBackup')]);
  try {
    ok(x.get('.nav-toggle').hidden, 'shell masqué'); ok(x.get('.nav-toggle').disabled, 'shell inactif');
    ok(x.get('.pr-page button').disabled, 'bouton HTML réellement désactivé');
    eq(x.get('.pr-page button').getAttribute('aria-disabled'), 'true', 'motif accessible');
    ok(!x.get('.other').disabled, 'pas de correspondance sur une page étrangère');
  } finally { x.close(); }
});

test('GUI : Visible/Default ne réactive ni ne montre un contrôle indisponible', () => {
  const x = fixture('<div class="pr-page"><button data-act="backup" disabled hidden>Copie</button></div>', [entry('BtnIndexBackup', 'Default')]);
  try { ok(x.get('button').disabled, 'validité intrinsèque conservée'); ok(x.get('button').hidden, 'visibilité intrinsèque conservée'); }
  finally { x.close(); }
});

test('GUI : un contrôle inséré est bloqué avant même le rafraîchissement et toute réactivation est corrigée', async () => {
  const x = fixture('', [entry('BtnThemeToggle')]); let ran = 0;
  try {
    x.root.innerHTML = '<div class="theme-switch"><button><span>Thème</span></button></div>';
    x.get('button').addEventListener('click', () => ran++);
    x.get('span').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    eq(ran, 0, 'capture intercepte le nouveau contrôle'); eq(x.messages.length, 1, 'refus explicite');
    await frame(); ok(x.get('button').disabled, 'nouveau bouton qualifié');
    x.get('button').disabled = false; x.get('button').removeAttribute('aria-disabled');
    await frame(); ok(x.get('button').disabled, 'restriction restaurée après rendu');
  } finally { x.close(); }
});

test('GUI : une entrée inconnue ou une valeur invalide ne devient jamais un sélecteur', () => {
  const x = fixture('<button>Libre</button>', [entry('body button', 'Hidden'), entry('FutureControl'), entry('BtnThemeToggle', 'Hidden', false)]);
  try {
    ok(!x.get('button').hidden && !x.get('button').disabled, 'aucun contrôle touché');
    eq(guiPolicyProblems([entry('FutureControl'), entry('BtnLogin'), entry('BtnLogin', 'Unknown', false)]).length, 2, 'noms et modes non pris en charge déclarés');
  } finally { x.close(); }
});

test('GUI : arrêt et Échap restent effectifs même si le nom d’annulation est masqué', () => {
  const x = fixture('<button class="sh-strip-cancel" data-task-cancel>Arrêter</button><button class="nav-toggle">Menu</button>', [entry('BtnCancelTask', 'Hidden'), entry('BtnUxSidebarToggle')]);
  let stopped = 0, escaped = 0;
  try {
    x.get('[data-task-cancel]').addEventListener('click', () => stopped++);
    x.root.addEventListener('keydown', e => { if (e.key === 'Escape') escaped++; });
    x.get('[data-task-cancel]').click();
    const event = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true });
    x.get('.nav-toggle').dispatchEvent(event);
    eq(stopped, 1, 'arrêt transmis'); eq(escaped, 1, 'fermeture transmise'); ok(!event.defaultPrevented, 'Échap non absorbé');
  } finally { x.close(); }
});

test('GUI : palette et raccourcis partagent la politique sans bouton DOM', () => {
  const entries = [entry('BtnThemeToggle', 'Hidden'), entry('LstUiProfile'), entry('BtnGlobalSearch'), entry('LogPanel')];
  for (const id of ['theme-dark', 'theme', 'profile', 'expert-once', 'palette', 'journal', 'notifications']) {
    ok(guiCommandReason(entries, id), `${id} interdit`);
    const decision = judge({ id, effect: 'local', run: () => { throw new Error('exécution interdite'); } }, { policy: command => guiCommandReason(entries, command) });
    eq(decision.available, false, `${id} indisponible dans la palette`);
    eq(decide({ ...decision, effect: 'local' }).action, 'none', `${id} jamais exécuté`);
  }
  eq(guiCommandReason(entries, 'operations'), '', 'centre des tâches/arrêt accessible');
  eq(guiCommandReason(entries, 'cancel'), '', 'annulation accessible');
});

test('GUI : le guide utilise son bouton réel et les contrôles de connexion leurs correspondances fermées', () => {
  const x = fixture('<button data-help-act="guide">Guide</button><button class="mode-chip">Session</button><button class="sh-banner-more">Détail</button>', [entry('BtnUxHelpGuide', 'Hidden'), entry('BtnUxNavAccount')]);
  try {
    ok(x.get('[data-help-act="guide"]').hidden, 'bouton du guide masqué');
    ok(x.get('.mode-chip').disabled && x.get('.sh-banner-more').disabled, 'accès directs à la session restreints');
    ok(guiCommandReason([entry('BtnUxNavAccount')], 'session'), 'commande de session restreinte aussi');
  } finally { x.close(); }
});

test('GUI : fermeture du propriétaire retire les gardes sans modifier les règles métier du contrôle', () => {
  const x = fixture('<button class="nav-toggle">Menu</button>', [entry('BtnUxSidebarToggle')]);
  let clicks = 0;
  try {
    x.get('button').addEventListener('click', () => clicks++); x.ctl.dispose();
    x.get('button').disabled = false; x.get('button').click();
    eq(clicks, 1, 'aucun listener abandonné');
  } finally { x.close(); }
});


test('GUI : reprise de sauvegardes restreinte dans la carte et sa copie du bandeau', () => {
  for (const policy of ['Hidden', 'Disabled']) {
    const x = fixture('<div class="pr-page"><button data-act="writer-resume">Carte</button><button data-alert-act="writer-resume">Avis</button></div>', [entry('BtnGuardStoreResume', policy)]);
    try { for (const button of x.root.querySelectorAll('button')) { ok(button.disabled, 'les deux chemins refusent le clic'); eq(button.hidden, policy === 'Hidden', 'même visibilité administrateur'); } }
    finally { x.close(); }
  }
});

test('GUI : menus de commande déplacés hors page gardent leur restriction et l’arrêt reste accessible', async () => {
  const x = fixture('<div class="rch"><div class="bar"></div></div>', []); let entries = [], ran = 0;
  x.ctl.dispose(); const ctl = installGuiPolicy(x.root, () => entries);
  const bar = createCommandBar(x.get('.bar'), { label: 'Actions', items: [
    { id: 'export', label: 'Exporter', overflow: true, items: [{ label: 'CSV de la sélection', run: () => ran++ }] },
    { id: 'verify', label: 'Arrêter', pinned: true, cancel: true, run: () => ran++ },
  ] });
  try {
    entries = [entry('BtnSearchExport'), entry('BtnSearchVerify', 'Hidden')]; ctl.refresh();
    x.get('.k-cmd-more').click();
    const item = [...document.querySelectorAll('[role="menuitem"]')].find(e => e.textContent.includes('Exporter'));
    ok(item, 'commande présente grisée dans Plus'); eq(item.getAttribute('aria-disabled'), 'true', 'restriction identique hors de la page');
    item.click(); eq(ran, 0, 'aucun export');
    closeMenus();
    x.get('[data-cmd="verify"]').click(); eq(ran, 1, 'arrêt ne dépend pas de la restriction sur le lancement');
    ok(!x.get('[data-cmd="verify"]').hidden, 'arrêt visible');
  } finally { closeMenus(); ctl.dispose(); bar.destroy(); x.close(); await frame(); }
});

test('GUI : une restriction tardive interdit aussi un sous-menu déjà ouvert', async () => {
  const x = fixture('<div class="rq-page"><div class="bar"></div></div>', []); x.ctl.dispose();
  let entries = [], ran = 0; const ctl = installGuiPolicy(x.root, () => entries);
  const bar = createCommandBar(x.get('.bar'), { label: 'Atelier', items: [{ id: 'collect', label: 'Collecter', pinned: true,
    items: [{ label: 'Collecter maintenant', run: () => ran++ }] }] });
  try {
    x.get('[data-cmd="collect"]').click();
    entries = [entry('BtnQueryCollect')]; ctl.refresh();
    const choice = [...document.querySelectorAll('[role="menuitem"]')].find(e => e.textContent.includes('Collecter maintenant'));
    ok(choice, 'menu ouvert avant la politique'); choice.click(); eq(ran, 0, 'propriétaire requalifié au clic');
  } finally { closeMenus(); ctl.dispose(); bar.destroy(); x.close(); await frame(); }
});

test('GUI : formulaire clavier restreint, texte natif du motif et noms d’écrans qualifiés', () => {
  const x = fixture('<div class="wfd"><form class="wfd-form"><input><button type="submit">Valider</button></form></div>',
    [{ ...entry('BtnWriteExample'), text: 'Grisé par la politique de cette session.' }]); let submits = 0;
  try {
    x.get('form').addEventListener('submit', e => { submits++; e.preventDefault(); });
    x.get('form').dispatchEvent(new SubmitEvent('submit', { bubbles: true, cancelable: true, submitter: x.get('button') }));
    eq(submits, 0, 'pas de contournement clavier du bouton'); eq(x.get('button').dataset.tip, 'Grisé par la politique de cette session.', 'motif du contrat affiché');
    eq(guiPolicyProblems(['TabFicheRights', 'TabPosteWmi', 'TabQueryWmi', 'BtnHomeEdit', 'BtnSectionScopeFollow'].map(id => entry(id))).length, 0, 'noms fermés pris en charge');
  } finally { x.close(); }
});
