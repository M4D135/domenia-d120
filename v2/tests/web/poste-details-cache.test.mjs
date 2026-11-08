import { test, eq, ok } from './harness.mjs';
import { renderInventory } from '../../web/js/pages/poste/inventory.js';
import { renderDiagnostic } from '../../web/js/pages/poste/diagnostic.js';

const settle = async () => { await new Promise(resolve => setTimeout(resolve, 0)); await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame); };
const pending = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const service = name => ({ name, displayName: name, state: 'Running', stateLabel: 'En cours', startMode: 'Auto', startLabel: 'Automatique', dependsOn: [], dependents: [], canStart: false, canRestart: false, canStop: false });
const result = name => ({ rows: [service(name)], summary: name, profile: [], facts: [] });
const host = () => { const el = document.createElement('div'); el.style.width = '1000px'; document.body.append(el); return el; };

test('Services conservés : ouverture locale seule et réponse ancienne ignorée même au prochain filtre', async () => {
  const el = host(), cache = pending(), first = pending(), second = pending(), calls = [];
  let reads = 0;
  const destroy = renderInventory(el, { initialTab: 'services', dn: 'CN=PC1,DC=test', on: () => () => {},
    data: { computer: { name: 'PC1' } }, call(op) { calls.push(op); if (op === 'poste.detail.cached') return cache.promise;
      if (op === 'poste.services') return (++reads === 1 ? first : second).promise; throw new Error(op); } });
  try {
    eq(calls, ['poste.detail.cached'], 'aucune collecte réseau à l’ouverture');
    cache.resolve({ display: { services: result('Historique') }, notice: 'Relevé local daté' }); await settle();
    ok(el.textContent.includes('Relevé local daté'), 'provenance locale visible');
    const button = el.querySelector('[data-act="read"]'); button.click(); button.click();
    second.resolve(result('Récent')); await settle(); first.resolve(result('Périmé')); await settle();
    const filter = el.querySelector('[data-filter]'); filter.value = ''; filter.dispatchEvent(new Event('input', { bubbles: true }));
    await settle();
    ok(el.textContent.includes('Récent'), 'réponse actuelle conservée après nouveau rendu');
    ok(!el.textContent.includes('Périmé'), 'réponse ancienne absente du modèle et du tableau');
  } finally { destroy(); el.remove(); }
});

test('Diagnostic rapide : cache tardif et ancienne erreur ne remplacent pas le dernier relevé', async () => {
  const el = host(), cache = pending(), first = pending(), second = pending(); let reads = 0;
  const quick = summary => ({ summary, complete: true, durationText: '1 s', facts: [], costText: '', fallback: '' });
  const destroy = renderDiagnostic(el, { initialTab: 'rapide', dn: 'CN=PC1,DC=test', on: () => () => {},
    call(op) { if (op === 'poste.detail.cached') return cache.promise; if (op === 'poste.quickDiag') return (++reads === 1 ? first : second).promise; throw new Error(op); } });
  try {
    const button = el.querySelector('[data-act="run"]'); button.click(); button.click();
    second.resolve(quick('Dernier diagnostic')); await settle();
    first.reject(new Error('Ancienne panne')); cache.resolve({ display: { quick: quick('Ancien cache') }, notice: 'Historique' }); await settle();
    ok(el.textContent.includes('Dernier diagnostic'), 'dernier succès visible');
    ok(!el.textContent.includes('Ancienne panne') && !el.textContent.includes('Ancien cache'), 'réponses tardives ignorées');
  } finally { destroy(); el.remove(); }
});

test('Explorateur WMI : ouverture du relevé conservé sans lecture des espaces ni des instances', async () => {
  const el = host(), calls = [];
  const destroy = renderDiagnostic(el, { ctx: { expert: true }, initialTab: 'wmi', dn: 'CN=PC1,DC=test', on: () => () => {},
    call: async op => { calls.push(op); if (op !== 'poste.detail.cached') throw new Error(op);
      return { display: { wmi: { class: 'Win32_OperatingSystem', schema: [{ name: 'Caption', type: 'string', key: false, qualifiers: '' }], instances: [['Historique Windows']], query: 'Projection locale', status: 'Répondu' } }, notice: 'Relevé local daté' }; } });
  try {
    await settle(); eq(calls, ['poste.detail.cached'], 'opération locale unique');
    ok(el.textContent.includes('Relevé local daté'), 'date et origine présentées');
    ok(el.textContent.includes('Historique Windows'), 'instances conservées consultables');
  } finally { destroy(); el.remove(); }
});
