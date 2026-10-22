// Assistance · support workshop (Domenia 1 Domenia-Support, ASS-001 and ASS-003 to ASS-007): local findings of a fiche,
// comparison of two captures A and B, explained incidents of the session and pins. Memory of the session only; nothing here
// reads the network except « Relire la fiche » and the opening of a pin, on a click.
import { esc, errorText, applyVars, reveal, announce, formatDateTime, formatTime } from '../../ui.js';
import { copyButton, confirmDialog, createTabs, createSplit } from '../../kit/index.js';
import { ico, chip, tone, avatar, empty, plural, button, fresh, valueHtml, factValue, enter, COLON, NBSP } from './common.js';
import { dnPath } from './format.js';

export { dnPath };

const LEVEL_ORDER = { attention: 0, toCheck: 1, undetermined: 2, information: 3 };
const LEVEL_ICON = { attention: 'alert', toCheck: 'eye', undetermined: 'info', information: 'info' };
const COVERAGE = { provided: ['ok', 'Fourni'], partial: ['warn', 'Partiel'], notProvided: ['off', 'Non fourni'] };
const capitalize = (text) => (text ? text[0].toLocaleUpperCase('fr') + text.slice(1) : text);
// The bridge refuses a message beyond 1 Mio; a capture file must leave room for its JSON envelope (escapes included).
const MAX_ENVELOPE = 1_048_576 - 4096;
const NOT_PROVIDED = '[non fourni]';
const PARTIAL = ' [partiel]';

