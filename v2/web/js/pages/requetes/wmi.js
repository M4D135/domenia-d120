// « WMI avancé »: one workstation at a time, every remote read after an explicit gesture and a confirmation (once per
// workstation and session for the metadata, every time for a SELECT or a relation). Namespaces one level at a time, class
// definitions, the schema of one class (secret properties left out), a SELECT prepared from the checked properties or
// typed in a closed grammar, analysed locally, run on the chosen workstation, related instances through declared relations
// only, a local recipe made from a tested SELECT, and the results of the SELECT memorised on every workstation (pages of 250).
// Metadata already read are reused with their date. Until a workstation is chosen, the steps stay folded.
import {
  esc, glyph, plural, emptyState, skLines, dateText, vars, ago,
} from './shared.js';
import { createGrid, confirmDialog, debounce } from '../../kit/index.js';
import { formatNumber } from '../../ui.js';
import { reveal } from '../../ui.js';

const ROOT = 'root\\cimv2';

export function mountWmi(panel, store, api, { computerName = null } = {}) {
  const st = {
    computer: null, ns: ROOT, classes: [], filter: '', className: null, schema: null, checked: new Set(), result: null, related: null,
    relations: [], grid: null, relGrid: null, activeRow: null, findToken: 0, confirmed: new Set(), stored: { key: null, offset: 0 },
  };
  panel.innerHTML = `<div class="rq-wmi" data-stage="pick">
    <div class="rq-wmi-banner" role="note">${glyph('shield')}<p><b>Lecture distante explicite.</b> Chaque bouton marqué ${glyph('wifi')} lit le poste choisi, et lui seul ; aucune écriture, aucune méthode WMI appelée, propriétés de secret écartées.</p></div>
    <div class="grid rq-wmi-top">
      <section class="card span-4 rq-wmi-pc spot reveal" aria-labelledby="rq-wp-title">
        <div class="card-head"><span class="rq-flow-n">1</span><div class="rq-head-titles"><h3 id="rq-wp-title">Poste interrogé</h3><p class="rq-sub">Choisi dans la base locale.</p></div></div>
        <label class="rq-search">${glyph('search')}<input type="search" class="input rq-wp-find" maxlength="100" placeholder="Nom du poste…" aria-label="Chercher un poste" autocomplete="off"></label>
        <ul class="rq-t-found rq-wp-found" role="listbox" aria-label="Postes trouvés"></ul>
        <div class="rq-wp-chosen"></div>
      </section>
      <section class="card span-8 rq-wmi-steps spot reveal" aria-label="Étapes suivantes">
      <div class="card-head"><span class="card-icon">${glyph('chip')}</span><div class="rq-head-titles"><h3>Ensuite, sur ce seul poste</h3><p class="rq-sub">Chaque lecture distante demande votre accord ; rien n’est écrit.</p></div></div>
      <ol class="rq-wsteps">
        <li><span class="rq-flow-n">2</span><div><b>Espace de noms et classe</b><span>Un niveau à la fois, 500 espaces et 2 000 classes au plus.</span></div></li>
        <li><span class="rq-flow-n">3</span><div><b>Propriétés</b><span>Schéma de la classe, propriétés de secret écartées.</span></div></li>
        <li><span class="rq-flow-n">4</span><div><b>SELECT WQL</b><span>Grammaire fermée, analysé localement avant toute lecture.</span></div></li>
        <li><span class="rq-flow-n">5</span><div><b>Instances lues</b><span>Relations déclarées seulement, puis recette sur les résultats mémorisés.</span></div></li>
      </ol>
    </section>
      <section class="card span-4 rq-wmi-ns spot reveal" aria-labelledby="rq-wn-title">
        <div class="card-head"><span class="rq-flow-n">2</span><div class="rq-head-titles"><h3 id="rq-wn-title">Espace de noms et classe</h3><p class="rq-sub rq-wn-sub">root\\cimv2 par défaut.</p></div></div>
        <div class="rq-wn-path"></div>
        <div class="rq-wn-children"></div>
        <div class="rq-wn-tools"><button type="button" class="btn xs subtle rq-wn-read" data-net>${glyph('wifi')}Lire les espaces enfants</button></div>
        <label class="rq-search">${glyph('filter')}<input type="search" class="input rq-wc-filter" maxlength="128" placeholder="Classe (Win32_Disk*)…" aria-label="Filtre de classe" autocomplete="off" spellcheck="false"></label>
        <div class="rq-wn-tools"><button type="button" class="btn xs subtle rq-wc-read" data-net>${glyph('wifi')}Lire les classes</button><span class="rq-note rq-wc-meta"></span></div>
        <ul class="rq-wc-list" role="listbox" aria-label="Classes"></ul>
      </section>
      <section class="card span-4 rq-wmi-schema spot reveal" aria-labelledby="rq-ws-title">
        <div class="card-head"><span class="rq-flow-n">3</span><div class="rq-head-titles"><h3 id="rq-ws-title">Propriétés</h3><p class="rq-sub rq-ws-sub">Lisez le schéma d’une classe.</p></div></div>
        <div class="rq-ws-body"></div>
      </section>
    </div>
    <div class="grid">
      <section class="card span-7 rq-wmi-select spot reveal" aria-labelledby="rq-wq-title">
        <div class="card-head"><span class="rq-flow-n">4</span><div class="rq-head-titles"><h3 id="rq-wq-title">SELECT WQL</h3><p class="rq-sub">Grammaire fermée : propriétés explicites, une classe, WHERE simple.</p></div>
          <label class="rq-limit">Instances au plus<input type="number" class="input sm rq-wq-limit" min="1" max="2000" value="100"></label></div>
        <textarea class="input rq-mono rq-wq-text" rows="4" maxlength="8192" spellcheck="false" aria-label="Requête WQL" placeholder="SELECT Name, FreeSpace, Size FROM Win32_LogicalDisk WHERE DriveType = 3"></textarea>
        <div class="rq-save-actions">
          <button type="button" class="btn subtle rq-wq-analyze">${glyph('search')}Analyser localement</button>
          <button type="button" class="btn primary rq-wq-run" data-net>${glyph('play')}Exécuter sur le poste…</button>
          <span class="rq-spacer"></span>
          <button type="button" class="btn ghost rq-wq-recipe">${glyph('star')}En faire une recette</button>
        </div>
      </section>
      <section class="card span-5 rq-wmi-report spot reveal" aria-labelledby="rq-wr-title">
        <div class="card-head"><span class="card-icon">${glyph('shield')}</span><div class="rq-head-titles"><h3 id="rq-wr-title">Analyse</h3><p class="rq-sub">Avant toute lecture distante.</p></div></div>
        <div class="rq-wr-body"><p class="rq-note">${glyph('info')}Écrivez ou préparez un SELECT puis « Analyser localement ».</p></div>
      </section>
    </div>
    <section class="card rq-wmi-result spot reveal" aria-labelledby="rq-wx-title">
      <div class="card-head"><span class="rq-flow-n">5</span><div class="rq-head-titles"><h3 id="rq-wx-title">Instances lues</h3><p class="rq-sub rq-wx-sub">Aucun SELECT exécuté.</p></div>
        <span class="meta rq-wx-meta"></span></div>
      <div class="rq-wx-grid"><div class="rq-wx-empty">${glyph('chip')}<p><b>Aucune instance lue</b>Préparez un SELECT à partir du schéma ou écrivez-le, analysez-le, puis exécutez-le sur le poste choisi : les instances s’affichent ici, avec les relations déclarées.</p></div></div>
      <div class="rq-wx-rel"></div>
    </section>
    <section class="card rq-wmi-stored spot reveal" aria-labelledby="rq-wm-title">
      <div class="card-head"><span class="card-icon">${glyph('database')}</span><div class="rq-head-titles"><h3 id="rq-wm-title">Résultats mémorisés des SELECT</h3>
        <p class="rq-sub rq-wm-sub">Nombre d’instances gardé pour chaque poste où un SELECT a été exécuté : source des informations « SELECT mémorisé ».</p></div>
        <span class="meta"><button type="button" class="btn xs subtle rq-wm-refresh">${glyph('refresh')}Actualiser</button></span></div>
      <div class="rq-wm-defs"></div>
      <div class="rq-wm-rows"></div>
    </section>
  </div>`;
  const $ = (sel) => panel.querySelector(sel);

  function needComputer() {
    if (st.computer) return true;
    store.toast('Choisissez d’abord le poste à interroger.', 'warn');
    $('.rq-wp-find').focus();
    return false;
  }

  function netDisabled() {
    panel.querySelectorAll('[data-net]').forEach((b) => { b.disabled = !st.computer; b.title = st.computer ? '' : 'Choisissez d’abord un poste'; });
    $('.rq-wq-recipe').disabled = !st.computer;
    panel.querySelector('.rq-wmi').dataset.stage = st.computer ? 'work' : 'pick';
  }

  /**
   * Domenia 1 asks before any remote read of WMI metadata: once per workstation and session here (the SELECT and the
   * relations still confirm each time), with the reminder of the read-only rule.
   */
  async function allowRead(what) {
    if (st.confirmed.has(st.computer.id)) return true;
    const ok = await confirmDialog({
      title: `Lire WMI sur ${st.computer.name} ?`,
      message: `${what} : lecture distante du seul poste ${st.computer.name}, en lecture seule (aucune méthode WMI appelée, propriétés de secret écartées). Les lectures de métadonnées suivantes sur ce poste ne redemanderont pas pendant cette session.`,
      confirmLabel: 'Lire sur ce poste',
      icon: 'wifi',
    });
    if (ok) st.confirmed.add(st.computer.id);
    return ok;
  }

  // ---------- 1. Computer ----------

  const find = debounce(async () => {
    const text = $('.rq-wp-find').value.trim();
    const list = $('.rq-wp-found');
    if (text.length < 2) { list.innerHTML = ''; return; }
    const my = ++st.findToken;
    const res = await store.call('requetes.objects.find', { text, target: 'computer' });
    if (!store.alive || my !== st.findToken) return;
    if (res.error) { list.innerHTML = `<li class="rq-note">${esc(res.message)}</li>`; return; }
    list.innerHTML = res.data.length ? res.data.map((o, n) => `<li role="option" tabindex="-1" data-n="${n}" data-i="${n}"><span class="avatar pc">${glyph('monitor')}</span>
      <div><b>${esc(o.name)}</b><span>${esc(o.os ?? '')}${o.presence ? ` · ${esc(o.presence)}` : ''}</span></div>${o.active === false ? '<span class="k-pill off sm">Désactivé</span>' : ''}</li>`).join('')
      : `<li class="rq-note">Aucun poste dont le nom contient « ${esc(text)} ».</li>`;
    list.found = res.data;
    vars(list);
  }, 250);
  $('.rq-wp-find').addEventListener('input', find);
  $('.rq-wp-found').addEventListener('click', (e) => {
    const li = e.target instanceof Element ? e.target.closest('[data-n]') : null;
    if (li) choose($('.rq-wp-found').found[Number(li.dataset.n)]);
  });
  $('.rq-wp-found').addEventListener('keydown', (e) => {
    const items = [...panel.querySelectorAll('.rq-wp-found [data-n]')];
    const at = items.indexOf(document.activeElement);
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); items[Math.max(0, Math.min(items.length - 1, at + (e.key === 'ArrowDown' ? 1 : -1)))]?.focus(); }
    if (e.key === 'Enter' && at >= 0) choose($('.rq-wp-found').found[at]);
  });
  $('.rq-wp-find').addEventListener('keydown', (e) => { if (e.key === 'ArrowDown') { e.preventDefault(); $('.rq-wp-found [data-n]')?.focus(); } });

  async function choose(pc) {
    if (!pc) return;
    st.computer = pc;
    st.classes = [];
    st.schema = null;
    st.className = null;
    st.checked.clear();
    $('.rq-wp-found').innerHTML = '';
    $('.rq-wp-find').value = '';
    $('.rq-wp-chosen').innerHTML = `<div class="rq-pc-card pop"><span class="avatar pc">${glyph('monitor')}</span><div><b>${esc(pc.name)}</b><span class="rq-mono">${esc(pc.dn)}</span>
      <small>${esc(pc.os ?? '')}${pc.active === false ? ' · compte désactivé' : ''}</small></div></div>`;
    netDisabled();
    await fromCache();
    renderNs();
    renderClasses();
    renderSchema();
  }

  async function fromCache() {
    if (!st.computer) return;
    const res = await store.call('requetes.wmi.cache', { computer: st.computer.id, namespace: st.ns, className: st.className, filter: st.filter || null });
    if (res.error || !store.alive) return;
    const c = res.data;
    st.children = c.namespaces;
    if (c.classes) { st.classes = c.classes.classes; st.classMeta = c.classes; }
    if (c.schema) st.schema = c.schema;
    if (c.tested) $('.rq-wx-meta').innerHTML = `<span class="k-pill ok sm">${glyph('check')}Testé ${esc(ago(c.tested.at))} · ${esc(c.tested.className)}</span>`;
  }

  // ---------- 2. Namespaces and classes ----------

  function renderNs() {
    const parts = st.ns.split('\\');
    $('.rq-wn-path').innerHTML = `<ol class="rq-crumbs">${parts.map((p, n) => `<li><button type="button" class="rq-crumb${n === parts.length - 1 ? ' now' : ''}" data-ns="${esc(parts.slice(0, n + 1).join('\\'))}">${esc(p)}</button></li>`).join('')}</ol>`;
    $('.rq-wn-sub').textContent = st.ns;
    const ch = st.children;
    $('.rq-wn-children').innerHTML = ch ? `${ch.children.length ? `<div class="rq-ns-chips">${ch.children.map((c, n) => `<button type="button" class="chip sm rq-ns-chip" data-child="${esc(c)}" data-i="${n}">${glyph('folder')}${esc(c)}</button>`).join('')}</div>` : '<p class="rq-note">Aucun espace enfant.</p>'}
      <p class="rq-note">${glyph('clock')}Lu ${esc(ago(ch.readAt))}${ch.truncated ? ' · liste tronquée à 500' : ''}</p>` : '';
    vars($('.rq-wn-children'));
  }

  $('.rq-wn-path').addEventListener('click', async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-ns]') : null;
    if (!b || b.dataset.ns === st.ns) return;
    await setNs(b.dataset.ns);
  });
  $('.rq-wn-children').addEventListener('click', async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-child]') : null;
    if (b) await setNs(`${st.ns}\\${b.dataset.child}`);
  });

  async function setNs(ns) {
    st.ns = ns;
    st.children = null;
    st.classes = [];
    st.classMeta = null;
    st.className = null;
    st.schema = null;
    st.checked.clear();
    await fromCache();
    renderNs();
    renderClasses();
    renderSchema();
  }

  $('.rq-wn-read').addEventListener('click', async () => {
    if (!needComputer() || !(await allowRead(`Espaces de noms enfants de ${st.ns}`))) return;
    const b = $('.rq-wn-read');
    b.classList.add('busy');
    const res = await store.call('requetes.wmi.namespaces', { computer: st.computer.id, namespace: st.ns });
    b.classList.remove('busy');
    if (res.error) { store.toast(res.message, 'warn'); return; }
    st.children = res.data;
    renderNs();
  });

  function renderClasses() {
    const list = $('.rq-wc-list');
    const meta = st.classMeta;
    $('.rq-wc-meta').textContent = meta ? `${plural(meta.classes.length, 'classe', 'classes')} · lues ${ago(meta.readAt)}${meta.truncated ? ' · tronqué à 2 000' : ''}` : '';
    if (!st.classes.length) { list.innerHTML = meta ? '<li class="rq-note">Aucune classe pour ce filtre.</li>' : ''; return; }
    list.innerHTML = st.classes.slice(0, 600).map((c, n) => `<li role="option" tabindex="-1" data-class="${esc(c.name)}" aria-selected="${c.name === st.className}" data-i="${Math.min(n, 20)}">
      <b>${esc(c.name)}</b><span>${plural(c.properties, 'propriété', 'propriétés')}${c.keys ? ` · ${plural(c.keys, 'clé', 'clés')}` : ''}${c.remark ? ` · ${esc(c.remark)}` : ''}</span></li>`).join('');
    vars(list);
  }

  async function readClasses() {
    if (!needComputer()) return;
    st.filter = $('.rq-wc-filter').value.trim();
    if (!(await allowRead(`Classes de ${st.ns}${st.filter ? ` (filtre ${st.filter})` : ''}`))) return;
    const b = $('.rq-wc-read');
    b.classList.add('busy');
    const res = await store.call('requetes.wmi.classes', { computer: st.computer.id, namespace: st.ns, filter: st.filter || null });
    b.classList.remove('busy');
    if (res.error) { store.toast(res.message, 'warn'); return; }
    st.classMeta = res.data;
    st.classes = res.data.classes;
    renderClasses();
  }
  $('.rq-wc-read').addEventListener('click', readClasses);
  $('.rq-wc-filter').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); readClasses(); } });
  $('.rq-wc-list').addEventListener('click', (e) => {
    const li = e.target instanceof Element ? e.target.closest('[data-class]') : null;
    if (!li) return;
    st.className = li.dataset.class;
    panel.querySelectorAll('.rq-wc-list [data-class]').forEach((x) => x.setAttribute('aria-selected', String(x === li)));
    st.schema = null;
    st.checked.clear();
    fromCache().then(renderSchema);
  });

  // ---------- 3. Schema ----------

  function renderSchema() {
    const host = $('.rq-ws-body');
    if (!st.className) {
      host.innerHTML = `<div class="rq-ws-empty">${glyph('layers')}<p>Choisissez une classe dans la liste, puis lisez son schéma sur le poste.</p></div>`;
      $('.rq-ws-sub').textContent = 'Lisez le schéma d’une classe.';
      return;
    }
    const s = st.schema;
    if (!s) {
      host.innerHTML = `<div class="rq-ws-empty">${glyph('chip')}<p><b>${esc(st.className)}</b>Schéma non lu pour ce poste.</p>
        <button type="button" class="btn subtle sm rq-ws-read" data-net>${glyph('wifi')}Lire le schéma</button></div>`;
      host.querySelector('.rq-ws-read').addEventListener('click', readSchema);
      netDisabled();
      return;
    }
    $('.rq-ws-sub').textContent = `${s.className} · ${plural(s.properties.length, 'propriété', 'propriétés')} · lu ${ago(s.readAt)}`;
    host.innerHTML = `${s.description ? `<p class="rq-note">${esc(s.description)}</p>` : ''}
      <div class="rq-ws-tools"><button type="button" class="btn xs ghost" data-ws="keys">Cocher les clés</button><button type="button" class="btn xs ghost" data-ws="none">Tout décocher</button>
        <span class="rq-spacer"></span><button type="button" class="btn xs primary" data-ws="build">${glyph('edit')}Préparer le SELECT</button></div>
      <ul class="rq-ws-props">${s.properties.map((p, n) => `<li data-i="${Math.min(n, 24)}"><label class="rq-check"><input type="checkbox" class="k-checkbox" data-prop="${esc(p.name)}"${st.checked.has(p.name) ? ' checked' : ''}>
        <span><b>${esc(p.name)}${p.key ? ' <span class="k-badge accent">clé</span>' : ''}</b><small>${esc(p.cimType)}${p.unit ? ` · ${esc(p.unit)}` : ''}${p.description ? ` · ${esc(p.description)}` : ''}</small></span></label></li>`).join('')}</ul>
      ${s.secretsLeftOut.length ? `<p class="rq-note">${glyph('lock')}Écartées (secret) : ${esc(s.secretsLeftOut.join(', '))}</p>` : ''}`;
    vars(host);
  }

  async function readSchema() {
    if (!needComputer() || !st.className || !(await allowRead(`Schéma de la classe ${st.className}`))) return;
    const res = await store.call('requetes.wmi.schema', { computer: st.computer.id, namespace: st.ns, className: st.className });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    st.schema = res.data;
    st.checked = new Set(res.data.properties.filter((p) => p.key).map((p) => p.name));
    renderSchema();
  }

  $('.rq-ws-body').addEventListener('change', (e) => {
    const box = e.target instanceof HTMLInputElement ? e.target : null;
    if (!box?.dataset.prop) return;
    if (box.checked) st.checked.add(box.dataset.prop); else st.checked.delete(box.dataset.prop);
  });
  $('.rq-ws-body').addEventListener('click', async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-ws]') : null;
    if (!b) return;
    if (b.dataset.ws === 'keys') { st.schema.properties.filter((p) => p.key).forEach((p) => st.checked.add(p.name)); renderSchema(); }
    if (b.dataset.ws === 'none') { st.checked.clear(); renderSchema(); }
    if (b.dataset.ws === 'build') {
      const res = await store.call('requetes.wmi.build', { computer: st.computer.id, namespace: st.ns, className: st.className, properties: [...st.checked] });
      if (res.error) { store.toast(res.message, 'warn'); return; }
      $('.rq-wq-text').value = res.data.query;
      $('.rq-wq-text').classList.remove('flash');
      void $('.rq-wq-text').offsetWidth;
      $('.rq-wq-text').classList.add('flash');
      analyze();
    }
  });

  // ---------- 4. SELECT ----------

  const limit = () => Math.max(1, Math.min(2000, Number($('.rq-wq-limit').value) || 100));

  async function analyze() {
    const query = $('.rq-wq-text').value.trim();
    const host = $('.rq-wr-body');
    if (!query) { host.innerHTML = `<p class="rq-note">${glyph('info')}Écrivez ou préparez un SELECT.</p>`; return null; }
    const res = await store.call('requetes.wmi.analyze', { ...(st.computer ? { computer: st.computer.id, computerName: st.computer.name } : {}), namespace: st.ns, query, limit: limit() });
    if (res.error) { host.innerHTML = emptyState('alert', 'Analyse impossible', res.message); return null; }
    const r = res.data;
    const list = (title, items, icon) => (items?.length ? `<h5 class="rq-mini-title">${esc(title)}</h5><ul class="rq-wr-list">${items.map((x) => `<li>${glyph(icon)}${esc(x)}</li>`).join('')}</ul>` : '');
    host.innerHTML = `<div class="rq-wr ${r.valid ? 'ok' : 'err'}">
      <p class="rq-wr-head">${glyph(r.valid ? 'check' : 'alert')}<b>${esc(r.message)}</b></p>
      ${r.valid ? `<code class="rq-mono rq-wr-canon">${esc(r.canonicalQuery)}</code>
        <div class="rq-wr-props">${r.properties.map((p) => `<span class="chip sm${r.keyProperties.includes(p) ? ' key' : ''}${r.missingProperties.includes(p) ? ' missing' : ''}">${esc(p)}</span>`).join('')}</div>` : ''}
      ${list('Préconditions', r.preconditions, 'shield')}${list('Limites', r.limits, 'gauge')}${list('Prudence', r.warnings, 'alert')}
      <p class="rq-wr-ready ${r.ready ? 'ok' : ''}">${glyph(r.ready ? 'check' : 'clock')}${esc(r.readyText)}</p></div>`;
    return r;
  }
  $('.rq-wq-analyze').addEventListener('click', analyze);

  $('.rq-wq-run').addEventListener('click', async () => {
    if (!needComputer()) return;
    const report = await analyze();
    if (!report?.valid) { store.toast('Le SELECT est refusé : voir l’analyse.', 'warn'); return; }
    const ok = await confirmDialog({
      title: `Exécuter sur ${st.computer.name} ?`,
      message: `${report.canonicalQuery} — lecture WMI du seul poste ${st.computer.name}, ${limit()} instances au plus, dans ${st.ns}. Aucune écriture.`,
      confirmLabel: 'Exécuter la lecture',
      icon: 'wifi',
    });
    if (!ok) return;
    const b = $('.rq-wq-run');
    b.classList.add('busy');
    $('.rq-wx-grid').setAttribute('aria-busy', 'true');
    const res = await store.call('requetes.wmi.run', { computer: st.computer.id, namespace: st.ns, query: $('.rq-wq-text').value.trim(), limit: limit() });
    b.classList.remove('busy');
    $('.rq-wx-grid').removeAttribute('aria-busy');
    if (!store.alive) return;
    if (res.error) { store.toast(res.message, 'warn'); return; }
    st.result = res.data;
    renderResult();
    analyze();
    loadStored();
  });

  function columnsOf(result) {
    return result.columns.map((c, n) => ({ id: c, label: c, width: n === 0 ? 220 : 170, get: (r) => r.values?.[c] ?? null }));
  }

  function renderResult() {
    const r = st.result;
    $('.rq-wx-sub').textContent = `${r.className} sur ${r.computer} · ${plural(r.rows.length, 'instance', 'instances')}${r.truncated ? ` sur ${r.count} (partiel)` : ''} · lu ${dateText(r.readAt)}`;
    $('.rq-wx-meta').innerHTML = `<span class="k-pill ${r.truncated ? 'warn' : 'ok'} sm">${glyph(r.truncated ? 'alert' : 'check')}${r.truncated ? 'Résultat partiel' : 'Testé sur ce poste'}</span>`;
    st.grid?.destroy();
    st.grid = createGrid($('.rq-wx-grid'), {
      key: `requetes.wmi.${r.className}`,
      label: `Instances de ${r.className}`,
      columns: columnsOf(r),
      rowId: (row) => row.id,
      rows: r.rows,
      selection: 'single',
      height: '360px',
      empty: { icon: 'chip', title: 'Aucune instance', text: 'Le SELECT n’a renvoyé aucune instance sur ce poste.' },
      onActiveChange: (row) => { st.activeRow = row; paintRelations(); },
    });
    loadRelations(r.className);
  }

  async function loadRelations(className) {
    const res = await store.call('requetes.wmi.relations', { className });
    st.relations = res.error ? [] : res.data;
    paintRelations();
  }

  function paintRelations() {
    const host = $('.rq-wx-rel');
    if (!st.result) { host.innerHTML = ''; return; }
    if (!st.relations.length) { host.innerHTML = `<p class="rq-note">${glyph('info')}Aucune relation déclarée depuis ${esc(st.result.className)}.</p>`; return; }
    host.innerHTML = `<div class="rq-rel"><h5 class="rq-mini-title">Relations déclarées</h5>
      <p class="rq-note">${st.activeRow ? `Depuis l’instance choisie : ${esc(Object.values(st.activeRow.values ?? {})[0] ?? st.activeRow.id)}` : 'Choisissez une instance dans le tableau.'}</p>
      <div class="rq-rel-list">${st.relations.map((p) => `<button type="button" class="rq-rel-btn" data-preset="${esc(p.id)}"${st.activeRow ? '' : ' disabled'}>${glyph('link')}<b>${esc(p.label)}</b><span>${esc(p.result)} · ${esc(p.kind)}</span></button>`).join('')}</div>
      <div class="rq-rel-grid"></div></div>`;
    host.querySelectorAll('[data-preset]').forEach((b) => b.addEventListener('click', () => related(b.dataset.preset)));
  }

  async function related(preset) {
    if (!st.activeRow) return;
    const p = st.relations.find((x) => x.id === preset);
    const ok = await confirmDialog({ title: `${p?.label ?? 'Relation'} ?`, message: `Lecture WMI des instances liées sur ${st.computer.name}, par la relation déclarée « ${p?.label ?? preset} ». Aucune jointure libre, aucune écriture.`, confirmLabel: 'Lire les instances liées', icon: 'link' });
    if (!ok) return;
    const res = await store.call('requetes.wmi.relation', { computer: st.computer.id, namespace: st.ns, preset, rowId: st.activeRow.id });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    const r = res.data;
    st.relGrid?.destroy();
    const host = $('.rq-rel-grid');
    host.innerHTML = `<p class="rq-note">${esc(r.className)} · ${plural(r.rows.length, 'instance liée', 'instances liées')}${r.note ? ` · ${esc(r.note)}` : ''}</p><div></div>`;
    st.relGrid = createGrid(host.lastElementChild, { key: `requetes.wmi.rel.${r.className}`, label: `Instances liées de ${r.className}`, columns: columnsOf(r), rowId: (row) => row.id, rows: r.rows, selection: 'none', height: '260px', toolbar: false });
  }

  // ---------- Recipe ----------

  $('.rq-wq-recipe').addEventListener('click', async () => {
    if (!needComputer()) return;
    const query = $('.rq-wq-text').value.trim();
    if (!query) { store.toast('Écrivez ou préparez un SELECT.', 'warn'); return; }
    const res = await store.call('requetes.wmi.recipe', { computer: st.computer.id, namespace: st.ns, query, limit: limit(), name: null });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    api.loadRecipe(res.data.recipe, { origin: 'load', saved: null });
    store.toast(res.data.text, 'ok');
    api.goto('creer');
  });

  // ---------- Memorised results (no remote read) ----------

  async function loadStored() {
    const defs = $('.rq-wm-defs');
    const rowsHost = $('.rq-wm-rows');
    rowsHost.setAttribute('aria-busy', 'true');
    const res = await store.call('requetes.details.list', { requestKey: st.stored.key, offset: st.stored.offset, limit: 250 });
    rowsHost.removeAttribute('aria-busy');
    if (!store.alive) return;
    if (res.error) { rowsHost.innerHTML = `<p class="rq-note">${esc(res.message)}</p>`; return; }
    const d = res.data;
    defs.innerHTML = d.definitions.length ? `<div class="rq-wm-chips" role="group" aria-label="SELECT mémorisés">
      <button type="button" class="chip sm" data-key="" aria-pressed="${st.stored.key === null}">Tous les SELECT</button>
      ${d.definitions.map((x) => `<button type="button" class="chip sm" data-key="${esc(x.requestKey)}" aria-pressed="${st.stored.key === x.requestKey}" data-tip="${esc(x.query ?? `Clé ${x.requestKey.slice(0, 12)}…`)}">${glyph('chip')}${esc(x.className ?? 'SELECT')}<b>${formatNumber(x.computers)}</b></button>`).join('')}</div>` : '';
    if (!d.rows.length) {
      rowsHost.innerHTML = `<div class="rq-wx-empty">${glyph('database')}<p><b>Aucun résultat mémorisé</b>Exécutez un SELECT sur un poste (étape 4) ou relevez celui d’une recette enregistrée par « Collecter les données manquantes ».</p></div>`;
      return;
    }
    rowsHost.innerHTML = `<div class="rq-table-wrap"><table class="table rq-table rq-wm-table"><thead><tr><th>Poste</th><th>SELECT</th><th>Instances</th><th>Lecture</th><th>Date</th></tr></thead><tbody>
      ${d.rows.map((r, n) => `<tr data-i="${Math.min(n, 16)}"><th scope="row">${esc(r.name)}<small class="rq-mono">${esc(r.dn)}</small></th><td>${esc(r.className ?? r.requestKey.slice(0, 12))}</td>
        <td>${r.success ? (r.complete ? formatNumber(r.count) : `${formatNumber(r.count)} (partiel)`) : '—'}</td>
        <td>${r.success ? (r.complete ? '<span class="k-pill ok sm">Complète</span>' : '<span class="k-pill warn sm">Incomplète</span>') : '<span class="k-pill alert sm">Erreur</span>'}</td>
        <td>${esc(dateText(r.at))}</td></tr>`).join('')}</tbody></table></div>
      <div class="rq-pager"><button type="button" class="btn xs subtle rq-wm-prev"${d.offset ? '' : ' disabled'}>${glyph('chevronLeft')}Postes précédents</button>
        <span>${formatNumber(d.offset + 1)} à ${formatNumber(d.offset + d.rows.length)} sur ${formatNumber(d.total)}</span>
        <button type="button" class="btn xs subtle rq-wm-next"${d.hasMore ? '' : ' disabled'}>Postes suivants${glyph('chevronRight')}</button></div>`;
    vars(rowsHost);
    $('.rq-wm-sub').textContent = `${plural(d.total, 'résultat mémorisé', 'résultats mémorisés')} · ${plural(d.definitions.length, 'SELECT', 'SELECT')} · pages de 250, aucune lecture distante`;
  }
  $('.rq-wm-defs').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-key]') : null;
    if (!b) return;
    st.stored = { key: b.dataset.key || null, offset: 0 };
    loadStored();
  });
  $('.rq-wm-rows').addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (t?.closest('.rq-wm-prev')) { st.stored.offset = Math.max(0, st.stored.offset - 250); loadStored(); }
    if (t?.closest('.rq-wm-next')) { st.stored.offset += 250; loadStored(); }
  });
  $('.rq-wm-refresh').addEventListener('click', loadStored);

  netDisabled();
  renderNs();
  renderSchema();
  loadStored();
  const stopReveal = reveal(panel);
  if (computerName) {
    store.call('requetes.objects.find', { text: computerName, target: 'computer' }).then((res) => {
      if (!store.alive || res.error) return;
      const exact = res.data.find((o) => o.name.toLowerCase() === computerName.toLowerCase()) ?? res.data[0];
      if (exact) choose(exact);
    });
  }

  return {
    destroy() {
      stopReveal();
      st.grid?.destroy();
      st.relGrid?.destroy();
    },
  };
}
