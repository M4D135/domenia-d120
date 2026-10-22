// Paramètres › Préférences (PAR-050, PAR-051 and their improvements): the preferences document of the mode with its keys by
// screen, export (text to copy: approved keys and the interface, never the connection identity), import previewed then
// applied with its fingerprint, and reset by group. Nothing here touches the directory, the receipts or the journal.
import {
  esc, glyph, card, facts, notes, sectionHead, button, paint, skeleton, errorBlock, reported, pill, int, count, size, when, meter, NBSP, COLON, setOff, isOff,
} from './common.js';
import { reveal, copyText } from '../../ui.js';
import { confirmDialog } from '../../kit/dialog.js';

const HEAD = { title: 'Préférences', lead: 'Ce que Domenia mémorise sur ce poste, écran par écran : exportez-le, importez-le sur un autre poste, ou revenez aux réglages d’origine par groupe.', icon: 'sliders', tone: 'accent' };
const STATES = {
  read: ['ok', 'Lu', 'check'], absent: ['off', 'Pas encore créé', 'info'], memory: ['accent', 'En mémoire', 'sparkles'],
  locked: ['warn', 'Verrouillé', 'lock'], unreadable: ['alert', 'Illisible', 'alert'], unknownFormat: ['alert', 'Format inconnu', 'alert'], tooLarge: ['alert', 'Trop volumineux', 'alert'],
};
const UI_DEFAULTS = { zoom: 100, density: 'confort', profile: 'essentiel', helpVisible: false, logWrap: false, logSize: 11 };
const PREF_KEY = 'domenia.prefs.v1';
const UI_KEY = 'domenia.ui.v1';

function readJson(key) {
  try { return JSON.parse(localStorage.getItem(key) ?? '{}') ?? {}; } catch { return {}; }
}

/** The interface part of an export: theme, animations, menu (shell) and the preferences of Paramètres (zoom, density…). */
function interfacePart() {
  const p = readJson(PREF_KEY);
  const ui = readJson(UI_KEY);
  const out = {};
  for (const k of ['theme', 'motion', 'navCollapsed']) if (k in p) out[k] = p[k];
  for (const k of Object.keys(UI_DEFAULTS)) if (k in ui) out[k] = ui[k];
  return out;
}

function describeInterface(ui) {
  const parts = [];
  const themes = { light: 'thème clair', dark: 'thème sombre', contrast: 'contraste élevé', system: 'thème de Windows' };
  if (ui.theme) parts.push(themes[ui.theme] ?? ui.theme);
  if (ui.motion) parts.push(ui.motion === 'reduced' ? 'animations réduites' : ui.motion === 'system' ? 'animations de Windows' : 'animations riches');
  if (Number.isInteger(ui.zoom)) parts.push(`zoom ${ui.zoom}${NBSP}%`);
  if (ui.density) parts.push(`densité ${ui.density}`);
  if (ui.profile) parts.push(`profil ${ui.profile === 'expert' ? 'Expert' : 'Essentiel'}`);
  if (typeof ui.navCollapsed === 'boolean') parts.push(ui.navCollapsed ? 'menu replié' : 'menu déplié');
  return parts.join(', ');
}

function applyInterface(sctx, ui) {
  const shell = sctx.shell;
  const known = ['light', 'dark', 'contrast', 'system'];
  if (shell) {
    if (known.includes(ui.theme)) shell.setTheme(ui.theme);
    if (['full', 'reduced', 'system'].includes(ui.motion)) shell.setMotion(ui.motion);
    if (typeof ui.navCollapsed === 'boolean') shell.setCollapsed(ui.navCollapsed);
    const patch = {};
    for (const k of Object.keys(UI_DEFAULTS)) if (k in ui) patch[k] = ui[k];
    shell.setUi(patch);
  } else {
    try {
      localStorage.setItem(PREF_KEY, JSON.stringify({ ...readJson(PREF_KEY), theme: ui.theme, motion: ui.motion, navCollapsed: ui.navCollapsed }));
      localStorage.setItem(UI_KEY, JSON.stringify({ ...readJson(UI_KEY), ...ui }));
    } catch { /* session only */ }
  }
  sctx.refreshAppearanceTile();
}

