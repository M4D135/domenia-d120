// Assistance · guided paths (Domenia 1 recipes, ASS-013 to ASS-016): the recipes by symptom on the left, the chosen recipe as
// an animated stepper on the right. Each step says what it reads, why and at what cost, for which object, whether it is
// optional and whether it needs the administration rights of the workstation. A step reads only on its own click (or after
// the confirmation of a batch of reads without administration rights); its result is shown in its row, never a verdict.
import { esc, errorText, applyVars, reveal, announce, motionReduced } from '../../ui.js';
import { confirmDialog } from '../../kit/index.js';
import { ico, chip, tone, avatar, plural, COLON, NBSP } from './common.js';
import { loadSuggestions } from './subjects.js';

const ICONS = { key: 'key', gauge: 'gauge', disk: 'disk', layers: 'layers', printer: 'printer', folder: 'folder', domain: 'domain' };
const SCREEN_LABEL = { fiche: 'Fiche', poste: 'Poste', audit: 'Audit AD', comptes: 'Comptes' };
const PHASE_ICON = { needSubject: 'user', viewOnly: 'eye', ready: 'play', read: 'check', refused: 'lock', failed: 'alert' };

const ringLength = 100;

function ring(done, total, label) {
  const p = total > 0 ? done / total : 0;
  return `<div class="as-ring" role="img" aria-label="${esc(`${done} sur ${total} ${label}`)}">
    <svg viewBox="0 0 64 64" aria-hidden="true"><circle class="track" cx="32" cy="32" r="26" pathLength="${ringLength}"/>
      <circle class="value" cx="32" cy="32" r="26" pathLength="${ringLength}" data-p="${p.toFixed(3)}"/></svg>
    <span class="as-ring-center"><b>${done}<small>/${total}</small></b><span>${esc(label)}</span></span>
  </div>`;
}

function recipeCard(r, selected, n) {
  const reads = r.userReads + r.computerReads;
  const p = reads > 0 ? r.done / reads : 0;
  return `<button type="button" role="option" class="as-recipe-card hue-${(n % 7) + 1}${selected ? ' selected' : ''}" data-recipe="${esc(r.id)}" aria-selected="${selected}" data-tip="${esc(r.symptom)}" aria-description="${esc(r.symptom)}">
    <span class="as-recipe-ico">${ico(ICONS[r.icon] ?? 'route')}${r.added ? `<span class="as-new" data-tip="Recette ajoutée par Domenia${NBSP}2"><span class="visually-hidden">Nouvelle recette</span>${ico('sparkles')}</span>` : ''}</span>
    <span class="as-recipe-text"><b>${esc(r.title)}</b></span>
    <span class="as-recipe-meta"><span>${plural(r.steps, 'étape', 'étapes')}</span>${r.privileged ? `<span>${ico('shield')}${r.privileged}${NBSP}admin</span>` : ''}${r.done ? `<span class="done">${ico('check')}${r.done}/${reads}</span>` : ''}</span>
    <span class="as-recipe-bar" aria-hidden="true"><span data-p="${p.toFixed(3)}"></span></span>
  </button>`;
}

function stepTags(s) {
  return [
    chip(s.subject === 'computer' ? 'info' : 'accent', `Pour${COLON}${s.subjectLabel}`, { icon: s.subject === 'computer' ? 'monitor' : 'user' }),
    s.optional ? chip('off', 'Facultative', { tip: 'À lancer seulement si les étapes précédentes n’expliquent pas le symptôme.' }) : '',
    s.privileged ? chip('warn', 'Droits d’administration du poste', { icon: 'shield', tip: 'Le compte de la session doit être administrateur du poste.' }) : '',
    s.action ? '' : chip('off', 'Sans lecture', { icon: 'eye', tip: 'Cette étape ouvre une vue déjà lue, sans nouvelle lecture.' }),
  ].join('');
}

function stateChip(s, running) {
  if (running) return `<span class="as-state running"><span class="k-spin" aria-hidden="true"></span>Lecture en cours…</span>`;
  return `<span class="as-state ${esc(s.state.phase)} ${tone(s.state.tone)}">${ico(PHASE_ICON[s.state.phase] ?? 'info')}${esc(s.state.text)}</span>`;
}

