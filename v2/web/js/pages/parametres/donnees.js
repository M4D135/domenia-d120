// Paramètres › Données et cache (PAR-010 to PAR-036): the local base of Domenia — overview and reliability, backups with
// the annex of their preferences and their schedule, retention and purge with their previews, diagnostic (measure,
// integrity, limits), maintenance assistant (move, restore, resume, roll back), data policy and cache catalogue, takeover of
// the Domenia 1 data. Every change of the base is a write of the circuit (plan, confirmation, receipt written before,
// re-read after; docs/WRITES.md); the policy and the schedule are local preferences. In simulation the base is fictitious,
// in memory: nothing is written on the disk; in directory mode of this version it is not wired yet (Domenia.Store).
import {
  esc, glyph, icon, card, row, facts, notes, sectionHead, toggle, select, button, paint, skeleton, errorBlock, emptyState,
  reported, pill, int, count, size, when, rel, meter, NBSP, COLON, tone, setOff, isOff, quote,
} from './common.js';
import { reveal, countUp, donut, copyText } from '../../ui.js';
import { createTabs } from '../../kit/tabs.js';
import { runWrite } from '../../write-flow.js';
import { chooseDestination, chooseRestore } from './pickers.js';

const TABS = [
  { id: 'apercu', label: 'Vue d’ensemble', icon: 'activity' },
  { id: 'sauvegardes', label: 'Sauvegardes', icon: 'shield' },
  { id: 'conservation', label: 'Conservation', icon: 'history' },
  { id: 'diagnostic', label: 'Diagnostic', icon: 'gauge' },
  { id: 'assistant', label: 'Assistant', icon: 'layers' },
  { id: 'politique', label: 'Politique', icon: 'lock' },
  { id: 'reprise', label: 'Reprise', icon: 'download' },
];
const HOURS = [1, 2, 4, 6, 12, 24, 48, 72, 168, 336, 720];
const KEEP = [2, 3, 5, 7, 10, 14, 20, 30];
const HEAD = { title: 'Données et cache', lead: 'La base locale de Domenia : ce qu’elle garde, ses sauvegardes, combien de temps les mesures restent, et comment la contrôler. Rien n’en sort.', icon: 'database', tone: 'ok' };
const ACTIONS = { import: ['info', 'Reprise'], add: ['ok', 'Ajout'], keep: ['off', 'Conservé'], ignore: ['off', 'Ignoré'], refuse: ['alert', 'Refusé'] };
const PATHLIKE = /^(%[A-Z_]+%|[A-Za-z]:\\|\\\\)/;

// ---------- Small pieces ----------

const simNote = (v) => (v.simulated
  ? `<p class="pr-hint accent">${glyph('sparkles')}<span>Simulation${COLON}base fictive en mémoire. Sauvegardes, conservation, purge et bascules s’y jouent pour de vrai, avec plan, reçu et relecture, mais aucun fichier n’est écrit. Les scénarios de démonstration (section Démonstration) montrent les pannes.</span></p>` : '');

function tiles(v) {
  return `<div class="pr-tiles">${v.tiles.map((t, n) => `<div class="pr-tile" data-tone="${esc(tone(t.tone))}" data-i="${n}">
    <span class="pr-tile-k">${esc(t.label)}</span><b class="pr-tile-v" data-count="${esc(t.value)}">${esc(t.value)}</b><span class="pr-tile-s">${esc(t.sub)}</span></div>`).join('')}</div>`;
}

function annexPill(b) {
  return b.preferencesBound
    ? pill('ok', count(b.preferenceKeys, 'clé jointe', 'clés jointes'), { size: 'sm', icon: 'sliders', tip: 'Annexe Domenia.BackupPreferences.1 liée au SHA-256 de cette copie' })
    : pill('off', 'Sans annexe', { size: 'sm', tip: 'Copie faite hors de l’interface (migration) : données seules' });
}

function backupTable(v) {
  if (!v.backups.length) return emptyState('shield', 'Aucune sauvegarde', 'Faites une première sauvegarde vérifiée : elle devient le point de retour de la base.');
  const rows = v.backups.slice(0, 50).map((b, n) => {
    const tip = `${b.content}${b.lastMeasureAt ? ` · dernière mesure ${when(b.lastMeasureAt)}` : ''}`;
    return `<tr data-j="${n}"${n === 0 ? ' class="pr-newest"' : ''}>
      <td><span class="pr-file" data-tip="${esc(tip)}">${glyph('database')}<span class="pr-file-text"><b class="mono">${esc(b.fileName)}</b><span class="pr-file-meta">${pill(b.inRotation ? 'info' : 'accent', b.kindLabel, { size: 'sm' })}<span class="pr-sub">lot ${int(b.revision)}</span></span></span></span></td>
      <td><span data-tip="${esc(when(b.at))}">${rel(b.at)}</span></td>
      <td class="num">${esc(b.bytesText)}</td>
      <td>${b.verified ? pill('ok', 'Vérifiée', { size: 'sm', icon: 'check', tip: `quick_check, SHA-256 ${b.sha256Short}` }) : pill('warn', 'Non vérifiée', { size: 'sm', icon: 'alert' })}
        <span class="mono pr-sha pr-expert-only" data-tip="Empreinte SHA-256 du fichier produit">${esc(b.sha256Short)}</span></td>
      <td>${annexPill(b)}</td>
      <td class="pr-cell-act">${button(`restore:${b.id}`, 'Restaurer…', 'undo', { kind: 'ghost', write: true, disabled: !b.verified || !v.maintenance?.restore, reason: !b.verified ? 'Sauvegarde non vérifiée.' : (v.maintenance?.restoreReason ?? '') })}</td>
    </tr>`;
  }).join('');
  return `<div class="pr-table-wrap"><table class="pr-table pr-backup-table"><colgroup><col class="c-file"><col class="c-when"><col class="c-size"><col class="c-proof"><col class="c-annex"><col class="c-act"></colgroup>
    <thead><tr><th>Fichier</th><th>Écrite</th><th class="num">Taille</th><th>Preuve</th><th>Préférences</th><th><span class="visually-hidden">Actions</span></th></tr></thead><tbody>${rows}</tbody></table></div>`;
}

/** Latest backups as a compact list (card of the overview). */
function backupList(v) {
  if (!v.backups.length) return emptyState('shield', 'Aucune sauvegarde', 'Faites une première sauvegarde vérifiée : elle devient le point de retour de la base.');
  return `<ul class="pr-backups">${v.backups.slice(0, 4).map((b, n) => `<li data-j="${n}">
      <span class="pr-backup-ico" data-tone="${b.verified ? 'ok' : 'warn'}">${glyph(b.verified ? 'check' : 'alert')}</span>
      <div><b class="mono" data-tip="${esc(b.fileName)}">${esc(b.fileName)}</b><span class="pr-sub">${esc(b.kindLabel)} · <span data-tip="${esc(when(b.at))}">${rel(b.at)}</span> · ${esc(b.bytesText)}</span></div>
      ${pill(b.verified ? 'ok' : 'warn', b.verified ? 'Vérifiée' : 'Non vérifiée', { size: 'sm' })}</li>`).join('')}</ul>`;
}