function documentCard(v) {
  const [toneName, label, iconName] = STATES[v.state] ?? STATES.read;
  const max = Math.max(1, ...v.owners.map((o) => o.keys));
  const owners = v.owners.length
    ? `<ul class="pr-owners">${v.owners.map((o, n) => `<li data-j="${n}"><details><summary><b>${esc(o.label)}</b><span class="pr-owner-n">${count(o.keys, 'clé', 'clés')}</span>${meter((o.keys / max) * 100, `${o.label} : ${o.keys} clés`)}<span class="pr-sub">${esc(size(o.bytes))}</span></summary>
        <ul class="pr-keys-list">${o.names.map((k) => `<li class="mono">${esc(k)}</li>`).join('')}</ul></details></li>`).join('')}</ul>`
    : '<p class="pr-sub">Aucune préférence mémorisée pour l’instant : tout est à sa valeur d’origine.</p>';
  return card({
    id: 'document', title: 'Document des préférences', sub: v.persistent ? 'Écrit atomiquement, partagé entre les fenêtres de Domenia' : 'Rien n’est écrit sur le disque dans cette session', iconName: 'file',
    actions: v.persistent ? button('open-data', 'Ouvrir le dossier', 'folder', { kind: 'ghost' }) : '',
    body: `<div class="pr-verdict" data-tone="${toneName}"><span class="pr-verdict-ico">${glyph(iconName)}</span><b>${esc(label)}</b><span class="mono">${esc(v.fileLabel)}</span></div>
      ${facts([['Clés', int(v.keys)], ['Taille', v.exists ? size(v.bytes) : '—'], ['Modifié', v.modifiedAt ? when(v.modifiedAt) : '—']])}
      <h4 class="pr-h4">Par écran</h4>${owners}`,
  });
}

function exportCard() {
  return card({
    id: 'export', title: 'Exporter', sub: 'Texte à copier, à importer sur un autre poste', iconName: 'download',
    body: `<p class="pr-text">Les préférences approuvées des écrans et celles de l’interface (thème, animations, zoom, densité). Jamais l’identité de connexion, jamais un secret.</p>
      <div class="pr-actions" data-setting="export">${button('export', 'Exporter les préférences', 'download', { kind: 'primary' })}</div>
      <div class="pr-export" data-slot="export" hidden></div>`,
  });
}

function importCard() {
  return card({
    id: 'import', title: 'Importer', sub: 'Aperçu d’abord, puis application avec son empreinte', iconName: 'edit',
    body: `<label class="pr-import" data-setting="import"><span>Texte d’un export de Domenia</span><textarea class="input mono" rows="6" data-import placeholder="{ &quot;format&quot;: &quot;domenia.preferencesExport&quot;, … }" spellcheck="false"></textarea></label>
      <div class="pr-actions">${button('import-preview', 'Aperçu de l’import', 'eye', { kind: 'primary' })}${button('import-apply', 'Importer', 'check', { disabled: true, reason: 'Faites d’abord l’aperçu de l’import.' })}</div>
      <div class="pr-preview" data-slot="import-preview" hidden></div>`,
  });
}

function resetCard(v) {
  return card({
    id: 'reset', title: 'Réinitialiser', sub: 'Par groupe ; rien d’autre n’est touché', iconName: 'undo', cls: 'pr-wide',
    body: `<div class="pr-resets" data-setting="reset">${v.resetGroups.map((g, n) => `<div class="pr-reset${g.id === 'all' ? ' all' : ''}" data-j="${n}">
        <span class="pr-reset-ico">${glyph(g.id === 'interface' ? 'sparkles' : g.id === 'widgets' ? 'home' : g.id === 'workingScope' ? 'folder' : g.id === 'collection' ? 'wifi' : g.id === 'storage' ? 'database' : g.id === 'connection' ? 'key' : 'undo')}</span>
        <div><b>${esc(g.label)}</b><span>${esc(g.detail)}</span></div>
        ${button(`reset:${g.id}`, 'Réinitialiser…', 'undo', { kind: g.id === 'all' ? 'danger' : '' })}</div>`).join('')}</div>`,
  });
}