function result(s) {
  if (s.reading) {
    const r = s.reading;
    const facts = (r.facts ?? []).map((f, n) => `<div class="as-fact ${tone(f.tone)}" data-j="${n}"><span>${esc(f.label)}</span><b>${esc(f.value)}</b></div>`).join('');
    const items = (r.items ?? []).map((it) => `<li class="${tone(it.tone)}"><span class="as-dot" aria-hidden="true"></span><b>${esc(it.title)}</b>${it.detail ? `<small>${esc(it.detail)}</small>` : ''}</li>`).join('');
    const count = (r.items?.length ?? 0) + (r.more ?? 0);
    return `<div class="as-result ${tone(r.tone)}">
      <div class="as-result-head">${ico(r.tone === 'ok' ? 'check' : r.tone === 'alert' ? 'alert' : 'info')}<p>${esc(r.summary)}</p></div>
      ${facts ? `<div class="as-facts">${facts}</div>` : ''}
      ${items ? `<details class="as-result-items"${count <= 4 ? ' open' : ''}><summary>${ico('chevronRight')}${esc(plural(count, 'élément lu', 'éléments lus'))}${r.more ? ` (${r.items.length} affichés)` : ''}</summary><ul>${items}</ul></details>` : ''}
      <p class="as-result-limit">${ico('info')}${esc(r.limit)}</p>
    </div>`;
  }
  if (s.error) {
    return `<div class="as-result failed ${s.state.phase === 'refused' ? 'alert' : 'warn'}" role="note">
      <div class="as-result-head">${ico(s.state.phase === 'refused' ? 'lock' : 'alert')}<p>${esc(s.error)}</p></div>
      <p class="as-result-limit">${ico('info')}Rien n’est relancé automatiquement. L’incident est expliqué dans «${NBSP}Incidents expliqués${NBSP}».</p>
    </div>`;
  }
  return '';
}

function stepItem(s, running, last, next = false) {
  const subjectMissing = s.state.phase === 'needSubject';
  const runLabel = s.state.phase === 'read' || s.state.phase === 'failed' || s.state.phase === 'refused' ? 'Relancer la lecture' : 'Lancer la lecture';
  const run = s.action ? `<button class="btn sm ${next ? 'as-run next' : 'subtle'}" type="button" data-run${s.state.canRun && !running ? '' : ' disabled'}
      ${subjectMissing ? `data-tip="${esc(s.state.text)}"` : ''}>${running ? '<span class="k-spin" aria-hidden="true"></span>' : ico('play')}${esc(running ? 'Lecture en cours…' : runLabel)}</button>` : '';
  const open = `<button class="btn ghost sm" type="button" data-open${s.state.canOpen ? '' : ' disabled'}>${ico('external')}Ouvrir${NBSP}· ${esc(s.view.label)}</button>`;
  return `<li class="as-step phase-${esc(s.state.phase)}${running ? ' running' : ''}${last ? ' last' : ''} reveal" data-step="${esc(s.id)}">
    <div class="as-step-rail" aria-hidden="true"><span class="as-step-num">${s.state.phase === 'read' ? ico('check') : s.order}</span><span class="as-step-line"></span></div>
    <div class="as-step-card">
      <div class="as-step-top">
        <div class="as-step-title"><h3><span class="visually-hidden">Étape ${s.order}${COLON}</span>${esc(s.title)}</h3><div class="as-step-tags">${stepTags(s)}</div></div>
        ${stateChip(s, running)}
      </div>
      <dl class="as-step-facts">
        <div><dt>${ico('scan')}Ce qui est lu</dt><dd>${esc(s.reads)}</dd></div>
        <div><dt>${ico('bulb')}Pourquoi</dt><dd>${esc(s.why)}</dd></div>
        <div><dt>${ico('clock')}Coût</dt><dd>${esc(s.cost)}</dd></div>
      </dl>
      <div class="as-step-actions">${run}${open}${s.actionLabel ? `<span class="as-step-op" data-tip="Lecture de la liste fermée, choisie par le moteur">${ico('lock')}${esc(s.operation)}</span>` : ''}</div>
      <div class="as-step-result" aria-live="polite">${result(s)}</div>
      ${running ? '<span class="as-scan" aria-hidden="true"></span>' : ''}
    </div>
  </li>`;
}