// ---------- Tabs ----------

function overview(v) {
  const loc = v.location;
  const noFile = v.simulated || !loc.path;
  const location = card({
    id: 'location', title: 'Emplacement de la base', sub: v.simulated ? 'Base fictive de la simulation' : 'Fichier SQLite de ce domaine', iconName: 'folder', cls: 'pr-wide',
    body: `<div class="pr-location"><span class="pr-location-art" aria-hidden="true">${glyph('database')}</span>
        <div class="pr-location-text"><b>${esc(loc.text)}</b><span class="mono pr-path" data-tip="${esc(loc.pathLabel)}">${esc(loc.pathLabel)}</span></div>
        <div class="pr-location-actions">${button('copy-path', 'Copier le chemin', 'copy', { disabled: !loc.path, reason: loc.path ? '' : 'Aucune base active : aucun chemin à copier.' })}
          ${button('open-base', 'Ouvrir l’emplacement', 'external', { disabled: noFile, reason: v.simulated ? 'Base de démonstration : aucun fichier sur le disque à montrer.' : 'Aucune base locale pour ce domaine : rien à montrer.' })}</div></div>
      ${loc.alert ? `<p class="pr-hint warn">${glyph('alert')}<span>${esc(loc.alertText)}</span></p>` : ''}${simNote(v)}`,
  });
  const writer = v.writer;
  const space = v.space;
  const reliability = card({
    id: 'reliability', title: 'Fiabilité', sub: 'Enregistrement local, espace disque et maintenance', iconName: 'shield',
    body: `<div class="pr-status-list">
        <div class="pr-status" data-setting="writer"><span class="pr-status-ico" data-tone="${esc(tone(writer.tone))}">${glyph('database')}</span>
          <div><b>Enregistrement local</b><span>${esc(writer.text)}</span><span class="pr-sub">${esc(writer.unsaved)}</span></div>
          ${button('writer-resume', 'Reprendre les sauvegardes', 'play', { kind: writer.canResume ? 'primary' : '', write: true, disabled: !writer.canResume, reason: writer.resumeReason ?? '' })}</div>
        <div class="pr-status" data-setting="space"><span class="pr-status-ico" data-tone="${esc(tone(space.tone))}">${glyph('disk')}</span>
          <div><b>Espace disque · ${esc(space.label)}</b><span>${esc(space.text)}</span></div>
          ${button('measure', 'Mesurer', 'gauge')}</div>
        <div class="pr-status"><span class="pr-status-ico" data-tone="${esc(tone(v.maintenance.tone))}">${glyph('layers')}</span>
          <div><b>Maintenance</b><span>${esc(v.maintenance.text)}</span></div>${button('tab:assistant', 'Assistant', 'chevronRight', { kind: 'ghost' })}</div>
      </div>`,
  });
  const content = card({
    id: 'content', title: 'Contenu', sub: `Schéma ${v.schema} · révision ${int(v.revision)}`, iconName: 'layers',
    body: `<p class="pr-content-line">${esc(v.content)}</p>
      <h4 class="pr-h4">Dernières sauvegardes</h4>${backupList(v)}
      <div class="pr-actions">${button('tab:sauvegardes', 'Toutes les sauvegardes', 'chevronRight', { kind: 'ghost' })}</div>`,
  });
  return `${tiles(v)}<div class="pr-grid">${location}${reliability}${content}</div>`;
}

function backups(v) {
  const s = v.schedule;
  const p = v.policy;
  const now = card({
    id: 'backup', title: 'Sauvegarder', sub: 'Copie à chaud cohérente, contrôlée puis rangée dans Backups', iconName: 'shield', toneName: 'ok',
    body: `<div class="pr-cta" data-setting="backup">
        <div class="pr-cta-text"><b>Une copie vérifiée de la base</b><span>Contrôle SQLite (quick_check), empreinte SHA-256 et annexe des préférences approuvées liée à la copie ; l’original n’est jamais modifié.</span></div>
        <div class="pr-cta-actions">${button('backup', 'Sauvegarder maintenant', 'shield', { kind: 'primary', small: false, write: true })}${button('backup-copy', 'Copier une sauvegarde vers…', 'download', { write: true })}</div>
      </div>${simNote(v)}`,
  });
  const schedule = card({
    id: 'schedule', title: 'Sauvegarde automatique', sub: 'Pendant que Domenia est ouvert ; désactivée par défaut', iconName: 'clock',
    body: `<form class="pr-form" data-form="schedule" novalidate>
        ${row({ label: 'Sauvegarder automatiquement', desc: 'Contrôle chaque minute ; différée pendant une opération, 15 min entre deux essais, arrêtée par une date future.', control: toggle('schedule-enabled', 'Sauvegarder automatiquement', p.automaticBackup), setting: 'schedule' })}
        ${row({ label: 'Toutes les', desc: 'De 1 à 720 heures.', control: select('schedule-hours', 'Fréquence', HOURS.concat(HOURS.includes(p.backupHours) ? [] : [p.backupHours]).sort((a, b) => a - b).map((h) => ({ value: h, label: h < 48 ? `${h}${NBSP}h` : `${h / 24}${NBSP}jours` })), p.backupHours) })}
        ${row({ label: 'Copies à conserver', desc: 'De 2 à 30 ; les copies faites avant une conservation, une purge ou une reprise restent hors rotation.', control: select('schedule-keep', 'Copies à conserver', KEEP.concat(KEEP.includes(p.backupKeep) ? [] : [p.backupKeep]).sort((a, b) => a - b).map((k) => ({ value: k, label: `${k} copies` })), p.backupKeep) })}
        <div class="pr-actions">${button('schedule-save', 'Enregistrer', 'check', { kind: 'primary' })}</div>
      </form>
      <ul class="pr-lines">${s.lines.map((l, n) => `<li data-j="${n}">${esc(l)}</li>`).join('')}</ul>`,
  });
  const list = card({
    id: 'backups', title: 'Sauvegardes', sub: `${count(v.backups.length, 'copie', 'copies')} · la plus récente en premier`, iconName: 'database', cls: 'pr-wide',
    body: backupTable(v) + (v.exports.length ? `<h4 class="pr-h4">Copies publiées vers un fichier</h4><ul class="pr-exports">${v.exports.map((x, n) => `<li data-j="${n}">${glyph('download')}<span class="mono" data-tip="${esc(x.destination)}">${esc(x.destination)}</span><span class="pr-sub">${esc(when(x.at))} · ${esc(size(x.bytes))}</span><span class="mono pr-sub pr-expert-only">SHA-256 ${esc(x.sha256.slice(0, 12))}…</span></li>`).join('')}</ul>` : ''),
  });
  return `<div class="pr-grid">${now}${schedule}${list}</div>`;
}

