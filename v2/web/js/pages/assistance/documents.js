// Assistance · documents for a ticket (Domenia 1 ASS-002, ASS-008, ASS-009, ASS-012): the support dossier (text, GLPI or
// ServiceNow, keyed pseudonyms, standalone HTML export), the reviewable ticket report (attempted, confirmed, refused, not
// tested) and the offline diagnostic dossier (manifest and SHA-256). Previews are computed by the engine from the memory of
// the session; a file is written only after a confirmation, as a new dated document of the exports folder.
import { esc, errorText, applyVars, reveal, formatTime } from '../../ui.js';
import { copyButton, confirmDialog, writeClipboard, debounce } from '../../kit/index.js';
import { ico, chip, empty, plural, shortHash, COLON, NBSP } from './common.js';

const SECTIONS = [
  { id: 'context', label: 'Contexte' }, { id: 'attempted', label: 'Tenté' }, { id: 'confirmed', label: 'Confirmé' },
  { id: 'refused', label: 'Refusé' }, { id: 'notTested', label: 'Non testé' }, { id: 'limits', label: 'Limites' },
];
const TEMPLATES = [
  { id: 'text', label: 'Texte', tip: 'Texte brut, comme Domenia 1' },
  { id: 'glpi', label: 'GLPI', tip: 'Titres et listes Markdown' },
  { id: 'servicenow', label: 'ServiceNow', tip: 'Notes de travail' },
];
const SECTION_LABEL = { etat: 'État', postes: 'Postes', observations: 'Observations', associations: 'Associations', requetes: 'Requêtes' };
const OPTIONS = [
  { id: 'observations', label: 'Observations', text: 'Derniers relevés de présence et d’inventaire, datés, champs secrets exclus.' },
  { id: 'associations', label: 'Associations', text: 'Liens utilisateur ↔ poste mémorisés (responsable déclaré, sessions vues).' },
  { id: 'requetes', label: 'Requêtes enregistrées', text: 'Définitions et empreintes des requêtes non archivées.' },
];

function resultLine(result) {
  if (!result) return '';
  return `<div class="as-saved ${result.saved ? 'ok' : 'off'} enter">${ico(result.saved ? 'check' : 'info')}
    <span>${esc(result.message)}${result.path ? `<br><span class="mono">${esc(result.path)}</span>` : ''}</span>
    ${result.path ? copyButton(result.path, { label: 'Copier le chemin', done: 'Chemin copié' }) : ''}</div>`;
}

// ---------------------------------------------------------------- support dossier and ticket report

