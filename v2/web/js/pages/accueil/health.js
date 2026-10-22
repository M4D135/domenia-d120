// Accueil: « Règles de santé » editor (Domenia 1 points 74 to 77): checks on or off, thresholds, personal alerts and
// dated suspensions, for the whole domain or as an exception of one OU (only its differences are kept). Saved in the
// local preferences (accueil.health.save, LocalWrite); nothing reaches the directory. docs/ops/accueil.md § 7.
// Fields are the kit's (field(), createForm()): same gestures and messages as every screen. Changes not saved are never lost
// silently: « Fermer », Échap, the cross and the backdrop ask first; leaving the screen keeps them as a draft of the window,
// offered at the next opening.
import { openDrawer } from '../../kit/drawer.js';
import { openDialog } from '../../kit/dialog.js';
import { createTabs } from '../../kit/tabs.js';
import { glyph } from '../../kit/glyphs.js';
import { pill } from '../../kit/status.js';
import { openMenu } from '../../kit/menu.js';
import { field, createForm } from '../../kit/form.js';
import { esc, formatNumber } from '../../ui.js';
import { NBSP, plural, paint, reported, surface, localStamp, sk, pathOf, PATH_SEP } from './shared.js';

const camel = (id) => id.charAt(0).toLowerCase() + id.slice(1);
const HOURS_LABEL = { 1: '1 heure', 24: '24 heures', 168: '7 jours', 720: '30 jours' };
const MEASURES = { DiskFree: 'Espace libre sur C: (%)', UptimeDays: 'Jours depuis le démarrage', MemoryUsed: 'Mémoire utilisée (%)' };
const OPERATORS = { LessThan: 'inférieur à', GreaterThan: 'supérieur à' };
const SEVERITY = { Warn: 'À surveiller', Alert: 'Critique' };
const STATE = { on: { label: 'Actif', tone: 'ok' }, disabled: { label: 'Désactivé', tone: 'off' }, suspended: { label: 'Suspendu', tone: 'warn' } };
const DRAFT_KEY = 'domenia.accueil.healthDraft.v1';
// Readable name of a scope: « Postes › Lyon » for an OU (the engine label is a relative DN), « le domaine » otherwise.
const friendly = (v) => (v?.scopeDn ? pathOf(v.scopeDn, null).split(PATH_SEP).slice(1).join(PATH_SEP) || v.scopeLabel : 'le domaine');
// Option of the scope list: the engine wording before the colon, then the readable path of the OU.
const scopeName = (s) => (s.dn && s.name.includes(':') ? `${s.name.slice(0, s.name.indexOf(':')).trim()}${NBSP}: ${friendly({ scopeDn: s.dn, scopeLabel: s.name })}` : s.name);
const loading = () => `<div class="acc-loading" aria-busy="true">${[85, 70, 55, 70, 85].map((w) => sk(`sk-line w${w}`)).join('')}</div>`;

function readDraft() {
  try {
    const d = JSON.parse(sessionStorage.getItem(DRAFT_KEY) ?? 'null');
    return d && typeof d === 'object' && d.policy ? d : null;
  } catch {
    return null;
  }
}

function writeDraft(value) {
  try {
    if (value) sessionStorage.setItem(DRAFT_KEY, JSON.stringify(value)); else sessionStorage.removeItem(DRAFT_KEY);
  } catch (err) {
    console.warn('Brouillon des règles de santé non gardé (stockage de la fenêtre indisponible).', err?.name);
  }
}

/**
 * @param {{ ctx: any, dn?: string|null, onSaved: () => void }} o
 */