function noSubject(what) {
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

function facts(list) {
  return (list ?? []).map((f, n) => `<div class="as-fact ${tone(f.tone)}" data-j="${n}"><span>${esc(f.label)}</span>${factValue(f.value)}</div>`).join('');
}

/** One value of a capture or a comparison, as the operator reads it (several values: one per line). */
function captured(attribute, text) {
  const value = String(text ?? '');
  if (!value || value === NOT_PROVIDED) return `<span class="as-faint">${value === NOT_PROVIDED ? 'non fourni' : '—'}</span>`;
  const partial = value.endsWith(PARTIAL);
  const values = (partial ? value.slice(0, -PARTIAL.length) : value).split(' ; ');
  const body = values.length > 3
    ? `<details><summary>${esc(plural(values.length, 'valeur', 'valeurs'))}</summary><ul>${values.map((v) => `<li>${valueHtml(attribute, v)}</li>`).join('')}</ul></details>`
    : values.map((v) => valueHtml(attribute, v)).join('<br>');
  return `${body}${partial ? ` ${chip('warn', 'partiel')}` : ''}`;
}

// ---------------------------------------------------------------- findings (ASS-003, ASS-004)

export function renderFindings(host, app) {
  const offs = [];
  const selected = { user: null, computer: null };
  const providedOnly = { user: false, computer: false };
  let tabs = null;
  bindFocusSearch(host);

  function paint() {
    tabs?.destroy();
    tabs = null;
    const kinds = ['user', 'computer'].filter((k) => app.subject(k));
    if (!kinds.length) {
      host.innerHTML = `<section class="card as-panel reveal">${noSubject('Domenia analyse localement ce qui a été lu, sans nouvelle lecture ni réparation.')}</section>`;
      reveal(host);
      return;
    }
    if (!app.subject(app.memory.focus)) app.memory.focus = kinds[0];
    host.innerHTML = '<div class="as-findings-tabs reveal"></div>';
    tabs = createTabs(host.firstElementChild, {
      label: 'Fiche analysée',
      selected: app.memory.focus,
      tabs: ['user', 'computer'].map((k) => {
        const view = app.subject(k);
        const count = view?.findings?.filter((f) => f.level !== 'information').length;
        return {
          id: k,
          label: view ? `${k === 'user' ? 'Compte' : 'Poste'}${NBSP}· ${view.card.name}` : k === 'user' ? 'Compte' : 'Poste',
          icon: k === 'user' ? 'user' : 'monitor',
          count: view ? count : undefined,
          tone: view?.findings?.some((f) => f.level === 'attention') ? 'alert' : count ? 'warn' : 'ok',
          disabled: !view,
          reason: k === 'user' ? 'Choisissez d’abord le compte dans la session d’assistance.' : 'Choisissez d’abord le poste dans la session d’assistance.',
          render: (panel) => paintPanel(panel, k),
        };
      }),
      onChange: (id) => { app.memory.focus = id; app.emit('focus'); },
    });
    reveal(host);
  }

  function paintPanel(panel, kind) {
    const view = app.subject(kind);
    if (!view) return;
    const findings = [...(view.findings ?? [])].sort((a, b) => (LEVEL_ORDER[a.level] ?? 9) - (LEVEL_ORDER[b.level] ?? 9));
    if (!findings.some((f) => f.code === selected[kind])) selected[kind] = findings[0]?.code ?? null;
    const counts = Object.keys(LEVEL_ORDER).map((level) => [level, findings.filter((f) => f.level === level)]).filter(([, list]) => list.length);
    const cov = view.coverage;
    const c = view.card;
    const ws = app.workshop;
    const pinsFull = (ws?.pins?.length ?? 0) >= (ws?.pinLimit ?? 24) && !ws?.pins?.some((p) => p.dn === c.dn);
    // Domenia 1 (ASS-003, ASS-004): while the object is read again, a capture or a pin would freeze the previous read.
    const reading = Boolean(app.busy?.[kind]);
    const readingReason = `Lecture de ${c.name} en cours${COLON}attendez sa fin pour capturer ou épingler.`;
    panel.innerHTML = `<div class="as-stack">
      <section class="card as-cover reveal">
        <div class="as-cover-id">${avatar(c.name, c.kind)}
          <div class="as-cover-name"><span class="as-k">${esc(c.kindLabel)}${NBSP}· ${esc(cov.sourceLabel)}</span><h2>${esc(c.name)}</h2>
            <p class="as-faint"><span class="mono">${esc(c.login)}</span>${c.path ? `${NBSP}· ${esc(c.path)}` : ''}</p></div>
          <div class="as-cover-side"><div class="as-cover-pills">${(c.pills ?? []).map((p) => chip(tone(p.tone), p.label, { size: 'md' })).join('')}</div>${fresh(c.readAt)}</div>
        </div>
        <div class="as-cover-actions">
          ${button({ label: 'Recalculer', icon: 'refresh', data: { act: 'analyse' }, tip: 'Recalcule les constats sur la même lecture, sans rien relire' })}
          ${button({ label: 'Relire la fiche', icon: 'scan', data: { act: 'reread' }, tip: 'Une nouvelle lecture de l’objet (geste explicite)' })}
          ${button({ label: 'Épingler', icon: 'pin', data: { act: 'pin' }, disabled: pinsFull || reading, reason: reading ? readingReason : `${ws?.pinLimit ?? 24}${NBSP}repères sont déjà présents${COLON}retirez-en un dans «${NBSP}Repères${NBSP}».` })}
          ${button({ label: 'Capturer en A', icon: 'compare', data: { act: 'a' }, disabled: reading, reason: readingReason })}
          ${button({ label: 'Capturer en B', icon: 'compare', data: { act: 'b' }, disabled: reading, reason: readingReason })}
        </div>
        <div class="as-coverage">
          <div class="as-coverage-head"><b>${cov.provided + cov.partial}</b><span>attributs fournis sur ${cov.total}</span></div>
          <div class="as-coverage-bar" role="img" aria-label="${esc(cov.text)}">
            <span class="ok" data-grow="${cov.provided}" data-tip="Fournis${COLON}${cov.provided}"></span>
            <span class="warn" data-grow="${cov.partial}" data-tip="Partiels${COLON}${cov.partial}"></span>
            <span class="off" data-grow="${cov.notProvided}" data-tip="Non fournis${COLON}${cov.notProvided}"></span>
          </div>
          <div class="as-coverage-legend">${chip('ok', plural(cov.provided, 'fourni', 'fournis'))}${chip('warn', plural(cov.partial, 'partiel', 'partiels'))}${chip('off', plural(cov.notProvided, 'non fourni', 'non fournis'))}</div>
        </div>
        ${c.facts?.length ? `<div class="as-facts wide">${facts(c.facts)}</div>` : ''}
      </section>
      <section class="card as-panel reveal">
        <div class="as-panel-head"><span class="as-panel-ico">${ico('bulb')}</span><div><h2>Constats</h2><p>Règles locales${COLON}chaque constat cite son indice${NBSP}; une donnée absente reste indéterminée, rien n’est réparé.</p></div>
          <div class="as-panel-meta">${counts.map(([level, list]) => chip(tone(list[0].tone), `${list.length}${NBSP}${list[0].levelLabel.toLowerCase()}`, { icon: LEVEL_ICON[level] })).join('')}</div></div>
        <div class="as-split" data-split></div>
      </section>
      <section class="card as-panel reveal">
        <div class="as-panel-head"><span class="as-panel-ico">${ico('layers')}</span><div><h2>Capture filtrée et masquée</h2><p>Liste fermée de ${cov.total}${NBSP}attributs, sans secret ni certificat ni note${NBSP}; dates lisibles, valeur brute en info-bulle.</p></div>
          <label class="as-toggle"><input type="checkbox" class="switch" data-provided${providedOnly[kind] ? ' checked' : ''}><span>Fournis seulement</span></label></div>
        <div class="as-attrs" role="table" aria-label="Attributs de la capture">${attributes(view.snapshot, providedOnly[kind])}</div>
      </section>
    </div>`;
    const list = document.createElement('div');
    list.className = 'as-list';
    list.setAttribute('role', 'listbox');
    list.setAttribute('aria-label', 'Constats');
    list.innerHTML = findings.map((f, n) => `
      <button type="button" role="option" class="as-row ${tone(f.tone)}" data-code="${esc(f.code)}" aria-selected="${f.code === selected[kind]}" data-j="${n}" aria-label="${esc(`${f.levelLabel}${COLON}${f.title}`)}">
        <span class="as-row-mark">${ico(LEVEL_ICON[f.level] ?? 'info')}</span>
        <span class="as-row-body"><b>${esc(f.title)}</b><small>${esc(f.levelLabel)}${NBSP}· ${esc(f.basisLabel)}</small></span>
      </button>`).join('');
    const box = document.createElement('div');
    box.className = 'as-list-detail';
    box.setAttribute('aria-live', 'polite');
    const split = createSplit(panel.querySelector('[data-split]'), { a: list, b: box, key: 'assistance.constats', fixed: 'a', size: 340, min: 260, max: 560, label: 'Largeur de la liste des constats' });
    paintDetail(box, findings.find((f) => f.code === selected[kind]));
    list.addEventListener('click', (e) => {
      const row = e.target instanceof Element ? e.target.closest('[data-code]') : null;
      if (!row) return;
      selected[kind] = row.dataset.code;
      list.querySelectorAll('[data-code]').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.code === selected[kind])));
      paintDetail(box, findings.find((f) => f.code === selected[kind]));
    });
    list.addEventListener('keydown', (e) => {
      if (!['ArrowDown', 'ArrowUp'].includes(e.key)) return;
      const rows = [...list.querySelectorAll('[data-code]')];
      const at = rows.indexOf(document.activeElement);
      if (at < 0) return;
      e.preventDefault();
      const next = rows[(at + (e.key === 'ArrowDown' ? 1 : -1) + rows.length) % rows.length];
      next.focus();
      next.click();
    });
    applyVars(panel);
    reveal(panel);
    app.freshen(panel);
    return () => split.destroy?.();
  }

  function attributes(snapshot, only) {
    const head = '<div class="as-attr head" role="row"><span role="columnheader">Attribut</span><span role="columnheader">Couverture</span><span role="columnheader">Valeur</span></div>';
    return head + (snapshot.fields ?? []).filter((f) => !only || f.coverage !== 'notProvided').map((f) => {
      const [t, label] = COVERAGE[f.coverage] ?? COVERAGE.notProvided;
      const value = f.values.length === 0 ? '<span class="as-faint">—</span>'
        : f.values.length > 3 ? `<details><summary>${esc(plural(f.values.length, 'valeur', 'valeurs'))}</summary><ul>${f.values.map((v) => `<li>${valueHtml(f.name, v)}</li>`).join('')}</ul></details>`
          : f.values.map((v) => valueHtml(f.name, v)).join('<br>');
      return `<div class="as-attr" role="row"><span role="cell" class="as-attr-name mono" data-tip="${esc(f.name)}">${esc(f.name)}</span><span role="cell">${chip(t, label)}</span><span role="cell" class="as-attr-value">${value}</span></div>`;
    }).join('');
  }

  function paintDetail(box, f) {
    if (!f) { box.innerHTML = '<p class="as-faint as-pad">Choisissez un constat.</p>'; return; }
    box.innerHTML = `<div class="as-detail ${tone(f.tone)} enter">
      <div class="as-detail-head">${chip(tone(f.tone), f.levelLabel, { icon: LEVEL_ICON[f.level], size: 'md' })}${chip('off', f.basisLabel)}<code class="as-code">${esc(f.code)}</code></div>
      <h3>${esc(f.title)}</h3>
      <div class="as-detail-block"><span>${ico('scan')}Élément observé</span><p>${esc(f.evidence)}</p></div>
      <div class="as-detail-block next"><span>${ico('route')}Vérification proposée</span><p>${esc(f.next)}</p></div>
    </div>`;
  }

  host.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const act = t?.closest('[data-act]')?.dataset.act;
    const kind = tabs?.current();
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
    } else if ((act === 'pin' || act === 'a' || act === 'b') && app.busy?.[kind]) {
      app.toast(`Lecture de ${view.card.name} en cours${COLON}attendez sa fin pour capturer ou épingler.`, { tone: 'info' });
    } else if (act === 'pin') {
      await app.workshopCall('assistance.pin.add', { dn }, `${view.card.name} épinglé dans les repères.`);
    } else if (act === 'a' || act === 'b') {
      const ok = await app.workshopCall('assistance.capture.take', { slot: act, dn }, `Capture ${act.toUpperCase()}${COLON}${view.card.name}.`);
      if (ok) app.go('comparer');
    }
  });
  host.addEventListener('change', (e) => {
    if (!(e.target instanceof HTMLInputElement) || !e.target.matches('[data-provided]')) return;
    const kind = tabs?.current();
    const view = kind ? app.subject(kind) : null;
    if (!view) return;
    providedOnly[kind] = e.target.checked;
    const box = e.target.closest('.as-panel')?.querySelector('.as-attrs');
    if (box) box.innerHTML = attributes(view.snapshot, providedOnly[kind]);
  });

  // A read that starts or ends greys or frees « Épingler » and « Capturer » (the next read repaints the findings anyway).
  paint();
  offs.push(app.on('subjects', paint), app.on('busy', paint));
  return () => { offs.forEach((off) => off()); tabs?.destroy(); };
}

