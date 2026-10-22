// Assistance · the session of assistance (hero card): the account and the workstation concerned, each chosen by a search
// in the local index (assistance.subjects.search) or among the suggestions (assistance.subjects.suggest), then read once
// (assistance.subject.read, the operator's gesture). The workstation the account is responsible for (managedBy) is offered.
import { esc, debounce, highlight, fold } from '../../kit/util.js';
import { errorText } from '../../ui.js';
import { ico, chip, avatar, tone, when, COLON, NBSP } from './common.js';

const MIN_TEXT = 2;
const KIND = {
  user: { label: 'Compte concerné', short: 'Compte', icon: 'user', placeholder: 'Nom, identifiant ou adresse du compte…', none: 'Aucun compte ne correspond.' },
  computer: { label: 'Poste concerné', short: 'Poste', icon: 'monitor', placeholder: 'Nom du poste (PC-…, PT-…)…', none: 'Aucun poste ne correspond.' },
};

/** Suggestions of the session (locked accounts, workstations to watch), read once. */
export async function loadSuggestions(app) {
  if (app.suggestions) return app.suggestions;
  if (!app.suggestionsPromise) {
    app.suggestionsPromise = app.call('assistance.subjects.suggest')
      .then((list) => { app.suggestions = Array.isArray(list) ? list : []; return app.suggestions; })
      .catch((err) => { console.error(err); app.suggestionsPromise = null; return []; });
  }
  return app.suggestionsPromise;
}

/** DN of a subject named in the address: a DN as is, else the exact login or name found in the local index. */
export async function resolveSubject(app, kind, value) {
  const text = String(value ?? '').trim();
  if (!text) return null;
  if (text.includes('=')) return text;
  try {
    const hits = await app.call('assistance.subjects.search', { text: text.slice(0, 100) });
    const wanted = text.toLowerCase();
    const hit = (hits ?? []).find((h) => h.kind === kind && (h.login.toLowerCase().replace(/\$$/, '') === wanted || h.name.toLowerCase() === wanted))
      ?? (hits ?? []).find((h) => h.kind === kind);
    if (!hit) app.toast(`${KIND[kind].short} introuvable${COLON}${text}.`, { tone: 'warn' });
    return hit?.dn ?? null;
  } catch (err) {
    app.toast(`Recherche impossible${COLON}${errorText(err)}`, { tone: 'alert' });
    return null;
  }
}

function option(hit, n, query) {
  const t = tone(hit.tone);
  return `<li role="option" id="as-opt-${n}" class="as-option" data-dn="${esc(hit.dn)}" aria-selected="false">
    ${avatar(hit.name, hit.kind, 'sm')}
    <span class="as-option-body"><b>${highlight(hit.name, fold(query))}</b><small><span class="mono">${esc(hit.login)}</span>${NBSP}· ${esc(hit.detail)}</small></span>
    ${chip(t, hit.stateLabel)}
  </li>`;
}

function suggestionOption(s, n) {
  const hit = s.subject;
  return `<li role="option" id="as-opt-${n}" class="as-option suggestion" data-dn="${esc(hit.dn)}" aria-selected="false">
    ${avatar(hit.name, hit.kind, 'sm')}
    <span class="as-option-body"><b>${esc(hit.name)}</b><small>${esc(s.reason)}</small></span>
    ${chip(tone(hit.tone), hit.stateLabel)}
  </li>`;
}