export function openHealthRules(o) {
  const { ctx } = o;
  const host = surface('acc-health', loading());
  let view = null;
  let draft = null;
  let dirty = false;
  let tabs = null;
  let selectedTab = 'rules';
  let saved = false;
  const forms = [];

  const drawer = openDrawer({
    title: 'Règles de santé', subtitle: 'Contrôles, seuils, alertes et suspensions ; gardés dans les préférences locales, jamais dans l’annuaire.',
    icon: 'shield', key: 'accueil.health', width: 860, minWidth: 460, body: host,
    actions: [
      { id: 'cancel', label: 'Fermer', run: () => closeSafely() },
      { id: 'save', label: 'Enregistrer', icon: 'check', primary: true, run: () => save() },
    ],
    onClose: () => {
      tabs?.destroy?.();
      forms.splice(0).forEach((f) => f.destroy?.());
      // Closed without asking (screen left): the changes stay as a draft of the window, offered at the next opening.
      if (dirty && view && !saved) writeDraft({ scopeDn: view.scopeDn ?? null, policy: draft, at: new Date().toISOString() });
      window.removeEventListener('hashchange', onLeave, true);
    },
  });
  const saveBtn = () => drawer.foot?.querySelector('[data-id="save"]');

  // Guard of the closing gestures the drawer handles itself: Échap (bubbling, before the panel's own handler), the cross and the
  // backdrop (capture phase on the layer, before its click handler).
  const panel = drawer.el;
  const layer = panel?.parentElement;
  panel?.querySelector('.k-drw-body')?.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || e.defaultPrevented || !dirty) return;
    e.preventDefault();
    closeSafely();
  });
  layer?.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t || !dirty || !(t.classList.contains('k-drw-backdrop') || t.closest('.k-drw-x'))) return;
    e.stopPropagation();
    e.preventDefault();
    closeSafely();
  }, true);
  const onLeave = () => { /* the drawer closes itself on hashchange; onClose keeps the draft */ };
  window.addEventListener('hashchange', onLeave, true);

  async function closeSafely() {
    if (await confirmDiscard()) {
      dirty = false;
      writeDraft(null);
      drawer.close();
    }
  }

  function markDirty(on = true) {
    dirty = on;
    const b = saveBtn();
    if (b) b.disabled = !dirty;
    host.querySelector('.hr-dirty')?.toggleAttribute('hidden', !dirty);
  }

  const clone = (p) => ({
    thresholds: { ...p.thresholds },
    disabledRules: [...p.disabledRules],
    customRules: p.customRules.map((r) => ({ ...r })),
    suspensions: p.suspensions.map((s) => ({ ruleId: s.ruleId, reason: s.reason, untilUtc: s.untilUtc, hours: s.hours, endNow: s.endNow })),
  });

  const activeSuspension = (ruleId) => draft.suspensions.find((s) => s.ruleId === ruleId && !s.endNow && (s.hours || Date.parse(s.untilUtc) > Date.now()));

  function ruleState(id) {
    if (draft.disabledRules.includes(id)) return 'disabled';
    return activeSuspension(id) ? 'suspended' : 'on';
  }

  function suspensionText(s) {
    if (!s) return '';
    if (s.hours) return `Suspendu ${HOURS_LABEL[s.hours] ?? `${s.hours}${NBSP}h`} à l’enregistrement · ${s.reason}`;
    return `Suspendu jusqu’au ${localStamp(s.untilUtc)} · ${s.reason}`;
  }

  // ---------- Panels ----------

  function rulesPanel(panel) {
    const rows = view.rules.map((r, n) => {
      const state = ruleState(r.id);
      const s = activeSuspension(r.id);
      return `<li class="hr-rule" data-rule="${esc(r.id)}" data-state="${state}" data-j="${Math.min(n, 14)}">
        <label class="hr-switch"><input class="switch" type="checkbox" role="switch" data-hr-toggle="${esc(r.id)}"${state !== 'disabled' ? ' checked' : ''} aria-label="${esc(r.name)}"></label>
        <div class="hr-t"><h4>${esc(r.name)}</h4><p>${s ? esc(suspensionText(s)) : esc(r.origin)}${r.fleet ? '' : ' · donnée WMI'}</p></div>
        ${pill(STATE[state].tone, STATE[state].label, { size: 'sm' })}
        <button class="btn ghost sm" type="button" data-hr-suspend="${esc(r.id)}" aria-haspopup="menu"${state === 'disabled' ? ' disabled' : ''}>${glyph(s ? 'play' : 'pause')}${s ? 'Réactiver' : 'Suspendre'}</button></li>`;
    }).join('');
    panel.innerHTML = `<p class="hr-lead">Un contrôle désactivé ne compte plus dans le score ; une suspension a un motif et une échéance, puis le contrôle revient seul. Les postes masqués restent comptés à part.</p><ul class="hr-rules cascade">${rows}</ul>`;
    paint(panel);
  }

  function thresholdsPanel(panel) {
    const origin = (id) => view.origins.find((x) => x.kind === 'Seuil' && x.id === id)?.origin ?? '';
    panel.innerHTML = `<p class="hr-lead">Seuils de cette portée ; une OU sans exception hérite de sa parente puis du domaine.</p><form class="k-form hr-th-form">${view.thresholds.map((t) => field({
      name: camel(t.id), label: t.name, type: 'number', value: draft.thresholds[camel(t.id)], min: t.minimum, max: t.maximum, step: 1, required: true, width: 'half',
      hint: `De ${formatNumber(t.minimum)} à ${formatNumber(t.maximum)} · défaut ${formatNumber(t.default)} · ${origin(t.id)}`,
    })).join('')}<div class="k-form-actions"><button class="btn ghost sm" type="button" data-hr-th-defaults>${glyph('undo')}Valeurs par défaut</button></div></form>`;
    const form = panel.querySelector('form');
    const f = createForm(form, {
      rules: Object.fromEntries(view.thresholds.map((t) => [camel(t.id), (v) => (Number.isInteger(v) ? null : 'Nombre entier attendu.')])),
      onChange: (values) => {
        let changed = false;
        for (const t of view.thresholds) {
          const k = camel(t.id);
          const v = values[k];
          if (Number.isInteger(v) && v >= t.minimum && v <= t.maximum && draft.thresholds[k] !== v) { draft.thresholds[k] = v; changed = true; }
        }
        if (changed) markDirty();
      },
    });
    forms.push(f);
    form.querySelector('[data-hr-th-defaults]').addEventListener('click', () => {
      for (const t of view.thresholds) {
        const input = form.elements.namedItem(camel(t.id));
        if (input instanceof HTMLInputElement) input.value = String(t.default);
        draft.thresholds[camel(t.id)] = t.default;
      }
      f.validate();
      markDirty();
    });
    paint(panel);
  }

  function alertsPanel(panel) {
    const list = draft.customRules;
    panel.innerHTML = `<p class="hr-lead">Alertes personnelles sur les mesures relevées par WMI (${formatNumber(view.maxCustomRules)} au plus). ${view.queryAlertsAvailable ? '' : 'Les alertes sur requête enregistrée arriveront avec l’atelier de requêtes.'}</p>
      ${list.length ? `<ul class="hr-alerts">${list.map((r, n) => `<li data-j="${n}"><label class="hr-switch"><input class="switch" type="checkbox" role="switch" data-hr-alert-on="${n}"${r.enabled ? ' checked' : ''} aria-label="Activer ${esc(r.name)}"></label>
        <div class="hr-t"><h4>${esc(r.name)}</h4><p>${esc(MEASURES[r.measure] ?? r.measure)} ${esc(OPERATORS[r.operator] ?? r.operator)} ${formatNumber(r.threshold)}</p></div>
        ${pill(r.severity === 'Alert' ? 'alert' : 'warn', SEVERITY[r.severity] ?? r.severity, { size: 'sm' })}
        <button class="btn ghost icon sm" type="button" data-hr-alert-drop="${n}" aria-label="Supprimer l’alerte ${esc(r.name)}" data-tip="Supprimer">${glyph('trash')}</button></li>`).join('')}</ul>` : '<p class="faint">Aucune alerte personnelle.</p>'}
      <form class="k-form hr-alert-form"><h4 class="hr-form-title">Nouvelle alerte</h4>
        ${field({ name: 'name', label: 'Nom', required: true, maxLength: 80, placeholder: 'Disque sous 15 %', width: 'full' })}
        ${field({ name: 'measure', label: 'Mesure', type: 'select', value: 'DiskFree', options: Object.entries(MEASURES).map(([value, label]) => ({ value, label })), width: 'third' })}
        ${field({ name: 'operator', label: 'Condition', type: 'select', value: 'LessThan', options: Object.entries(OPERATORS).map(([value, label]) => ({ value, label })), width: 'third' })}
        ${field({ name: 'threshold', label: 'Seuil', type: 'number', value: 15, min: 0, max: 3650, step: 1, required: true, width: 'third' })}
        ${field({ name: 'severity', label: 'Niveau', type: 'radio', value: 'Warn', options: Object.entries(SEVERITY).map(([value, label]) => ({ value, label })) })}
        <div class="k-form-actions"><button class="btn sm primary" type="submit">${glyph('plus')}Ajouter l’alerte</button></div></form>`;
    paint(panel);
    const form = panel.querySelector('form');
    const f = createForm(form, {
      rules: {
        threshold: (v, values) => {
          const max = values.measure === 'UptimeDays' ? 3650 : 100;
          return Number.isFinite(v) && (v < 0 || v > max) ? `De 0 à ${formatNumber(max)} pour cette mesure.` : null;
        },
        name: (v) => (draft.customRules.some((r) => r.name.trim().toLowerCase() === String(v ?? '').trim().toLowerCase()) ? { warn: 'Une alerte porte déjà ce nom.' } : null),
      },
      onSubmit: (values) => {
        if (draft.customRules.length >= view.maxCustomRules) { ctx.toast(`${formatNumber(view.maxCustomRules)} alertes au plus.`, { tone: 'warn' }); return; }
        draft.customRules.push({ name: String(values.name).trim(), measure: values.measure, operator: values.operator, threshold: values.threshold, severity: values.severity || 'Warn', enabled: true });
        markDirty();
        f.destroy?.();
        alertsPanel(panel);
        ctx.toast(`Alerte «${NBSP}${String(values.name).trim()}${NBSP}» ajoutée${NBSP}: enregistrez pour l’appliquer.`, { tone: 'info', life: 2600 });
      },
    });
    forms.push(f);
  }

  function originPanel(panel) {
    panel.innerHTML = `<p class="hr-lead">D’où vient chaque réglage pour ${esc(view.scopeDn ? `l’OU ${friendly(view)}` : 'le domaine')}.</p><div class="acc-scroll"><table class="acc-table hr-origin"><thead><tr><th scope="col">Réglage</th><th scope="col">Valeur</th><th scope="col">Origine</th></tr></thead><tbody>`
      + view.origins.map((x) => `<tr${x.local ? ' class="local"' : ''}><th scope="row"><span class="faint">${esc(x.kind)}</span> ${esc(x.name)}</th><td>${esc(x.value)}</td><td>${x.local ? pill('accent', x.origin, { size: 'sm', dot: false }) : esc(x.origin)}</td></tr>`).join('')
      + '</tbody></table></div>';
  }

  function exceptionsPanel(panel) {
    panel.innerHTML = loading();
    ctx.call('accueil.health.exceptions').then((r) => {
      const rows = r.rows ?? [];
      const missing = rows.filter((x) => x.missing).length;
      // An exception whose OU is no longer known locally (deleted, moved or renamed) is said so (ACC-026): it stays listed so
      // it can be reviewed and removed (« Revenir aux règles héritées »), never presented as an OU that still exists.
      const item = (x, n) => `<li data-j="${n}"${x.missing ? ' class="missing"' : ''}><button class="hr-exc-pick" type="button" data-hr-scope="${esc(x.scopeDn)}"${x.missing ? ` data-tip="${esc(`OU introuvable dans l’index local${NBSP}: supprimée, déplacée ou renommée. L’exception est gardée${NBSP}; ouvrez-la pour la retirer.`)}"` : ''}>${glyph(x.missing ? 'alert' : 'ou')}`
        + `<span><b>${esc(x.label)}</b>${x.missing ? `<span class="k-pill sm warn hr-exc-missing">OU introuvable</span>` : ''}${x.missing ? `<span class="mono hr-exc-dn">${esc(x.scopeDn)}</span>` : ''}<span>${esc(x.changes)}</span></span>`
        + `<span class="num">${plural(x.count, 'réglage', 'réglages')}</span>${glyph('chevronRight', 'chev')}</button></li>`;
      panel.innerHTML = rows.length
        ? `<p class="hr-lead">OU qui s’écartent des règles du domaine (seules leurs différences sont gardées).</p>`
          + (missing ? `<p class="hr-exc-warn">${glyph('alert')}<span>${plural(missing, 'exception porte', 'exceptions portent')} sur une OU introuvable dans l’index local${NBSP}: vérifiez qu’elle n’a pas été renommée, puis retirez l’exception si l’OU n’existe plus.</span></p>` : '')
          + `<ul class="hr-exc">${rows.map(item).join('')}</ul>`
        : `<div class="acc-empty">${glyph('check')}<p>Aucune exception${NBSP}: toutes les OU suivent les règles du domaine.</p></div>`;
      paint(panel);
    }).catch((err) => { panel.innerHTML = `<div class="acc-err">${glyph('alert')}<span>${esc(reported(err))}</span></div>`; });
  }

  // ---------- Frame ----------

  function paintAll() {
    const scopes = view.scopes ?? [];
    forms.splice(0).forEach((f) => f.destroy?.());
    host.innerHTML = `<div class="hr-scope">
        <form class="k-form hr-scope-form">${field({ name: 'scope', label: 'Portée', type: 'select', value: view.scopeDn ?? '', options: scopes.map((s) => ({ value: s.dn ?? '', label: scopeName(s) })) })}</form>
        <p class="hr-scope-note">${view.scopeDn ? (view.local ? `${glyph('edit')}<span>Exception de l’OU ${esc(friendly(view))}${NBSP}: seules ses différences sont gardées.</span>` : `${glyph('info')}<span>L’OU ${esc(friendly(view))} hérite ; enregistrer crée une exception pour elle.</span>`) : `${glyph('domain')}<span>Règles de tout le domaine, héritées par les OU sans exception.</span>`}</p>
        ${view.scopeDn && view.local ? `<button class="btn ghost sm" type="button" data-hr-revert>${glyph('undo')}Revenir aux règles héritées</button>` : ''}
        <span class="hr-dirty k-pill sm warn" hidden><span class="k-pill-dot pulse" aria-hidden="true"></span>Modifications non enregistrées</span>
      </div><div class="hr-draft" hidden></div><div class="hr-tabs"></div>`;
    tabs?.destroy?.();
    const disabled = draft.disabledRules.length;
    const suspended = view.rules.filter((r) => activeSuspension(r.id)).length;
    tabs = createTabs(host.querySelector('.hr-tabs'), {
      label: 'Règles de santé', selected: selectedTab,
      onChange: (id) => { selectedTab = id; },
      tabs: [
        { id: 'rules', label: 'Contrôles', icon: 'check', count: view.rules.length - disabled, tone: suspended ? 'warn' : 'ok', render: rulesPanel },
        { id: 'thresholds', label: 'Seuils', icon: 'sliders', render: thresholdsPanel },
        { id: 'alerts', label: 'Mes alertes', icon: 'bell', count: draft.customRules.length, render: alertsPanel },
        { id: 'origin', label: 'Origine', icon: 'layers', render: originPanel },
        { id: 'exceptions', label: 'Exceptions', icon: 'ou', render: exceptionsPanel },
      ],
    });
    paint(host);
    markDirty(dirty);
    offerDraft();
  }

  // A draft kept when the screen was left with changes not saved: offered for the same scope, never applied by itself.
  function offerDraft() {
    const d = readDraft();
    const slot = host.querySelector('.hr-draft');
    if (!slot || !d || (d.scopeDn ?? null) !== (view.scopeDn ?? null) || dirty) return;
    slot.hidden = false;
    slot.innerHTML = `${glyph('history')}<span>Modifications non enregistrées du ${esc(localStamp(d.at))} pour cette portée.</span>`
      + `<button class="btn sm" type="button" data-hr-draft="use">${glyph('undo')}Reprendre</button><button class="btn ghost sm" type="button" data-hr-draft="drop">Abandonner</button>`;
  }

  async function load(dn) {
    host.innerHTML = loading();
    try {
      view = await ctx.call('accueil.health.policy', dn ? { dn } : {});
      draft = clone(view.policy);
      dirty = false;
      paintAll();
    } catch (err) {
      host.innerHTML = `<div class="acc-err" role="alert">${glyph('alert')}<span>${esc(reported(err))}</span><button class="btn sm" type="button" data-hr-retry>${glyph('refresh')}Réessayer</button></div>`;
    }
  }

  async function save() {
    if (!view || !dirty) return;
    drawer.setBusy(true);
    try {
      const policy = {
        thresholds: draft.thresholds,
        disabledRules: draft.disabledRules,
        customRules: draft.customRules.map((r) => (r.id ? r : { name: r.name, measure: r.measure, operator: r.operator, threshold: r.threshold, severity: r.severity, enabled: r.enabled })),
        suspensions: draft.suspensions,
      };
      view = await ctx.call('accueil.health.save', { ...(view.scopeDn ? { dn: view.scopeDn } : {}), policy });
      draft = clone(view.policy);
      dirty = false;
      saved = true;
      writeDraft(null);
      paintAll();
      saved = false;
      ctx.toast(`Règles de santé enregistrées pour ${view.scopeDn ? `l’OU ${friendly(view)}` : 'le domaine'}. Le tableau du parc est recalculé.`, { tone: 'ok' });
      o.onSaved();
    } catch (err) {
      ctx.toast(reported(err), { tone: 'alert' });
    } finally {
      drawer.setBusy(false);
    }
  }

  async function confirmDiscard() {
    if (!dirty) return true;
    const d = openDialog({
      title: 'Abandonner les modifications ?', icon: 'alert', size: 'sm',
      body: '<p class="k-dlg-text">Les réglages changés pour cette portée ne sont pas enregistrés.</p>',
      actions: [{ id: 'cancel', label: 'Rester', safe: true }, { id: 'ok', label: 'Abandonner', danger: true }],
    });
    return (await d.result) === 'ok';
  }

  async function askReason(ruleName, hours) {
    const form = document.createElement('form');
    form.dataset.page = 'accueil';
    form.className = 'acc-surface k-form hr-reason';
    form.innerHTML = field({
      name: 'reason', label: 'Motif', required: true, minLength: 3, maxLength: 240, placeholder: 'Campagne de remplacement des disques',
      hint: `«${NBSP}${ruleName}${NBSP}» sera suspendu ${HOURS_LABEL[hours] ?? `${hours}${NBSP}h`} à partir de l’enregistrement, puis reviendra seul.`,
    });
    let reason = null;
    const d = openDialog({ title: 'Suspendre le contrôle', icon: 'pause', size: 'sm', body: form, actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'ok', label: 'Suspendre', primary: true }] });
    const f = createForm(form, { onSubmit: (values) => { reason = String(values.reason).trim(); d.close('ok'); } });
    form.querySelector('input')?.focus();
    const r = await d.result;
    if (r === 'ok' && reason === null) {
      // « Suspendre » of the footer: the same checks as a submit; an invalid reason keeps nothing.
      if (f.validate()) reason = String(f.values().reason).trim();
    }
    f.destroy?.();
    if (r === 'ok' && !(reason && reason.length >= 3)) {
      ctx.toast(`Motif obligatoire${NBSP}: 3 à 240 caractères. Rien n’a été suspendu.`, { tone: 'warn' });
      return null;
    }
    return r === 'ok' ? reason : null;
  }

  // ---------- Events ----------

  host.addEventListener('change', async (e) => {
    const t = e.target;
    if (!(t instanceof HTMLElement)) return;
    if (t.matches('.hr-scope-form select')) {
      const value = /** @type {HTMLSelectElement} */ (t).value;
      if (!(await confirmDiscard())) { /** @type {HTMLSelectElement} */ (t).value = view.scopeDn ?? ''; return; }
      dirty = false;
      load(value || null);
      return;
    }
    if (t.matches('[data-hr-toggle]')) {
      const id = t.dataset.hrToggle;
      const on = /** @type {HTMLInputElement} */ (t).checked;
      draft.disabledRules = on ? draft.disabledRules.filter((x) => x !== id) : [...new Set([...draft.disabledRules, id])];
      markDirty();
      const li = t.closest('[data-rule]');
      const panel = li?.closest('.k-tabpanel');
      if (panel) rulesPanel(panel);
      panel?.querySelector(`[data-hr-toggle="${CSS.escape(id)}"]`)?.focus();
      return;
    }
    if (t.matches('[data-hr-alert-on]')) {
      const r = draft.customRules[Number(t.dataset.hrAlertOn)];
      if (r) { r.enabled = /** @type {HTMLInputElement} */ (t).checked; markDirty(); }
    }
  });

  host.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    if (t.closest('[data-hr-retry]')) { load(o.dn ?? null); return; }
    const use = t.closest('[data-hr-draft]');
    if (use) {
      const d = readDraft();
      writeDraft(null);
      if (use.dataset.hrDraft === 'use' && d?.policy) {
        draft = clone({ ...view.policy, ...d.policy, suspensions: d.policy.suspensions ?? [] });
        dirty = true;
        paintAll();
        ctx.toast('Brouillon repris : relisez puis enregistrez.', { tone: 'info', life: 2600 });
      } else {
        host.querySelector('.hr-draft')?.setAttribute('hidden', '');
      }
      return;
    }
    if (t.closest('[data-hr-revert]')) {
      try {
        view = await ctx.call('accueil.health.revert', { dn: view.scopeDn });
        draft = clone(view.policy);
        dirty = false;
        paintAll();
        ctx.toast(`L’OU ${friendly(view)} suit de nouveau les règles héritées.`, { tone: 'ok' });
        o.onSaved();
      } catch (err) {
        ctx.toast(reported(err), { tone: 'alert' });
      }
      return;
    }
    const scope = t.closest('[data-hr-scope]');
    if (scope) {
      if (!(await confirmDiscard())) return;
      dirty = false;
      selectedTab = 'rules';
      load(scope.dataset.hrScope || null);
      return;
    }
    const drop = t.closest('[data-hr-alert-drop]');
    if (drop) {
      draft.customRules.splice(Number(drop.dataset.hrAlertDrop), 1);
      markDirty();
      const panel = drop.closest('.k-tabpanel');
      if (panel) alertsPanel(panel);
      return;
    }
    const suspend = t.closest('[data-hr-suspend]');
    if (suspend && !suspend.disabled) {
      const id = suspend.dataset.hrSuspend;
      const rule = view.rules.find((r) => r.id === id);
      const panel = suspend.closest('.k-tabpanel');
      const current = activeSuspension(id);
      if (current) {
        if (current.hours) draft.suspensions = draft.suspensions.filter((s) => s !== current);
        else current.endNow = true;
        markDirty();
        if (panel) rulesPanel(panel);
        return;
      }
      openMenu(suspend, [
        { heading: 'Suspendre pendant' },
        ...view.suspensionHours.map((h) => ({
          label: HOURS_LABEL[h] ?? `${h}${NBSP}h`, icon: 'clock',
          run: async () => {
            const reason = await askReason(rule?.name ?? id, h);
            if (!reason) return;
            draft.suspensions = draft.suspensions.filter((s) => !(s.ruleId === id && s.hours));
            draft.suspensions.push({ ruleId: id, reason, hours: h });
            markDirty();
            if (panel?.isConnected) rulesPanel(panel);
          },
        })),
      ], { label: `Suspendre ${rule?.name ?? ''}` });
    }
  });

  markDirty(false);
  load(o.dn ?? null);
  return drawer;
}
