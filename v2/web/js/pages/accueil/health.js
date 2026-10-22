// Accueil: « Règles de santé » editor (Domenia 1 points 74 to 77): checks on or off, thresholds, personal alerts and
// dated suspensions, for the whole domain or as an exception of one OU (only its differences are kept). Saved in the
// local preferences (accueil.health.save, LocalWrite); nothing reaches the directory. docs/ops/accueil.md § 7.
import { openDrawer } from '../../kit/drawer.js';
import { openDialog } from '../../kit/dialog.js';
import { createTabs } from '../../kit/tabs.js';
import { glyph } from '../../kit/glyphs.js';
import { pill } from '../../kit/status.js';
import { openMenu } from '../../kit/menu.js';
import { esc, formatNumber } from '../../ui.js';
import { plural, paint, reported, surface, localStamp, sk, pathOf, PATH_SEP } from './shared.js';

const camel = (id) => id.charAt(0).toLowerCase() + id.slice(1);
const HOURS_LABEL = { 1: '1 heure', 24: '24 heures', 168: '7 jours', 720: '30 jours' };
const MEASURES = { DiskFree: 'Espace libre sur C: (%)', UptimeDays: 'Jours depuis le démarrage', MemoryUsed: 'Mémoire utilisée (%)' };
const OPERATORS = { LessThan: 'inférieur à', GreaterThan: 'supérieur à' };
const SEVERITY = { Warn: 'À surveiller', Alert: 'Critique' };
const STATE = { on: { label: 'Actif', tone: 'ok' }, disabled: { label: 'Désactivé', tone: 'off' }, suspended: { label: 'Suspendu', tone: 'warn' } };
// Readable name of a scope: « Postes › Lyon » for an OU (the engine label is a relative DN), « le domaine » otherwise.
const friendly = (v) => (v?.scopeDn ? pathOf(v.scopeDn, null).split(PATH_SEP).slice(1).join(PATH_SEP) || v.scopeLabel : 'le domaine');
// Option of the scope list: the engine wording before the colon, then the readable path of the OU.
const scopeName = (s) => (s.dn && s.name.includes(':') ? `${s.name.slice(0, s.name.indexOf(':')).trim()}\u00a0: ${friendly({ scopeDn: s.dn, scopeLabel: s.name })}` : s.name);
const loading = () => `<div class="acc-loading" aria-busy="true">${[85, 70, 55, 70, 85].map((w) => sk(`sk-line w${w}`)).join('')}</div>`;

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

  const drawer = openDrawer({
    title: 'Règles de santé', subtitle: 'Contrôles, seuils, alertes et suspensions ; gardés dans les préférences locales, jamais dans l’annuaire.',
    icon: 'shield', key: 'accueil.health', width: 860, minWidth: 460, body: host,
    actions: [
      { id: 'cancel', label: 'Fermer', run: (d) => d.close() },
      { id: 'save', label: 'Enregistrer', icon: 'check', primary: true, run: () => save() },
    ],
    onClose: () => tabs?.destroy?.(),
  });
  const saveBtn = () => drawer.foot?.querySelector('[data-id="save"]');

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
    suspensions: p.suspensions.map((s) => ({ ruleId: s.ruleId, reason: s.reason, untilUtc: s.untilUtc })),
  });

  const activeSuspension = (ruleId) => draft.suspensions.find((s) => s.ruleId === ruleId && !s.endNow && (s.hours || Date.parse(s.untilUtc) > Date.now()));

  function ruleState(id) {
    if (draft.disabledRules.includes(id)) return 'disabled';
    return activeSuspension(id) ? 'suspended' : 'on';
  }

  function suspensionText(s) {
    if (!s) return '';
    if (s.hours) return `Suspendu ${HOURS_LABEL[s.hours] ?? `${s.hours} h`} à l’enregistrement · ${s.reason}`;
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
    panel.innerHTML = `<p class="hr-lead">Un contrôle désactivé ne compte plus dans le score ; une suspension a un motif et une échéance, puis le contrôle revient seul. Les postes masqués restent comptés à part.</p><ul class="hr-rules cascade">${rows}</ul>`;
    paint(panel);
  }

  function thresholdsPanel(panel) {
    const origin = (id) => view.origins.find((x) => x.kind === 'Seuil' && x.id === id)?.origin ?? '';
    panel.innerHTML = `<p class="hr-lead">Seuils de cette portée ; une OU sans exception hérite de sa parente puis du domaine.</p><div class="hr-thresholds">${view.thresholds.map((t, n) => `
      <label class="hr-th" data-j="${n}"><span class="hr-th-name">${esc(t.name)}</span>
        <span class="hr-th-input"><input class="input num" type="number" inputmode="numeric" min="${t.minimum}" max="${t.maximum}" step="1" value="${draft.thresholds[camel(t.id)]}" data-hr-th="${esc(camel(t.id))}">
        <button class="btn ghost icon sm" type="button" data-hr-th-reset="${esc(camel(t.id))}" data-default="${t.default}" aria-label="Valeur par défaut : ${t.default}" data-tip="Défaut : ${t.default}">${glyph('undo')}</button></span>
        <span class="hr-th-note">De ${formatNumber(t.minimum)} à ${formatNumber(t.maximum)} · défaut ${formatNumber(t.default)} · ${esc(origin(t.id))}</span></label>`).join('')}</div>`;
    paint(panel);
  }

  function alertsPanel(panel) {
    const list = draft.customRules;
    panel.innerHTML = `<p class="hr-lead">Alertes personnelles sur les mesures relevées par WMI (32 au plus). ${view.queryAlertsAvailable ? '' : 'Les alertes sur requête enregistrée arriveront avec l’atelier de requêtes.'}</p>
      ${list.length ? `<ul class="hr-alerts">${list.map((r, n) => `<li data-j="${n}"><label class="hr-switch"><input class="switch" type="checkbox" role="switch" data-hr-alert-on="${n}"${r.enabled ? ' checked' : ''} aria-label="Activer ${esc(r.name)}"></label>
        <div class="hr-t"><h4>${esc(r.name)}</h4><p>${esc(MEASURES[r.measure] ?? r.measure)} ${esc(OPERATORS[r.operator] ?? r.operator)} ${formatNumber(r.threshold)}</p></div>
        ${pill(r.severity === 'Alert' ? 'alert' : 'warn', SEVERITY[r.severity] ?? r.severity, { size: 'sm' })}
        <button class="btn ghost icon sm" type="button" data-hr-alert-drop="${n}" aria-label="Supprimer l’alerte ${esc(r.name)}" data-tip="Supprimer">${glyph('trash')}</button></li>`).join('')}</ul>` : '<p class="faint">Aucune alerte personnelle.</p>'}
      <form class="hr-alert-form"><h4>Nouvelle alerte</h4>
        <label><span>Nom</span><input class="input" name="name" type="text" maxlength="80" required placeholder="Disque sous 15 %"></label>
        <label><span>Mesure</span><select class="input acc-select" name="measure">${Object.entries(MEASURES).map(([k, v]) => `<option value="${k}">${esc(v)}</option>`).join('')}</select></label>
        <label><span>Condition</span><select class="input acc-select" name="operator">${Object.entries(OPERATORS).map(([k, v]) => `<option value="${k}">${esc(v)}</option>`).join('')}</select></label>
        <label><span>Seuil</span><input class="input num" name="threshold" type="number" step="1" min="0" max="3650" value="15" required></label>
        <label><span>Niveau</span><select class="input acc-select" name="severity">${Object.entries(SEVERITY).map(([k, v]) => `<option value="${k}">${esc(v)}</option>`).join('')}</select></label>
        <button class="btn sm" type="submit">${glyph('plus')}Ajouter l’alerte</button></form>`;
    paint(panel);
    panel.querySelector('form').addEventListener('submit', (e) => {
      e.preventDefault();
      const f = e.currentTarget;
      if (draft.customRules.length >= view.maxCustomRules) { ctx.toast(`${formatNumber(view.maxCustomRules)} alertes au plus.`, { tone: 'warn' }); return; }
      const threshold = Number(f.threshold.value);
      const max = f.measure.value === 'UptimeDays' ? 3650 : 100;
      if (!f.name.value.trim() || !Number.isFinite(threshold) || threshold < 0 || threshold > max) {
        ctx.toast(`Alerte incomplète : nom et seuil de 0 à ${formatNumber(max)}.`, { tone: 'warn' });
        return;
      }
      draft.customRules.push({ name: f.name.value.trim(), measure: f.measure.value, operator: f.operator.value, threshold, severity: f.severity.value, enabled: true });
      markDirty();
      alertsPanel(panel);
    });
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
      panel.innerHTML = rows.length
        ? `<p class="hr-lead">OU qui s’écartent des règles du domaine (seules leurs différences sont gardées).</p><ul class="hr-exc">${rows.map((x, n) => `<li data-j="${n}"><button class="hr-exc-pick" type="button" data-hr-scope="${esc(x.scopeDn)}">${glyph('ou')}<span><b>${esc(x.label)}</b><span>${esc(x.changes)}</span></span><span class="num">${plural(x.count, 'réglage', 'réglages')}</span>${glyph('chevronRight', 'chev')}</button></li>`).join('')}</ul>`
        : `<div class="acc-empty">${glyph('check')}<p>Aucune exception : toutes les OU suivent les règles du domaine.</p></div>`;
      paint(panel);
    }).catch((err) => { panel.innerHTML = `<div class="acc-err">${glyph('alert')}<span>${esc(reported(err))}</span></div>`; });
  }

  // ---------- Frame ----------

  function paintAll() {
    const scopes = view.scopes ?? [];
    host.innerHTML = `<div class="hr-scope">
        <label><span>Portée</span><select class="input acc-select" data-hr-scope-select>${scopes.map((s) => `<option value="${esc(s.dn ?? '')}"${(s.dn ?? null) === (view.scopeDn ?? null) ? ' selected' : ''}>${esc(scopeName(s))}</option>`).join('')}</select></label>
        <p class="hr-scope-note">${view.scopeDn ? (view.local ? `${glyph('edit')}<span>Exception de l’OU ${esc(friendly(view))} : seules ses différences sont gardées.</span>` : `${glyph('info')}<span>L’OU ${esc(friendly(view))} hérite ; enregistrer crée une exception pour elle.</span>`) : `${glyph('domain')}<span>Règles de tout le domaine, héritées par les OU sans exception.</span>`}</p>
        ${view.scopeDn && view.local ? `<button class="btn ghost sm" type="button" data-hr-revert>${glyph('undo')}Revenir aux règles héritées</button>` : ''}
        <span class="hr-dirty k-pill sm warn" hidden><span class="k-pill-dot pulse" aria-hidden="true"></span>Modifications non enregistrées</span>
      </div><div class="hr-tabs"></div>`;
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
      paintAll();
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
      title: 'Abandonner les modifications ?', icon: 'alert', size: 'sm',
      body: '<p class="k-dlg-text">Les réglages changés pour cette portée ne sont pas enregistrés.</p>',
      actions: [{ id: 'cancel', label: 'Rester', safe: true }, { id: 'ok', label: 'Abandonner', danger: true }],
    });
    return (await d.result) === 'ok';
  }

  async function askReason(ruleName, hours) {
    const form = document.createElement('form');
    form.dataset.page = 'accueil';
    form.className = 'acc-surface hr-reason';
    form.innerHTML = `<label class="fw-field"><span>Motif (3 à 240 caractères)</span><input class="input" type="text" minlength="3" maxlength="240" required placeholder="Campagne de remplacement des disques" autocomplete="off"></label>
      <p class="fw-field-note">« ${esc(ruleName)} » sera suspendu ${esc(HOURS_LABEL[hours] ?? `${hours} h`)} à partir de l’enregistrement, puis reviendra seul.</p>`;
    const d = openDialog({ title: 'Suspendre le contrôle', icon: 'pause', size: 'sm', body: form, actions: [{ id: 'cancel', label: 'Annuler' }, { id: 'ok', label: 'Suspendre', primary: true }] });
    form.addEventListener('submit', (e) => { e.preventDefault(); d.close('ok'); });
    const r = await d.result;
    const text = form.querySelector('input').value.trim();
    if (r !== 'ok') return null;
    if (text.length < 3) { ctx.toast('Motif trop court : 3 caractères au moins.', { tone: 'warn' }); return null; }
    return text;
  }

  // ---------- Events ----------

  host.addEventListener('change', async (e) => {
    const t = e.target;
    if (!(t instanceof HTMLElement)) return;
    if (t.matches('[data-hr-scope-select]')) {
      const value = /** @type {HTMLSelectElement} */ (t).value;
      if (!(await confirmDiscard())) { t.value = view.scopeDn ?? ''; return; }
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
    if (t.matches('[data-hr-th]')) {
      const input = /** @type {HTMLInputElement} */ (t);
      const n = Number(input.value);
      const def = view.thresholds.find((x) => camel(x.id) === input.dataset.hrTh);
      if (!def || !Number.isInteger(n) || n < def.minimum || n > def.maximum) {
        input.classList.add('invalid');
        ctx.toast(`${def?.name ?? 'Seuil'} : valeur attendue de ${def?.minimum} à ${def?.maximum}.`, { tone: 'warn' });
        return;
      }
      input.classList.remove('invalid');
      draft.thresholds[input.dataset.hrTh] = n;
      markDirty();
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
      selectedTab = 'rules';
      load(scope.dataset.hrScope || null);
      return;
    }
    const reset = t.closest('[data-hr-th-reset]');
    if (reset) {
      const input = host.querySelector(`[data-hr-th="${CSS.escape(reset.dataset.hrThReset)}"]`);
      if (input) { input.value = reset.dataset.default; input.dispatchEvent(new Event('change', { bubbles: true })); }
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
          label: HOURS_LABEL[h] ?? `${h} h`, icon: 'clock',
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