export function renderSession(host, app) {
  host.innerHTML = `<div class="as-session-head">
      <span class="as-session-ico">${ico('lifebuoy')}</span>
      <div><span class="as-session-k">Session d’assistance</span><span class="as-session-title">Pour qui intervenez-vous${NBSP}?</span></div>
    </div>
    <div class="as-slots">
      <div class="as-slot" data-kind="user"></div>
      <div class="as-slot" data-kind="computer"></div>
    </div>
    <div class="as-related" data-related hidden></div>`;
  const slots = { user: host.querySelector('[data-kind="user"]'), computer: host.querySelector('[data-kind="computer"]') };
  const related = host.querySelector('[data-related]');
  const offs = [];

  function paint(kind) {
    const slot = slots[kind];
    const view = app.subject(kind);
    const k = KIND[kind];
    slot.classList.toggle('filled', Boolean(view));
    slot.classList.remove('busy');
    slot.removeAttribute('aria-busy');
    if (app.busy[kind]) {
      slot.classList.add('busy');
      slot.setAttribute('aria-busy', 'true');
      slot.innerHTML = `<span class="as-slot-ico">${ico(k.icon)}</span><div class="as-slot-body"><span class="as-slot-k">${esc(k.label)}</span>
        <span class="skeleton as-sk w70"></span><span class="skeleton as-sk w40"></span></div>`;
      return;
    }
    if (!view) {
      slot.innerHTML = `<span class="as-slot-ico">${ico(k.icon)}</span>
        <div class="as-slot-body">
          <label class="as-slot-k" for="as-search-${kind}">${esc(k.label)}</label>
          <div class="as-combo" role="combobox" aria-expanded="false" aria-haspopup="listbox" aria-owns="as-list-${kind}">
            ${ico('search', 'as-combo-ico')}
            <input class="input as-combo-input" id="as-search-${kind}" type="search" autocomplete="off" spellcheck="false" placeholder="${esc(k.placeholder)}"
              aria-autocomplete="list" aria-controls="as-list-${kind}" maxlength="100">
            <span class="k-spin as-combo-spin" hidden aria-hidden="true"></span>
          </div>
          <ul class="as-options" id="as-list-${kind}" role="listbox" aria-label="${esc(k.label)}" hidden></ul>
        </div>`;
      bindCombo(kind, slot);
      return;
    }
    const c = view.card;
    const pills = (c.pills ?? []).slice(0, 3).map((p) => chip(tone(p.tone), p.label)).join('');
    slot.innerHTML = `${avatar(c.name, c.kind === 'computer' ? 'computer' : 'user')}
      <div class="as-slot-body">
        <span class="as-slot-k">${esc(k.short)}${NBSP}· lu ${when(c.readAt)}</span>
        <b class="as-slot-name">${esc(c.name)}</b>
        <span class="as-slot-sub"><span class="mono">${esc(c.login)}</span>${c.path ? `${NBSP}· ${esc(c.path)}` : ''}</span>
        <span class="as-slot-pills">${pills}</span>
      </div>
      <div class="as-slot-actions">
        <button class="btn ghost icon sm" type="button" data-act="analyse" aria-label="Constats de ${esc(c.name)}" data-tip="Comprendre la fiche">${ico('bulb')}</button>
        <button class="btn ghost icon sm" type="button" data-act="reread" aria-label="Relire ${esc(c.name)}" data-tip="Relire la fiche">${ico('refresh')}</button>
        <button class="btn ghost icon sm" type="button" data-act="clear" aria-label="Changer de ${esc(k.short.toLowerCase())}" data-tip="Changer">${ico('x')}</button>
      </div>`;
    slot.querySelector('[data-act="reread"]').addEventListener('click', () => app.readSubject(kind, c.dn));
    slot.querySelector('[data-act="analyse"]').addEventListener('click', () => { app.memory.focus = kind; app.go('constats'); });
    slot.querySelector('[data-act="clear"]').addEventListener('click', () => {
      app.clearSubject(kind);
      requestAnimationFrame(() => slots[kind].querySelector('input')?.focus());
    });
  }

  function paintRelated() {
    const items = [];
    for (const [from, to] of [['user', 'computer'], ['computer', 'user']]) {
      const view = app.subject(from);
      if (!view || app.subject(to)) continue;
      for (const hit of (view.card.related ?? []).slice(0, 2)) {
        items.push(`<button type="button" class="as-related-item" data-dn="${esc(hit.dn)}" data-kind="${to}">
          ${ico(to === 'computer' ? 'monitor' : 'user')}<span>${esc(to === 'computer' ? 'Poste associé' : 'Utilisateur associé')}${COLON}<b>${esc(hit.name)}</b></span>
          <span class="as-related-go">Choisir${ico('chevronRight')}</span></button>`);
      }
    }
    related.hidden = items.length === 0;
    related.innerHTML = items.length ? `<span class="as-related-k">${ico('link')}managedBy</span>${items.join('')}` : '';
  }
  related.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-dn]') : null;
    if (b) app.readSubject(b.dataset.kind, b.dataset.dn);
  });

  function bindCombo(kind, slot) {
    const combo = slot.querySelector('.as-combo');
    const input = slot.querySelector('input');
    const list = slot.querySelector('.as-options');
    const spin = slot.querySelector('.as-combo-spin');
    let items = [];
    let active = -1;
    let seq = 0;

    const open = (on) => {
      list.hidden = !on;
      combo.setAttribute('aria-expanded', String(on));
      slot.classList.toggle('open', on);
      if (!on) { active = -1; input.removeAttribute('aria-activedescendant'); }
    };
    const setActive = (n) => {
      const options = [...list.querySelectorAll('[role="option"]')];
      if (!options.length) return;
      active = (n + options.length) % options.length;
      options.forEach((o, i) => o.setAttribute('aria-selected', String(i === active)));
      input.setAttribute('aria-activedescendant', options[active].id);
      options[active].scrollIntoView({ block: 'nearest' });
    };
    const pick = (dn) => {
      open(false);
      app.readSubject(kind, dn);
    };
    const showSuggestions = async () => {
      const my = ++seq;
      const all = await loadSuggestions(app);
      if (my !== seq || input.value.trim().length >= MIN_TEXT || document.activeElement !== input) return;
      const mine = all.filter((s) => s.subject.kind === kind);
      items = mine.map((s) => s.subject);
      list.innerHTML = mine.length
        ? `<li class="as-options-head" role="presentation">${ico('sparkles')}Suggestions${NBSP}· d’après les données locales</li>${mine.map((s, n) => suggestionOption(s, `${kind}-${n}`)).join('')}`
        : `<li class="as-options-empty" role="presentation">Tapez au moins deux caractères pour chercher.</li>`;
      open(true);
    };
    const search = debounce(async () => {
      const text = input.value.trim();
      if (text.length < MIN_TEXT) { showSuggestions(); return; }
      const my = ++seq;
      spin.hidden = false;
      try {
        const hits = await app.call('assistance.subjects.search', { text });
        if (my !== seq) return;
        items = (hits ?? []).filter((h) => h.kind === kind);
        list.innerHTML = items.length
          ? items.map((h, n) => option(h, `${kind}-${n}`, text)).join('')
          : `<li class="as-options-empty" role="presentation">${esc(KIND[kind].none)}</li>`;
        open(true);
        if (items.length) setActive(0);
      } catch (err) {
        if (my !== seq) return;
        list.innerHTML = `<li class="as-options-empty" role="presentation">${esc(errorText(err))}</li>`;
        open(true);
      } finally {
        if (my === seq) spin.hidden = true;
      }
    }, 180);

    input.addEventListener('input', search);
    input.addEventListener('focus', () => { if (input.value.trim().length < MIN_TEXT) showSuggestions(); else search(); });
    input.addEventListener('blur', () => setTimeout(() => { if (document.activeElement !== input) open(false); }, 160));
    input.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown') { e.preventDefault(); if (list.hidden) search(); else setActive(active + 1); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); setActive(active - 1); }
      else if (e.key === 'Enter') {
        const options = [...list.querySelectorAll('[role="option"]')];
        const chosen = options[active] ?? (options.length === 1 ? options[0] : null);
        if (chosen) { e.preventDefault(); pick(chosen.dataset.dn); }
      } else if (e.key === 'Escape' && !list.hidden) { e.preventDefault(); e.stopPropagation(); open(false); }
    });
    list.addEventListener('pointerdown', (e) => e.preventDefault());
    list.addEventListener('click', (e) => {
      const o = e.target instanceof Element ? e.target.closest('[role="option"]') : null;
      if (o) pick(o.dataset.dn);
    });
  }

  const repaint = () => { paint('user'); paint('computer'); paintRelated(); };
  repaint();
  offs.push(app.on('subjects', repaint), app.on('busy', repaint));
  return () => offs.forEach((off) => off());
}
