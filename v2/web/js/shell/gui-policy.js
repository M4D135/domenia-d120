// Closed mappings of administrator control names; config never supplies CSS selectors or actions.
// Restrictions only: Default/Visible cannot restore a control disabled or hidden by its own business rules.
const SETTINGS = {
  LblStorageMaintenance: '[data-gui="LblStorageMaintenance"]',
  BtnIndexBackup: '[data-act="backup"]', BtnIndexBackupTo: '[data-act="backup-copy"]', BtnIndexCopyPath: '[data-act="copy-path"]', BtnIndexOpenFolder: '[data-act="open-base"]',
  BtnStorageMove: '[data-act="move"]', BtnStorageRestore: '[data-act="restore"], [data-act^="restore:"]', BtnStorageResume: '[data-act="resume"]', BtnStorageRollback: '[data-act="rollback"]',
  BtnStoragePurge: '[data-act="purge-apply"]', BtnStoragePurgePreview: '[data-act="purge-preview"]', BtnStorageRetentionApply: '[data-act="retention-apply"]',
  BtnStorageRetentionPreview: '[data-act="retention-preview"]', BtnStoragePolicySave: '[data-act="retention-save"]', BtnStorageUsage: '[data-act="measure"]', BtnStorageIntegrity: '[data-act="integrity"]',
  ChkStorageAutoBackup: '[data-toggle="schedule-enabled"]', BtnGuardStoreResume: '[data-act="writer-resume"], [data-alert-act="writer-resume"]', BtnGuardLegacyImport: '[data-act="legacy-preview"], [data-act="legacy-apply"]',
  CmbSuiteDensity: '[data-seg="density"]', LstUiProfile: '[data-seg="profile"]', BtnThemeToggle: '[data-setting="theme"]', BtnUiZoomIn: '[data-act="zoom-in"]',
  BtnUiZoomOut: '[data-act="zoom-out"]', BtnUiZoomReset: '[data-act="zoom-reset"]', BtnUxSidebarToggle: '[data-toggle="nav"]', BtnUxHelpToggle: '[data-act="help-open"]',
  BtnRootOuChoose: '[data-act="choose"]', BtnRootOuReset: '[data-act="default"], [data-act="domain"]', TxtCollectionWindow: '[data-window]', BtnCollectionWindowApply: '[data-act="window-save"]',
  CmbCollectionProfile: '[data-setting="profile"] .pr-profile', BtnCollectionFreshnessReset: '[data-act="fresh-reset"]', CmbCollectionConcurrency: '[data-select="budget:concurrency"]',
  CmbCollectionCache: '[data-select="budget:cacheMinutes"]', CmbCollectionWidgetMax: '[data-select="budget:widgetMax"]', CmbCollectionWmiRetries: '[data-select="budget:wmiRetries"]',
  CmbCollectionWmiRetryDelay: '[data-select="budget:wmiRetryDelay"]', ChkUiLogFollow: '[data-toggle="follow"]', ChkUiLogErrorsOnly: '[data-toggle="errors"]',
  ChkSuiteLogWrap: '[data-toggle="wrap"]', CmbSuiteLogSize: '[data-select="size"]',
};
const SHELL = {
  BtnThemeToggle: '.theme-switch button', BtnUxSidebarToggle: '.nav-toggle', BtnUxHelpToggle: '.sh-help-btn',
  BtnUxNavAccount: '.nav-account, .mode-chip, .live, .sh-banner-more', BtnLoginOtherAccount: '.nav-account', LblStatus: '.live',
  BtnGlobalSearch: '.search-trigger', TxtGlobalSearch: '.search-trigger', BtnUxSubjectClear: '.sh-subject-clear',
  LstUiProfile: '.sh-expert-chip', BtnUxHelpGuide: '[data-help-act="guide"]', UxHelpBadge: '.sh-help-dot',
  LogPanel: '.notif',
};
const NATIVE = ['BtnSuiteLoginTheme', 'BtnCopyLoginDiag', 'TxtLogin', 'PwdLogin', 'BtnRevealLogin', 'ChkRemember', 'BtnLoginVaultUse', 'LblLoginError', 'BtnLogin', 'BtnCancel'];
const PAGES = {
  TabFicheRights: '.fi-page [data-tab="droits"]', TabFicheAttributes: '.fi-page [data-tab="attributs"]',
  TabPosteDiagnostic: '.ps-page [data-tab="diagnostic"]', TabPosteProbes: '.ps-page [data-tab="releves"]',
  TabPosteActions: '.ps-page [data-tab="intervenir"]', TabPosteSecrets: '.ps-page [data-tab="secrets"]', TabPosteWmi: '.ps-page [data-tab="wmi"]',
  TabQueryWmi: '.rq-page [data-tab="wmi"]',
  BtnHomeEdit: '.home [data-cmd="edit"], .home [data-fw-menu]', BtnHomeAdd: '.home [data-cmd="catalog"]',
  BtnHomeRefresh: '.home [data-refresh-mode], .home [data-refresh-menu], .home [data-refresh]',
  BtnSearchRun: '.rch .rch-go', BtnSearchVerify: '.rch [data-cmd="verify"], .rch [data-cmd="verifyMenu"]',
  BtnSearchExport: '.rch [data-cmd="export"]', BtnSearchRefresh: '.rch [data-cmd="refresh"]',
  BtnFicheRefresh: '.fi-page [data-cmd="reread"]', BtnPostePresence: '.ps-page [data-cmd="ping"]',
  BtnPosteInventory: '.ps-page [data-cmd="inventory"]', BtnQueryCollect: '.rq-page [data-cmd="collect"]',
  BtnWriteExample: '.wfd .wfd-form button[type="submit"]', BtnSectionScopeFollow: '.pr-page [data-follow-section]',
};
// Closing/physical cancellation must stay reachable regardless of presentation policy.
const CANCELLATION = new Set(['btncancel', 'btncanceltask', 'btnreadfallbackcancel']);
const index = new Map();
for (const [id, selector] of Object.entries(SHELL)) index.set(id.toLowerCase(), selector);
for (const [id, selector] of Object.entries(PAGES)) index.set(id.toLowerCase(), selector);
for (const [id, selector] of Object.entries(SETTINGS)) {
  const scoped = selector.split(',').map(s => `.pr-page ${s.trim()}`).join(',');
  const key = id.toLowerCase(); index.set(key, index.has(key) ? `${index.get(key)},${scoped}` : scoped);
}
export const guiElementNames = Object.freeze([...new Set([...Object.keys(SHELL), ...Object.keys(SETTINGS), ...Object.keys(PAGES), ...NATIVE, 'BtnCancelTask'])]);
const allowedNames = new Set(guiElementNames.map(n => n.toLowerCase()));
const mode = entry => entry?.valid === true && ['Hidden', 'Disabled'].includes(entry.policy) ? entry.policy : null;
export function guiPolicyProblems(entries) {
  return (Array.isArray(entries) ? entries.slice(0, 512) : []).filter(e => !e?.valid || !allowedNames.has(String(e.element).toLowerCase()));
}
function restrictions(entries) {
  return (Array.isArray(entries) ? entries.slice(0, 512) : []).flatMap(e => {
    const key = String(e?.element ?? '').toLowerCase(); const policy = mode(e); const selector = index.get(key);
    return policy && selector && !CANCELLATION.has(key) ? [{ key, selector, policy, reason: e.text || (policy === 'Hidden' ? 'Masqué par l’administrateur.' : 'Grisé par l’administrateur ; droits et lecture seule restent prioritaires.') }] : [];
  });
}
export function applyGuiPolicy(root, entries) {
  for (const { key, selector, policy, reason } of restrictions(entries)) {
    for (const el of root.querySelectorAll(selector)) {
      if (el.matches('[data-gui-cancel]')) continue;
      if (el.dataset.guiPolicy !== policy) el.dataset.guiPolicy = policy;
      if (el.dataset.guiPolicyElement !== key) el.dataset.guiPolicyElement = key;
      if (policy === 'Hidden' && !el.hidden) el.hidden = true;
      if ('disabled' in el && el.disabled !== true) el.disabled = true;
      if (el.getAttribute('aria-disabled') !== 'true') el.setAttribute('aria-disabled', 'true');
      if (el.dataset.tip !== reason) el.dataset.tip = reason;
      if (el.getAttribute('aria-description') !== reason) el.setAttribute('aria-description', reason);
    }
  }
}
const COMMANDS = {
  nav: ['BtnUxSidebarToggle'], 'help-panel': ['BtnUxHelpToggle'], 'help-centre': ['BtnUxHelpToggle'],
  session: ['BtnUxNavAccount', 'BtnLoginOtherAccount'], notifications: ['LogPanel'], journal: ['LogPanel'],
  'expert-once': ['LstUiProfile'], profile: ['LstUiProfile'], tools: ['BtnUxHelpToggle'], 'pick-ou': ['BtnRootOuChoose'], palette: ['BtnGlobalSearch', 'TxtGlobalSearch'],
  'zoom-in': ['BtnUiZoomIn'], 'zoom-out': ['BtnUiZoomOut'], 'zoom-reset': ['BtnUiZoomReset'],
  'fiche-reread': ['BtnFicheRefresh'], 'requetes-collect': ['BtnQueryCollect'],
};
export function guiCommandReason(entries, command) {
  const id = String(typeof command === 'string' ? command : command?.id ?? '').replace(/^screen:/, '');
  const names = id === 'theme' || id.startsWith('theme-') ? ['BtnThemeToggle'] : COMMANDS[id] ?? [];
  const blocked = (Array.isArray(entries) ? entries : []).some(e => mode(e) && names.some(n => n.toLowerCase() === String(e.element).toLowerCase()));
  return blocked ? 'Commande désactivée par l’administrateur (GuiElementPolicy).' : '';
}
export function installGuiPolicy(root, getEntries, report = () => {}) {
  const binding = { root, getEntries }; bindings.add(binding);
  let frame = 0; let closed = false;
  const apply = () => { frame = 0; if (!closed) applyGuiPolicy(root, getEntries()); };
  const observer = new MutationObserver(() => { if (!frame && !closed) frame = requestAnimationFrame(apply); });
  observer.observe(root, { subtree: true, childList: true, attributes: true, attributeFilter: ['disabled', 'hidden', 'aria-disabled'] });
  const guard = event => {
    // Escape and typing/navigation keys must never be swallowed by a presentation restriction.
    if (event.type === 'keydown' && !['Enter', ' ', 'Spacebar'].includes(event.key)) return;
    const target = event.type === 'submit' ? event.submitter ?? event.target?.querySelector('button[type="submit"]') : event.target instanceof Element ? event.target : null;
    if (!target || target.closest('[data-gui-cancel], .sh-strip-cancel, [data-queue-cancel], [data-task-cancel]')) return;
    const denied = restrictions(getEntries()).find(r => { const hit = target.closest(r.selector); return hit && root.contains(hit); });
    if (!denied) return;
    event.preventDefault(); event.stopImmediatePropagation(); report(denied.reason);
  };
  const events = ['click', 'keydown', 'beforeinput', 'change', 'submit'];
  for (const type of events) root.addEventListener(type, guard, true);
  apply();
  return { refresh: apply, dispose() { bindings.delete(binding); closed = true; cancelAnimationFrame(frame); observer.disconnect(); for (const type of events) root.removeEventListener(type, guard, true); } };
}
const bindings = new Set();
// Menus that moved out of their page use the original command button as their policy owner.
export function guiControlRestriction(element) {
  if (!element || element.matches('[data-gui-cancel]')) return null;
  const matches = [...bindings].flatMap(b => b.root.contains(element) ? restrictions(b.getEntries()).filter(r => element.matches(r.selector)) : []);
  return matches.find(r => r.policy === 'Hidden') ?? matches[0] ?? null;
}