function retentionEditor(v) {
  return v.retention.map((f) => `<div class="pr-ret" data-family="${esc(f.family)}">
      <div class="pr-ret-text"><b>${esc(f.label)}</b><span>${esc(f.compaction ? 'Compacte les observations identiques répétées ; chaque changement d’utilisateur reste.' : f.loss.charAt(0).toUpperCase() + f.loss.slice(1) + '.')}</span></div>
      <label class="pr-ret-input"><input class="input" type="number" min="0" max="36500" step="1" inputmode="numeric" data-days="${esc(f.policyKey)}" value="${esc(f.days)}" aria-label="${esc(f.label)}${NBSP}: jours de conservation"><span>jours</span></label>
      <span class="pr-ret-now" data-ret-now="${esc(f.family)}">${esc(f.daysText)}</span>
    </div>`).join('');
}

function conservation(v) {
  const retention = card({
    id: 'retention', title: 'Conservation des mesures', sub: '0 = sans limite ; de 0 à 36 500 jours par famille', iconName: 'history', cls: 'pr-wide',
    body: `<div data-setting="retention">${retentionEditor(v)}</div>
      ${v.policyUnreadable ? `<p class="pr-hint warn">${glyph('alert')}<span>Politique enregistrée illisible${COLON}les valeurs par défaut sont affichées.</span></p>` : ''}
      <div class="pr-actions">${button('retention-save', 'Enregistrer la politique', 'check')}${button('retention-preview', 'Prévisualiser', 'eye', { kind: 'primary' })}
        ${button('retention-apply', 'Appliquer la conservation…', 'trash', { kind: 'danger', write: true, disabled: true, reason: 'Prévisualisez d’abord : la conservation exige l’empreinte de sa prévisualisation.' })}</div>
      <p class="pr-hint">${glyph('info')}<span>Enregistrer ne supprime rien. La conservation ne s’applique qu’après prévisualisation et confirmation, avec une sauvegarde vérifiée juste avant.</span></p>
      <div class="pr-preview" data-slot="retention-preview" hidden></div>`,
  });
  const purgeable = v.purge.filter((c) => c.purgeable);
  const never = v.purge.filter((c) => !c.purgeable);
  const purge = card({
    id: 'purge', title: 'Purger des données locales', sub: 'Catégories fermées ; simulation exigée', iconName: 'trash', toneName: 'alert', cls: 'pr-wide',
    body: `<div class="pr-purge" data-setting="purge">
        <fieldset class="pr-cats"><legend>À purger</legend>${purgeable.map((c) => `<label class="pr-cat"><input type="checkbox" class="k-checkbox" data-purge="${esc(c.id)}">
          <span><b>${esc(c.label)}</b><span>${esc(c.detail)} ${esc(count(c.rows, 'ligne', 'lignes'))}${c.bytes ? ` · ${esc(size(c.bytes))}` : ''}.</span></span></label>`).join('')}</fieldset>
        <fieldset class="pr-cats never"><legend>Jamais purgé</legend>${never.map((c) => `<label class="pr-cat" data-tip="Jamais purgé"><input type="checkbox" class="k-checkbox" disabled><span><b>${esc(c.label)}</b><span>${esc(c.detail)}</span></span></label>`).join('')}</fieldset>
      </div>
      <div class="pr-row pr-history-days"><div class="pr-row-text"><span class="pr-row-label">Historique plus ancien que</span><span class="pr-row-desc">Pour la catégorie Historique seulement ; 730 jours par défaut, de 1 à 36 500.</span></div>
        <label class="pr-ret-input"><input class="input" type="number" min="1" max="36500" value="730" data-history-days aria-label="Âge de l’historique purgé, en jours"><span>jours</span></label></div>
      <div class="pr-actions">${button('purge-preview', 'Simuler la purge', 'eye', { kind: 'primary' })}${button('purge-apply', 'Purger…', 'trash', { kind: 'danger', write: true, disabled: true, reason: 'Simulez d’abord : la purge exige l’empreinte de sa simulation.' })}</div>
      <div class="pr-preview" data-slot="purge-preview" hidden></div>
      ${notes(v.never)}`,
  });
  return `<div class="pr-grid">${retention}${purge}</div>`;
}

function usageMarkup(u) {
  if (!u) return emptyState('gauge', 'Pas encore mesurée', 'La mesure lit la base sans la modifier : taille du fichier et de son journal, lignes et octets par catégorie, temps de lectures types.');
  const segments = u.categories.filter((c) => (u.dbstatAvailable ? c.bytes : c.rows) > 0).map((c, n) => ({ value: u.dbstatAvailable ? c.bytes : c.rows, cls: `s${(n % 8) + 1}` }));
  const legend = u.categories.map((c, n) => `<li data-j="${n}"><span class="pr-swatch s${(n % 8) + 1}"></span><span class="pr-leg-label">${esc(c.label)}</span><b>${esc(u.dbstatAvailable ? c.bytesText : int(c.rows))}</b><span class="pr-leg-share">${esc(String(c.share).replace('.', ','))}${NBSP}%</span>${meter(c.share, `${c.label} : ${c.share} %`, null)}</li>`).join('');
  return `<div class="pr-usage">
      ${donut(segments, { center: `<b>${esc(u.databaseText)}</b><span>fichier</span>`, label: `Répartition du fichier de la base : ${u.categories.map((c) => `${c.label} ${c.share} %`).join(', ')}` })}
      <ul class="pr-legend">${legend}</ul>
    </div>
    ${facts([['Fichier de la base', u.databaseText, 'réparti ci-dessus'], ['Journal SQLite (WAL)', u.walText], ['Total sur le disque', size(u.databaseBytes + u.walBytes), 'le même total que l’emplacement'], ['Mesurée', when(u.measuredAt), `en ${int(u.durationMilliseconds)}${NBSP}ms, en lecture seule`]])}
    <h4 class="pr-h4">Lectures types</h4>
    <ul class="pr-probes">${u.probes.map((p, n) => `<li data-j="${n}"><span class="pr-probe-how" data-how="${esc(p.how)}">${esc(p.how)}</span><span>${esc(p.label)}</span><b>${esc(String(p.milliseconds).replace('.', ','))}${NBSP}ms</b><span class="pr-sub">${esc(count(p.rows, 'ligne', 'lignes'))}</span></li>`).join('')}</ul>
    <p class="pr-sub pr-expert-only">${esc(u.probesText)}</p>`;
}

