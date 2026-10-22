// « Partage »: export of personal recipes as a named, versioned pack (Domenia.QueryPack/3 with a content fingerprint);
// import examined before any write (provenance, version, integrity, state and differences of every recipe, one choice per
// recipe), applied with a restore point; history of the imports and restore. Files are read by the page (FileReader) and
// sent as text: the engine never opens a path given by the page.
import {
  esc, glyph, plural, emptyState, skLines, dateText, vars,
} from './shared.js';
import { openExport } from './drawers.js';
import { confirmDialog } from '../../kit/index.js';
import { reveal, formatNumber } from '../../ui.js';

const ACTION_LABEL = { ignore: 'Ignorer', create: 'Créer', copy: 'Nouvelle copie', replace: 'Remplacer' };
const STATUS_TONE = { new: 'ok', identical: 'off', conflict: 'warn', archived: 'warn', foreignDomain: 'alert' };

export function mountShare(panel, store) {
  const st = { personal: [], selected: new Set(), plan: null, choices: {}, busy: false, maxLength: 900000 };
  panel.innerHTML = `<div class="grid rq-share">
    <section class="card span-6 rq-pack-export spot reveal" aria-labelledby="rq-px-title">
      <div class="card-head"><span class="card-icon">${glyph('download')}</span><div class="rq-head-titles"><h3 id="rq-px-title">Exporter un pack</h3>
        <p class="rq-sub">Requêtes personnelles choisies, avec nom, version et empreinte du contenu.</p></div></div>
      <div class="rq-form">
        <label class="rq-lbl">Nom du pack<input type="text" class="input rq-px-name" maxlength="80" value="Requêtes de l’équipe" autocomplete="off"></label>
        <label class="rq-lbl narrow">Version<input type="number" class="input rq-px-version" min="1" max="1000000" step="1" value="1"></label>
        <label class="rq-lbl wide">Origine déclarée (facultative)<input type="text" class="input rq-px-origin" maxlength="256" placeholder="Service, équipe ou poste d’origine" autocomplete="off"></label>
      </div>
      <div class="rq-px-tools"><span class="rq-px-count"></span><span class="rq-spacer"></span>
        <button type="button" class="btn xs ghost rq-px-all">Tout cocher</button><button type="button" class="btn xs ghost rq-px-none">Tout décocher</button></div>
      <ul class="rq-px-list" aria-label="Requêtes à exporter"></ul>
      <div class="rq-save-actions"><button type="button" class="btn primary rq-px-go">${glyph('download')}Préparer le pack</button></div>
    </section>

    <section class="card span-6 rq-pack-import spot reveal" aria-labelledby="rq-pi-title">
      <div class="card-head"><span class="card-icon">${glyph('folder')}</span><div class="rq-head-titles"><h3 id="rq-pi-title">Importer un pack</h3>
        <p class="rq-sub">Le pack est examiné avant toute écriture : vous choisissez le sort de chaque requête.</p></div></div>
      <label class="rq-drop" tabindex="-1">
        <input type="file" class="rq-pi-file visually-hidden" accept=".json,application/json">
        <span class="rq-drop-art" aria-hidden="true">${glyph('folder')}<i></i><i></i></span>
        <b>Déposez un fichier de pack ici</b><span>ou <u>choisissez un fichier</u> (JSON, 900 Ko au plus) — Domenia 1 et Domenia 2</span>
      </label>
      <details class="rq-fold rq-paste"><summary><span class="rq-fold-title"><b>Coller le contenu d’un pack</b></span>${glyph('chevronDown', 'rq-fold-chev')}</summary>
        <div class="rq-fold-body"><textarea class="input rq-pi-text rq-mono" rows="6" maxlength="900000" spellcheck="false" aria-label="Contenu du pack"></textarea>
          <button type="button" class="btn subtle sm rq-pi-examine">${glyph('search')}Examiner ce contenu</button></div></details>
      <div class="rq-pi-plan" aria-live="polite"></div>
    </section>

    <section class="card span-12 rq-pack-history spot reveal" aria-labelledby="rq-ph-title">
      <div class="card-head"><span class="card-icon">${glyph('history')}</span><div class="rq-head-titles"><h3 id="rq-ph-title">Imports restaurables</h3>
        <p class="rq-sub">Chaque import garde un point de restauration (10 au plus) : définitions remplacées remises, créations retirées.</p></div>
        <span class="meta"><button type="button" class="btn xs subtle rq-ph-refresh">${glyph('refresh')}Actualiser</button></span></div>
      <div class="rq-ph-list"></div>
    </section>
  </div>`;
  const $ = (sel) => panel.querySelector(sel);

  // ---------- Export ----------

  async function loadPersonal() {
    const host = $('.rq-px-list');
    host.innerHTML = `<li>${skLines(80, 60, 70)}</li>`;
    const res = await store.call('requetes.library.list', { source: 'personal', limit: 500 });
    if (!store.alive) return;
    if (res.error) { host.innerHTML = `<li class="rq-note">${esc(res.message)}</li>`; return; }
    st.personal = res.data.rows;
    st.selected = new Set(st.personal.map((r) => r.id));
    renderPersonal();
  }

  function renderPersonal() {
    const host = $('.rq-px-list');
    $('.rq-px-tools').hidden = !st.personal.length;
    if (!st.personal.length) {
      host.innerHTML = `<li class="rq-px-empty">${glyph('info')}<span>Aucune requête personnelle : enregistrez d’abord une requête (les modèles livrés ne s’exportent pas).</span></li>`;
      $('.rq-px-go').disabled = true;
      $('.rq-px-count').textContent = '';
      return;
    }
    host.innerHTML = st.personal.map((r, n) => `<li data-i="${n}"><label class="rq-check"><input type="checkbox" class="k-checkbox" data-id="${esc(r.id)}"${st.selected.has(r.id) ? ' checked' : ''}>
      <span><b>${esc(r.name)}</b><small>${esc(r.category)} · révision ${esc(String(r.revision))}</small></span></label></li>`).join('');
    vars(host);
    count();
  }

  function count() {
    $('.rq-px-count').textContent = `${plural(st.selected.size, 'requête cochée', 'requêtes cochées')} sur ${formatNumber(st.personal.length)}`;
    $('.rq-px-go').disabled = st.selected.size === 0;
  }

  $('.rq-px-list').addEventListener('change', (e) => {
    const box = e.target instanceof HTMLInputElement ? e.target : null;
    if (!box?.dataset.id) return;
    if (box.checked) st.selected.add(box.dataset.id); else st.selected.delete(box.dataset.id);
    count();
  });
  $('.rq-px-all').addEventListener('click', () => { st.selected = new Set(st.personal.map((r) => r.id)); renderPersonal(); });
  $('.rq-px-none').addEventListener('click', () => { st.selected.clear(); renderPersonal(); });

  async function proposeVersion() {
    const name = $('.rq-px-name').value.trim();
    if (!name) return;
    const res = await store.call('requetes.pack.version', { name });
    if (!res.error) $('.rq-px-version').value = String(res.data.version);
  }
  $('.rq-px-name').addEventListener('change', proposeVersion);

  $('.rq-px-go').addEventListener('click', async () => {
    const name = $('.rq-px-name').value.trim();
    const version = Number($('.rq-px-version').value);
    if (!name) { store.toast('Donnez un nom au pack.', 'warn'); return; }
    if (!(Number.isInteger(version) && version >= 1)) { store.toast('La version est un entier de 1 à 1 000 000.', 'warn'); return; }
    const res = await store.call('requetes.pack.export', { name, version, ids: [...st.selected], origin: $('.rq-px-origin').value.trim() || null });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    $('.rq-px-version').value = String(res.data.nextVersion);
    openExport(store, { ...res.data, text: `Pack « ${name} » version ${version} : ${plural(res.data.count, 'requête', 'requêtes')}. La version proposée pour le prochain export passe à ${res.data.nextVersion}.` }, { title: 'Pack prêt' });
  });

  // ---------- Import ----------

  function readFile(file) {
    if (!file) return;
    if (file.size > st.maxLength * 2) { store.toast('Fichier trop volumineux pour un pack (900 Ko au plus).', 'warn'); return; }
    const reader = new FileReader();
    reader.addEventListener('load', () => examine(String(reader.result ?? ''), file.name));
    reader.addEventListener('error', () => store.toast('Lecture du fichier impossible.', 'warn'));
    reader.readAsText(file, 'utf-8');
  }

  const drop = $('.rq-drop');
  $('.rq-pi-file').addEventListener('change', (e) => { readFile(e.target.files?.[0]); e.target.value = ''; });
  drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('over'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('over'));
  drop.addEventListener('drop', (e) => { e.preventDefault(); drop.classList.remove('over'); readFile(e.dataTransfer?.files?.[0]); });
  $('.rq-pi-examine').addEventListener('click', () => examine($('.rq-pi-text').value, null));

  async function examine(content, fileName) {
    const host = $('.rq-pi-plan');
    const text = content.replace(/^﻿/, '');
    if (!text.trim()) { store.toast('Le pack est vide.', 'warn'); return; }
    if (text.length > st.maxLength) { store.toast('Pack trop volumineux (900 000 caractères au plus).', 'warn'); return; }
    host.innerHTML = `<div aria-busy="true">${skLines(70, 90, 80)}</div>`;
    const res = await store.call('requetes.pack.examine', { content: text });
    if (!store.alive) return;
    if (res.error) { st.plan = null; host.innerHTML = emptyState('alert', 'Pack refusé', res.message); return; }
    st.plan = res.data;
    st.choices = Object.fromEntries(st.plan.items.map((i) => [i.id, i.defaultAction]));
    renderPlan(fileName);
  }

  function renderPlan(fileName) {
    const p = st.plan;
    const host = $('.rq-pi-plan');
    const counts = p.items.reduce((acc, i) => { acc[i.status] = (acc[i.status] ?? 0) + 1; return acc; }, {});
    host.innerHTML = `<div class="rq-plan-card">
      <header><div><b>${esc(p.packName ?? 'Pack sans nom')}${p.packVersion ? ` · v${esc(String(p.packVersion))}` : ''}</b>
        <span>${esc(fileName ?? 'Contenu collé')} · ${esc(p.format)}${p.exportedAt ? ` · exporté le ${esc(dateText(p.exportedAt))}` : ''}${p.origin ? ` · origine déclarée : ${esc(p.origin)}` : ''}</span></div>
        <span class="k-pill ${p.verified ? 'ok' : 'warn'} sm">${glyph(p.verified ? 'shield' : 'alert')}${esc(p.integrity)}</span></header>
      ${p.previousVersion ? `<p class="rq-note">${glyph('history')}Version déjà importée de ce pack : ${esc(String(p.previousVersion))}${p.previousVersion >= p.packVersion ? ' (ce pack n’est pas plus récent)' : ''}.</p>` : ''}
      <div class="rq-plan-counts">${Object.entries(counts).map(([s, n]) => `<span class="k-pill ${STATUS_TONE[s] ?? 'info'} sm">${esc(p.items.find((i) => i.status === s)?.statusLabel ?? s)} · ${n}</span>`).join('')}</div>
      <div class="rq-plan-bulk"><button type="button" class="btn xs ghost" data-bulk="create">Créer toutes les nouvelles</button><button type="button" class="btn xs ghost" data-bulk="copy">Copier tous les conflits</button><button type="button" class="btn xs ghost" data-bulk="ignore">Tout ignorer</button></div>
      <ol class="rq-plan-items">${p.items.map((i, n) => `<li data-i="${n}" data-status="${esc(i.status)}">
        <div class="rq-plan-main"><b>${esc(i.name)}</b><span class="k-pill ${STATUS_TONE[i.status] ?? 'info'} sm">${esc(i.statusLabel)}</span><small>${esc(i.changeSummary)}</small>
          ${i.changes.length ? `<details class="rq-plan-diff"><summary>${plural(i.changes.length, 'différence', 'différences')}</summary><ul class="rq-diff">${i.changes.map((c) => `<li><b>${esc(c.element)}</b><span class="rq-before">${esc(c.before || '—')}</span>${glyph('chevronRight')}<span class="rq-after">${esc(c.after || '—')}</span></li>`).join('')}</ul></details>` : ''}</div>
        <div class="segmented sm rq-plan-choice" role="radiogroup" aria-label="Sort de ${esc(i.name)}">${i.allowedActions.map((a) => `<button type="button" role="radio" data-item="${esc(i.id)}" data-action="${a}" aria-checked="${st.choices[i.id] === a}">${esc(ACTION_LABEL[a] ?? a)}</button>`).join('')}</div>
      </li>`).join('')}</ol>
      <div class="rq-save-actions"><button type="button" class="btn primary rq-pi-apply">${glyph('check')}Appliquer les choix…</button><span class="rq-note rq-pi-sum"></span></div>
    </div>`;
    vars(host);
    summarize();
  }

  function summarize() {
    const n = Object.values(st.choices).filter((a) => a !== 'ignore').length;
    const sum = $('.rq-pi-sum');
    if (sum) sum.textContent = n ? `${plural(n, 'requête sera écrite', 'requêtes seront écrites')} dans la bibliothèque locale.` : 'Aucune requête retenue : rien ne sera écrit.';
    const apply = $('.rq-pi-apply');
    if (apply) apply.disabled = n === 0;
  }

  $('.rq-pi-plan').addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const choice = t?.closest('[data-action]');
    if (choice) {
      st.choices[choice.dataset.item] = choice.dataset.action;
      choice.parentElement.querySelectorAll('[data-action]').forEach((b) => b.setAttribute('aria-checked', String(b === choice)));
      summarize();
      return;
    }
    const bulk = t?.closest('[data-bulk]');
    if (bulk) {
      for (const i of st.plan.items) {
        const want = bulk.dataset.bulk;
        if (want === 'ignore' || i.allowedActions.includes(want)) st.choices[i.id] = i.allowedActions.includes(want) ? want : st.choices[i.id];
      }
      renderPlan(null);
      return;
    }
    if (t?.closest('.rq-pi-apply')) apply();
  });

  async function apply() {
    if (!st.plan || st.busy) return;
    const chosen = st.plan.items.filter((i) => st.choices[i.id] !== 'ignore');
    const ok = await confirmDialog({
      title: `Importer ${plural(chosen.length, 'requête', 'requêtes')} ?`,
      message: `${chosen.map((i) => `${ACTION_LABEL[st.choices[i.id]]} « ${i.name} »`).slice(0, 8).join(' ; ')}${chosen.length > 8 ? ' ; …' : ''}. Un point de restauration est gardé ; rien n’est écrit dans l’annuaire.`,
      confirmLabel: 'Importer',
      icon: 'folder',
    });
    if (!ok) return;
    st.busy = true;
    const res = await store.call('requetes.pack.apply', { examinationId: st.plan.examinationId, choices: st.choices });
    st.busy = false;
    if (!store.alive) return;
    if (res.error) { store.toast(res.message, 'warn'); return; }
    const r = res.data;
    const readBack = r.receipt?.readBack ?? true;
    $('.rq-pi-plan').innerHTML = `<div class="rq-receipt ${readBack ? 'ok' : 'warn'} pop" role="status"><span class="rq-receipt-mark">${glyph(readBack ? 'check' : 'alert')}</span>
      <div class="rq-receipt-text"><b>Import appliqué : ${esc([r.created ? plural(r.created, 'créée', 'créées') : '', r.replaced ? plural(r.replaced, 'remplacée', 'remplacées') : '', r.copied ? plural(r.copied, 'copie', 'copies') : '', r.ignored ? plural(r.ignored, 'ignorée', 'ignorées') : ''].filter(Boolean).join(', '))}</b>
      <span>${esc(r.receipt?.text ?? 'Aucune requête écrite.')}</span></div></div>`;
    st.plan = null;
    store.emit('saved', store.saved);
    loadPersonal();
    loadHistory();
  }

  // ---------- History ----------

  async function loadHistory() {
    const host = $('.rq-ph-list');
    host.innerHTML = skLines(80, 70);
    const res = await store.call('requetes.pack.history', {});
    if (!store.alive) return;
    if (res.error) { host.innerHTML = `<p class="rq-note">${esc(res.message)}</p>`; return; }
    const list = res.data;
    if (!list.length) { host.innerHTML = `<p class="rq-note">${glyph('info')}Aucun import dans cette bibliothèque.</p>`; return; }
    host.innerHTML = `<ol class="rq-ph-items">${list.map((e, n) => `<li data-i="${n}" data-kind="${esc(e.kind)}">
      <span class="rq-ph-mark">${glyph(e.kind === 'rollback' ? 'undo' : 'folder')}</span>
      <div><b>${esc(e.label)}</b><span>${esc(dateText(e.at))} · ${e.verified ? 'intégrité vérifiée' : 'intégrité non vérifiée'}</span>
        <small>${e.items.slice(0, 6).map((i) => `${esc(i.name)}${i.created ? ' (créée)' : ''}`).join(', ')}${e.items.length > 6 ? ', …' : ''}</small></div>
      <button type="button" class="btn xs subtle" data-rollback="${esc(e.importId)}">${glyph('undo')}${e.kind === 'rollback' ? 'Reprendre la restauration' : 'Restaurer avant cet import'}</button></li>`).join('')}</ol>`;
    vars(host);
  }

  $('.rq-ph-list').addEventListener('click', async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-rollback]') : null;
    if (!b) return;
    const ok = await confirmDialog({ title: 'Restaurer la bibliothèque ?', message: 'Les définitions remplacées par cet import sont remises et les requêtes créées sont retirées. Une requête modifiée depuis est refusée et signalée.', confirmLabel: 'Restaurer', icon: 'undo' });
    if (!ok) return;
    const res = await store.call('requetes.pack.rollback', { importId: b.dataset.rollback });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    const { restored, refused } = res.data;
    store.toast(`Restauration : ${plural(restored, 'requête remise', 'requêtes remises')}${refused ? `, ${plural(refused, 'refusée', 'refusées')} (modifiée depuis l’import)` : ''}.`, refused ? 'warn' : 'ok');
    store.emit('saved', store.saved);
    loadPersonal();
    loadHistory();
  });
  $('.rq-ph-refresh').addEventListener('click', loadHistory);

  const stopReveal = reveal(panel);
  loadPersonal();
  loadHistory();
  proposeVersion();

  return {
    destroy() {
      stopReveal();
    },
  };
}