export function renderDossier(host, app) {
  const offs = [];
  const m = app.memory.report;
  if (!m.sections) m.sections = SECTIONS.map((s) => s.id);
  let preview = null;
  let error = '';
  let lastExport = null;
  let seq = 0;

  function subjectChoice() {
    const user = app.subject('user');
    const computer = app.subject('computer');
    if (m.subject === 'user' && !user) m.subject = computer ? 'computer' : 'none';
    if (m.subject === 'computer' && !computer) m.subject = user ? 'user' : 'none';
    if (m.subject === 'none' && m.kind === 'ticket') m.subject = user ? 'user' : computer ? 'computer' : 'none';
    return { user, computer };
  }

  function form() {
    const { user, computer } = subjectChoice();
    const incidents = app.workshop?.incidents?.items ?? [];
    if (m.incident && !incidents.some((i) => i.id === m.incident)) m.incident = null;
    const ws = app.workshop;
    const radio = (value, label, disabled, sub = '') => `<label class="as-radio${disabled ? ' disabled' : ''}"><input type="radio" class="k-radio" name="as-doc-subject" value="${value}"${m.subject === value ? ' checked' : ''}${disabled ? ' disabled' : ''}><span><b>${esc(label)}</b>${sub ? `<small>${esc(sub)}</small>` : ''}</span></label>`;
    const subjectField = `<fieldset class="as-field"><legend>Fiche du dossier</legend><div class="as-radios">
        ${radio('user', 'Compte', !user, user?.card?.name ?? 'Non choisi')}
        ${radio('computer', 'Poste', !computer, computer?.card?.name ?? 'Non choisi')}
        ${m.kind === 'support' ? radio('none', 'Aucune', false, 'Comparaison et incident seulement') : ''}
      </div></fieldset>`;
    const pseudo = `<div class="as-field as-pseudo">
        <label class="as-toggle"><input type="checkbox" class="switch" data-field="pseudonymize"${m.pseudonymize ? ' checked' : ''}><span><b>Pseudonymiser les noms</b><small>Pseudonymes HMAC-SHA256 sous votre clé${NBSP}; la table de correspondance reste sur ce poste, jamais dans le texte.</small></span></label>
        <div class="as-key"${m.pseudonymize ? '' : ' hidden'}><label for="as-doc-key">Clé de pseudonymisation</label>
          <input class="input mono" id="as-doc-key" type="password" autocomplete="off" spellcheck="false" minlength="8" maxlength="256" data-field="key" placeholder="8 caractères au moins">
          <small>Jamais enregistrée, jamais journalisée${NBSP}; la même clé redonne les mêmes pseudonymes.</small></div>
      </div>`;
    if (m.kind === 'ticket') {
      return `${subjectField}
        <fieldset class="as-field"><legend>Sections</legend><div class="as-checks">${SECTIONS.map((s) => `<label class="as-check"><input type="checkbox" class="k-checkbox" data-section="${s.id}"${m.sections.includes(s.id) ? ' checked' : ''}><span>${esc(s.label)}</span></label>`).join('')}</div></fieldset>
        <p class="as-note">${ico('info')}Le compte rendu reprend les étapes des parcours lancées pour cette fiche et les reçus d’écriture de l’objet, rattachés par son GUID. «${NBSP}Envoyé${NBSP}» n’est jamais «${NBSP}fait${NBSP}».</p>
        ${pseudo}`;
    }
    return `<div class="as-field"><label for="as-doc-ticket">Référence du ticket</label>
        <input class="input" id="as-doc-ticket" type="text" maxlength="80" data-field="ticket" value="${esc(m.ticket)}" placeholder="Ex. INC-2026-10421 (facultatif)" autocomplete="off">
        <small>Filtrée, 80 caractères au plus.</small></div>
      <fieldset class="as-field"><legend>Gabarit</legend><div class="as-seg" role="radiogroup">${TEMPLATES.map((t) => `<label class="as-seg-item" data-tip="${esc(t.tip)}"><input type="radio" name="as-doc-template" value="${t.id}"${m.template === t.id ? ' checked' : ''}><span>${esc(t.label)}</span></label>`).join('')}</div></fieldset>
      ${subjectField}
      <div class="as-field"><label for="as-doc-incident">Incident de la session</label>
        <span class="k-select"><select class="input" id="as-doc-incident" data-field="incident"><option value="">Aucun incident</option>${incidents.map((i) => `<option value="${esc(i.id)}"${m.incident === i.id ? ' selected' : ''}>${esc(`${formatTime(i.at) ?? '—'} · ${i.title}`)}</option>`).join('')}</select></span>
        <small>Seules ses explications sont reprises, jamais le message brut.</small></div>
      <div class="as-field"><span class="as-field-k">Comparaison A / B</span>
        <p class="as-inline">${ws?.comparison?.ready ? chip('ok', 'Incluse', { icon: 'check' }) : chip('off', 'Absente', { icon: 'info' })}<small>${ws?.comparison?.ready ? esc(ws.comparison.summary) : 'Capturez A et B dans « Comparer A / B » pour l’inclure.'}</small></p></div>
      ${pseudo}`;
  }

  function previewCard() {
    const isTicket = m.kind === 'ticket';
    if (error) {
      return `<div class="as-banner warn">${ico('alert')}<div><b>Aperçu impossible</b><p>${esc(error)}</p></div></div>`;
    }
    if (!preview) return '<div class="as-sk-stack" aria-busy="true"><span class="skeleton as-sk w40"></span><span class="skeleton as-sk w100"></span><span class="skeleton as-sk w85"></span><span class="skeleton as-sk w70"></span></div>';
    if (!preview.ready) return `<div class="as-banner warn">${ico('lock')}<div><b>Compte rendu refusé</b><p>${esc(preview.reason)}</p></div></div>`;
    const counts = preview.counts
      ? `<div class="as-doc-counts">${chip('info', `Tenté ${preview.counts.attempted}`)}${chip('ok', `Confirmé ${preview.counts.confirmed}`)}${chip('alert', `Refusé ${preview.counts.refused}`)}${chip('off', `Non testé ${preview.counts.notTested}`)}${preview.excluded && (preview.excluded.otherObject + preview.excluded.unlinked) ? chip('warn', `${preview.excluded.otherObject + preview.excluded.unlinked} écarté(s)`) : ''}</div>`
      : '';
    const map = preview.pseudonymized && preview.map?.length
      ? `<details class="as-map"><summary>${ico('lock')}Table de correspondance (${preview.map.length})${NBSP}· reste sur ce poste</summary><div class="as-map-rows">${preview.map.map((e) => `<div><span class="mono">${esc(e.pseudonym)}</span><span>${esc(e.kind)}</span><span>${esc(e.original)}</span></div>`).join('')}</div></details>`
      : '';
    return `${counts}
      <pre class="as-pre" tabindex="0" aria-label="Aperçu du document">${esc(preview.text)}</pre>
      <div class="as-doc-actions">
        <button class="btn subtle" type="button" data-copy-text>${ico('copy')}Copier le texte</button>
        <button class="btn primary" type="button" data-export>${ico(isTicket ? 'save' : 'download')}${isTicket ? 'Enregistrer en texte' : 'Exporter en HTML'}</button>
      </div>
      ${resultLine(lastExport)}
      ${map}`;
  }

  function paint() {
    host.innerHTML = `<div class="as-stack">
      <div class="as-switch big reveal" role="group" aria-label="Document">
        <button type="button" data-kind="support" aria-pressed="${m.kind === 'support'}">${ico('ticket')}Dossier support</button>
        <button type="button" data-kind="ticket" aria-pressed="${m.kind === 'ticket'}">${ico('steps')}Compte rendu de ticket</button>
      </div>
      <div class="as-doc-grid">
        <section class="card as-panel as-doc-form reveal">
          <div class="as-panel-head"><span class="as-panel-ico">${ico(m.kind === 'ticket' ? 'steps' : 'ticket')}</span><div><h2>${m.kind === 'ticket' ? 'Compte rendu relisible' : 'Dossier support'}</h2>
            <p>${m.kind === 'ticket' ? 'Ce qui a été tenté, confirmé, refusé ou non testé pour une fiche, avant de l’envoyer.' : 'Objet observé, constats, attributs fournis, comparaison A / B, incident choisi et limites.'}</p></div></div>
          <form class="as-form" data-form novalidate>${form()}</form>
        </section>
        <section class="card as-panel as-doc-preview reveal">
          <div class="as-panel-head"><span class="as-panel-ico">${ico('eye')}</span><div><h2>Aperçu</h2><p data-meta>Calculé sur ce poste, rien n’est envoyé.</p></div>
            <div class="as-panel-meta" data-chips></div></div>
          <div data-preview aria-live="polite">${previewCard()}</div>
        </section>
      </div>
    </div>`;
    paintMeta();
    applyVars(host);
    reveal(host);
  }

  function paintMeta() {
    const chips = host.querySelector('[data-chips]');
    if (!chips) return;
    chips.innerHTML = preview?.ready
      ? `${chip('off', plural(preview.lines, 'ligne', 'lignes'))}${chip('off', plural(preview.characters, 'caractère', 'caractères'))}<span class="as-sha" data-tip="Empreinte SHA-256 du texte">${ico('fingerprint')}${shortHash(preview.sha256)}${copyButton(preview.sha256, { label: 'Copier l’empreinte', done: 'Empreinte copiée' })}</span>${preview.pseudonymized ? chip('accent', 'Pseudonymisé', { icon: 'lock' }) : ''}`
      : '';
  }

  function paintPreview() {
    const box = host.querySelector('[data-preview]');
    if (box) box.innerHTML = previewCard();
    paintMeta();
  }

  function key() {
    return host.querySelector('[data-field="key"]')?.value ?? '';
  }

  function args() {
    const dn = m.subject === 'none' ? null : app.dnOf(m.subject);
    if (m.kind === 'ticket') return { dn, sections: m.sections, pseudonymize: m.pseudonymize, key: m.pseudonymize ? key() : null };
    return { dn, ticket: m.ticket || null, template: m.template, incident: m.incident, pseudonymize: m.pseudonymize, key: m.pseudonymize ? key() : null };
  }

  const refresh = debounce(async () => {
    const my = ++seq;
    error = '';
    if (m.kind === 'ticket' && !app.dnOf(m.subject)) {
      preview = null;
      const box = host.querySelector('[data-preview]');
      if (box) box.innerHTML = empty('user', 'Aucune fiche', 'Choisissez le compte ou le poste de la session pour en faire le compte rendu.');
      paintMeta();
      return;
    }
    if (m.pseudonymize && key().length < 8) {
      preview = null;
      error = 'Saisissez une clé de pseudonymisation de 8 caractères au moins : aucun aperçu en clair n’est produit à la place.';
      paintPreview();
      return;
    }
    try {
      const out = await app.call(m.kind === 'ticket' ? 'assistance.ticket.preview' : 'assistance.report.preview', args());
      if (my !== seq) return;
      preview = out;
    } catch (err) {
      if (my !== seq) return;
      preview = null;
      error = errorText(err);
    }
    paintPreview();
  }, 260);

  host.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const kindButton = t.closest('.as-switch [data-kind]');
    if (kindButton && kindButton.dataset.kind !== m.kind) {
      m.kind = kindButton.dataset.kind;
      preview = null;
      lastExport = null;
      paint();
      refresh();
      return;
    }
    if (t.closest('[data-copy-text]') && preview?.text) {
      const ok = await writeClipboard(preview.text);
      if (ok) { app.memory.transmitted = true; app.emit('flow'); }
      app.toast(ok ? 'Texte copié dans le presse-papiers. Il contient des métadonnées internes : relisez-le avant de le partager.' : 'Copie impossible : le presse-papiers est indisponible.', { tone: ok ? 'ok' : 'warn' });
      return;
    }
    if (t.closest('[data-export]') && preview?.ready) {
      const ticket = m.kind === 'ticket';
      const ok = await confirmDialog({
        title: ticket ? 'Enregistrer le compte rendu ?' : 'Exporter le dossier support ?',
        message: `Le document contient des identifiants et des métadonnées internes du parc, pas les champs secrets dédiés. Il est écrit dans un nouveau fichier daté du dossier des exports (${ticket ? 'texte' : 'HTML autonome, sans script ni ressource externe'}), sans aucun envoi.`,
        confirmLabel: ticket ? 'Enregistrer' : 'Exporter', icon: ticket ? 'save' : 'download',
      });
      if (!ok) return;
      try {
        lastExport = await app.call(ticket ? 'assistance.ticket.export' : 'assistance.report.export', args());
        app.memory.transmitted = true;
        app.emit('flow');
        app.toast(lastExport.message, { tone: lastExport.saved ? 'ok' : 'info' });
      } catch (err) {
        app.toast(errorText(err), { tone: 'warn' });
      }
      paintPreview();
    }
  });
  host.addEventListener('input', (e) => {
    const t = e.target;
    if (!(t instanceof HTMLInputElement || t instanceof HTMLSelectElement)) return;
    if (t.dataset.field === 'ticket') m.ticket = t.value;
    if (t.dataset.field === 'key' || t.dataset.field === 'ticket') refresh();
  });
  host.addEventListener('change', (e) => {
    const t = e.target;
    if (!(t instanceof HTMLInputElement || t instanceof HTMLSelectElement)) return;
    if (t.name === 'as-doc-template') m.template = t.value;
    else if (t.name === 'as-doc-subject') m.subject = t.value;
    else if (t.dataset.field === 'incident') m.incident = t.value || null;
    else if (t.dataset.field === 'pseudonymize') {
      m.pseudonymize = t.checked;
      const box = host.querySelector('.as-key');
      if (box) box.hidden = !t.checked;
      if (t.checked) host.querySelector('[data-field="key"]')?.focus();
    } else if (t.dataset.section) {
      m.sections = SECTIONS.map((s) => s.id).filter((id) => host.querySelector(`[data-section="${id}"]`)?.checked);
    } else return;
    lastExport = null;
    refresh();
  });
  host.addEventListener('submit', (e) => e.preventDefault());

  paint();
  refresh();
  const repaintForm = () => {
    const formEl = host.querySelector('[data-form]');
    if (formEl) {
      const typedKey = key();
      formEl.innerHTML = form();
      const input = host.querySelector('[data-field="key"]');
      if (input) input.value = typedKey;
    }
    refresh();
  };
  offs.push(app.on('subjects', repaintForm), app.on('workshop', repaintForm));
  return () => { refresh.cancel(); offs.forEach((off) => off()); };
}