function integrityMarkup(i, v) {
  if (!i) return emptyState('shield', 'Pas encore contrôlée', 'Neuf contrôles en lecture seule : ouverture, schéma, tables, identité, bascule, reçus, références, quick_check, journal.');
  return `<div class="pr-verdict" data-tone="${esc(tone(i.tone))}"><span class="pr-verdict-ico">${glyph(i.tone === 'ok' ? 'check' : 'alert')}</span><b>${esc(i.verdict)}</b><span>${esc(i.lines[0])}</span></div>
    <ul class="pr-checks">${i.checks.map((c, n) => `<li data-j="${n}" data-tone="${esc(tone(c.tone))}"><span class="pr-check-ico">${glyph(c.status === 'ok' ? 'check' : c.status === 'unknown' ? 'info' : 'alert')}</span><b>${esc(c.label)}</b><span>${esc(c.statusLabel)}<span class="pr-expert-only">${c.detail ? ` · ${esc(c.detail)}` : ''}</span></span></li>`).join('')}</ul>
    ${i.failed ? `<div class="pr-hint warn pr-hint-action">${glyph('alert')}<span>${esc(i.lines.at(-2))}</span>${button('restore', 'Restaurer une sauvegarde…', 'undo', { kind: 'primary', write: true, disabled: !v.maintenance?.restore, reason: v.maintenance?.restoreReason ?? '' })}</div>` : ''}
    <p class="pr-hint">${glyph('info')}<span>${esc(i.lines.at(-1))}</span></p>`;
}

function diagnostic(v) {
  const usage = card({
    id: 'usage', title: 'Mesure du stockage', sub: 'Lecture seule ; une mesure à la fois', iconName: 'gauge', cls: 'pr-wide',
    actions: button('measure', 'Mesurer', 'gauge', { kind: 'primary' }),
    body: `<div data-setting="measure" data-slot="usage">${usageMarkup(v.usage)}</div>`,
  });
  const integrity = card({
    id: 'integrity', title: 'Intégrité de la base', sub: 'Aucune réparation automatique', iconName: 'shield',
    actions: button('integrity', 'Contrôler', 'shield', { kind: 'primary' }),
    body: `<div data-setting="integrity" data-slot="integrity">${integrityMarkup(v.integrity, v)}</div>`,
  });
  const space = card({
    id: 'space', title: 'Espace disque', sub: 'Réserve de la base', iconName: 'disk',
    body: `<div class="pr-verdict" data-tone="${esc(tone(v.space.tone))}"><span class="pr-verdict-ico">${glyph('disk')}</span><b>${esc(v.space.label)}</b><span>${esc(v.space.freeText)}</span></div>
      <p class="pr-text">${esc(v.space.text)}</p>
      ${facts([['Écritures refusées sous', size(v.space.writeReserveBytes)], ['Collectes suspendues sous', size(v.space.suspendBelowBytes)], ['Alerte sous', size(v.space.warnBelowBytes)]])}`,
  });
  const limits = card({
    id: 'limits', title: 'Limites déclarées', sub: 'Rien n’est illimité', iconName: 'info', cls: 'pr-wide',
    body: `<ul class="pr-lines pr-lines-cols">${v.limits.map((l, n) => `<li data-j="${n}">${esc(l)}</li>`).join('')}</ul>`,
  });
  return `<div class="pr-grid">${usage}${integrity}${space}${limits}</div>`;
}

function assistant(v) {
  const m = v.maintenance;
  const action = (act, title, text, iconName, enabled, reason, kind = '') => `<div class="pr-assist${enabled ? '' : ' off'}">
      <span class="pr-assist-ico">${glyph(iconName)}</span><div><b>${esc(title)}</b><span>${esc(text)}</span></div>
      ${button(act, title + (act === 'move' || act === 'restore' ? '…' : ''), iconName, { kind: enabled ? kind : '', write: true, disabled: !enabled, reason: reason ?? '' })}</div>`;
  const body = `<div class="pr-verdict" data-tone="${esc(tone(m.tone))}"><span class="pr-verdict-ico">${glyph('layers')}</span><b>État de la maintenance</b><span>${esc(m.text)}</span></div>
    <div class="pr-assists" data-setting="assistant">
      ${action('move', 'Déplacer la base', 'Copie vérifiée vers un nouveau fichier local, puis bascule ; l’original reste en lecture seule.', 'external', m.move, m.moveReason, 'primary')}
      ${action('restore', 'Restaurer une sauvegarde', 'Une copie vérifiée, une copie publiée ou un autre fichier .db, restauré dans un nouveau fichier ; rien n’est écrasé.', 'undo', m.restore, m.restoreReason, m.move ? '' : 'primary')}
      ${action('resume', 'Reprendre la bascule', 'Termine le passage vers la copie vérifiée désignée par le marqueur.', 'play', m.resume, m.resumeReason, 'primary')}
      ${action('rollback', 'Revenir à la base précédente', 'Annule une bascule de cette session tant que la nouvelle base n’a reçu aucune écriture, ou abandonne une bascule interrompue.', 'history', m.rollback, m.rollbackReason)}
    </div>
    <ol class="pr-steps">${['Inspection en lecture seule de la source et de la destination : disque local, dossier existant, réserve de deux fois la base plus 32 Mo.', 'Suspension des nouvelles collectes, enregistrement de la file (120 s au plus), copie puis contrôle SQLite et empreinte.', 'Bascule vers la copie vérifiée ; retour possible tant qu’aucune écriture n’a eu lieu. Aucun fichier n’est supprimé.'].map((s, n) => `<li data-j="${n}"><span>${n + 1}</span>${esc(s)}</li>`).join('')}</ol>
    ${simNote(v)}`;
  return `<div class="pr-grid">${card({ id: 'assistant', title: 'Assistant de la base locale', sub: 'Chaque étape est un plan confirmé, tracé par un reçu', iconName: 'layers', cls: 'pr-wide', body })}</div>`;
}

const DATA_ICONS = {
  directory: 'tree', collectionClock: 'clock', presence: 'wifi', console: 'user', inventory: 'monitor', probe: 'gauge', detail: 'layers',
  association: 'link', backup: 'shield', preference: 'sliders', receipt: 'check', log: 'file', webProfile: 'monitor', legacy: 'download', vault: 'key',
};

