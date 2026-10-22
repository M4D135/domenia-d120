// Assistance · documents for a ticket (Domenia 1 ASS-002, ASS-008, ASS-009, ASS-012): the support dossier (text, GLPI or
// ServiceNow, keyed pseudonyms, standalone HTML export), the reviewable ticket report (attempted, confirmed, refused, not
// tested) and the offline diagnostic dossier (manifest and SHA-256, five perimeters, command line equivalent). Previews are
// computed by the engine from the memory of the session; a file is written only after a confirmation, as a new dated document
// of the exports folder, which can then be shown in Windows Explorer.
import { esc, errorText, applyVars, reveal, formatTime } from '../../ui.js';
import { copyButton, confirmDialog, writeClipboard, debounce, createTabs, field, openDrawer, createTree } from '../../kit/index.js';
import { ico, chip, empty, plural, shortHash, button, breakableText, enter, COLON, NBSP } from './common.js';
import { parseNames, dossierCommand } from './format.js';

export { parseNames };

const SECTIONS = [
  { id: 'context', label: 'Contexte' }, { id: 'attempted', label: 'Tenté' }, { id: 'confirmed', label: 'Confirmé' },
  { id: 'refused', label: 'Refusé' }, { id: 'notTested', label: 'Non testé' }, { id: 'limits', label: 'Limites' },
];
const TEMPLATES = [
  { value: 'text', label: 'Texte brut' },
  { value: 'glpi', label: 'GLPI (Markdown)' },
  { value: 'servicenow', label: 'ServiceNow (notes)' },
];
const SECTION_LABEL = { etat: 'État', postes: 'Postes', observations: 'Observations', associations: 'Associations', requetes: 'Requêtes' };
const OPTIONS = [
  { id: 'observations', label: 'Observations', text: 'Derniers relevés de présence et d’inventaire, datés, champs secrets exclus.' },
  { id: 'associations', label: 'Associations', text: 'Liens utilisateur ↔ poste mémorisés (responsable déclaré, sessions vues).' },
  { id: 'requetes', label: 'Requêtes enregistrées', text: 'Définitions et empreintes des requêtes non archivées.' },
];
const MAX_NAMES = 500;

/** Line saying where a document went, with « Copier le chemin » and « Montrer dans l’Explorateur » once it is on the disk. */
function resultLine(result) {
  if (!result) return '';
  return `<div class="as-saved ${result.saved ? 'ok' : 'off'} enter">${ico(result.saved ? 'check' : 'info')}
    <span>${esc(result.message)}${result.path ? `<br><span class="mono as-path-text">${breakableText(result.path)}</span>` : ''}</span>
    ${result.path ? copyButton(result.path, { label: 'Copier le chemin', done: 'Chemin copié' }) : ''}
    ${result.saved ? button({ label: 'Montrer', icon: 'folder', cls: 'ghost sm', data: { reveal: result.name }, tip: 'Montre le document dans l’Explorateur Windows' }) : ''}</div>`;
}

async function revealDocument(app, name) {
  try {
    await app.call('assistance.document.reveal', { name });
  } catch (err) {
    app.toast(errorText(err), { tone: 'warn' });
  }
}

// ---------------------------------------------------------------- support dossier and ticket report

export function renderDossier(host, app) {
  const m = app.memory.report;
  if (!m.sections) m.sections = SECTIONS.map((s) => s.id);
  host.innerHTML = '<div class="as-doc-tabs reveal"></div>';
  const tabs = createTabs(host.firstElementChild, {
    label: 'Document à préparer',
    selected: m.kind,
    tabs: [
      { id: 'support', label: 'Dossier support', icon: 'file', render: (panel) => documentPanel(panel, app, 'support') },
      { id: 'ticket', label: 'Compte rendu de ticket', icon: 'tag', render: (panel) => documentPanel(panel, app, 'ticket') },
    ],
    onChange: (id) => { m.kind = id; },
  });
  reveal(host);
  return () => tabs.destroy();
}

