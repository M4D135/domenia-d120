// Assistance · support workshop (Domenia 1 Domenia-Support, ASS-001 and ASS-003 to ASS-007): local findings of a fiche,
// comparison of two captures A and B, explained incidents of the session and pins. Memory of the session only; nothing here
// reads the network except « Relire la fiche » and « Ouvrir » a pin, on a click.
import { esc, errorText, applyVars, reveal, announce, formatDateTime } from '../../ui.js';
import { copyButton, confirmDialog } from '../../kit/index.js';
import { ico, chip, tone, avatar, empty, when, plural, clock, COLON, NBSP } from './common.js';

const LEVEL_ORDER = { attention: 0, toCheck: 1, undetermined: 2, information: 3 };
const capitalize = (text) => (text ? text[0].toLocaleUpperCase('fr') + text.slice(1) : text);
const LEVEL_ICON = { attention: 'alert', toCheck: 'eye', undetermined: 'info', information: 'info' };
const COVERAGE = { provided: ['ok', 'Fourni'], partial: ['warn', 'Partiel'], notProvided: ['off', 'Non fourni'] };
const MAX_FILE = 1_048_576;

/** Readable path of a DN, without the domain nor the object itself: « Utilisateurs › Lyon › Commercial ». */
export function dnPath(dn) {
  const parts = [];
  let cur = '';
  const text = String(dn ?? '');
  for (let n = 0; n < text.length; n++) {
    const c = text[n];
    if (c === '\\' && n + 1 < text.length) { cur += text[n + 1]; n += 1; continue; }
    if (c === ',') { parts.push(cur.trim()); cur = ''; continue; }
    cur += c;
  }
  if (cur.trim()) parts.push(cur.trim());
  return parts.slice(1).filter((p) => !/^DC=/i.test(p)).map((p) => p.slice(p.indexOf('=') + 1)).reverse().join(`${NBSP}› `);
}

function noSubject(app, what) {
  return empty('user', 'Aucune fiche à comprendre', `Choisissez le compte ou le poste concerné dans la session d’assistance${NBSP}: ${what}`,
    '<button class="btn primary" type="button" data-focus-search>Choisir un compte</button>');
}

function bindFocusSearch(host) {
  host.addEventListener('click', (e) => {
    if (e.target instanceof Element && e.target.closest('[data-focus-search]')) {
      const input = document.querySelector('.main[data-page="assistance"] .as-slot input');
      input?.focus();
      input?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }
  });
}

// ---------------------------------------------------------------- findings (ASS-003, ASS-004)