function policyMarkup(p, v) {
  if (!p) return skeleton(1);
  const place = (text) => (PATHLIKE.test(text ?? '') ? `<span class="mono pr-path" data-tip="${esc(text)}">${esc(text)}</span>` : esc(text));
  const rows = p.rows.map((r, n) => `<tr data-j="${n}">
      <th scope="row"><span class="pr-data-name"><span class="pr-data-ico">${glyph(DATA_ICONS[r.category] ?? 'database')}</span><span><b>${esc(r.label)}</b><span class="pr-sub">${esc(r.content)}</span></span></span></th>
      <td>${place(r.location)}</td><td>${esc(r.retention)}</td><td>${esc(r.export)}</td><td>${esc(r.deletion)}</td>
      <td class="pr-cell-act">${r.folder ? button(`open:${r.folder}`, 'Ouvrir', 'folder', { kind: 'ghost' }) : ''}</td></tr>`).join('');
  const catalog = v.catalog.length
    ? `<div class="pr-table-wrap"><table class="pr-table"><thead><tr><th>Périmètre</th><th>Source</th><th>Contrôleur</th><th>Compte lecteur</th><th class="num">Objets</th><th>Observé</th><th>Usage permis</th></tr></thead><tbody>${v.catalog.map((c, n) => `<tr data-j="${n}"><td><b>${esc(c.scope)}</b></td><td>${esc(c.source)}</td><td class="mono">${esc(c.controller)}</td><td class="mono">${esc(c.reader)}</td><td class="num">${int(c.objects)}</td><td>${esc(c.observed)}${c.age ? `<span class="pr-sub">il y a ${esc(c.age)}</span>` : ''}</td><td>${esc(c.usage)}</td></tr>`).join('')}</tbody></table></div>`
    : emptyState('database', 'Aucun périmètre en cache', 'Les périmètres apparaissent après une lecture de l’annuaire.');
  return `<p class="pr-statement">${glyph('lock')}<span>${esc(p.statement)}</span></p>
    <div class="pr-table-wrap"><table class="pr-table pr-policy-table"><colgroup><col class="c-data"><col class="c-place"><col><col><col><col class="c-act"></colgroup>
      <thead><tr><th>Donnée</th><th>Emplacement</th><th>Durée</th><th>Export</th><th>Suppression</th><th><span class="visually-hidden">Dossier</span></th></tr></thead><tbody>${rows}</tbody></table></div>
    <h4 class="pr-h4">Catalogue du cache par périmètre</h4>${catalog}`;
}

function policy(v, p) {
  return `<div class="pr-grid">${card({ id: 'policy', title: 'Politique des données locales', sub: 'Une ligne par donnée gardée sur ce poste', iconName: 'lock', cls: 'pr-wide', body: `<div data-setting="policy" data-slot="policy">${policyMarkup(p, v)}</div>` })}</div>`;
}

function stepsTable(steps) {
  if (!steps.length) return '';
  return `<div class="pr-table-wrap"><table class="pr-table pr-steps-table"><thead><tr><th>Donnée</th><th>Source</th><th>Cible</th><th>Décision</th><th class="num">Lignes</th><th>Raison</th></tr></thead><tbody>${steps.map((s, n) => {
    const [t, label] = ACTIONS[s.action] ?? ['off', s.action];
    return `<tr data-j="${n}"><th scope="row">${esc(s.label)}</th><td class="mono pr-sub-cell">${esc(s.source)}</td><td class="mono pr-sub-cell">${esc(s.target || '—')}</td><td>${pill(t, label, { size: 'sm' })}</td><td class="num">${s.rows ? int(s.rows) : '—'}</td><td class="pr-reason">${esc(s.reason)}</td></tr>`;
  }).join('')}</tbody></table></div>`;
}

function legacy(v) {
  const l = v.legacy;
  const db = l.database;
  const head = l.state === 'available' ? 'Données à reprendre' : l.state === 'imported' ? 'Déjà reprises' : l.state === 'blocked' ? 'Reprise bloquée' : l.state === 'nothing' ? 'Rien à ajouter' : 'Rien à reprendre';
  const source = db ? card({
    id: 'legacy-db', title: 'Base de Domenia 1', sub: 'Lue en lecture seule, laissée intacte', iconName: 'database',
    body: `${facts([['Fichier', db.name, db.path], ['Schéma', db.schemaVersion ?? 'inconnu', db.schemaVersion === '11' ? 'pris en charge' : 'non pris en charge'], ['Révision', db.revision ?? 'inconnue'], ['Domaine', db.domain ?? 'inconnu'], ['Taille', size(db.bytes)]])}`,
  }) : '';
  const files = card({
    id: 'legacy-files', title: 'Fichiers de l’ancienne version', sub: 'objets.tsv, parc.tsv, recherches.tsv, secrets-etat.tsv, liens', iconName: 'file',
    body: l.files.length
      ? `<div class="pr-table-wrap"><table class="pr-table"><thead><tr><th>Fichier</th><th class="num">Lignes</th><th class="num">Taille</th><th>Lecture</th></tr></thead><tbody>${l.files.map((f, n) => `<tr data-j="${n}"><th scope="row">${esc(f.label)}<span class="pr-sub mono">${esc(f.path)}</span></th><td class="num">${int(f.rows)}${f.rejected ? `<span class="pr-sub">${int(f.rejected)} invalides</span>` : ''}</td><td class="num">${esc(f.bytesText)}</td><td>${f.locked ? pill('ok', 'Sous verrou', { size: 'sm' }) : pill('warn', 'En écriture', { size: 'sm' })}</td></tr>`).join('')}</tbody></table></div>`
      : emptyState('file', 'Aucun fichier trouvé', 'Les fichiers de l’ancienne version sont repris par la même règle s’ils existent : tables cibles vides, même domaine, 128 Mo et 250 000 lignes au plus.'),
  });
  return `<div class="pr-grid">${card({
    id: 'legacy', title: 'Reprendre les données de Domenia 1', sub: 'Base au schéma 11, réglages et fichiers de l’ancienne version', iconName: 'download', cls: 'pr-wide',
    body: `<div class="pr-legacy-body" data-setting="legacy">
        <div class="pr-verdict" data-tone="${esc(tone(l.tone))}"><span class="pr-verdict-ico">${glyph(l.state === 'imported' ? 'check' : l.state === 'blocked' ? 'alert' : 'download')}</span><b>${esc(head)}</b><span>${esc(l.text)}</span></div>
        <p class="pr-sub mono">${esc(l.location)}</p>
        ${l.blockers.length ? `<ul class="pr-errors">${l.blockers.map((b) => `<li>${esc(b)}</li>`).join('')}</ul>` : ''}
        <h4 class="pr-h4">Ce que la reprise ferait</h4>${stepsTable(l.steps) || '<p class="pr-sub">Aucune donnée à examiner.</p>'}
        <div class="pr-actions">${button('legacy-preview', 'Simuler la reprise', 'eye', { kind: 'primary', disabled: l.state === 'none' })}${button('legacy-apply', 'Reprendre…', 'download', { write: true, disabled: true, reason: 'Simulez d’abord : la reprise exige l’empreinte de sa simulation.' })}</div>
        <div class="pr-preview" data-slot="legacy-preview" hidden></div>
        <h4 class="pr-h4">Garde-fous</h4>${notes(l.guards)}
      </div>`,
  })}${source}${files}</div>`;
}