export function renderRecipes(host, app) {
  host.innerHTML = `<div class="as-recipes-view">
    <div class="as-start" data-start hidden></div>
    <div class="as-recipes">
      <div class="as-recipe-list reveal" role="listbox" aria-label="Recettes par symptôme" data-list></div>
      <article class="as-recipe card reveal" data-detail aria-live="off"></article>
    </div>
  </div>`;
  const listHost = host.querySelector('[data-list]');
  const detail = host.querySelector('[data-detail]');
  const start = host.querySelector('[data-start]');
  const offs = [];

  const recipes = () => app.recipes?.recipes ?? [];
  const current = () => recipes().find((r) => r.id === app.memory.recipe) ?? recipes()[0];

  function paintList() {
    const list = recipes();
    if (!list.length) {
      listHost.innerHTML = Array.from({ length: 5 }, () => '<div class="as-recipe-card sk"><span class="skeleton as-sk w70"></span><span class="skeleton as-sk w40"></span></div>').join('');
      listHost.setAttribute('aria-busy', 'true');
      return;
    }
    listHost.removeAttribute('aria-busy');
    const chosen = current();
    listHost.innerHTML = list.map((r, n) => recipeCard(r, r.id === chosen?.id, n)).join('');
    applyVars(listHost);
  }

  async function paintStart() {
    if (app.subject('user') || app.subject('computer')) { start.hidden = true; start.innerHTML = ''; return; }
    start.hidden = false;
    start.innerHTML = `<div class="as-start-head">${ico('sparkles')}<div><h2>Pour commencer</h2><p>Choisissez le compte ou le poste concerné dans la session d’assistance${NBSP}: les étapes s’activent pour lui. Quelques pistes d’après les données locales${NBSP}:</p></div></div>
      <div class="as-start-grid" aria-busy="true">${'<span class="skeleton as-sk-card"></span>'.repeat(4)}</div>`;
    const list = await loadSuggestions(app);
    if (app.disposed() || app.subject('user') || app.subject('computer')) { paintStartHidden(); return; }
    const grid = start.querySelector('.as-start-grid');
    grid.removeAttribute('aria-busy');
    grid.innerHTML = list.length ? list.slice(0, 8).map((s, n) => `<button type="button" class="as-suggestion reveal" data-dn="${esc(s.subject.dn)}" data-kind="${esc(s.subject.kind)}" data-j="${n}">
        ${avatar(s.subject.name, s.subject.kind, 'sm')}<span class="as-sug-body"><b>${esc(s.subject.name)}</b><small class="${s.subject.kind === 'computer' ? 'warn' : tone(s.subject.tone)}"><span class="as-dot" aria-hidden="true"></span>${esc(s.reason)}</small></span></button>`).join('')
      : '<p class="as-faint">Aucune suggestion dans les données locales.</p>';
    applyVars(grid);
    reveal(grid);
  }
  function paintStartHidden() { start.hidden = true; start.innerHTML = ''; }
  start.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-dn]') : null;
    if (b) app.readSubject(b.dataset.kind === 'computer' ? 'computer' : 'user', b.dataset.dn);
  });

  function nextStep(r) {
    return r?.stepList?.find((s) => s.action && s.state.phase === 'ready');
  }

  function batchSteps(r) {
    return (r?.stepList ?? []).filter((s) => s.action && !s.privileged && s.state.canRun && s.state.phase === 'ready');
  }

  function paintDetail(animate = true) {
    const r = current();
    if (!r) {
      detail.innerHTML = '<div class="as-sk-stack" aria-busy="true"><span class="skeleton as-sk w40"></span><span class="skeleton as-sk w85"></span><span class="skeleton as-sk w70"></span></div>';
      return;
    }
    const reads = r.userReads + r.computerReads;
    const user = app.subject('user');
    const computer = app.subject('computer');
    const needs = [];
    if (r.stepList.some((s) => s.subject === 'user')) {
      needs.push(user ? chip('ok', `Compte${COLON}${user.card.name}`, { icon: 'user' }) : chip('warn', 'Compte à choisir', { icon: 'user', tip: 'Les étapes « Pour : Utilisateur » attendent le compte concerné.' }));
    }
    if (r.stepList.some((s) => s.subject === 'computer')) {
      needs.push(computer ? chip('ok', `Poste${COLON}${computer.card.name}`, { icon: 'monitor' }) : chip('warn', 'Poste à choisir', { icon: 'monitor', tip: 'Les étapes « Pour : Poste » attendent le poste concerné.' }));
    }
    const next = nextStep(r);
    const batch = batchSteps(r);
    const anyRunning = r.stepList.some((s) => app.running.has(`${r.id}/${s.id}`));
    detail.innerHTML = `<header class="as-recipe-head">
        <span class="as-recipe-hero-ico hue-${(recipes().indexOf(r) % 7) + 1}">${ico(ICONS[r.icon] ?? 'route')}</span>
        <div class="as-recipe-titles"><span class="as-k">Parcours guidé${NBSP}· ${esc(plural(r.steps, 'étape', 'étapes'))}${r.added ? `${NBSP}· ajouté par Domenia${NBSP}2` : ''}</span>
          <h2>${esc(r.title)}</h2><p>${esc(r.symptom)}</p></div>
        ${ring(r.done, reads, reads > 1 ? 'lectures' : 'lecture')}
      </header>
      <div class="as-plan">${ico('scan')}<p><b>Avant le premier clic${COLON}</b>${esc(r.plan)}</p></div>
      <div class="as-recipe-bar-row">
        <div class="as-needs">${needs.join('')}</div>
        <div class="as-recipe-actions">
          <button class="btn primary" type="button" data-next${next && !anyRunning ? '' : ' disabled'}>${ico('play')}${next ? `Étape suivante${COLON}${esc(next.title)}` : 'Aucune lecture à lancer'}</button>
          <button class="btn subtle" type="button" data-batch${batch.length > 1 && !anyRunning ? '' : ' disabled'} data-tip="Lectures sans droits d’administration du poste, l’une après l’autre, après confirmation">${ico('steps')}Lancer en lot (${batch.length})</button>
        </div>
      </div>
      <ol class="as-steps">${r.stepList.map((s, i) => stepItem(s, app.running.has(`${r.id}/${s.id}`), i === r.stepList.length - 1, s === next)).join('')}</ol>`;
    applyVars(detail);
    if (animate) reveal(detail);
    else detail.querySelectorAll('.reveal').forEach((el) => el.classList.remove('reveal'));
  }

  function replaceStep(recipeId, step) {
    const r = recipes().find((x) => x.id === recipeId);
    if (!r) return;
    const at = r.stepList.findIndex((s) => s.id === step.id);
    if (at >= 0) r.stepList[at] = step;
    r.done = r.stepList.filter((s) => s.state.phase === 'read').length;
  }

  async function runStep(recipeId, stepId) {
    const r = recipes().find((x) => x.id === recipeId);
    const s = r?.stepList.find((x) => x.id === stepId);
    if (!s || !s.action) return false;
    const dn = app.dnOf(s.subject);
    if (!dn) { app.toast(s.state.text, { tone: 'warn' }); return false; }
    const key = `${recipeId}/${stepId}`;
    if (app.running.has(key)) return false;
    app.running.add(key);
    if (recipeId === current()?.id) paintStepOnly(stepId);
    announce(`Lecture lancée${COLON}${s.title}.`);
    try {
      const out = await app.call('assistance.step.run', { recipe: recipeId, step: stepId, dn });
      app.running.delete(key);
      replaceStep(recipeId, out.step);
      const phase = out.step.state.phase;
      announce(`${s.title}${COLON}${out.step.reading?.summary ?? out.step.error ?? out.step.state.text}`);
      if (phase !== 'read') {
        app.toast(out.step.error ?? out.step.state.text, { tone: phase === 'refused' ? 'alert' : 'warn' });
        app.refreshWorkshop();
      }
      return phase === 'read';
    } catch (err) {
      app.running.delete(key);
      app.toast(`${s.title}${COLON}${errorText(err)}`, { tone: 'warn' });
      return false;
    } finally {
      if (!app.disposed()) {
        app.running.delete(key);
        if (recipeId === current()?.id) paintDetail(false);
        paintList();
        flash(stepId);
      }
    }
  }
  app.runStep = runStep;

  function paintStepOnly(stepId) {
    const r = current();
    const s = r?.stepList.find((x) => x.id === stepId);
    const li = detail.querySelector(`[data-step="${CSS.escape(stepId)}"]`);
    if (!s || !li) return;
    const i = r.stepList.indexOf(s);
    li.outerHTML = stepItem(s, app.running.has(`${r.id}/${s.id}`), i === r.stepList.length - 1, s === nextStep(r)).replace(' reveal"', '"');
    detail.querySelectorAll('[data-next],[data-batch]').forEach((b) => { b.disabled = true; });
  }

  function flash(stepId) {
    const li = detail.querySelector(`[data-step="${CSS.escape(stepId)}"]`);
    if (!li || motionReduced()) return;
    li.classList.add('just-read');
    li.querySelector('.as-step-result')?.firstElementChild?.classList.add('enter');
    setTimeout(() => li.classList.remove('just-read'), 1400);
  }

  async function runBatch() {
    const r = current();
    const steps = batchSteps(r);
    if (steps.length < 2) return;
    const list = steps.map((s) => `${s.title} (${s.subjectLabel.toLowerCase()})`).join(', ');
    const ok = await confirmDialog({
      title: `Lancer ${steps.length} lectures${NBSP}?`,
      message: `${list}. Ces lectures ne demandent pas les droits d’administration du poste${NBSP}; elles partent l’une après l’autre, pour les objets choisis seulement, et aucune n’écrit. Budget${COLON}${plural(steps.length, 'lecture', 'lectures')} au plus. Un refus ou un échec arrête le lot, rien n’est relancé.`,
      confirmLabel: `Lancer ${plural(steps.length, 'lecture', 'lectures')}`, icon: 'play',
    });
    if (!ok) return;
    for (const s of steps) {
      if (app.disposed()) return;
      const read = await runStep(r.id, s.id);
      if (!read) { app.toast('Lot arrêté' + COLON + 'une lecture n’a pas abouti, rien n’est relancé.', { tone: 'warn' }); break; }
    }
  }

  async function openView(step) {
    const dn = app.dnOf(step.subject);
    if (!dn) return;
    const screen = step.view.screen;
    try {
      await import(`../${screen}.js`);
    } catch {
      // A view that does not exist in this version is said as such, never guessed (Domenia 1 Open-DomeniaAssistanceRoute).
      app.toast(`Vue «${NBSP}${step.view.label}${NBSP}» pas encore disponible dans cette version${COLON}le résultat de l’étape reste affiché ici.`, { tone: 'info' });
      return;
    }
    // Fiche opens on its landing tab; Poste and Audit AD take the section as « onglet » (former tabs of Domenia 1 accepted).
    app.ctx.navigate(screen, screen === 'fiche' ? { dn, depuis: 'assistance' } : { dn, onglet: step.view.section, depuis: 'assistance' });
  }

  listHost.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-recipe]') : null;
    if (!b || b.dataset.recipe === app.memory.recipe) return;
    app.memory.recipe = b.dataset.recipe;
    app.keepAddress();
    paintList();
    detail.classList.remove('swap');
    if (!motionReduced()) { void detail.offsetWidth; detail.classList.add('swap'); }
    paintDetail();
  });
  listHost.addEventListener('keydown', (e) => {
    if (!['ArrowDown', 'ArrowUp'].includes(e.key)) return;
    const cards = [...listHost.querySelectorAll('[data-recipe]')];
    const at = cards.indexOf(document.activeElement);
    if (at < 0) return;
    e.preventDefault();
    cards[(at + (e.key === 'ArrowDown' ? 1 : -1) + cards.length) % cards.length].focus();
  });
  detail.addEventListener('click', (e) => {
    const target = e.target instanceof Element ? e.target : null;
    const r = current();
    if (!target || !r) return;
    if (target.closest('[data-next]')) { const n = nextStep(r); if (n) runStep(r.id, n.id); return; }
    if (target.closest('[data-batch]')) { runBatch(); return; }
    const li = target.closest('[data-step]');
    const s = li ? r.stepList.find((x) => x.id === li.dataset.step) : null;
    if (!s) return;
    if (target.closest('[data-run]')) runStep(r.id, s.id);
    else if (target.closest('[data-open]')) openView(s);
  });

  const repaint = () => { paintList(); paintDetail(false); paintStart(); };
  paintList();
  paintDetail();
  paintStart();
  offs.push(app.on('recipes', repaint), app.on('subjects', () => paintStart()));
  return () => { offs.forEach((off) => off()); if (app.runStep === runStep) app.runStep = null; };
}