function documentPanel(panel, app, kind) {
  const m = app.memory.report;
  const offs = [];
  const ticket = kind === 'ticket';
  let preview = null;
  let error = '';
  let lastExport = null;
  let seq = 0;
  let typedKey = '';

  function subjectChoice() {
    const user = app.subject('user');
    const computer = app.subject('computer');
    // Until the operator picks one, the document follows the session: the account, else the workstation.
    if (!m.subjectChosen) m.subject = user ? 'user' : computer ? 'computer' : 'none';
    if (m.subject === 'user' && !user) m.subject = computer ? 'computer' : 'none';
    if (m.subject === 'computer' && !computer) m.subject = user ? 'user' : 'none';
    if (m.subject === 'none' && ticket) m.subject = user ? 'user' : computer ? 'computer' : 'none';
    return { user, computer };
  }

  function form() {
    const { user, computer } = subjectChoice();
    const incidents = app.workshop?.incidents?.items ?? [];
    if (m.incident && !incidents.some((i) => i.id === m.incident)) m.incident = null;
    const ws = app.workshop;
    const subjectOptions = [
      { value: 'user', label: user ? `Compte${COLON}${user.card.name}` : 'Compte (non choisi)', disabled: !user },
      { value: 'computer', label: computer ? `Poste${COLON}${computer.card.name}` : 'Poste (non choisi)', disabled: !computer },
      ...(ticket ? [] : [{ value: 'none', label: 'Aucune fiche (comparaison et incident seulement)' }]),
    ];
    const subject = field({ name: 'subject', label: 'Fiche du document', type: 'radio', options: subjectOptions, value: ticket && m.subject === 'none' ? '' : m.subject });
    const pseudo = `<div class="as-pseudo w-full">
        <label class="as-toggle"><input type="checkbox" class="switch" role="switch" data-field="pseudonymize"${m.pseudonymize ? ' checked' : ''}><span><b>Pseudonymiser les noms</b><small>Sujet, captures, manager, groupes et objets cités${NBSP}; pseudonymes HMAC-SHA256 sous votre clé, table de correspondance sur ce poste seulement.</small></span></label>
        <div class="as-key"${m.pseudonymize ? '' : ' hidden'}><label for="as-doc-key-${kind}">Clé de pseudonymisation</label>
          <input class="input mono" id="as-doc-key-${kind}" type="password" autocomplete="off" spellcheck="false" minlength="8" maxlength="256" data-field="key" placeholder="8 caractères au moins">
          <small>Jamais enregistrée ni journalisée${NBSP}; la même clé redonne les mêmes pseudonymes.</small></div>
      </div>`;
    if (ticket) {
      return `${subject}
        <fieldset class="k-field w-full as-sections"><legend>Sections du compte rendu</legend><div class="as-section-list">${SECTIONS.map((s) => `<label class="as-section-item"><input type="checkbox" class="k-checkbox" data-section="${s.id}"${m.sections.includes(s.id) ? ' checked' : ''}><span>${esc(s.label)}</span></label>`).join('')}</div></fieldset>
        <p class="as-note w-full">${ico('info')}<span>Le compte rendu reprend les étapes des parcours lancées pour cette fiche et les reçus d’écriture de l’objet, rattachés par son GUID. «${NBSP}Envoyé${NBSP}» n’est jamais «${NBSP}fait${NBSP}».</span></p>
        ${pseudo}`;
    }
    return `${field({ name: 'ticket', label: 'Référence du ticket', value: m.ticket, maxLength: 80, placeholder: 'Ex. INC-2026-10421 (facultatif)', hint: 'Filtrée, 80 caractères au plus.' })}
      ${field({ name: 'template', label: 'Gabarit', type: 'radio', options: TEMPLATES, value: m.template })}
      ${subject}
      ${field({ name: 'incident', label: 'Incident de la session', type: 'select', value: m.incident ?? '', placeholder: 'Aucun incident',
        options: incidents.map((i) => ({ value: i.id, label: `${formatTime(i.at) ?? '—'} · ${i.title}` })), hint: 'Seules ses explications sont reprises, jamais le message brut.' })}
      <div class="as-inline w-full"><span class="as-field-k">Comparaison A / B</span>${ws?.comparison?.ready ? chip('ok', 'Incluse', { icon: 'check' }) : chip('off', 'Absente', { icon: 'info' })}<small>${ws?.comparison?.ready ? esc(ws.comparison.summary) : 'Capturez A et B dans « Comparer A / B » pour l’inclure.'}</small></div>
      ${pseudo}`;
  }

  function previewCard() {
    if (error) return `<div class="as-banner warn">${ico('alert')}<div><b>Aperçu impossible</b><p>${esc(error)}</p></div></div>`;
    if (ticket && !app.dnOf(m.subject)) return empty('user', 'Aucune fiche', 'Choisissez le compte ou le poste de la session pour en faire le compte rendu.');
    if (!preview) return '<div class="as-sk-stack" aria-busy="true"><span class="skeleton as-sk w40"></span><span class="skeleton as-sk w100"></span><span class="skeleton as-sk w85"></span><span class="skeleton as-sk w70"></span></div>';
    if (!preview.ready) return `<div class="as-banner warn">${ico('lock')}<div><b>Compte rendu refusé</b><p>${esc(preview.reason)}</p></div></div>`;
    const excluded = preview.excluded ? preview.excluded.otherObject + preview.excluded.unlinked : 0;
    const counts = preview.counts
      ? `<div class="as-doc-counts">${chip('info', `Tenté${NBSP}${preview.counts.attempted}`)}${chip('ok', `Confirmé${NBSP}${preview.counts.confirmed}`)}${chip('alert', `Refusé${NBSP}${preview.counts.refused}`)}${chip('off', `Non testé${NBSP}${preview.counts.notTested}`)}${excluded ? chip('warn', plural(excluded, 'élément écarté', 'éléments écartés')) : ''}</div>`
      : '';
    const map = preview.pseudonymized && preview.map?.length
      ? `<details class="as-map"><summary>${ico('lock')}Table de correspondance (${preview.map.length})${NBSP}· reste sur ce poste</summary><div class="as-map-rows">${preview.map.map((e) => `<div><span class="mono">${esc(e.pseudonym)}</span><span>${esc(e.kind)}</span><span>${esc(e.original)}</span></div>`).join('')}</div></details>`
      : '';
    return `${counts}
      <pre class="as-pre" tabindex="0" aria-label="Aperçu du document">${breakableText(preview.text)}</pre>
      <div class="as-doc-actions">
        ${button({ label: 'Copier le texte', icon: 'copy', cls: 'subtle', data: { 'copy-text': '1' } })}
        ${button({ label: ticket ? 'Enregistrer en texte…' : 'Exporter en HTML…', icon: ticket ? 'save' : 'download', cls: 'primary', data: { export: '1' } })}
      </div>
      ${resultLine(lastExport)}
      ${map}`;
  }

  panel.innerHTML = `<div class="as-doc-grid">
      <section class="card as-panel as-doc-form reveal">
        <div class="as-panel-head"><span class="as-panel-ico">${ico(ticket ? 'steps' : 'ticket')}</span><div><h2>${ticket ? 'Compte rendu relisible' : 'Dossier support'}</h2>
          <p>${ticket ? 'Ce qui a été tenté, confirmé, refusé ou non testé pour une fiche, avant de l’envoyer.' : 'Objet observé, constats, attributs fournis, comparaison A / B, incident choisi et limites.'}</p></div></div>
        <form class="k-form as-form" data-form novalidate>${form()}</form>
      </section>
      <section class="card as-panel as-doc-preview reveal">
        <div class="as-panel-head"><span class="as-panel-ico">${ico('eye')}</span><div><h2>Aperçu</h2><p>Calculé sur ce poste, rien n’est envoyé.</p></div>
          <div class="as-panel-meta" data-chips></div></div>
        <div data-preview aria-live="polite">${previewCard()}</div>
      </section>
    </div>`;

  function paintMeta() {
    const chips = panel.querySelector('[data-chips]');
    if (!chips) return;
    chips.innerHTML = preview?.ready
      ? `${chip('off', plural(preview.lines, 'ligne', 'lignes'))}${chip('off', plural(preview.characters, 'caractère', 'caractères'))}<span class="as-sha" data-tip="Empreinte SHA-256 du texte">${ico('fingerprint')}${shortHash(preview.sha256)}${copyButton(preview.sha256, { label: 'Copier l’empreinte', done: 'Empreinte copiée' })}</span>${preview.pseudonymized ? chip('accent', 'Pseudonymisé', { icon: 'lock' }) : ''}`
      : '';
  }

  function paintPreview() {
    const box = panel.querySelector('[data-preview]');
    if (box) box.innerHTML = previewCard();
    paintMeta();
  }

  function repaintForm() {
    const formEl = panel.querySelector('[data-form]');
    if (!formEl) return;
    formEl.innerHTML = form();
    const input = panel.querySelector('[data-field="key"]');
    if (input) input.value = typedKey;
    refresh();
  }

  function args() {
    const dn = m.subject === 'none' ? null : app.dnOf(m.subject);
    const key = m.pseudonymize ? typedKey : null;
    if (ticket) return { dn, sections: m.sections, pseudonymize: m.pseudonymize, key };
    return { dn, ticket: m.ticket || null, template: m.template, incident: m.incident, pseudonymize: m.pseudonymize, key };
  }

  const refresh = debounce(async () => {
    const my = ++seq;
    error = '';
    if (ticket && !app.dnOf(m.subject)) { preview = null; paintPreview(); return; }
    if (m.pseudonymize && typedKey.length < 8) {
      preview = null;
      error = `Saisissez une clé de pseudonymisation de 8 caractères au moins${COLON}aucun aperçu en clair n’est produit à la place.`;
      paintPreview();
      return;
    }
    try {
      const out = await app.call(ticket ? 'assistance.ticket.preview' : 'assistance.report.preview', args());
      if (my !== seq) return;
      preview = out;
    } catch (err) {
      if (my !== seq) return;
      preview = null;
      error = errorText(err);
    }
    paintPreview();
  }, 260);

  panel.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const shown = t.closest('[data-reveal]');
    if (shown) { revealDocument(app, shown.dataset.reveal); return; }
    if (t.closest('[data-copy-text]') && preview?.text) {
      const ok = await writeClipboard(preview.text);
      app.toast(ok ? `Texte copié dans le presse-papiers. Il contient des métadonnées internes${COLON}relisez-le avant de le partager.` : `Copie impossible${COLON}le presse-papiers est indisponible.`, { tone: ok ? 'ok' : 'warn' });
      return;
    }
    if (t.closest('[data-export]') && preview?.ready) {
      const ok = await confirmDialog({
        title: ticket ? 'Enregistrer le compte rendu ?' : 'Exporter le dossier support ?',
        message: `Le document contient des identifiants et des métadonnées internes du parc, pas les champs secrets dédiés${preview.pseudonymized ? ' (noms pseudonymisés)' : ''}. Il est écrit dans un nouveau fichier daté du dossier des exports (${ticket ? 'texte' : 'HTML autonome, sans script ni ressource externe'}), sans aucun envoi. ${app.overview?.exportsLabel ?? ''}`,
        confirmLabel: ticket ? 'Enregistrer' : 'Exporter', icon: ticket ? 'save' : 'download',
      });
      if (!ok) return;
      try {
        lastExport = await app.call(ticket ? 'assistance.ticket.export' : 'assistance.report.export', args());
        app.toast(lastExport.message, { tone: lastExport.saved ? 'ok' : 'info' });
      } catch (err) {
        app.toast(errorText(err), { tone: 'warn' });
      }
      paintPreview();
    }
  });
  panel.addEventListener('input', (e) => {
    const t = e.target;
    if (!(t instanceof HTMLInputElement)) return;
    if (t.name === 'ticket') { m.ticket = t.value; refresh(); }
    if (t.dataset.field === 'key') { typedKey = t.value; refresh(); }
  });
  panel.addEventListener('change', (e) => {
    const t = e.target;
    if (!(t instanceof HTMLInputElement || t instanceof HTMLSelectElement)) return;
    if (t.name === 'template') m.template = t.value;
    else if (t.name === 'subject') { m.subject = t.value; m.subjectChosen = true; }
    else if (t.name === 'incident') m.incident = t.value || null;
    else if (t.dataset.field === 'pseudonymize') {
      m.pseudonymize = t.checked;
      const box = panel.querySelector('.as-key');
      if (box) box.hidden = !t.checked;
      if (t.checked) panel.querySelector('[data-field="key"]')?.focus();
    } else if (t.dataset.section) {
      m.sections = SECTIONS.map((s) => s.id).filter((id) => panel.querySelector(`[data-section="${id}"]`)?.checked);
    } else return;
    lastExport = null;
    refresh();
  });
  panel.addEventListener('submit', (e) => e.preventDefault());

  applyVars(panel);
  reveal(panel);
  refresh();
  // The workshop changes every time an incident arrives: the form is repainted only when what it offers changed.
  const offered = () => `${(app.workshop?.incidents?.items ?? []).map((i) => i.id).join(',')}|${app.workshop?.comparison?.ready ? 1 : 0}`;
  let lastOffered = offered();
  offs.push(app.on('subjects', repaintForm), app.on('workshop', () => {
    const now = offered();
    if (ticket || now === lastOffered) return;
    lastOffered = now;
    repaintForm();
  }));
  return () => { refresh.cancel(); offs.forEach((off) => off()); typedKey = ''; };
}