export function renderFindings(host, app) {
  const offs = [];
  let selected = null;
  let providedOnly = false;
  bindFocusSearch(host);

  function focusKind() {
    if (app.subject(app.memory.focus)) return app.memory.focus;
    return app.subject('user') ? 'user' : app.subject('computer') ? 'computer' : null;
  }

  function paint() {
    const kind = focusKind();
    const view = kind ? app.subject(kind) : null;
    if (!view) {
      host.innerHTML = `<section class="card as-panel reveal">${noSubject(app, 'Domenia analyse localement ce qui a été lu, sans nouvelle lecture ni réparation.')}</section>`;
      reveal(host);
      return;
    }
    const both = app.subject('user') && app.subject('computer');
    const findings = [...(view.findings ?? [])].sort((a, b) => (LEVEL_ORDER[a.level] ?? 9) - (LEVEL_ORDER[b.level] ?? 9));
    if (!findings.some((f) => f.code === selected)) selected = findings[0]?.code ?? null;
    const counts = Object.keys(LEVEL_ORDER).map((level) => [level, findings.filter((f) => f.level === level)]).filter(([, list]) => list.length);
    const cov = view.coverage;
    const c = view.card;
    const facts = (c.facts ?? []).map((f, n) => `<div class="as-fact ${tone(f.tone)}" data-j="${n}"><span>${esc(f.label)}</span><b>${esc(f.value)}</b></div>`).join('');
    host.innerHTML = `<div class="as-stack">
      ${both ? `<div class="as-switch reveal" role="group" aria-label="Fiche analysée">
          ${['user', 'computer'].map((k) => `<button type="button" data-kind="${k}" aria-pressed="${k === kind}">${ico(k === 'user' ? 'user' : 'monitor')}${esc(app.subject(k).card.name)}</button>`).join('')}
        </div>` : ''}
      <section class="card as-cover reveal">
        <div class="as-cover-id">${avatar(c.name, c.kind)}
          <div><span class="as-k">${esc(c.kindLabel)}${NBSP}· ${esc(cov.sourceLabel)}</span><h2>${esc(c.name)}</h2><p class="as-faint"><span class="mono">${esc(c.login)}</span>${c.path ? `${NBSP}· ${esc(c.path)}` : ''}</p></div>
          <div class="as-cover-pills">${(c.pills ?? []).map((p) => chip(tone(p.tone), p.label)).join('')}</div>
        </div>
        <div class="as-cover-actions">
            <button class="btn subtle sm" type="button" data-act="analyse" data-tip="Recalcule les constats sur la même lecture, sans rien relire">${ico('refresh')}Recalculer</button>
            <button class="btn subtle sm" type="button" data-act="reread" data-tip="Relit la fiche (geste explicite)">${ico('scan')}Relire la fiche</button>
            <button class="btn subtle sm" type="button" data-act="pin">${ico('pin')}Épingler</button>
            <button class="btn subtle sm" type="button" data-act="a">${ico('compare')}Capturer → A</button>
            <button class="btn subtle sm" type="button" data-act="b">${ico('compare')}Capturer → B</button>
        </div>
        <div class="as-coverage">
          <div class="as-coverage-head"><b>${cov.provided + cov.partial}</b><span>attributs fournis sur ${cov.total}${NBSP}· lecture ${when(cov.observedAt)}</span></div>
          <div class="as-coverage-bar" role="img" aria-label="${esc(cov.text)}">
            <span class="ok" data-grow="${cov.provided}" data-tip="Fournis${COLON}${cov.provided}"></span>
            <span class="warn" data-grow="${cov.partial}" data-tip="Partiels${COLON}${cov.partial}"></span>
            <span class="off" data-grow="${cov.notProvided}" data-tip="Non fournis${COLON}${cov.notProvided}"></span>
          </div>
          <div class="as-coverage-legend">${chip('ok', `${cov.provided} fournis`)}${chip('warn', `${cov.partial} partiels`)}${chip('off', `${cov.notProvided} non fournis`)}</div>
        </div>
        ${facts ? `<div class="as-facts wide">${facts}</div>` : ''}
      </section>
      <section class="card as-panel reveal">
        <div class="as-panel-head"><span class="as-panel-ico">${ico('bulb')}</span><div><h2>Constats</h2><p>Règles locales${COLON}chaque constat cite son indice${NBSP}; une donnée absente reste indéterminée, rien n’est réparé.</p></div>
          <div class="as-panel-meta">${counts.map(([level, list]) => chip(tone(list[0].tone), `${list.length}${NBSP}${list[0].levelLabel.toLowerCase()}`, { icon: LEVEL_ICON[level] })).join('')}</div></div>
        <div class="as-master">
          <div class="as-master-list" role="listbox" aria-label="Constats">${findings.map((f, n) => `
            <button type="button" role="option" class="as-row ${tone(f.tone)}" data-code="${esc(f.code)}" aria-selected="${f.code === selected}" data-j="${n}">
              <span class="as-row-mark">${ico(LEVEL_ICON[f.level] ?? 'info')}</span>
              <span class="as-row-body"><b>${esc(f.title)}</b><small><span class="mono">${esc(f.code)}</span>${NBSP}· ${esc(f.basisLabel)}</small></span>
              ${chip(tone(f.tone), f.levelLabel)}
            </button>`).join('')}</div>
          <div class="as-master-detail" data-detail aria-live="polite"></div>
        </div>
      </section>
      <section class="card as-panel reveal">
        <div class="as-panel-head"><span class="as-panel-ico">${ico('layers')}</span><div><h2>Capture filtrée et masquée</h2><p>Liste fermée de ${cov.total} attributs, sans secret ni certificat ni note${NBSP}; 1${NBSP}024 caractères et 128 valeurs au plus par attribut.</p></div>
          <label class="as-toggle"><input type="checkbox" class="switch" data-provided${providedOnly ? ' checked' : ''}><span>Fournis seulement</span></label></div>
        <div class="as-attrs" role="table" aria-label="Attributs de la capture">${attributes(view.snapshot, providedOnly)}</div>
      </section>
    </div>`;
    paintDetail(findings);
    applyVars(host);
    reveal(host);
  }

  function attributes(snapshot, only) {
    return (snapshot.fields ?? []).filter((f) => !only || f.coverage !== 'notProvided').map((f) => {
      const [t, label] = COVERAGE[f.coverage] ?? COVERAGE.notProvided;
      const many = f.values.length > 3;
      const value = f.values.length === 0 ? '<span class="as-faint">—</span>'
        : many ? `<details><summary>${esc(plural(f.values.length, 'valeur', 'valeurs'))}</summary><ul>${f.values.map((v) => `<li class="mono">${esc(v)}</li>`).join('')}</ul></details>`
          : f.values.map((v) => `<span class="mono">${esc(v)}</span>`).join('<br>');
      return `<div class="as-attr" role="row"><span role="cell" class="as-attr-name mono">${esc(f.name)}</span><span role="cell">${chip(t, label)}</span><span role="cell" class="as-attr-value">${value}</span></div>`;
    }).join('');
  }

  function paintDetail(findings) {
    const box = host.querySelector('[data-detail]');
    const f = findings.find((x) => x.code === selected);
    if (!box) return;
    if (!f) { box.innerHTML = '<p class="as-faint">Choisissez un constat.</p>'; return; }
    box.innerHTML = `<div class="as-detail ${tone(f.tone)} enter">
      <div class="as-detail-head">${chip(tone(f.tone), f.levelLabel, { icon: LEVEL_ICON[f.level] })}${chip('off', f.basisLabel)}<code class="as-code">${esc(f.code)}</code></div>
      <h3>${esc(f.title)}</h3>
      <div class="as-detail-block"><span>${ico('scan')}Élément observé</span><p>${esc(f.evidence)}</p></div>
      <div class="as-detail-block next"><span>${ico('route')}Vérification proposée</span><p>${esc(f.next)}</p></div>
    </div>`;
  }

  host.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const kindButton = t.closest('.as-switch [data-kind]');
    if (kindButton) { app.memory.focus = kindButton.dataset.kind; selected = null; paint(); app.emit('focus'); return; }
    const row = t.closest('[data-code]');
    if (row) {
      selected = row.dataset.code;
      host.querySelectorAll('[data-code]').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.code === selected)));
      const kind = focusKind();
      paintDetail([...(app.subject(kind)?.findings ?? [])]);
      return;
    }
    const act = t.closest('[data-act]')?.dataset.act;
    const kind = focusKind();
    const view = kind ? app.subject(kind) : null;
    if (!act || !view) return;
    const dn = view.card.dn;
    if (act === 'analyse') {
      try {
        app.memory[kind] = await app.call('assistance.subject.analyse', { dn });
        app.emit('subjects');
        app.toast('Constats recalculés sur la même lecture.', { tone: 'ok' });
      } catch (err) { app.toast(errorText(err), { tone: 'warn' }); }
    } else if (act === 'reread') {
      await app.readSubject(kind, dn);
    } else if (act === 'pin') {
      await app.workshopCall('assistance.pin.add', { dn }, `${view.card.name} épinglé dans les repères.`);
    } else if (act === 'a' || act === 'b') {
      const ok = await app.workshopCall('assistance.capture.take', { slot: act, dn }, `Capture ${act.toUpperCase()}${COLON}${view.card.name}.`);
      if (ok) app.go('comparer');
    }
  });
  host.addEventListener('change', (e) => {
    if (e.target instanceof HTMLInputElement && e.target.matches('[data-provided]')) {
      providedOnly = e.target.checked;
      const view = app.subject(focusKind());
      const box = host.querySelector('.as-attrs');
      if (view && box) box.innerHTML = attributes(view.snapshot, providedOnly);
    }
  });

  paint();
  offs.push(app.on('subjects', paint));
  return () => offs.forEach((off) => off());
}