// ---------------------------------------------------------------- comparison (ASS-001, ASS-005)

export function renderCompare(host, app) {
  const offs = [];
  const view = { painted: false };
  let lastExport = { a: null, b: null };

  function slotCard(letter) {
    const s = app.workshop?.[letter];
    const user = app.subject('user');
    const computer = app.subject('computer');
    const takes = `
      ${button({ label: 'Capturer le compte', icon: 'user', data: { take: 'user', slot: letter }, disabled: !user, reason: 'Choisissez d’abord le compte dans la session d’assistance.' })}
      ${button({ label: 'Capturer le poste', icon: 'monitor', data: { take: 'computer', slot: letter }, disabled: !computer, reason: 'Choisissez d’abord le poste dans la session d’assistance.' })}
      ${button({ label: 'Charger un fichier…', icon: 'upload', cls: 'ghost sm', data: { load: letter }, tip: 'Capture Domenia.Capture.1 enregistrée (Domenia 1 ou 2), du même domaine' })}`;
    if (!s) {
      return `<div class="as-slotcard is-empty reveal" data-slotcard="${letter}">
        <span class="as-letter">${letter.toUpperCase()}</span>
        <div class="as-slotcard-body"><b>Emplacement ${letter.toUpperCase()} vide</b><p>Capturez la fiche actuelle, ou chargez une capture historique enregistrée.</p></div>
        <div class="as-slotcard-actions">${takes}</div>
      </div>`;
    }
    const saved = lastExport[letter];
    return `<div class="as-slotcard is-filled reveal" data-slotcard="${letter}">
      <span class="as-letter">${letter.toUpperCase()}</span>
      <div class="as-slotcard-body">
        <span class="as-k">${esc(s.kindLabel)}${NBSP}· ${s.historical ? 'capture historique' : 'capture de la session'}</span>
        <b data-tip="${esc(s.name)}">${esc(s.name)}</b>
        <p class="as-faint">${fresh(s.capturedAt, 'Capturée', 60 * 60_000)}${NBSP}· ${esc(plural(s.fieldCount, 'attribut fourni', 'attributs fournis'))}</p>
        <div class="as-slot-pills">${chip(s.source === 'live' ? 'ok' : 'warn', capitalize(s.sourceLabel), { icon: s.source === 'live' ? 'check' : 'history' })}${s.historical ? chip('info', 'Jamais une lecture actuelle', { icon: 'info' }) : ''}</div>
        ${saved ? `<p class="as-saved ${saved.saved ? 'ok' : 'off'}">${ico(saved.saved ? 'check' : 'info')}<span>${esc(saved.message)}</span>${saved.path ? copyButton(saved.path, { label: 'Copier le chemin', done: 'Chemin copié' }) : ''}</p>` : ''}
      </div>
      <div class="as-slotcard-actions">
        ${takes}
        ${button({ label: 'Enregistrer', icon: 'save', cls: 'ghost sm', data: { save: letter }, tip: 'Nouveau fichier Domenia.Capture.1 daté dans le dossier des exports' })}
        ${button({ label: 'Effacer', icon: 'x', cls: 'ghost sm', data: { clear: letter } })}
      </div>
    </div>`;
  }

  function paint() {
    const ws = app.workshop;
    if (!ws) { host.innerHTML = '<section class="card as-panel"><div class="as-sk-stack" aria-busy="true"><span class="skeleton as-sk w70"></span><span class="skeleton as-sk w40"></span></div></section>'; return; }
    const cmp = ws.comparison;
    const rows = (cmp.rows ?? []).filter((r) => !app.memory.diffOnly || r.status !== 'identical');
    const swapReason = ws.a || ws.b ? '' : 'Capturez d’abord une fiche en A ou en B.';
    const banner = cmp.ready
      ? `<div class="as-banner ${cmp.sameObject ? 'info' : 'accent'} reveal">${ico(cmp.sameObject ? 'history' : 'compare')}<div><b>${esc(cmp.summary)}</b>
          <p>memberOf compare les groupes directs fournis, pas les droits effectifs ni les groupes imbriqués. Un attribut manquant n’est jamais compté comme une suppression.</p></div>
          <div class="as-banner-chips">${chip('warn', plural(cmp.different, 'différence', 'différences'), { size: 'md' })}${chip('off', plural(cmp.undetermined, 'indéterminé', 'indéterminés'), { size: 'md' })}${chip('ok', plural(cmp.identical, 'identique', 'identiques'), { size: 'md' })}</div></div>`
      : `<div class="as-banner ${cmp.refusal ? 'warn' : 'off'} reveal">${ico(cmp.refusal ? 'alert' : 'info')}<div><b>${esc(cmp.summary)}</b><p>${cmp.refusal ? 'Comparez deux captures du même domaine et du même type d’objet.' : 'Une capture fige la fiche telle qu’elle a été lue, sans nouvelle lecture.'}</p></div></div>`;
    host.innerHTML = `<div class="as-stack">
      <div class="as-slots-row">
        ${slotCard('a')}
        ${button({ label: 'Inverser A et B', icon: 'swap', cls: 'as-swap reveal', iconOnly: true, data: { swap: '1' }, disabled: Boolean(swapReason), reason: swapReason })}
        ${slotCard('b')}
      </div>
      ${banner}
      ${cmp.ready ? `<section class="card as-panel reveal">
        <div class="as-panel-head"><span class="as-panel-ico">${ico('compare')}</span><div><h2>Attribut par attribut</h2><p>Dates lisibles (valeur brute en info-bulle), nom des objets cités${NBSP}; la casse et l’ordre de memberOf sont ignorés.</p></div>
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
    </div>`;
    host.append(fileInput);
    applyVars(host);
    enter(host, view);
    app.freshen(host);
  }

  function diffRow(r, n) {
    const changes = r.attribute === 'memberOf' && (r.added?.length || r.removed?.length)
      ? `<div class="as-groups">${(r.removed ?? []).map((g) => `<span class="as-group minus" data-tip="${esc(`Présent seulement en A${COLON}${g}`)}">−${NBSP}${valueHtml('memberOf', g)}</span>`).join('')}${(r.added ?? []).map((g) => `<span class="as-group plus" data-tip="${esc(`Présent seulement en B${COLON}${g}`)}">+${NBSP}${valueHtml('memberOf', g)}</span>`).join('')}</div>`
      : '';
    return `<div class="as-diff-row ${esc(r.status)}" role="row" data-j="${n}">
      <span role="cell" class="mono as-attr-name" data-tip="${esc(r.attribute)}">${esc(r.attribute)}</span>
      <span role="cell">${chip(tone(r.tone), r.statusLabel)}</span>
      ${changes ? `<span role="cell" class="as-diff-val span2">${changes}</span>`
        : `<span role="cell" class="as-diff-val">${captured(r.attribute, r.before)}</span><span role="cell" class="as-diff-val">${captured(r.attribute, r.after)}</span>`}
    </div>`;
  }

  let pendingSlot = 'a';
  // One file input for the whole life of the view, moved back after each repaint: a choice dialog left open across a
  // repaint still delivers its file (a replaced input would lose it without a word).
  const fileInput = document.createElement('input');
  fileInput.type = 'file';
  fileInput.accept = 'application/json,.json';
  fileInput.hidden = true;
  fileInput.dataset.file = '';
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
    if (load) { pendingSlot = load.dataset.load; fileInput.click(); return; }
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
      const tooBig = `Capture refusée${COLON}fichier trop volumineux (1${NBSP}Mio au plus). Rien n’a été chargé.`;
      if (file.size > MAX_ENVELOPE) { app.toast(tooBig, { tone: 'warn' }); return; }
      const content = await file.text();
      // The message to the engine escapes the text (quotes, accents, line breaks): its real size is checked before sending.
      if (JSON.stringify({ op: 'assistance.capture.import', args: { slot: pendingSlot, content } }).length > MAX_ENVELOPE) { app.toast(tooBig, { tone: 'warn' }); return; }
      // Read locally by the page, checked by the engine (format, domain, dates, allowlist): nothing else is read.
      const view = await app.workshopCall('assistance.capture.import', { slot: pendingSlot, content }, `Capture historique chargée en ${pendingSlot.toUpperCase()}${COLON}elle ne devient jamais une lecture actuelle.`);
      if (view) announce(`Capture chargée en ${pendingSlot.toUpperCase()}.`);
    }
  });

  // The view follows what it shows (captures, comparison, subjects that can be captured), not every new incident.
  const shownOf = () => JSON.stringify([app.workshop?.a ?? null, app.workshop?.b ?? null, app.workshop?.comparison ?? null, app.subject('user')?.card?.dn ?? null, app.subject('computer')?.card?.dn ?? null]);
  let shown = '';
  const repaint = () => { const now = shownOf(); if (now === shown) return; shown = now; paint(); };
  paint();
  shown = shownOf();
  offs.push(app.on('workshop', repaint), app.on('subjects', repaint), app.on('reset', () => { lastExport = { a: null, b: null }; }));
  return () => offs.forEach((off) => off());
}

// ---------------------------------------------------------------- incidents (ASS-006)

export function renderIncidents(host, app) {
  const offs = [];
  const view = { painted: false };
  let selected = null;
  let split = null;
  let shownRevision = -1;

  function visible() {
    const query = app.memory.incidentFilter.trim().toLowerCase();
    return (app.workshop?.incidents?.items ?? []).filter((i) => !query || `${i.title} ${i.codes} ${i.area}`.toLowerCase().includes(query));
  }

  function rowsHtml(items) {
    return items.length ? items.map((i, n) => `
      <button type="button" role="option" class="as-row ${tone(i.tone)}" data-id="${esc(i.id)}" aria-selected="${i.id === selected}" data-j="${n}" aria-label="${esc(`${i.levelLabel}, ${formatTime(i.at) ?? ''}${COLON}${i.title}`)}">
        <span class="as-row-mark" data-tip="${esc(i.levelLabel)}">${ico(i.tone === 'alert' ? 'alert' : 'info')}</span>
        <span class="as-row-body"><b class="as-two-lines">${esc(i.title)}</b><small data-tip="${esc(i.codes)}"><span class="as-row-time">${esc(formatTime(i.at) ?? '—')}</span>${NBSP}· ${esc(i.area)}${NBSP}· <span class="mono">${esc(i.codes)}</span></small></span>
      </button>`).join('') : '<p class="as-faint as-pad">Aucun incident ne correspond au filtre.</p>';
  }

  function paint() {
    const inc = app.workshop?.incidents;
    split?.destroy?.();
    split = null;
    if (!inc) { host.innerHTML = '<section class="card as-panel"><div class="as-sk-stack" aria-busy="true"><span class="skeleton as-sk w70"></span></div></section>'; return; }
    shownRevision = app.workshop.revision;
    const items = visible();
    if (!items.some((i) => i.id === selected)) selected = items[0]?.id ?? null;
    host.innerHTML = `<section class="card as-panel reveal">
      <div class="as-panel-head"><span class="as-panel-ico">${ico('alert')}</span><div><h2>Incidents expliqués</h2><p data-summary>${esc(inc.summary)}</p></div>
        <div class="as-panel-tools">
          <div class="as-filter">${ico('filter')}<input class="input" type="search" data-filter placeholder="Filtrer${NBSP}: titre, code ou zone" value="${esc(app.memory.incidentFilter)}" aria-label="Filtrer les incidents" maxlength="100"></div>
          ${chip('info', 'Suivi chaque seconde', { icon: 'activity', tip: 'Les nouveaux avertissements et erreurs de la session s’ajoutent seuls tant que l’écran est affiché.' })}
          ${button({ label: 'Effacer', icon: 'trash', cls: 'ghost sm', data: { clear: '1' }, disabled: !inc.total, reason: 'Aucun incident à effacer.' })}
        </div></div>
      ${inc.total === 0 ? empty('check', 'Aucun incident', 'Aucun avertissement ni erreur dans cette session. Les lectures refusées ou en échec apparaîtront ici, expliquées.')
        : '<div class="as-split" data-split></div>'}
    </section>`;
    const host2 = host.querySelector('[data-split]');
    if (host2) {
      const list = document.createElement('div');
      list.className = 'as-list';
      list.setAttribute('role', 'listbox');
      list.setAttribute('aria-label', 'Incidents');
      list.innerHTML = rowsHtml(items);
      const box = document.createElement('div');
      box.className = 'as-list-detail';
      box.setAttribute('aria-live', 'polite');
      split = createSplit(host2, { a: list, b: box, key: 'assistance.incidents', fixed: 'a', size: 380, min: 280, max: 600, label: 'Largeur de la liste des incidents' });
      paintDetail();
    }
    applyVars(host);
    enter(host, view);
  }

  function paintDetail() {
    const box = host.querySelector('.as-list-detail');
    if (!box) return;
    const i = (app.workshop?.incidents?.items ?? []).find((x) => x.id === selected);
    if (!i) { box.innerHTML = '<p class="as-faint as-pad">Choisissez un incident.</p>'; return; }
    box.innerHTML = `<div class="as-detail ${tone(i.tone)} enter">
      <div class="as-detail-head">${chip(tone(i.tone), i.levelLabel, { size: 'md' })}${chip('off', i.area, { icon: 'tag' })}<span class="as-faint">${esc(formatDateTime(i.at) ?? '')}</span></div>
      <h3>${esc(i.title)}</h3>
      <p class="as-note">${ico('info')}<span>Session complète${COLON}cet incident n’est pas lié automatiquement à une fiche. Les pistes sont des règles locales, pas une cause prouvée.</span></p>
      ${i.hints.map((h, n) => `<div class="as-hint" data-j="${n}">
        <div class="as-hint-head"><b>${esc(h.title)}</b><code class="as-code">${esc(h.code)}</code></div>
        <p><span>Indice${COLON}</span>${esc(h.evidence)}</p>
        <p class="next"><span>À vérifier${COLON}</span>${esc(h.next)}</p>
        <button class="btn ghost xs" type="button" data-route="${esc(h.route)}">${ico('external')}${esc(h.routeLabel)}</button>
      </div>`).join('')}
      <div class="as-raw"><span>${ico('lock')}Message local, exclu du dossier exporté</span><pre>${esc(i.detail)}</pre></div>
      <div class="as-detail-actions">${button({ label: 'Joindre au dossier support', icon: 'ticket', data: { attach: '1' } })}</div>
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
    if (t.closest('[data-clear]')) {
      const ok = await confirmDialog({ title: 'Effacer les incidents ?', message: 'La liste des incidents expliqués de l’atelier sera vidée. Le journal des opérations n’est pas touché.', confirmLabel: 'Effacer', icon: 'trash' });
      if (ok) await app.workshopCall('assistance.incidents.clear', {}, 'Incidents effacés.');
      return;
    }
    const route = t.closest('[data-route]');
    // « moteur » is the engine state of this screen (its own panel), the other routes open their screen.
    if (route) { if (route.dataset.route === 'moteur') app.openEngine?.(); else app.ctx.navigate(route.dataset.route); return; }
    if (t.closest('[data-attach]') && selected) {
      app.memory.report.incident = selected;
      app.memory.report.kind = 'support';
      app.go('dossier');
    }
  });
  host.addEventListener('keydown', (e) => {
    if (!['ArrowDown', 'ArrowUp'].includes(e.key) || !(e.target instanceof Element) || !e.target.closest('.as-list')) return;
    const rows = [...host.querySelectorAll('.as-list [data-id]')];
    const at = rows.indexOf(document.activeElement);
    if (at < 0) return;
    e.preventDefault();
    const next = rows[(at + (e.key === 'ArrowDown' ? 1 : -1) + rows.length) % rows.length];
    next.focus();
    next.click();
  });
  let timer = 0;
  host.addEventListener('input', (e) => {
    if (!(e.target instanceof HTMLInputElement) || !e.target.matches('[data-filter]')) return;
    app.memory.incidentFilter = e.target.value;
    clearTimeout(timer);
    timer = setTimeout(() => {
      const list = host.querySelector('.as-list');
      if (!list) return;
      const items = visible();
      if (!items.some((i) => i.id === selected)) selected = items[0]?.id ?? null;
      list.innerHTML = rowsHtml(items);
      paintDetail();
    }, 180);
  });

  paint();
  app.refreshWorkshop();
  // The workshop is compared every second by the page: a new incident repaints the list, never the filter being typed.
  // A new revision updates the list, its summary and the detail in place: the filter being typed, the keyboard focus on a row
  // and the scroll of the master-detail stay where they are. Only the first display (or an emptied workshop) repaints.
  offs.push(app.on('workshop', () => {
    if (app.workshop?.revision === shownRevision) return;
    const list = host.querySelector('.as-list');
    if (!list || !app.workshop?.incidents) { paint(); return; }
    shownRevision = app.workshop.revision;
    const focusedId = document.activeElement instanceof Element && list.contains(document.activeElement) ? document.activeElement.closest('[data-id]')?.dataset.id : null;
    const scroll = list.scrollTop;
    const items = visible();
    if (!items.some((i) => i.id === selected)) selected = items[0]?.id ?? null;
    list.innerHTML = rowsHtml(items);
    list.scrollTop = scroll;
    if (focusedId) /** @type {HTMLElement|null} */ (list.querySelector(`[data-id="${CSS.escape(focusedId)}"]`))?.focus({ preventScroll: true });
    const summary = host.querySelector('[data-summary]');
    if (summary) summary.textContent = app.workshop.incidents.summary;
    paintDetail();
  }));
  return () => { clearTimeout(timer); split?.destroy?.(); offs.forEach((off) => off()); };
}