function markup(v) {
  return `${sectionHead(HEAD)}<div class="pr-grid">${documentCard(v)}${exportCard()}${importCard()}${resetCard(v)}
    <div class="pr-footnote reveal">${notes(v.rules)}</div></div>`;
}

export function mount(host, sctx, { open } = {}) {
  let view = null;
  let alive = true;
  let preview = null;
  let previewText = '';
  host.innerHTML = `${sectionHead(HEAD)}${skeleton(3)}`;

  async function load() {
    try {
      view = await sctx.call('settings.preferences');
      if (!alive) return;
      host.innerHTML = markup(view);
      paint(host);
      reveal(host);
      if (open === 'import') { open = null; host.querySelector('[data-import]')?.focus({ preventScroll: true }); host.querySelector('[data-card="import"]')?.scrollIntoView({ block: 'center' }); }
      if (open === 'export') { open = null; doExport(); }
    } catch (err) {
      if (!alive) return;
      host.innerHTML = `${sectionHead(HEAD)}${errorBlock(err)}`;
    }
  }

  async function doExport() {
    try {
      const out = await sctx.call('settings.preferences.export');
      const doc = JSON.parse(out.text);
      doc.interface = interfacePart();
      const text = JSON.stringify(doc, null, 2);
      const slot = host.querySelector('[data-slot="export"]');
      if (!slot) return;
      slot.hidden = false;
      slot.innerHTML = `<textarea class="input mono" rows="8" readonly aria-label="Texte de l’export">${esc(text)}</textarea>
        <div class="pr-actions">${button('export-copy', 'Copier le texte', 'copy', { kind: 'primary' })}<span class="pr-sub">${esc(`${count(out.keys, 'clé', 'clés')}, ${size(new TextEncoder().encode(text).length)}`)}${out.excluded.length ? ` · ${esc(count(out.excluded.length, 'clé exclue', 'clés exclues'))} (identité de connexion)` : ''}</span></div>`;
      slot.dataset.text = text;
      paint(slot);
    } catch (err) { sctx.toast(reported(err), { tone: 'alert' }); }
  }

  function showPreview(p, ui) {
    const slot = host.querySelector('[data-slot="import-preview"]');
    if (!slot) return;
    slot.hidden = false;
    if (!p.valid) {
      slot.innerHTML = `<p class="pr-hint warn">${glyph('alert')}<span>${esc(p.problem ?? 'Export illisible.')}</span></p>`;
      paint(slot);
      return;
    }
    const rows = p.changes.map((c, n) => `<tr data-j="${n}"><td class="mono">${esc(c.key)}</td><td>${esc(c.owner)}</td><td>${pill(c.kind === 'add' ? 'info' : 'warn', c.kind === 'add' ? 'Ajout' : 'Remplacement', { size: 'sm' })}</td><td class="mono pr-diff"><s>${esc(c.before ?? '—')}</s><span>${esc(c.after)}</span></td></tr>`).join('');
    slot.innerHTML = `<div class="pr-preview-head">${glyph('eye')}<b>Aperçu de l’import</b>${pill(p.changes.length ? 'warn' : 'ok', p.changes.length ? count(p.changes.length, 'changement', 'changements') : 'Rien ne change', { size: 'sm' })}${p.exportedAt ? `<span class="pr-sub">exporté le ${esc(when(p.exportedAt))}${p.mode ? ` (${esc(p.mode)})` : ''}</span>` : ''}</div>
      ${rows ? `<div class="pr-table-wrap"><table class="pr-table"><thead><tr><th>Clé</th><th>Écran</th><th>Effet</th><th>Avant → après</th></tr></thead><tbody>${rows}</tbody></table></div>` : ''}
      ${p.unchanged ? `<p class="pr-sub">${esc(count(p.unchanged, 'clé déjà identique', 'clés déjà identiques'))}.</p>` : ''}
      ${p.refused.length ? `<p class="pr-hint warn">${glyph('alert')}<span>Refusé${COLON}${esc(p.refused.join(' '))}</span></p>` : ''}
      ${ui ? `<p class="pr-hint">${glyph('sparkles')}<span>Interface${COLON}${esc(describeInterface(ui))}.</span></p>` : ''}`;
    paint(slot);
  }

  async function doPreview(btn) {
    const text = host.querySelector('[data-import]')?.value ?? '';
    btn.disabled = true;
    try {
      preview = await sctx.call('settings.preferences.import.preview', { text });
      previewText = text;
      let ui = null;
      try { ui = preview.hasInterface ? JSON.parse(text).interface : null; } catch { ui = null; }
      showPreview(preview, ui);
      setOff(host.querySelector('[data-act="import-apply"]'), !preview.valid || (!preview.changes.length && !ui), preview.valid ? 'Rien ne change.' : 'Export illisible : rien à importer.');
    } catch (err) { sctx.toast(reported(err), { tone: 'alert' }); } finally { btn.disabled = false; }
  }

  async function doImport(btn) {
    if (!preview?.valid) return;
    btn.disabled = true;
    try {
      let ui = null;
      try { ui = preview.hasInterface ? JSON.parse(previewText).interface : null; } catch { ui = null; }
      const result = preview.changes.length
        ? await sctx.call('settings.preferences.import', { text: previewText, fingerprint: preview.fingerprint })
        : { summary: 'Aucune préférence d’écran à changer.' };
      if (ui && typeof ui === 'object') applyInterface(sctx, ui);
      sctx.toast(`${result.summary}${ui ? ' Interface appliquée.' : ''}`, { tone: 'ok', life: 6000 });
      preview = null;
      await load();
    } catch (err) {
      sctx.toast(reported(err), { tone: err?.code === 'settings.previewStale' ? 'warn' : 'alert' });
      btn.disabled = false;
    }
  }

  async function doReset(group) {
    const g = view?.resetGroups.find((x) => x.id === group);
    if (!g) return;
    const ok = await confirmDialog({
      title: `Réinitialiser : ${g.label.toLowerCase()} ?`,
      message: `${g.detail} Les reçus d’écriture, le journal et la base locale ne sont jamais touchés.`,
      confirmLabel: 'Réinitialiser', danger: group === 'all',
    });
    if (!ok) return;
    try {
      if (group === 'interface' || group === 'all') applyInterface(sctx, { theme: 'system', motion: 'full', navCollapsed: false, ...UI_DEFAULTS });
      if (group !== 'interface') {
        const result = await sctx.call('settings.preferences.reset', { group });
        sctx.toast(result.summary, { tone: result.failed.length ? 'warn' : 'ok', life: 5200 });
      } else {
        sctx.toast('Interface réinitialisée : thème de Windows, animations riches, zoom 100 %, densité confort, profil Essentiel.', { tone: 'ok', life: 5200 });
      }
      await load();
    } catch (err) { sctx.toast(reported(err), { tone: 'alert' }); }
  }

  const onClick = async (e) => {
    const btn = e.target instanceof Element ? e.target.closest('[data-act]') : null;
    if (isOff(btn)) return;
    const act = btn.dataset.act;
    if (act === 'retry') load();
    else if (act === 'export') doExport();
    else if (act === 'export-copy') {
      const text = host.querySelector('[data-slot="export"]')?.dataset.text ?? '';
      const ok = await copyText(text);
      sctx.toast(ok ? 'Export copié dans le presse-papiers.' : 'Copie impossible : presse-papiers indisponible.', { tone: ok ? 'ok' : 'warn' });
    } else if (act === 'import-preview') doPreview(btn);
    else if (act === 'import-apply') doImport(btn);
    else if (act.startsWith('reset:')) doReset(act.slice(6));
    else if (act === 'open-data') {
      try { await sctx.call('settings.folder.open', { folder: 'preferences' }); } catch (err) { sctx.toast(reported(err), { tone: 'info' }); }
    }
  };
  const onInput = (e) => {
    if (e.target instanceof HTMLTextAreaElement && e.target.matches('[data-import]')) {
      if (preview) { setOff(host.querySelector('[data-act="import-apply"]'), true, 'Texte modifié : refaites l’aperçu.'); preview = null; }
    }
  };
  host.addEventListener('click', onClick);
  host.addEventListener('input', onInput);
  load();

  return {
    destroy() {
      alive = false;
      host.removeEventListener('click', onClick);
      host.removeEventListener('input', onInput);
    },
  };
}