// ---------------------------------------------------------------- comparison (ASS-001, ASS-005)

export function renderCompare(host, app) {
  const offs = [];
  let lastExport = { a: null, b: null };

  function slotCard(letter) {
    const s = app.workshop?.[letter];
    const user = app.subject('user');
    const computer = app.subject('computer');
    const takes = `
      <button class="btn subtle sm" type="button" data-take="user" data-slot="${letter}"${user ? '' : ' disabled data-tip="Choisissez d’abord le compte"'}>${ico('user')}Capturer le compte</button>
      <button class="btn subtle sm" type="button" data-take="computer" data-slot="${letter}"${computer ? '' : ' disabled data-tip="Choisissez d’abord le poste"'}>${ico('monitor')}Capturer le poste</button>
      <button class="btn ghost sm" type="button" data-load="${letter}">${ico('upload')}Charger un fichier…</button>`;
    if (!s) {
      return `<div class="as-slotcard empty reveal" data-slotcard="${letter}">
        <span class="as-letter">${letter.toUpperCase()}</span>
        <div class="as-slotcard-body"><b>Emplacement ${letter.toUpperCase()} vide</b><p>Capturez la fiche actuelle, ou chargez une capture historique enregistrée.</p></div>
        <div class="as-slotcard-actions">${takes}</div>
      </div>`;
    }
    const saved = lastExport[letter];
    return `<div class="as-slotcard filled reveal" data-slotcard="${letter}">
      <span class="as-letter">${letter.toUpperCase()}</span>
      <div class="as-slotcard-body">
        <span class="as-k">${esc(s.kindLabel)}${NBSP}· ${s.historical ? 'capture historique' : 'capture de la session'}</span>
        <b>${esc(s.name)}</b>
        <p class="as-faint">Capturée ${when(s.capturedAt)}${NBSP}· ${esc(plural(s.fieldCount, 'attribut fourni', 'attributs fournis'))}</p>
        <div class="as-slot-pills">${chip(s.source === 'live' ? 'ok' : 'warn', capitalize(s.sourceLabel), { icon: s.source === 'live' ? 'check' : 'history' })}${s.historical ? chip('info', 'Jamais une lecture actuelle', { icon: 'info' }) : ''}</div>
        ${saved ? `<p class="as-saved ${saved.saved ? 'ok' : 'off'}">${ico(saved.saved ? 'check' : 'info')}<span>${esc(saved.message)}</span>${saved.path ? copyButton(saved.path, { label: 'Copier le chemin', done: 'Chemin copié' }) : ''}</p>` : ''}
      </div>
      <div class="as-slotcard-actions">
        ${takes}
        <button class="btn ghost sm" type="button" data-save="${letter}" data-tip="Nouveau fichier Domenia.Capture.1 dans le dossier des exports">${ico('save')}Enregistrer</button>
        <button class="btn ghost sm" type="button" data-clear="${letter}">${ico('x')}Effacer</button>
      </div>
    </div>`;
  }

  function paint() {
    const ws = app.workshop;
    if (!ws) { host.innerHTML = `<section class="card as-panel">${'<div class="as-sk-stack" aria-busy="true"><span class="skeleton as-sk w70"></span><span class="skeleton as-sk w40"></span></div>'}</section>`; return; }
    const cmp = ws.comparison;
    const rows = (cmp.rows ?? []).filter((r) => !app.memory.diffOnly || r.status !== 'identical');
    const banner = cmp.ready
      ? `<div class="as-banner ${cmp.sameObject ? 'info' : 'accent'} reveal">${ico(cmp.sameObject ? 'history' : 'compare')}<div><b>${esc(cmp.summary)}</b>
          <p>memberOf compare les groupes directs fournis, pas les droits effectifs ni les groupes imbriqués. Un attribut manquant n’est jamais compté comme une suppression.</p></div>
          <div class="as-banner-chips">${chip('warn', plural(cmp.different, 'différence', 'différences'))}${chip('off', plural(cmp.undetermined, 'indéterminé', 'indéterminés'))}${chip('ok', plural(cmp.identical, 'identique', 'identiques'))}</div></div>`
      : `<div class="as-banner ${cmp.refusal ? 'warn' : 'off'} reveal">${ico(cmp.refusal ? 'alert' : 'info')}<div><b>${esc(cmp.summary)}</b><p>${cmp.refusal ? 'Comparez deux captures du même domaine et du même type d’objet.' : 'Une capture fige la fiche telle qu’elle a été lue, sans nouvelle lecture.'}</p></div></div>`;
    host.innerHTML = `<div class="as-stack">
      <div class="as-slots-row">
        ${slotCard('a')}
        <button class="as-swap reveal" type="button" data-swap aria-label="Inverser A et B" data-tip="Inverser A et B"${ws.a || ws.b ? '' : ' disabled'}>${ico('swap')}</button>
        ${slotCard('b')}
      </div>
      ${banner}
      ${cmp.ready ? `<section class="card as-panel reveal">
        <div class="as-panel-head"><span class="as-panel-ico">${ico('compare')}</span><div><h2>Attribut par attribut</h2><p>Identique, différent ou indéterminé. La casse et l’ordre de memberOf sont ignorés.</p></div>
          <label class="as-toggle"><input type="checkbox" class="switch" data-diffonly${app.memory.diffOnly ? ' checked' : ''}><span>Différences et inconnues seulement</span></label></div>
        ${rows.length ? `<div class="as-diff" role="table" aria-label="Comparaison A et B">
          <div class="as-diff-row head" role="row"><span role="columnheader">Attribut</span><span role="columnheader">État</span><span role="columnheader">A</span><span role="columnheader">B</span></div>
          ${rows.map((r, n) => diffRow(r, n)).join('')}</div>`
          : empty('check', 'Aucune différence', 'Les attributs fournis et comparables sont identiques.')}
      </section>` : `<section class="card as-panel as-howto reveal">
        <ol>
          <li><span>1</span><div><b>Capturez A</b><p>La fiche actuelle (compte ou poste), telle qu’elle vient d’être lue.</p></div></li>
          <li><span>2</span><div><b>Relisez ou changez de fiche</b><p>Après une intervention, ou une autre fiche du même type comme référence.</p></div></li>
          <li><span>3</span><div><b>Capturez B</b><p>La comparaison s’affiche aussitôt, attribut par attribut.</p></div></li>
        </ol>
      </section>`}
      <input type="file" accept="application/json,.json" data-file hidden>
    </div>`;
    applyVars(host);
    reveal(host);
  }

  function diffRow(r, n) {
    const changes = r.attribute === 'memberOf' && (r.added?.length || r.removed?.length)
      ? `<div class="as-groups">${(r.removed ?? []).map((g) => `<span class="as-group minus" data-tip="Présent seulement en A">−${NBSP}${esc(dnName(g))}</span>`).join('')}${(r.added ?? []).map((g) => `<span class="as-group plus" data-tip="Présent seulement en B">+${NBSP}${esc(dnName(g))}</span>`).join('')}</div>`
      : '';
    return `<div class="as-diff-row ${esc(r.status)}" role="row" data-j="${n}">
      <span role="cell" class="mono as-attr-name">${esc(r.attribute)}</span>
      <span role="cell">${chip(tone(r.tone), r.statusLabel)}</span>
      ${changes ? `<span role="cell" class="as-diff-val span2">${changes}</span>`
        : `<span role="cell" class="as-diff-val"><span class="mono">${esc(clip(r.before))}</span></span><span role="cell" class="as-diff-val"><span class="mono">${esc(clip(r.after))}</span></span>`}
    </div>`;
  }

  const clip = (text) => (String(text ?? '').length > 300 ? `${String(text).slice(0, 299)}…` : String(text ?? '') || '—');
  const dnName = (dn) => { const m = /^CN=((?:\\.|[^,])+)/i.exec(String(dn)); return m ? m[1].replace(/\\(.)/g, '$1') : String(dn); };

  let pendingSlot = 'a';
  host.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const take = t.closest('[data-take]');
    if (take) {
      const view = app.subject(take.dataset.take);
      if (view) await app.workshopCall('assistance.capture.take', { slot: take.dataset.slot, dn: view.card.dn }, `Capture ${take.dataset.slot.toUpperCase()}${COLON}${view.card.name}.`);
      return;
    }
    if (t.closest('[data-swap]')) {
      host.querySelector('.as-slots-row')?.classList.add('swapping');
      await app.workshopCall('assistance.capture.swap', {});
      return;
    }
    const clear = t.closest('[data-clear]');
    if (clear) { lastExport[clear.dataset.clear] = null; await app.workshopCall('assistance.capture.clear', { slot: clear.dataset.clear }); return; }
    const load = t.closest('[data-load]');
    if (load) { pendingSlot = load.dataset.load; host.querySelector('[data-file]')?.click(); return; }
    const save = t.closest('[data-save]');
    if (save) {
      const slot = save.dataset.save;
      const ok = await confirmDialog({
        title: `Enregistrer la capture ${slot.toUpperCase()}${NBSP}?`,
        message: `La capture contient des noms et des appartenances internes, pas les champs secrets dédiés. Elle est écrite dans un nouveau fichier daté du dossier des exports (jamais remplacé)${NBSP}; conservez-le sur un support protégé.`,
        confirmLabel: 'Enregistrer la capture', icon: 'save',
      });
      if (!ok) return;
      try {
        const result = await app.call('assistance.capture.export', { slot });
        lastExport[slot] = result;
        app.toast(result.message, { tone: result.saved ? 'ok' : 'info' });
        paint();
      } catch (err) { app.toast(errorText(err), { tone: 'warn' }); }
    }
  });
  host.addEventListener('change', async (e) => {
    const t = e.target;
    if (t instanceof HTMLInputElement && t.matches('[data-diffonly]')) { app.memory.diffOnly = t.checked; paint(); return; }
    if (t instanceof HTMLInputElement && t.matches('[data-file]')) {
      const file = t.files?.[0];
      t.value = '';
      if (!file) return;
      if (file.size > MAX_FILE) { app.toast(`Capture refusée${COLON}fichier trop volumineux (1${NBSP}Mio au plus). Rien n’a été chargé.`, { tone: 'warn' }); return; }
      const content = await file.text();
      // Read locally by the page, checked by the engine (format, domain, dates, allowlist): nothing else is read.
      const view = await app.workshopCall('assistance.capture.import', { slot: pendingSlot, content }, `Capture historique chargée en ${pendingSlot.toUpperCase()}${COLON}elle ne devient jamais une lecture actuelle.`);
      if (view) announce(`Capture chargée en ${pendingSlot.toUpperCase()}.`);
    }
  });

  paint();
  offs.push(app.on('workshop', paint), app.on('subjects', paint), app.on('reset', () => { lastExport = { a: null, b: null }; }));
  return () => offs.forEach((off) => off());
}