// ---------------------------------------------------------------- pins (ASS-007)

export function renderPins(host, app) {
  const offs = [];
  const view = { painted: false };

  function paint() {
    const ws = app.workshop;
    if (!ws) { host.innerHTML = '<section class="card as-panel"><div class="as-sk-stack" aria-busy="true"><span class="skeleton as-sk w70"></span></div></section>'; return; }
    const pins = ws.pins ?? [];
    const full = pins.length >= ws.pinLimit;
    const pinButton = (kind) => {
      const view = app.subject(kind);
      const label = kind === 'user' ? 'Épingler le compte' : 'Épingler le poste';
      const reason = !view ? (kind === 'user' ? 'Choisissez d’abord le compte dans la session d’assistance.' : 'Choisissez d’abord le poste dans la session d’assistance.')
        : full && !pins.some((p) => p.dn === view.card.dn) ? `${ws.pinLimit}${NBSP}repères sont déjà présents : retirez-en un.` : '';
      return button({ label, icon: kind === 'user' ? 'user' : 'monitor', data: { pin: kind }, disabled: Boolean(reason), reason });
    };
    host.innerHTML = `<section class="card as-panel reveal">
      <div class="as-panel-head"><span class="as-panel-ico">${ico('pin')}</span><div><h2>Repères de session</h2><p>${ws.pinLimit}${NBSP}fiches au plus, en mémoire seulement${NBSP}; vidés à la fermeture ou à une nouvelle session. Un repère se retrouve par son GUID, même déplacé.</p></div>
        <div class="as-panel-tools">
          <div class="as-capacity" role="meter" aria-valuemin="0" aria-valuemax="${ws.pinLimit}" aria-valuenow="${pins.length}" aria-label="Repères utilisés">
            <span class="as-capacity-bar"><span data-p="${(pins.length / ws.pinLimit).toFixed(3)}"></span></span><b>${pins.length}<small>/${ws.pinLimit}</small></b></div>
          ${pinButton('user')}${pinButton('computer')}
        </div></div>
      ${pins.length === 0 ? empty('pin', 'Aucun repère', 'Épinglez le compte ou le poste de la session pour y revenir en un clic pendant l’intervention.')
        : `<div class="as-pins">${pins.map((p, n) => `
          <article class="as-pin reveal" data-identity="${esc(p.identity)}" data-j="${n}" data-tip="Double clic${COLON}ouvrir la fiche">
            ${avatar(p.name, p.kind)}
            <div class="as-pin-body"><b>${esc(p.name)}</b><span class="as-pin-meta">${esc(p.kindLabel)}${NBSP}· ${fresh(p.pinnedAt, 'Épinglé', 4 * 60 * 60_000)}</span></div>
            <small class="as-pin-path" data-tip="${esc(p.dn)}">${ico('ou')}${esc(dnPath(p.dn) || p.dn)}</small>
            <div class="as-pin-actions">
              ${button({ label: 'Ouvrir la fiche', icon: 'external', data: { open: 'fiche' }, tip: 'Retrouve l’objet par son GUID puis ouvre sa fiche, avec ses lectures habituelles' })}
              ${button({ label: 'Reprendre ici', icon: 'lifebuoy', cls: 'ghost sm', data: { open: 'here' }, tip: 'Retrouve l’objet par son GUID et en fait le sujet de la session d’assistance' })}
              ${button({ label: `Retirer ${p.name}`, icon: 'x', cls: 'ghost sm', iconOnly: true, data: { remove: '1' }, tip: 'Retirer le repère' })}
            </div>
          </article>`).join('')}</div>`}
    </section>`;
    applyVars(host);
    enter(host, view);
    app.freshen(host);
  }

  async function open(card, where) {
    const identity = card.dataset.identity;
    card.classList.add('opening');
    card.setAttribute('aria-busy', 'true');
    try {
      const found = await app.call('assistance.pin.locate', { identity });
      app.toast(found.message, { tone: found.moved ? 'info' : 'ok' });
      if (where === 'fiche') {
        // Domenia 1 OpenAdObject: the pin opens as a fiche, with the usual reads of the fiche (on its own screen).
        app.ctx.navigate('fiche', { dn: found.dn });
        return;
      }
      await app.readSubject(found.kind === 'computer' ? 'computer' : 'user', found.dn, { quiet: true });
      app.refreshWorkshop();
    } catch (err) {
      app.toast(errorText(err), { tone: 'warn' });
    } finally {
      card.classList.remove('opening');
      card.removeAttribute('aria-busy');
    }
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
    if (t.closest('[data-remove]')) { await app.workshopCall('assistance.pin.remove', { identity: card.dataset.identity }); return; }
    const opener = t.closest('[data-open]');
    if (opener) await open(card, opener.dataset.open);
  });
  host.addEventListener('dblclick', (e) => {
    const card = e.target instanceof Element && !e.target.closest('button') ? e.target.closest('[data-identity]') : null;
    if (card) open(card, 'fiche');
  });

  paint();
  offs.push(app.on('workshop', paint), app.on('subjects', paint));
  return () => offs.forEach((off) => off());
}