// ---------------------------------------------------------------- offline dossier (ASS-012)

export function renderOffline(host, app) {
  const offs = [];
  const m = app.memory.offline;
  let scopeLabel = null;
  let running = false;
  let result = null;

  function perimeterCards() {
    const computer = app.subject('computer');
    const pins = (app.workshop?.pins ?? []).filter((p) => p.kind === 'computer');
    const cards = [
      { id: 'subject', icon: 'monitor', title: 'Poste de la session', text: computer ? computer.card.name : 'Choisissez d’abord le poste concerné.', ok: Boolean(computer) },
      { id: 'workingOu', icon: 'ou', title: 'OU de travail', text: scopeLabel ? `OU ${scopeLabel}, sous-OU comprises` : 'OU choisie sur l’Accueil', ok: true },
      { id: 'pins', icon: 'pin', title: 'Postes épinglés', text: pins.length ? plural(pins.length, 'poste épinglé', 'postes épinglés') : 'Aucun poste épinglé.', ok: pins.length > 0 },
    ];
    if (!cards.find((c) => c.id === m.scope)?.ok) m.scope = cards.find((c) => c.ok)?.id ?? 'workingOu';
    return cards.map((c, n) => `<label class="as-choice${c.ok ? '' : ' disabled'}" data-j="${n}">
      <input type="radio" name="as-off-scope" value="${c.id}"${m.scope === c.id ? ' checked' : ''}${c.ok ? '' : ' disabled'}>
      <span class="as-choice-ico">${ico(c.icon)}</span><span class="as-choice-body"><b>${esc(c.title)}</b><small>${esc(c.text)}</small></span>
      <span class="as-choice-mark" aria-hidden="true">${ico('check')}</span></label>`).join('');
  }

  function resultCard() {
    if (running) return `<div class="as-progress" aria-busy="true">${ico('archive')}<div><b>Préparation du dossier…</b><p>Lecture seule des données locales, sans accès réseau ni à l’annuaire.</p><span class="as-progress-bar"><span></span></span></div></div>`;
    if (!result) return empty('archive', 'Aucun dossier préparé dans cette session', 'Le dossier sert à une intervention sans Domenia : il se transporte et se vérifie avec ses empreintes.');
    return `<div class="as-medal-row enter"><span class="as-medal ${result.saved ? 'ok' : 'info'}">${ico(result.saved ? 'check' : 'info')}</span>
        <div><h3>${result.saved ? 'Dossier prêt' : 'Dossier préparé en mémoire'}</h3><p>${esc(result.message)}</p></div></div>
      ${result.path ? `<p class="as-path"><span class="mono">${esc(result.path)}</span>${copyButton(result.path, { label: 'Copier le chemin', done: 'Chemin copié' })}</p>` : ''}
      <div class="as-doc-counts">${result.sections.map((s) => chip(s.truncated ? 'warn' : s.elements ? 'ok' : 'off', `${SECTION_LABEL[s.section] ?? s.section} ${s.elements}${s.truncated ? ' (limite)' : ''}`)).join('')}${result.truncated ? chip('warn', 'Périmètre limité à 500 postes') : ''}</div>
      <div class="as-files" role="table" aria-label="Fichiers du dossier">
        <div class="as-file head" role="row"><span role="columnheader">Fichier</span><span role="columnheader">Taille</span><span role="columnheader">SHA-256</span></div>
        ${result.files.map((f, n) => `<div class="as-file" role="row" data-j="${n}"><span role="cell" class="mono">${ico(f.name.endsWith('.json') ? 'file' : 'file')}${esc(f.name)}</span><span role="cell">${esc(plural(f.characters, 'caractère', 'caractères'))}</span><span role="cell">${shortHash(f.sha256)}${copyButton(f.sha256, { label: `Copier l’empreinte de ${f.name}`, done: 'Empreinte copiée' })}</span></div>`).join('')}
      </div>
      <details class="as-map"><summary>${ico('lock')}Toujours exclus (${result.excluded.length})</summary><ul class="as-excluded">${result.excluded.map((x) => `<li>${esc(x)}</li>`).join('')}</ul></details>`;
  }

  function paint() {
    host.innerHTML = `<div class="as-stack">
      <div class="as-banner info reveal">${ico('shield')}<div><b>Lecture seule des données locales, sans accès réseau ni à l’annuaire</b>
        <p>Un nouveau dossier daté, avec manifeste et empreintes SHA-256, dans le dossier des exports. Mots de passe, clés BitLocker, données LAPS (métadonnées comprises) et champs nommés comme des secrets sont exclus. Les données sont datées, non revérifiées.</p></div></div>
      <div class="as-doc-grid">
        <section class="card as-panel reveal">
          <div class="as-panel-head"><span class="as-panel-ico">${ico('archive')}</span><div><h2>Dossier de diagnostic hors ligne</h2><p>Jamais tout le domaine${NBSP}: un poste, une OU ou les postes épinglés (500 au plus).</p></div></div>
          <fieldset class="as-field"><legend>Périmètre du dossier</legend><div class="as-choices">${perimeterCards()}</div></fieldset>
          <fieldset class="as-field"><legend>Sections</legend>
            <div class="as-locked">${chip('accent', 'État de la base', { icon: 'lock' })}${chip('accent', 'Postes', { icon: 'lock' })}<small>toujours inclus</small></div>
            <div class="as-options-list">${OPTIONS.map((o) => `<label class="as-check rich"><input type="checkbox" class="k-checkbox" data-option="${o.id}"${m.sections.includes(o.id) ? ' checked' : ''}><span><b>${esc(o.label)}</b><small>${esc(o.text)}</small></span></label>`).join('')}</div>
          </fieldset>
          <div class="as-doc-actions"><button class="btn primary" type="button" data-prepare${running ? ' disabled' : ''}>${running ? '<span class="k-spin" aria-hidden="true"></span>' : ico('archive')}Préparer le dossier</button></div>
          <p class="as-note">${ico('info')}La commande en ligne de Domenia${NBSP}1 (Domenia-Automate.ps1 dossier) aura son équivalent dans Domenia.exe${NBSP}; le contenu et le format (Domenia.OfflineDossier/1) restent les mêmes.</p>
        </section>
        <section class="card as-panel as-off-result reveal"><div class="as-panel-head"><span class="as-panel-ico">${ico('fingerprint')}</span><div><h2>Résultat</h2><p>Fichiers, tailles et empreintes, à vérifier avec Get-FileHash.</p></div></div>
          <div data-result aria-live="polite">${resultCard()}</div></section>
      </div>
    </div>`;
    applyVars(host);
    reveal(host);
  }

  host.addEventListener('change', (e) => {
    const t = e.target;
    if (!(t instanceof HTMLInputElement)) return;
    if (t.name === 'as-off-scope') m.scope = t.value;
    if (t.dataset.option) m.sections = OPTIONS.map((o) => o.id).filter((id) => host.querySelector(`[data-option="${id}"]`)?.checked);
  });
  host.addEventListener('click', async (e) => {
    if (!(e.target instanceof Element) || !e.target.closest('[data-prepare]') || running) return;
    running = true;
    paint();
    try {
      result = await app.call('assistance.dossier.prepare', { scope: m.scope, dn: app.dnOf('computer'), sections: m.sections });
      app.memory.transmitted = true;
      app.emit('flow');
      app.toast(`${result.saved ? 'Dossier hors ligne prêt' : 'Dossier préparé en mémoire, non écrit dans ce mode'}${COLON}${plural(result.files.length, 'fichier', 'fichiers')} avec leurs empreintes SHA-256.`, { tone: result.saved ? 'ok' : 'info' });
    } catch (err) {
      app.toast(`Dossier hors ligne non produit${COLON}${errorText(err)}`, { tone: 'warn' });
    } finally {
      running = false;
      if (!app.disposed()) paint();
    }
  });

  paint();
  app.call('session.info').then((s) => { scopeLabel = s?.scope?.label ?? null; if (!app.disposed() && !running) paint(); }).catch((err) => console.error(err));
  offs.push(app.on('subjects', () => { if (!running) paint(); }), app.on('workshop', () => { if (!running) paint(); }));
  return () => offs.forEach((off) => off());
}