// ---------------------------------------------------------------- incidents (ASS-006)

export function renderIncidents(host, app) {
  const offs = [];
  let selected = null;

  function visible() {
    const query = app.memory.incidentFilter.trim().toLowerCase();
    return (app.workshop?.incidents?.items ?? []).filter((i) => !query || `${i.title} ${i.codes} ${i.area}`.toLowerCase().includes(query));
  }

  function paint() {
    const inc = app.workshop?.incidents;
    if (!inc) { host.innerHTML = '<section class="card as-panel"><div class="as-sk-stack" aria-busy="true"><span class="skeleton as-sk w70"></span></div></section>'; return; }
    const items = visible();
    if (!items.some((i) => i.id === selected)) selected = items[0]?.id ?? null;
    host.innerHTML = `<section class="card as-panel reveal">
      <div class="as-panel-head"><span class="as-panel-ico">${ico('alert')}</span><div><h2>Incidents expliqués</h2><p>${esc(inc.summary)}</p></div>
        <div class="as-panel-tools">
          <div class="as-filter">${ico('filter')}<input class="input" type="search" data-filter placeholder="Filtrer : titre, code ou zone" value="${esc(app.memory.incidentFilter)}" aria-label="Filtrer les incidents" maxlength="100"></div>
          <button class="btn ghost sm" type="button" data-refresh>${ico('refresh')}Actualiser</button>
          <button class="btn ghost sm" type="button" data-clear${inc.total ? '' : ' disabled'}>${ico('trash')}Effacer</button>
        </div></div>
      ${inc.total === 0 ? empty('check', 'Aucun incident', 'Aucun avertissement ni erreur dans cette session. Les lectures refusées ou en échec apparaîtront ici, expliquées.')
        : `<div class="as-master">
          <div class="as-master-list" role="listbox" aria-label="Incidents">${items.length ? items.map((i, n) => `
            <button type="button" role="option" class="as-row ${tone(i.tone)}" data-id="${esc(i.id)}" aria-selected="${i.id === selected}" data-j="${n}">
              <span class="as-row-time">${clock(i.at)}</span>
              <span class="as-row-body"><b>${esc(i.title)}</b><small>${esc(i.area)}${NBSP}· <span class="mono">${esc(i.codes)}</span></small></span>
              ${chip(tone(i.tone), i.levelLabel)}
            </button>`).join('') : '<p class="as-faint as-pad">Aucun incident ne correspond au filtre.</p>'}</div>
          <div class="as-master-detail" data-detail aria-live="polite"></div>
        </div>`}
    </section>`;
    paintDetail();
    applyVars(host);
    reveal(host);
  }

  function paintDetail() {
    const box = host.querySelector('[data-detail]');
    if (!box) return;
    const i = (app.workshop?.incidents?.items ?? []).find((x) => x.id === selected);
    if (!i) { box.innerHTML = '<p class="as-faint">Choisissez un incident.</p>'; return; }
    box.innerHTML = `<div class="as-detail ${tone(i.tone)} enter">
      <div class="as-detail-head">${chip(tone(i.tone), i.levelLabel)}${chip('off', i.area, { icon: 'tag' })}<span class="as-faint">${esc(formatDateTime(i.at) ?? '')}</span></div>
      <p class="as-note">${ico('info')}Session complète${COLON}cet incident n’est pas lié automatiquement à une fiche. Les pistes sont des règles locales, pas une cause prouvée.</p>
      ${i.hints.map((h, n) => `<div class="as-hint" data-j="${n}">
        <div class="as-hint-head"><b>${esc(h.title)}</b><code class="as-code">${esc(h.code)}</code></div>
        <p><span>Indice${COLON}</span>${esc(h.evidence)}</p>
        <p class="next"><span>À vérifier${COLON}</span>${esc(h.next)}</p>
        <button class="btn ghost xs" type="button" data-route="${esc(h.route)}">${ico('external')}${esc(h.routeLabel)}</button>
      </div>`).join('')}
      <div class="as-raw"><span>${ico('lock')}Message local, exclu du dossier exporté</span><pre>${esc(i.detail)}</pre></div>
      <div class="as-detail-actions"><button class="btn subtle sm" type="button" data-attach>${ico('ticket')}Joindre au dossier support</button></div>
    </div>`;
  }

  host.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const row = t.closest('[data-id]');
    if (row) {
      selected = row.dataset.id;
      host.querySelectorAll('[data-id]').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.id === selected)));
      paintDetail();
      return;
    }
    if (t.closest('[data-refresh]')) { await app.refreshWorkshop(); return; }
    if (t.closest('[data-clear]')) {
      const ok = await confirmDialog({ title: 'Effacer les incidents ?', message: 'La liste des incidents expliqués de l’atelier sera vidée. Le journal des opérations n’est pas touché.', confirmLabel: 'Effacer', icon: 'trash' });
      if (ok) await app.workshopCall('assistance.incidents.clear', {}, 'Incidents effacés.');
      return;
    }
    const route = t.closest('[data-route]');
    if (route) { app.ctx.navigate(route.dataset.route); return; }
    if (t.closest('[data-attach]') && selected) {
      app.memory.report.incident = selected;
      app.memory.report.kind = 'support';
      app.go('dossier');
    }
  });
  let timer = 0;
  host.addEventListener('input', (e) => {
    if (!(e.target instanceof HTMLInputElement) || !e.target.matches('[data-filter]')) return;
    app.memory.incidentFilter = e.target.value;
    clearTimeout(timer);
    timer = setTimeout(() => {
      const caret = e.target.selectionStart;
      paint();
      const input = host.querySelector('[data-filter]');
      input?.focus();
      input?.setSelectionRange(caret, caret);
    }, 180);
  });

  paint();
  app.refreshWorkshop();
  offs.push(app.on('workshop', paint));
  return () => { clearTimeout(timer); offs.forEach((off) => off()); };
}