// ---------------------------------------------------------------- offline dossier (ASS-012)

// Shown command: it breaks between its arguments and after the commas of a list, never at a hyphen of a name (the copied
// text stays the command itself).
const cliText = (cmd) => breakableText(cmd).replace(/(?<=[A-Za-z0-9])-(?=[A-Za-z0-9])/g, '\u2011').replace('&lt;dossier local&gt;', '&lt;dossier\u00A0local&gt;');


export function renderOffline(host, app) {
  const offs = [];
  const view = { painted: false };
  const m = app.memory.offline;
  let session = null;
  let running = false;
  let result = null;
  let resolved = null;

  function pinsOf() {
    return (app.workshop?.pins ?? []).filter((p) => p.kind === 'computer' && p.identity.startsWith('guid:'));
  }

  function cards() {
    const computer = app.subject('computer');
    const pins = pinsOf();
    const names = parseNames(m.names);
    const working = session?.scope;
    // The working OU may be the whole domain: never a dossier perimeter (the engine refuses it), so the card says why.
    const wholeDomain = Boolean(working?.dn && session?.domain?.rootDn && working.dn.toLowerCase() === session.domain.rootDn.toLowerCase());
    const list = [
      { id: 'subject', icon: 'monitor', title: 'Poste de la session', text: computer ? computer.card.name : 'Choisissez d’abord le poste concerné.', ok: Boolean(computer) },
      { id: 'workingOu', icon: 'ou', title: 'OU de travail', ok: !wholeDomain,
        text: wholeDomain ? `L’OU de travail est tout le domaine${NBSP}: jamais en dossier, choisissez une OU sur l’Accueil ou dans l’arborescence.`
          : working ? `OU ${working.label}, sous-OU comprises` : 'OU choisie sur l’Accueil' },
      { id: 'branch', icon: 'tree', title: 'Une OU de l’arborescence', text: m.ou ? `OU ${m.ou.label}, sous-OU comprises` : 'Choisissez une OU, jamais tout le domaine.', ok: true },
      { id: 'pins', icon: 'pin', title: 'Postes épinglés', text: pins.length ? plural(pins.length, 'poste épinglé', 'postes épinglés') : 'Aucun poste épinglé dans les repères.', ok: pins.length > 0 },
      { id: 'list', icon: 'list', title: 'Liste de postes', text: names.length ? plural(names.length, 'nom collé', 'noms collés') : `Collez des noms (résultats d’une liste, ${MAX_NAMES}${NBSP}au plus).`, ok: true },
    ];
    // Until the operator picks one, the perimeter follows the session: its workstation, else the working OU.
    if (!m.scopeChosen) m.scope = computer ? 'subject' : wholeDomain ? 'branch' : 'workingOu';
    if (!list.find((c) => c.id === m.scope)?.ok) m.scope = list.find((c) => c.ok)?.id ?? 'workingOu';
    return list.map((c, n) => `<label class="as-choice${c.ok ? '' : ' disabled'}" data-j="${n}">
      <input type="radio" name="as-off-scope" value="${c.id}"${m.scope === c.id ? ' checked' : ''}${c.ok ? '' : ' disabled'}>
      <span class="as-choice-ico">${ico(c.icon)}</span><span class="as-choice-body"><b>${esc(c.title)}</b><small>${esc(c.text)}</small></span>
      <span class="as-choice-mark" aria-hidden="true">${ico('check')}</span></label>`).join('');
  }

  function scopeExtra() {
    if (m.scope === 'branch') {
      return `<div class="as-extra">${m.ou ? `<p class="as-inline">${chip('accent', m.ou.label, { icon: 'ou', size: 'md' })}<small class="as-faint">${esc(m.ou.path ?? '')}</small></p>` : ''}
        ${button({ label: m.ou ? 'Changer d’OU…' : 'Choisir dans l’arborescence…', icon: 'tree', cls: 'subtle sm', data: { 'pick-ou': '1' }, tip: 'Lit les OU branche par branche, sur vos clics' })}</div>`;
    }
    if (m.scope === 'list') {
      const names = parseNames(m.names);
      const over = names.length > MAX_NAMES;
      const check = resolved
        ? `<div class="as-inline">${chip(resolved.found.length ? 'ok' : 'warn', plural(resolved.found.length, 'poste reconnu', 'postes reconnus'), { icon: 'check' })}${resolved.unknown.length ? chip('warn', plural(resolved.unknown.length, 'nom inconnu', 'noms inconnus'), { icon: 'alert', tip: resolved.unknown.slice(0, 20).join(', ') }) : ''}</div>
          ${resolved.unknown.length ? `<p class="as-faint as-unknown">Inconnus de l’index local, ignorés${COLON}${esc(resolved.unknown.slice(0, 12).join(', '))}${resolved.unknown.length > 12 ? '…' : ''}</p>` : ''}`
        : '';
      return `<div class="as-extra">
        ${field({ name: 'names', label: 'Noms des postes', type: 'textarea', value: m.names, mono: true, placeholder: 'PC-LYO-0042\nPC-LYO-0043\n…', hint: `Un par ligne, ou séparés par des virgules${NBSP}; correspondance exacte du nom, jamais partielle.` })}
        <div class="as-inline">${button({ label: 'Vérifier la liste', icon: 'search', cls: 'subtle sm', data: { resolve: '1' }, disabled: names.length === 0 || over,
          reason: over ? `${MAX_NAMES}${NBSP}noms au plus${COLON}choisissez une OU ou découpez la liste.` : 'Collez d’abord des noms de postes.' })}<small class="as-faint">${esc(plural(names.length, 'nom', 'noms'))}${over ? ` (plus de ${MAX_NAMES})` : ''}</small></div>
        <div data-resolved>${check}</div></div>`;
    }
    return '';
  }

  function command() {
    const computer = app.subject('computer');
    const rootDn = String(session?.domain?.rootDn ?? '').toLowerCase();
    let perimeter = null;
    if (m.scope === 'subject' && computer) perimeter = { postes: [computer.card.name] };
    else if (m.scope === 'workingOu' && session?.scope?.dn && session.scope.dn.toLowerCase() !== rootDn) perimeter = { ou: session.scope.dn };
    else if (m.scope === 'branch' && m.ou) perimeter = { ou: m.ou.dn };
    else if (m.scope === 'pins' && pinsOf().length) perimeter = { guids: pinsOf().map((p) => p.identity.slice(5)) };
    else if (m.scope === 'list' && parseNames(m.names).length) perimeter = { postes: parseNames(m.names).slice(0, MAX_NAMES) };
    // Without --sections every optional section is written (Domenia 1); « etat,postes » alone writes none of them.
    return dossierCommand(perimeter, m.sections, OPTIONS, app.simulation);
  }

  function resultCard() {
    if (running) return `<div class="as-progress" aria-busy="true">${ico('archive')}<div><b>Préparation du dossier…</b><p>Lecture seule des données locales, sans accès réseau ni à l’annuaire.</p><span class="as-progress-bar"><span></span></span></div></div>`;
    if (!result) return empty('archive', 'Aucun dossier préparé dans cette session', 'Le dossier sert à une intervention sans Domenia : il se transporte et se vérifie avec ses empreintes.');
    return `<div class="as-medal-row enter"><span class="as-medal ${result.saved ? 'ok' : 'info'}">${ico(result.saved ? 'check' : 'info')}</span>
        <div><h3>${result.saved ? 'Dossier prêt' : 'Dossier préparé en mémoire'}</h3><p>${esc(result.message)}</p></div></div>
      ${result.path ? `<div class="as-path"><span class="mono as-path-text">${breakableText(result.path)}</span>${copyButton(result.path, { label: 'Copier le chemin', done: 'Chemin copié' })}${button({ label: 'Ouvrir le dossier', icon: 'folder', cls: 'subtle sm', data: { reveal: result.name }, tip: 'Ouvre le dossier dans l’Explorateur Windows' })}</div>` : ''}
      <div class="as-doc-counts">${result.sections.map((s) => chip(s.truncated ? 'warn' : s.elements ? 'ok' : 'off', `${SECTION_LABEL[s.section] ?? s.section}${NBSP}${s.elements}${s.truncated ? ' (limite)' : ''}`)).join('')}${result.truncated ? chip('warn', 'Périmètre limité à 500 postes') : ''}${result.unresolved ? chip('warn', plural(result.unresolved, 'nom inconnu ignoré', 'noms inconnus ignorés')) : ''}</div>
      <div class="as-files" role="table" aria-label="Fichiers du dossier">
        <div class="as-file head" role="row"><span role="columnheader">Fichier</span><span role="columnheader">Taille</span><span role="columnheader">SHA-256</span></div>
        ${result.files.map((f, n) => `<div class="as-file" role="row" data-j="${n}"><span role="cell" class="mono">${ico('file')}${esc(f.name)}</span><span role="cell" data-tip="${esc(plural(f.bytes, 'octet', 'octets'))}">${esc(f.size)}</span><span role="cell">${shortHash(f.sha256)}${copyButton(f.sha256, { label: `Copier l’empreinte de ${f.name}`, done: 'Empreinte copiée' })}</span></div>`).join('')}
      </div>
      <p class="as-note">${ico('fingerprint')}<span>Sur le poste d’arrivée${COLON}<code class="as-code">Get-FileHash -Algorithm SHA256 &lt;fichier&gt;</code> doit redonner l’empreinte de SHA256SUMS.txt.</span></p>
      <details class="as-map"><summary>${ico('lock')}Toujours exclus (${result.excluded.length})</summary><ul class="as-excluded">${result.excluded.map((x) => `<li>${esc(x)}</li>`).join('')}</ul></details>`;
  }

  function paint() {
    const cmd = command();
    host.innerHTML = `<div class="as-stack">
      <div class="as-banner info reveal">${ico('shield')}<div><b>Lecture seule des données locales, sans accès réseau ni à l’annuaire</b>
        <p>Un nouveau dossier daté, avec manifeste et empreintes SHA-256, dans le dossier des exports. Mots de passe, clés BitLocker, données LAPS (métadonnées comprises) et champs nommés comme des secrets sont exclus. Les données sont datées, non revérifiées.</p></div></div>
      <div class="as-doc-grid">
        <section class="card as-panel reveal">
          <div class="as-panel-head"><span class="as-panel-ico">${ico('archive')}</span><div><h2>Dossier de diagnostic hors ligne</h2><p>Jamais tout le domaine${NBSP}: un poste, une OU, les postes épinglés ou une liste (500 postes au plus).</p></div></div>
          <fieldset class="as-field"><legend>Périmètre du dossier</legend><div class="as-choices">${cards()}</div>${scopeExtra()}</fieldset>
          <fieldset class="as-field"><legend>Sections</legend>
            <div class="as-locked">${chip('accent', 'État de la base', { icon: 'lock' })}${chip('accent', 'Postes', { icon: 'lock' })}<small>toujours inclus</small></div>
            <div class="as-options-list">${OPTIONS.map((o) => `<label class="as-check rich"><input type="checkbox" class="k-checkbox" data-option="${o.id}"${m.sections.includes(o.id) ? ' checked' : ''}><span><b>${esc(o.label)}</b><small>${esc(o.text)}</small></span></label>`).join('')}</div>
          </fieldset>
          <div class="as-doc-actions">${button({ label: 'Préparer le dossier…', icon: 'archive', cls: 'primary', spin: running, data: { prepare: '1' }, disabled: running, reason: 'Un dossier est déjà en préparation.' })}</div>
          ${cmd ? `<div class="as-cli"><span>${ico('command')}Même dossier en ligne de commande, sans ouvrir la fenêtre</span><div class="as-cli-line"><code class="mono">${cliText(cmd)}</code>${copyButton(cmd, { label: 'Copier la commande', done: 'Commande copiée' })}</div>
            <small>Codes de sortie de Domenia${NBSP}1${COLON}0 réussi, 2 commande invalide, 3 base locale indisponible, 4 périmètre refusé, 5 non écrit. Le dossier de sortie doit être local. Pour attendre la fin et lire le code, lancez-la par <code class="as-code">Start-Process -Wait -PassThru</code> dans PowerShell ou <code class="as-code">start /wait</code> dans cmd.</small></div>` : ''}
        </section>
        <section class="card as-panel as-off-result reveal"><div class="as-panel-head"><span class="as-panel-ico">${ico('fingerprint')}</span><div><h2>Résultat</h2><p>Fichiers, tailles en octets et empreintes, à vérifier avec Get-FileHash.</p></div></div>
          <div data-result aria-live="polite">${resultCard()}</div></section>
      </div>
    </div>`;
    applyVars(host);
    enter(host, view);
  }

  function perimeterText() {
    switch (m.scope) {
      case 'subject': return `le poste ${app.subject('computer')?.card?.name ?? ''}`;
      case 'workingOu': return `l’OU de travail ${session?.scope?.label ?? ''}, sous-OU comprises`;
      case 'branch': return m.ou ? `l’OU ${m.ou.label}, sous-OU comprises` : 'une OU à choisir';
      case 'pins': return plural(pinsOf().length, 'poste épinglé', 'postes épinglés');
      default: return `${plural(parseNames(m.names).length, 'nom de poste', 'noms de poste')} de la liste`;
    }
  }

  async function prepare({ demonstration = false } = {}) {
    if (running) return;
    if (m.scope === 'branch' && !m.ou) { await pickOu(); if (!m.ou) return; }
    const names = parseNames(m.names);
    if (m.scope === 'list' && (names.length === 0 || names.length > MAX_NAMES)) {
      app.toast(names.length ? `${MAX_NAMES}${NBSP}noms au plus${COLON}choisissez une OU ou découpez la liste.` : 'Collez d’abord des noms de postes.', { tone: 'warn' });
      return;
    }
    // In a memory mode (capture), nothing is written: the demonstration of the address prepares at once. Anywhere else, the
    // operator confirms the perimeter, the sections and the destination first.
    if (!(demonstration && app.overview?.exportsPersistent === false)) {
      const chosen = ['État de la base', 'Postes', ...OPTIONS.filter((o) => m.sections.includes(o.id)).map((o) => o.label)];
      const ok = await confirmDialog({
        title: 'Préparer le dossier hors ligne ?',
        message: `Périmètre${COLON}${perimeterText()}. Sections${COLON}${chosen.join(', ')}. Mots de passe, clés BitLocker, données LAPS et champs nommés comme des secrets restent exclus. Un nouveau dossier daté est écrit, jamais remplacé${NBSP}; rien n’est lu sur le réseau. ${app.overview?.exportsLabel ?? ''}`,
        confirmLabel: 'Préparer le dossier', icon: 'archive',
      });
      if (!ok) return;
    }
    running = true;
    paint();
    try {
      result = await app.call('assistance.dossier.prepare', {
        scope: m.scope, dn: app.dnOf('computer'), ou: m.scope === 'branch' ? m.ou?.dn ?? null : null,
        names: m.scope === 'list' ? names : null, sections: m.sections,
      });
      app.toast(`${result.saved ? 'Dossier hors ligne prêt' : 'Dossier préparé en mémoire, non écrit dans ce mode'}${COLON}${plural(result.files.length, 'fichier', 'fichiers')} avec leurs empreintes SHA-256.`, { tone: result.saved ? 'ok' : 'info' });
    } catch (err) {
      app.toast(`Dossier hors ligne non produit${COLON}${errorText(err)}`, { tone: 'warn' });
    } finally {
      running = false;
      if (!app.disposed()) paint();
    }
  }
  app.prepareDossier = prepare;

  /** Panel over the page with the OU tree (read branch by branch on the operator's clicks); the domain is never chosen. */
  function pickOu() {
    return new Promise((resolve) => {
      let chosen = null;
      const body = document.createElement('div');
      body.className = 'as-ou-picker';
      body.dataset.page = 'assistance';
      body.innerHTML = '<p class="as-faint">Le dossier couvre l’OU choisie et ses sous-OU. La racine du domaine n’est pas proposée.</p><div class="as-ou-tree"></div>';
      const toNode = (ou) => ({ id: ou.dn, label: ou.name, hint: ou.path, leaf: !ou.hasChildren, icon: 'ou', data: ou });
      const panel = openDrawer({
        title: 'Choisir l’OU du dossier', subtitle: 'Lecture des OU branche par branche', icon: 'tree', key: 'assistance.ou', width: 460,
        body,
        actions: [
          { id: 'cancel', label: 'Annuler', run: (p) => p.close() },
          { id: 'choose', label: 'Choisir cette OU', primary: true, run: (p) => { if (chosen) { m.ou = { dn: chosen.dn, label: chosen.name, path: chosen.path }; m.scope = 'branch'; m.scopeChosen = true; } p.close(); } },
        ],
        onClose: () => { tree.destroy(); resolve(m.ou); if (!app.disposed()) paint(); },
      });
      const tree = createTree(body.querySelector('.as-ou-tree'), {
        label: 'Unités d’organisation',
        height: '520px',
        roots: async () => {
          const r = await app.call('directory.ou.children', { dn: null });
          return [{ id: r.parent.dn, label: r.parent.name, icon: 'domain', selectable: false, children: (r.children ?? []).map(toNode) }];
        },
        load: async (node) => ((await app.call('directory.ou.children', { dn: node.id })).children ?? []).map(toNode),
        onSelect: (node) => { chosen = node.data ?? null; },
        onActivate: (node) => { if (node.data) { chosen = node.data; m.ou = { dn: chosen.dn, label: chosen.name, path: chosen.path }; m.scope = 'branch'; m.scopeChosen = true; panel.close(); } },
      });
    });
  }

  host.addEventListener('change', (e) => {
    const t = e.target;
    if (!(t instanceof HTMLInputElement)) return;
    if (t.name === 'as-off-scope') { m.scope = t.value; m.scopeChosen = true; paint(); if (m.scope === 'branch' && !m.ou) pickOu(); }
    if (t.dataset.option) { m.sections = OPTIONS.map((o) => o.id).filter((id) => host.querySelector(`[data-option="${id}"]`)?.checked); paint(); }
  });
  let typing = 0;
  host.addEventListener('input', (e) => {
    const t = e.target;
    if (!(t instanceof HTMLTextAreaElement) || t.name !== 'names') return;
    m.names = t.value;
    resolved = null;
    clearTimeout(typing);
    // Typing never repaints the view (undo history, caret and scroll of a long list stay): only the count of names, the
    // verification, the « Vérifier la liste » button, the card of the perimeter and the command follow the text.
    typing = setTimeout(() => {
      if (app.disposed()) return;
      const names = parseNames(m.names);
      const over = names.length > MAX_NAMES;
      const count = host.querySelector('[data-resolve]')?.parentElement?.querySelector('small.as-faint');
      if (count) count.textContent = `${plural(names.length, 'nom', 'noms')}${over ? ` (plus de ${MAX_NAMES})` : ''}`;
      const check = host.querySelector('[data-resolve]');
      if (check) {
        const off = names.length === 0 || over;
        if (off) check.setAttribute('aria-disabled', 'true'); else check.removeAttribute('aria-disabled');
        if (off) check.dataset.tip = over ? `${MAX_NAMES}${NBSP}noms au plus${COLON}choisissez une OU ou découpez la liste.` : 'Collez d’abord des noms de postes.';
        else delete check.dataset.tip;
      }
      const verdict = host.querySelector('[data-resolved]');
      if (verdict) verdict.innerHTML = '';
      const card = host.querySelector('input[name="as-off-scope"][value="list"]')?.closest('.as-choice')?.querySelector('.as-choice-body small');
      if (card) card.textContent = names.length ? plural(names.length, 'nom collé', 'noms collés') : `Collez des noms (résultats d’une liste, ${MAX_NAMES}${NBSP}au plus).`;
      const line = host.querySelector('.as-cli-line');
      const cmd = command();
      if (line && cmd) {
        line.querySelector('code').innerHTML = cliText(cmd);
        line.querySelector('[data-copy]')?.setAttribute('data-copy', cmd);
      } else if (Boolean(line) !== Boolean(cmd)) {
        // The command appears or disappears (first name typed, list emptied): the only case that needs the full view.
        const area = host.querySelector('textarea[name="names"]');
        const caret = area?.selectionStart ?? 0;
        paint();
        const fresh = host.querySelector('textarea[name="names"]');
        fresh?.focus();
        fresh?.setSelectionRange(caret, caret);
      }
    }, 500);
  });
  host.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const shown = t.closest('[data-reveal]');
    if (shown) { revealDocument(app, shown.dataset.reveal); return; }
    if (t.closest('[data-pick-ou]')) { pickOu(); return; }
    if (t.closest('[data-resolve]')) {
      if (t.closest('[data-resolve]').getAttribute('aria-disabled') === 'true') return;
      try {
        resolved = await app.call('assistance.computers.resolve', { names: parseNames(m.names).slice(0, MAX_NAMES) });
        if (!app.disposed()) paint();
      } catch (err) { app.toast(errorText(err), { tone: 'warn' }); }
      return;
    }
    if (t.closest('[data-prepare]')) prepare();
  });

  paint();
  app.call('session.info').then((s) => { session = s ?? null; if (!app.disposed() && !running) paint(); }).catch((err) => console.error(err));
  const pinSignature = () => pinsOf().map((p) => p.identity).join(',');
  let lastPins = pinSignature();
  offs.push(app.on('subjects', () => { if (!running) paint(); }), app.on('workshop', () => {
    const now = pinSignature();
    if (now === lastPins || running) return;
    lastPins = now;
    paint();
  }));
  return () => { clearTimeout(typing); offs.forEach((off) => off()); if (app.prepareDossier === prepare) app.prepareDossier = null; };
}