// ---------- Section ----------

export function mount(host, sctx, { open, tab } = {}) {
  let view = null;
  let policyView = null;
  let alive = true;
  let tabs = null;
  const panels = new Map();
  const previews = { retention: null, purge: null, legacy: null };
  const writeCtx = { call: sctx.call };
  host.innerHTML = `${sectionHead(HEAD)}${skeleton(3)}`;

  const renderers = {
    apercu: () => overview(view),
    sauvegardes: () => backups(view),
    conservation: () => conservation(view),
    diagnostic: () => diagnostic(view),
    assistant: () => assistant(view),
    politique: () => policy(view, policyView),
    reprise: () => legacy(view),
  };

  function paintPanel(id) {
    const panel = panels.get(id);
    if (!panel || !view) return;
    panel.innerHTML = renderers[id]();
    paint(panel);
    reveal(panel);
    if (id === 'apercu') {
      panel.querySelectorAll('.pr-tile-v').forEach((el, n) => {
        const raw = el.dataset.count?.replace(/\s| | /g, '');
        if (/^\d+$/.test(raw ?? '')) countUp(el, Number(raw), { delay: n * 60 });
      });
    }
    if (id === 'politique' && !policyView) loadPolicy();
    if (id === 'conservation') restorePreviews(panel);
  }

  function restorePreviews(panel) {
    if (previews.retention) showRetention(previews.retention, panel);
    if (previews.purge) showPurge(previews.purge, panel);
  }

  function badges() {
    const alarm = view?.writer?.canResume || view?.maintenance?.tone === 'alert';
    sctx.badge('donnees', alarm || view?.location?.alert ? '!' : '', alarm ? 'alert' : view?.location?.alert ? 'warn' : 'off');
  }

  function build() {
    host.innerHTML = `${sectionHead(HEAD, `<span class="pr-head-pill">${pill(view.simulated ? 'accent' : view.available ? 'ok' : 'off', view.simulated ? 'Base fictive · en mémoire' : view.available ? `Révision ${int(view.revision)}` : 'Pas encore branchée', { icon: view.simulated ? 'sparkles' : 'database' })}</span>`)}<div class="pr-tabs-host"></div>`;
    paint(host);
    reveal(host);
    if (!view.available) {
      host.querySelector('.pr-tabs-host').innerHTML = `<div class="pr-grid">${card({
        id: 'unavailable', title: 'Base locale', sub: 'Mode annuaire de cette version', iconName: 'database', cls: 'pr-wide',
        body: emptyState('database', 'Base locale pas encore branchée', view.unavailableReason ?? '') + `<h4 class="pr-h4">Conservation enregistrée</h4>${retentionEditor(view)}<div class="pr-actions">${button('retention-save', 'Enregistrer la politique', 'check')}</div><h4 class="pr-h4">Limites</h4><ul class="pr-lines">${view.limits.map((l) => `<li>${esc(l)}</li>`).join('')}</ul>${notes(view.never)}`,
      })}</div>`;
      paint(host);
      reveal(host);
      return;
    }
    tabs = createTabs(host.querySelector('.pr-tabs-host'), {
      label: 'Données et cache',
      key: 'parametres.donnees',
      selected: TABS.some((t) => t.id === tab) ? tab : undefined,
      tabs: TABS.map((t) => ({
        ...t,
        count: t.id === 'sauvegardes' ? view.backups.length : null,
        tone: 'info',
        render: (panel) => { panels.set(t.id, panel); paintPanel(t.id); },
      })),
      onChange: (id) => sctx.address({ onglet: id }),
    });
    if (TABS.some((t) => t.id === tab)) tabs.select(tab);
  }

  async function load({ keepTab = true } = {}) {
    try {
      const next = await sctx.call('settings.storage');
      if (!alive) return;
      const firstBuild = !view || view.available !== next.available;
      view = next;
      badges();
      if (firstBuild || !tabs) build();
      else for (const id of panels.keys()) paintPanel(id);
      if (!keepTab) tabs?.select('apercu');
    } catch (err) {
      if (!alive) return;
      console.error(err);
      host.innerHTML = `${sectionHead(HEAD)}${errorBlock(err)}`;
    }
  }

  async function loadPolicy() {
    try {
      policyView = await sctx.call('settings.dataPolicy');
      if (!alive) return;
      const panel = panels.get('politique');
      const slot = panel?.querySelector('[data-slot="policy"]');
      if (slot) { slot.innerHTML = policyMarkup(policyView, view); paint(slot); }
    } catch (err) {
      const slot = panels.get('politique')?.querySelector('[data-slot="policy"]');
      if (slot) slot.innerHTML = errorBlock(err, 'policy-retry');
    }
  }

  function apply(next) {
    view = next;
    badges();
    for (const id of panels.keys()) paintPanel(id);
    tabs?.setCount('sauvegardes', view.backups.length, 'info');
    sctx.refreshStorage?.();
  }

  async function busy(btn, job) {
    if (btn) { btn.disabled = true; btn.setAttribute('aria-busy', 'true'); }
    try { return await job(); } finally {
      if (btn?.isConnected) { btn.disabled = false; btn.removeAttribute('aria-busy'); }
    }
  }

  // ----- Previews -----

  function showRetention(p, scope = panels.get('conservation')) {
    const slot = scope?.querySelector('[data-slot="retention-preview"]');
    if (!slot) return;
    const max = Math.max(1, ...p.families.map((f) => f.rows));
    slot.hidden = false;
    slot.innerHTML = `<div class="pr-preview-head">${glyph('eye')}<b>Prévisualisation du ${esc(when(p.at))}</b>${pill(p.nothingToDo ? 'ok' : 'warn', p.nothingToDo ? 'Rien à retirer' : `${count(p.totalRows, 'ligne à retirer', 'lignes à retirer')}`, { size: 'sm' })}</div>
      <ul class="pr-bars-list">${p.families.map((f, n) => `<li data-j="${n}"><span class="pr-bar-label">${esc(f.label)}</span><span class="pr-bar-track"><span class="pr-bar-fill" data-tone="${f.rows ? 'warn' : 'ok'}" data-w="${(f.rows / max) * 100}"></span></span><b>${f.cutoff ? int(f.rows) : '∞'}</b><span class="pr-sub">${esc(f.text)}</span></li>`).join('')}</ul>
      <ul class="pr-lines">${p.lines.slice(-3).map((l) => `<li>${esc(l)}</li>`).join('')}</ul>`;
    paint(slot);
    setOff(scope.querySelector('[data-act="retention-apply"]'), p.nothingToDo, 'Rien de plus ancien que la politique : rien à retirer.');
  }

  function showPurge(p, scope = panels.get('conservation')) {
    const slot = scope?.querySelector('[data-slot="purge-preview"]');
    if (!slot) return;
    slot.hidden = false;
    const rows = p.targets.map((t, n) => `<tr data-j="${n}"><td>${esc(t.label)}</td><td class="mono">${esc(t.table)}</td><td>${t.action === 'reset' ? pill('info', 'Réinitialisé', { size: 'sm' }) : pill(t.rows ? 'alert' : 'off', t.rows ? 'Retiré' : 'Déjà vide', { size: 'sm' })}</td><td class="num">${int(t.rows)}</td></tr>`).join('');
    slot.innerHTML = `<div class="pr-preview-head">${glyph('eye')}<b>Simulation de la purge</b>${pill(p.nothingToDo ? 'ok' : 'alert', p.nothingToDo ? 'Rien à purger' : count(p.totalRows, 'ligne', 'lignes'), { size: 'sm' })}</div>
      ${p.refused.length ? `<p class="pr-hint warn">${glyph('alert')}<span>${esc(p.refused.join(' '))}</span></p>` : ''}
      <ul class="pr-lines">${p.lines.map((l) => `<li>${esc(l)}</li>`).join('')}</ul>
      ${rows ? `<div class="pr-table-wrap"><table class="pr-table"><thead><tr><th>Groupe</th><th>Table</th><th>Effet</th><th class="num">Lignes</th></tr></thead><tbody>${rows}</tbody></table></div>` : ''}`;
    paint(slot);
    setOff(scope.querySelector('[data-act="purge-apply"]'), p.nothingToDo, 'Rien à purger dans les catégories choisies.');
  }

  function purgeChoice(scope) {
    const categories = [...scope.querySelectorAll('[data-purge]:checked')].map((c) => c.dataset.purge);
    const days = Number(scope.querySelector('[data-history-days]')?.value ?? 730);
    return { categories, historyDays: Number.isInteger(days) ? days : 730 };
  }

  async function previewRetention(btn) {
    await busy(btn, async () => {
      try {
        previews.retention = await sctx.call('settings.storage.retention.preview');
        showRetention(previews.retention);
      } catch (err) { sctx.toast(reported(err), { tone: 'alert' }); }
    });
  }

  async function previewPurge(btn) {
    const scope = panels.get('conservation');
    const choice = purgeChoice(scope);
    if (!choice.categories.length) { sctx.toast('Cochez au moins une catégorie à purger.', { tone: 'warn' }); return; }
    await busy(btn, async () => {
      try {
        previews.purge = { ...(await sctx.call('settings.storage.purge.preview', choice)), choice };
        showPurge(previews.purge);
      } catch (err) { sctx.toast(reported(err), { tone: 'alert' }); }
    });
  }

  async function previewLegacy(btn) {
    await busy(btn, async () => {
      try {
        previews.legacy = await sctx.call('settings.storage.legacy.preview');
        const slot = panels.get('reprise')?.querySelector('[data-slot="legacy-preview"]');
        if (slot) {
          const p = previews.legacy;
          slot.hidden = false;
          slot.innerHTML = `<div class="pr-preview-head">${glyph('eye')}<b>Simulation de la reprise</b>${pill(p.blockers.length ? 'alert' : p.nothingToDo ? 'ok' : 'info', p.blockers.length ? 'Bloquée' : p.nothingToDo ? 'Rien de nouveau' : `${count(p.writeCount, 'ligne à reprendre', 'lignes à reprendre')}`, { size: 'sm' })}</div>
            <ul class="pr-lines">${p.lines.map((l) => `<li>${esc(l)}</li>`).join('')}</ul>`;
          paint(slot);
        }
        setOff(panels.get('reprise')?.querySelector('[data-act="legacy-apply"]'), previews.legacy.nothingToDo,
          previews.legacy.blockers.length ? 'Reprise bloquée : la simulation dit pourquoi.' : 'Rien de nouveau à reprendre.');
      } catch (err) { sctx.toast(reported(err), { tone: 'alert' }); }
    });
  }

  // ----- Writes (circuit) -----

  const after = async () => {
    previews.retention = null;
    previews.purge = null;
    previews.legacy = null;
    await load();
  };

  // After a verified restore, the annex of the restored backup is re-applied (PAR-034), with the receipt as proof.
  async function reapply(receipt) {
    if (receipt?.kind !== 'storage.restore' || receipt.result !== 'applied' || receipt.verification !== 'verified') return;
    try {
      const result = await sctx.call('settings.storage.restore.preferences', { receiptId: receipt.id });
      sctx.toast(result.summary, { tone: result.failed?.length ? 'warn' : 'ok', life: 6000 });
    } catch (err) {
      sctx.toast(reported(err), { tone: 'warn' });
    }
  }

  function write(plan, args = {}) {
    return runWrite(writeCtx, {
      plan, args,
      onDone: (receipt) => { after().then(() => reapply(receipt)).catch((err) => console.error(err)); },
    });
  }

  const onClick = async (e) => {
    const btn = e.target instanceof Element ? e.target.closest('[data-act]') : null;
    if (isOff(btn) || !host.contains(btn)) return;
    const act = btn.dataset.act;
    const scope = btn.closest('.k-tabpanel') ?? host;
    if (act === 'retry') { load(); return; }
    if (act === 'policy-retry') { loadPolicy(); return; }
    if (act.startsWith('tab:')) { tabs?.select(act.slice(4)); return; }
    if (act === 'copy-path') {
      const ok = await copyText(view.location.path ?? view.location.pathLabel);
      sctx.toast(ok ? 'Chemin de la base copié.' : `Copie impossible${COLON}presse-papiers indisponible.`, { tone: ok ? 'ok' : 'warn' });
      return;
    }
    if (act === 'open-base' || act.startsWith('open:')) {
      try {
        await sctx.call('settings.folder.open', { folder: act === 'open-base' ? 'base' : act.slice(5) });
      } catch (err) { sctx.toast(reported(err), { tone: 'info' }); }
      return;
    }
    if (act === 'measure') {
      await busy(btn, async () => {
        try { apply(await sctx.call('settings.storage.measure')); sctx.toast('Base mesurée en lecture seule.', { tone: 'ok', life: 2600 }); } catch (err) { sctx.toast(reported(err), { tone: 'alert' }); }
      });
      return;
    }
    if (act === 'integrity') {
      await busy(btn, async () => {
        try {
          apply(await sctx.call('settings.storage.integrity'));
          sctx.toast(`Intégrité de la base${COLON}${view.integrity?.verdict ?? '—'}.`, { tone: view.integrity?.tone === 'ok' ? 'ok' : 'warn' });
        } catch (err) { sctx.toast(reported(err), { tone: 'alert' }); }
      });
      return;
    }
    if (act === 'schedule-save') {
      const form = scope.querySelector('[data-form="schedule"]');
      const args = {
        enabled: form.querySelector('[data-toggle="schedule-enabled"]').checked,
        hours: Number(form.querySelector('[data-select="schedule-hours"]').value),
        keep: Number(form.querySelector('[data-select="schedule-keep"]').value),
      };
      await busy(btn, async () => {
        try { apply(await sctx.call('settings.storage.backup.schedule.set', args)); sctx.toast(args.enabled ? `Sauvegarde automatique toutes les ${args.hours}${NBSP}h, ${args.keep} copies.` : 'Sauvegarde automatique désactivée.', { tone: 'ok' }); } catch (err) { sctx.toast(reported(err), { tone: 'alert' }); }
      });
      return;
    }
    if (act === 'retention-save') {
      const args = {};
      for (const input of scope.querySelectorAll('[data-days]')) {
        const n = Number(input.value);
        if (!Number.isInteger(n) || n < 0 || n > 36500) { input.setAttribute('aria-invalid', 'true'); input.focus(); sctx.toast(`Conservation${COLON}de 0 (sans limite) à 36${' '}500 jours.`, { tone: 'warn' }); return; }
        input.removeAttribute('aria-invalid');
        args[input.dataset.days] = n;
      }
      await busy(btn, async () => {
        try {
          apply(await sctx.call('settings.storage.retention.set', args));
          previews.retention = null;
          sctx.toast('Politique de conservation enregistrée. Rien n’a été supprimé.', { tone: 'ok' });
        } catch (err) { sctx.toast(reported(err), { tone: 'alert' }); }
      });
      return;
    }
    if (act === 'retention-preview') { previewRetention(btn); return; }
    if (act === 'purge-preview') { previewPurge(btn); return; }
    if (act === 'legacy-preview') { previewLegacy(btn); return; }
    if (act === 'retention-apply' && previews.retention) { write('settings.storage.retention.plan', { fingerprint: previews.retention.fingerprint }); return; }
    if (act === 'purge-apply' && previews.purge) { write('settings.storage.purge.plan', { ...previews.purge.choice, fingerprint: previews.purge.fingerprint }); return; }
    if (act === 'legacy-apply' && previews.legacy) { write('settings.storage.legacy.plan', { fingerprint: previews.legacy.fingerprint }); return; }
    if (act === 'backup') { write('settings.storage.backup.plan'); return; }
    if (act === 'writer-resume') { write('settings.storage.writerResume.plan'); return; }
    if (act === 'resume') { write('settings.storage.resume.plan'); return; }
    if (act === 'rollback') { write('settings.storage.rollback.plan'); return; }
    if (act === 'backup-copy') {
      const destination = await chooseDestination(sctx, {
        purpose: 'copy', title: 'Copier une sauvegarde vers…', action: 'Préparer la copie', fallbackName: view.exportName ?? undefined,
        hint: 'Une sauvegarde vérifiée est faite puis publiée vers le fichier choisi ; si la publication échoue, la copie locale vérifiée reste disponible.',
      });
      if (destination) write('settings.storage.backupCopy.plan', { destination });
      return;
    }
    if (act === 'move') {
      const destination = await chooseDestination(sctx, {
        purpose: 'move', title: 'Déplacer la base locale', action: 'Préparer le déplacement',
        hint: 'La base est copiée vers un nouveau fichier, contrôlée, puis la session bascule sur la copie ; l’original reste en lecture seule avec un marqueur.',
      });
      if (destination) write('settings.storage.move.plan', { destination });
      return;
    }
    if (act === 'restore' || act.startsWith('restore:')) {
      const args = act.startsWith('restore:') ? { backupId: act.slice(8) } : await chooseRestore(sctx, view);
      if (args) write('settings.storage.restore.plan', args);
    }
  };
  const onInput = (e) => {
    const input = e.target instanceof HTMLInputElement ? e.target : null;
    if (input?.matches('[data-days]')) {
      const n = Number(input.value);
      const label = input.closest('.pr-ret')?.querySelector('[data-ret-now]');
      if (label) label.textContent = Number.isInteger(n) && n >= 0 ? (n === 0 ? 'sans limite' : count(n, 'jour', 'jours')) : '—';
      if (previews.retention) setOff(panels.get('conservation')?.querySelector('[data-act="retention-apply"]'), true, 'Politique modifiée : enregistrez-la puis prévisualisez de nouveau.');
    }
    if (input?.matches('[data-purge], [data-history-days]')) {
      setOff(panels.get('conservation')?.querySelector('[data-act="purge-apply"]'), true, 'Choix modifié : simulez de nouveau la purge.');
      previews.purge = null;
    }
  };
  host.addEventListener('click', onClick);
  host.addEventListener('input', onInput);
  host.addEventListener('change', onInput);

  async function openState(state) {
    if (!alive || !view?.available || !state) return;
    // Open states for links and captures (consumed once: the address forgets them).
    if (state === 'apercu') { tabs?.select('conservation'); await previewRetention(null); }
    else if (state === 'purge') {
      tabs?.select('conservation');
      const scope = panels.get('conservation');
      scope?.querySelectorAll('[data-purge="observations"], [data-purge="snapshots"]').forEach((c) => { c.checked = true; });
      await previewPurge(null);
    } else if (state === 'diagnostic') {
      tabs?.select('diagnostic');
      try { apply(await sctx.call('settings.storage.measure')); apply(await sctx.call('settings.storage.integrity')); } catch (err) { console.error(err); }
    } else if (state === 'plan') { tabs?.select('sauvegardes'); write('settings.storage.backup.plan'); }
    else if (state === 'reprise') { tabs?.select('reprise'); await previewLegacy(null); }
    else if (state === 'restaurer') { tabs?.select('assistant'); const args = await chooseRestore(sctx, view); if (args) write('settings.storage.restore.plan', args); }
    else if (state === 'copier') {
      tabs?.select('sauvegardes');
      const destination = await chooseDestination(sctx, { purpose: 'copy', title: 'Copier une sauvegarde vers…', action: 'Préparer la copie', hint: 'Une sauvegarde vérifiée est faite puis publiée vers le fichier choisi.' });
      if (destination) write('settings.storage.backupCopy.plan', { destination });
    }
  }

  load().then(() => openState(open));

  return {
    reload: () => load(),
    reveal({ tab: next, open: state } = {}) {
      if (next && TABS.some((t) => t.id === next)) tabs?.select(next);
      if (state) openState(state);
    },
    destroy() {
      alive = false;
      tabs?.destroy();
      host.removeEventListener('click', onClick);
      host.removeEventListener('input', onInput);
      host.removeEventListener('change', onInput);
    },
  };
}