// ---------------------------------------------------------------- pins (ASS-007)

export function renderPins(host, app) {
  const offs = [];

  function paint() {
    const ws = app.workshop;
    if (!ws) { host.innerHTML = '<section class="card as-panel"><div class="as-sk-stack" aria-busy="true"><span class="skeleton as-sk w70"></span></div></section>'; return; }
    const pins = ws.pins ?? [];
    const user = app.subject('user');
    const computer = app.subject('computer');
    host.innerHTML = `<section class="card as-panel reveal">
      <div class="as-panel-head"><span class="as-panel-ico">${ico('pin')}</span><div><h2>Repères de session</h2><p>${ws.pinLimit} fiches au plus, en mémoire seulement${NBSP}; vidés à la fermeture. Un repère se retrouve par son GUID, même déplacé.</p></div>
        <div class="as-panel-tools">
          <div class="as-capacity" role="meter" aria-valuemin="0" aria-valuemax="${ws.pinLimit}" aria-valuenow="${pins.length}" aria-label="Repères utilisés">
            <span class="as-capacity-bar"><span data-p="${(pins.length / ws.pinLimit).toFixed(3)}"></span></span><b>${pins.length}<small>/${ws.pinLimit}</small></b></div>
          <button class="btn subtle sm" type="button" data-pin="user"${user ? '' : ' disabled'}>${ico('user')}Épingler le compte</button>
          <button class="btn subtle sm" type="button" data-pin="computer"${computer ? '' : ' disabled'}>${ico('monitor')}Épingler le poste</button>
        </div></div>
      ${pins.length === 0 ? empty('pin', 'Aucun repère', 'Épinglez le compte ou le poste de la session pour y revenir en un clic pendant l’intervention.')
        : `<div class="as-pins">${pins.map((p, n) => `
          <article class="as-pin reveal" data-identity="${esc(p.identity)}" data-j="${n}">
            ${avatar(p.name, p.kind)}
            <div class="as-pin-body"><b>${esc(p.name)}</b><span class="as-pin-meta">${esc(p.kindLabel)}${NBSP}· épinglé ${when(p.pinnedAt)}</span></div>
            <small class="as-pin-path">${ico('ou')}${esc(dnPath(p.dn))}</small>
            <div class="as-pin-actions">
              <button class="btn subtle sm" type="button" data-open>${ico('external')}Ouvrir</button>
              <button class="btn ghost icon sm" type="button" data-remove aria-label="Retirer ${esc(p.name)}" data-tip="Retirer le repère">${ico('x')}</button>
            </div>
          </article>`).join('')}</div>`}
    </section>`;
    applyVars(host);
    reveal(host);
  }

  host.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const pin = t.closest('[data-pin]');
    if (pin) {
      const view = app.subject(pin.dataset.pin);
      if (view) await app.workshopCall('assistance.pin.add', { dn: view.card.dn }, `${view.card.name} épinglé.`);
      return;
    }
    const card = t.closest('[data-identity]');
    if (!card) return;
    const identity = card.dataset.identity;
    if (t.closest('[data-remove]')) { await app.workshopCall('assistance.pin.remove', { identity }); return; }
    if (t.closest('[data-open]')) {
      card.classList.add('opening');
      try {
        const where = await app.call('assistance.pin.locate', { identity });
        const kind = where.kind === 'computer' ? 'computer' : 'user';
        await app.readSubject(kind, where.dn, { quiet: true });
        app.toast(where.message, { tone: where.moved ? 'info' : 'ok' });
        app.refreshWorkshop();
      } catch (err) {
        app.toast(errorText(err), { tone: 'warn' });
      } finally {
        card.classList.remove('opening');
      }
    }
  });

  paint();
  offs.push(app.on('workshop', paint), app.on('subjects', paint));
  return () => offs.forEach((off) => off());
}
