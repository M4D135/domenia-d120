// General tab: sections of the object (identity, organisation, contact details, profile, system, management…), edit mode
// with the pencil (FIC-009, FIC-010, FIC-049, FIC-029, FIC-011) and the protected draft (FIC-007), and the side column:
// presence with the associated workstations or users (FIC-046, FIC-047), freshness per nature (FIC-036) and the « Résumé » of
// the object (FIC-039: type, name, class, GUID, SID, dates, DN, presence and its target, copy and parent). A new read repaints
// only the rows that changed (FIC-031).
import { kvSection, bindKv, glyph, pill, openDialog, copyButton, bindCopy, startFreshness } from '../../kit/index.js';
import { esc, errorText, toast, announce, applyVars } from '../../ui.js';
import { write, pickObject } from './actions.js';
import { card, ficheLink, freshChip, plural, kindOf, emptyNote, stamp, when, nobr, presenceWords, NBSP } from './common.js';

const GROUP_TITLES = {
  identite: ['Identité', 'user'], organisation: ['Organisation', 'users'], coordonnees: ['Coordonnées', 'link'], profil: ['Profil et ouverture de session', 'monitor'],
  gestion: ['Gestion', 'users'], groupe: ['Groupe', 'group'], branche: ['Branche', 'ou'],
};

const FRESH_TONES = { fresh: 'ok', stale: 'warn', unknown: 'off', historical: 'info' };

/**
 * @param {HTMLElement} panel
 * @param {any} S
 */
export function mountGeneral(panel, S) {
  let editing = false;
  let baseline = new Map();
  let kv = null;
  let pendingCompare = null;
  let sideKey = '';

  panel.innerHTML = `<div class="fi-general">
    <div class="fi-main"><div class="fi-gen-bar"></div><div class="fi-sections"></div></div>
    <aside class="fi-side"></aside>
  </div>`;
  const bar = /** @type {HTMLElement} */ (panel.querySelector('.fi-gen-bar'));
  const sectionsHost = /** @type {HTMLElement} */ (panel.querySelector('.fi-sections'));
  const side = /** @type {HTMLElement} */ (panel.querySelector('.fi-side'));
  const unbindSideCopy = bindCopy(side);

  // The technical « Objet » section is shown once, in the « Résumé » card of the side column (FIC-039).
  const leftSections = (sheet) => sheet.sections.filter((s) => s.id !== 'objet');

  function sectionMarkup(s, n) {
    return `<div class="card fi-card fi-kvcard reveal" data-j="${n}" data-section="${esc(s.id)}">${kvSection({
      id: s.id,
      title: s.title,
      icon: s.icon,
      items: s.items.map((it) => ({
        label: it.label, value: it.value, sub: it.sub ?? undefined, mono: it.mono, copy: it.copy, tone: it.tone ?? undefined, wide: it.wide,
        html: it.link ? ficheLink(it.link) : undefined,
      })),
    })}</div>`;
  }

  // Each row carries the key of its value, so that a new read repaints that row only.
  function tagRows(scope, sheet) {
    for (const s of leftSections(sheet)) {
      const rows = scope.querySelectorAll(`[data-section="${CSS.escape(s.id)}"] .k-kv-row`);
      rows.forEach((row, i) => { if (s.items[i]) row.dataset.key = s.items[i].key; });
    }
  }

  function barMarkup(sheet) {
    const edit = sheet.edit;
    if (editing) {
      return `<div class="fi-editbar editing" role="toolbar" aria-label="Modification de la fiche">
        <span class="fi-editbar-state">${glyph('edit')}<span class="fi-dirty-count">Aucun champ modifié</span></span>
        <span class="fi-editbar-note">Seuls les champs modifiés partent${NBSP}; un champ vidé est un effacement explicite.</span>
        <button class="btn sm ghost" type="button" data-edit="cancel">${glyph('undo')}Annuler</button>
        <button class="btn sm primary" type="button" data-edit="save" disabled>${glyph('check')}Enregistrer…</button></div>`;
    }
    return `<div class="fi-editbar" role="toolbar" aria-label="Fiche">
      <span class="fi-editbar-state">${glyph('eye')}<span>Lecture</span></span>
      <span class="fi-editbar-note">${edit.available ? `${plural(edit.fields.length, 'champ modifiable', 'champs modifiables')}, enregistrés par plan, confirmation et reçu.` : esc(edit.reason ?? 'Aucun champ modifiable.')}</span>
      ${freshChip(sheet, 'attributes')}
      <button class="btn sm fi-write" type="button" data-edit="start"${edit.available ? '' : ` aria-disabled="true" data-tip="${esc(edit.reason ?? '')}"`}>${glyph('edit')}Modifier</button></div>`;
  }

  function fieldMarkup(f) {
    const id = `fi-f-${f.attribute}`;
    const value = f.value ?? '';
    const label = `<label class="fi-field-label" for="${id}">${esc(f.label)}<span class="fi-field-attr mono">${esc(f.attribute)}</span></label>`;
    const reset = `<button class="btn ghost icon xs fi-field-reset" type="button" data-reset="${esc(f.attribute)}" aria-label="Rétablir la valeur lue" data-tip="Rétablir la valeur lue">${glyph('undo')}</button>`;
    if (f.type === 'dn') {
      return `<div class="fi-field dn" data-attr="${esc(f.attribute)}" data-type="dn">${label}
        <div class="fi-dn-field"><input id="${id}" type="hidden" value="${esc(value)}">
          <span class="fi-dn-name" data-tip="${esc(value)}">${dnName(value, f.display, linkKind(f.attribute, value))}</span>
          <button class="btn sm" type="button" data-pick="${esc(f.attribute)}">${glyph('search')}Choisir…</button>
          <button class="btn sm ghost" type="button" data-clear="${esc(f.attribute)}"${value ? '' : ' hidden'}>${glyph('x')}Retirer</button>
          ${reset}</div>
        ${f.hint ? `<span class="fi-field-hint">${esc(f.hint)}</span>` : ''}</div>`;
    }
    const input = f.type === 'multiline'
      ? `<textarea id="${id}" class="input" rows="2" maxlength="${f.maxLength}" spellcheck="true">${esc(value)}</textarea>`
      : `<input id="${id}" class="input${f.type === 'upn' || f.type === 'email' || f.type === 'drive' ? ' mono' : ''}" type="text" maxlength="${f.maxLength}" value="${esc(value)}" autocomplete="off" spellcheck="false"${f.hint ? ` aria-describedby="${id}-hint"` : ''}>`;
    return `<div class="fi-field${f.type === 'multiline' ? ' wide' : ''}" data-attr="${esc(f.attribute)}" data-type="${esc(f.type)}">${label}<div class="fi-field-row">${input}${reset}</div>
      ${f.hint && f.type !== 'multiline' ? `<span class="fi-field-hint" id="${id}-hint">${esc(f.hint)}</span>` : ''}</div>`;
  }

  function editMarkup(sheet) {
    const groups = new Map();
    for (const f of sheet.edit.fields) {
      if (!groups.has(f.group)) groups.set(f.group, []);
      groups.get(f.group).push(f);
    }
    return `<div class="fi-compare-band" hidden></div>${[...groups].map(([g, fields], n) => {
      const [title, icon] = GROUP_TITLES[g] ?? [g, 'object'];
      return `<section class="card fi-card fi-editcard reveal" data-j="${n}"><div class="card-head"><span class="card-icon">${glyph(icon)}</span><h3>${esc(title)}</h3>
        <span class="meta">${plural(fields.length, 'champ', 'champs')}</span></div><div class="fi-fields">${fields.map(fieldMarkup).join('')}</div></section>`;
    }).join('')}`;
  }

  function currentValue(attr) {
    const el = sectionsHost.querySelector(`#fi-f-${CSS.escape(attr)}`);
    if (!el) return null;
    return /** @type {HTMLInputElement} */ (el).value;
  }

  function dirtyFields() {
    const changed = [];
    for (const [attr, original] of baseline) {
      const now = currentValue(attr) ?? '';
      // Case sensitive, as Domenia 1: « dupont » and « Dupont » differ.
      if (now !== (original ?? '')) changed.push(attr);
    }
    return changed;
  }

  function syncDirty() {
    const changed = dirtyFields();
    S.draft = editing ? { count: changed.length, fields: changed } : null;
    sectionsHost.querySelectorAll('.fi-field').forEach((el) => el.classList.toggle('dirty', changed.includes(el.dataset.attr)));
    const count = bar.querySelector('.fi-dirty-count');
    if (count) count.textContent = changed.length ? `${plural(changed.length, 'champ modifié', 'champs modifiés')}` : 'Aucun champ modifié';
    const save = /** @type {HTMLButtonElement|null} */ (bar.querySelector('[data-edit="save"]'));
    if (save) save.disabled = changed.length === 0;
    bar.querySelector('.fi-editbar')?.classList.toggle('has-changes', changed.length > 0);
  }

  function renderSections() {
    const sheet = S.sheet;
    bar.innerHTML = barMarkup(sheet);
    kv?.destroy();
    kv = null;
    if (editing) {
      sectionsHost.innerHTML = editMarkup(sheet);
      baseline = new Map(sheet.edit.fields.map((f) => [f.attribute, f.value ?? '']));
      syncDirty();
    } else {
      sectionsHost.innerHTML = leftSections(sheet).map(sectionMarkup).join('');
      tagRows(sectionsHost, sheet);
      kv = bindKv(sectionsHost, { key: `fiche.${sheet.identity.kind}` });
    }
    applyVars(sectionsHost);
    revealNow(sectionsHost);
    startFreshness(bar);
  }

  /**
   * Partial refresh (FIC-031, Get-DomeniaObjectPresentationDelta): a section whose rows are the same keys gets only its changed
   * rows repainted (with a flash); a section whose shape changed is repainted whole; an unchanged section is left as it is.
   */
  function patchSections(sheet, previous) {
    const before = new Map(leftSections(previous).map((s) => [s.id, s]));
    const after = leftSections(sheet);
    if (after.map((s) => s.id).join() !== [...before.keys()].join()) {
      renderSections();
      return;
    }
    bar.innerHTML = barMarkup(sheet);
    startFreshness(bar);
    after.forEach((s, n) => {
      const old = before.get(s.id);
      if (JSON.stringify(old) === JSON.stringify(s)) return;
      const host = sectionsHost.querySelector(`[data-section="${CSS.escape(s.id)}"]`);
      if (!host) return;
      const sameShape = old.items.map((i) => i.key).join() === s.items.map((i) => i.key).join();
      const temp = document.createElement('div');
      temp.innerHTML = sectionMarkup(s, n);
      if (!sameShape) {
        host.replaceWith(temp.firstElementChild);
        tagRows(sectionsHost, sheet);
        return;
      }
      const fresh = temp.querySelectorAll('.k-kv-row');
      s.items.forEach((item, i) => {
        if (JSON.stringify(item) === JSON.stringify(old.items[i])) return;
        const row = host.querySelector(`.k-kv-row[data-key="${CSS.escape(item.key)}"]`);
        if (!row || !fresh[i]) return;
        row.innerHTML = fresh[i].innerHTML;
        row.classList.remove('fi-flash');
        void row.offsetWidth;
        row.classList.add('fi-flash');
      });
    });
    applyVars(sectionsHost);
  }

  function startEdit() {
    if (!S.sheet.edit.available) {
      toast(S.sheet.edit.reason ?? 'Modification indisponible.', { tone: 'info' });
      return;
    }
    editing = true;
    renderSections();
    sectionsHost.querySelector('input:not([type=hidden]), textarea')?.focus();
    announce('Mode modification : seuls les champs modifiés seront enregistrés.');
  }

  async function stopEdit(confirm = true) {
    const changed = dirtyFields();
    if (confirm && changed.length) {
      const d = openDialog({
        title: 'Abandonner les saisies ?', icon: 'undo', size: 'sm',
        body: `<p class="k-dlg-text">${esc(plural(changed.length, 'champ modifié', 'champs modifiés'))} ne ${changed.length > 1 ? 'seront' : 'sera'} pas enregistré${changed.length > 1 ? 's' : ''}. Les valeurs lues seront rétablies.</p>`,
        actions: [{ id: 'keep', label: 'Continuer la saisie', safe: true }, { id: 'drop', label: 'Abandonner', danger: true }],
      });
      if ((await d.result) !== 'drop') return;
    }
    editing = false;
    S.draft = null;
    pendingCompare = null;
    renderSections();
  }

  async function save() {
    const changed = dirtyFields();
    if (!changed.length) return;
    const fields = {};
    for (const attr of changed) {
      const v = (currentValue(attr) ?? '').trim();
      fields[attr] = v === '' ? null : v;
    }
    const receipt = await write(S.ctx, 'fiche.update.plan', { dn: S.sheet.identity.dn, fields }, { subtitle: `${S.sheet.identity.kindLabel} · ${S.sheet.identity.name}` });
    if (receipt && (receipt.result === 'applied' || receipt.result === 'noChange')) {
      editing = false;
      S.draft = null;
      await S.reload({ quiet: true, reread: true });
      renderSections();
    }
  }

  async function pickDn(attr) {
    const field = S.sheet.edit.fields.find((f) => f.attribute === attr);
    const kinds = attr === 'manager' ? ['user', 'contact'] : ['user', 'group', 'contact'];
    const chosen = await pickObject(S.ctx, {
      title: attr === 'manager' ? 'Choisir le responsable' : 'Choisir le gestionnaire', subtitle: field?.label ?? attr, kinds,
      exclude: [S.sheet.identity.dn],
    });
    if (!chosen) return;
    setDn(attr, chosen.dn, chosen.name, chosen.kind);
  }

  // Kind of the object a DN field points to (a manager is a person, managedBy may be a group): the icon follows it.
  function linkKind(attr, dn) {
    if (!dn) return 'user';
    const item = S.sheet.sections.flatMap((s) => s.items ?? []).find((i) => i.key === attr && i.link?.dn === dn);
    return item?.link?.kind ?? (S.sheet.manager?.dn === dn ? S.sheet.manager.kind : null) ?? 'user';
  }

  /** The name shown in a DN field, with the icon of its kind, or « Aucun ». */
  function dnName(dn, name, kind) {
    return dn ? `${glyph(kindOf(kind).icon)}${esc(name ?? dn)}` : '<span class="fi-none">Aucun</span>';
  }

  // « Retirer » exists only while the field holds a value; when it disappears under the focus, the focus goes to « Choisir… ».
  function setDn(attr, dn, name, kind) {
    const wrap = sectionsHost.querySelector(`.fi-field[data-attr="${CSS.escape(attr)}"]`);
    if (!wrap) return;
    const input = /** @type {HTMLInputElement} */ (wrap.querySelector('input[type=hidden]'));
    input.value = dn ?? '';
    const label = wrap.querySelector('.fi-dn-name');
    label.innerHTML = dnName(dn, name, kind ?? linkKind(attr, dn));
    label.setAttribute('data-tip', dn ?? '');
    const clear = /** @type {HTMLButtonElement|null} */ (wrap.querySelector('[data-clear]'));
    if (clear) {
      const hadFocus = document.activeElement === clear;
      clear.hidden = !dn;
      if (hadFocus && !dn) /** @type {HTMLElement|null} */ (wrap.querySelector('[data-pick]'))?.focus();
    }
    syncDirty();
  }

  // ---------- Draft comparison (FIC-007): a newer read never replaces what the operator typed ----------

  function checkNewerRead(sheet) {
    const differences = sheet.edit.fields.filter((f) => (f.value ?? '') !== (baseline.get(f.attribute) ?? ''));
    if (!differences.length) return;
    pendingCompare = { sheet, differences };
    const band = sectionsHost.querySelector('.fi-compare-band');
    if (!band) return;
    band.hidden = false;
    band.innerHTML = `${glyph('sync')}<span><b>Une relecture plus récente est arrivée</b>${NBSP}: ${esc(plural(differences.length, 'champ a changé', 'champs ont changé'))} dans l’annuaire. Vos saisies sont conservées.</span>
      <button class="btn sm" type="button" data-compare>${glyph('split')}Comparer les saisies</button>`;
  }

  async function compare() {
    if (!pendingCompare) return;
    const { differences } = pendingCompare;
    const rows = differences.map((f) => {
      const read = baseline.get(f.attribute) ?? '';
      const mine = currentValue(f.attribute) ?? '';
      const newer = f.value ?? '';
      return `<tr data-attr="${esc(f.attribute)}"><th scope="row">${esc(f.label)}</th><td>${esc(read || '—')}</td><td class="mine">${esc(mine || '—')}</td><td class="newer">${esc(newer || '—')}</td>
        <td><div class="segmented fi-choice" role="radiogroup" aria-label="Valeur à garder pour ${esc(f.label)}">
          <label><input type="radio" name="c-${esc(f.attribute)}" value="mine" checked><span>Ma saisie</span></label>
          <label><input type="radio" name="c-${esc(f.attribute)}" value="newer"><span>Nouvelle lecture</span></label></div></td></tr>`;
    }).join('');
    const d = openDialog({
      title: 'Comparer les saisies', subtitle: 'Valeur lue à l’ouverture, votre saisie et la nouvelle lecture', icon: 'split', size: 'lg',
      body: `<div data-page="fiche"><table class="fi-compare-table"><thead><tr><th>Champ</th><th>Valeur lue</th><th>Votre saisie</th><th>Nouvelle lecture</th><th>Garder</th></tr></thead><tbody>${rows}</tbody></table>
        <p class="fi-note">${glyph('info')}Aucune saisie n’est remplacée sans votre choix. Les mots de passe ne sont jamais reproduits.</p></div>`,
      actions: [{ id: 'cancel', label: 'Fermer', safe: true }, { id: 'apply', label: 'Appliquer les choix', primary: true }],
    });
    const result = await d.result;
    if (result !== 'apply') return;
    for (const f of differences) {
      const choice = d.el.querySelector(`input[name="c-${CSS.escape(f.attribute)}"]:checked`)?.value ?? 'mine';
      if (choice === 'newer') {
        if (f.type === 'dn') setDn(f.attribute, f.value, f.display);
        else {
          const input = sectionsHost.querySelector(`#fi-f-${CSS.escape(f.attribute)}`);
          if (input) input.value = f.value ?? '';
        }
      }
      baseline.set(f.attribute, f.value ?? '');
    }
    pendingCompare = null;
    const band = sectionsHost.querySelector('.fi-compare-band');
    if (band) band.hidden = true;
    syncDirty();
    toast('Saisies comparées : la nouvelle lecture devient la référence.', { tone: 'info' });
  }

  // ---------- Side column ----------

  function presenceCard(sheet) {
    const id = sheet.identity;
    if (id.kind !== 'user' && id.kind !== 'computer') return '';
    const p = sheet.presence;
    const linked = sheet.linked ?? [];
    const tone = p?.state === 'online' ? 'ok' : p?.state === 'offline' ? 'warn' : 'off';
    const action = sheet.actions.find((a) => a.id === 'presence');
    const box = p ? `<div class="fi-presence" data-state="${esc(p.state)}"><span class="fi-presence-pulse" aria-hidden="true"></span>
        <div class="fi-presence-text"><b class="fi-presence-label">${nobr(p.label)}</b><p class="fi-presence-detail">${nobr(p.detail)}</p></div></div>` : '';
    const list = linked.length
      ? `<div class="fi-linked">${linked.map((l, n) => `<button type="button" class="fi-linked-row" data-open="${esc(l.dn)}" data-j="${n}" data-tip="${esc(l.rule)}">
          <span class="fi-linked-ico" data-kind="${esc(l.kind)}">${glyph(kindOf(l.kind).icon)}</span>
          <span class="fi-linked-body"><span class="fi-linked-name"><span class="fi-nobr">${esc(l.name)}</span>${l.primary ? `<span class="fi-primary" data-tip="Relation principale">${glyph('star')}</span>` : ''}</span>
            <span class="fi-linked-sub">${esc(l.source)}${l.when ? ` · ${esc(stamp(l.when))}` : ''}</span></span>
          ${pill(l.evidence === 'declared' ? 'ok' : l.evidence === 'observed' ? 'info' : 'off', l.evidenceLabel, { size: 'sm', dot: true })}</button>`).join('')}</div>`
      : emptyNote('link', id.kind === 'user' ? 'Aucun poste associé' : 'Aucun utilisateur associé', id.kind === 'user' ? 'Présence inconnue, pas « aucun poste »' + NBSP + ': un compte recréé n’hérite pas des postes de l’ancien.' : 'Aucune association connue de Domenia.');
    return card({
      id: 'presence', icon: 'wifi', tone, title: id.kind === 'user' ? 'Présence et postes associés' : 'Présence et utilisateurs associés',
      sub: id.kind === 'user' ? 'Par le poste associé le plus fiable, jamais un pourcentage' : 'Ping du poste, associations connues',
      fresh: freshChip(sheet, 'presence'),
      body: `${box}<h4 class="fi-side-sub">${id.kind === 'user' ? 'Postes associés' : 'Utilisateurs associés'}${linked.length ? `<span class="chip">${linked.length}</span>` : ''}</h4>${list}`,
      foot: action ? `<button class="btn sm fi-net" type="button" data-side="presence"${action.available ? '' : ` aria-disabled="true" data-tip="${esc(action.reason ?? '')}"`}>${glyph('wifi')}Vérifier la présence</button>
          <span class="fi-foot-note">Un ping, sur ce clic seulement.</span>` : '',
    });
  }

  function freshCard(sheet) {
    return card({
      id: 'fresh', icon: 'clock', title: 'Fraîcheur des données', sub: sheet.settings?.freshnessText ?? 'Durée de validité par nature',
      body: `<ul class="fi-fresh">${sheet.freshness.map((f, n) => `<li data-state="${esc(f.state)}" data-j="${n}" data-tip="${esc(f.text)}"><span class="fi-fresh-dot" data-tone="${FRESH_TONES[f.state] ?? 'off'}" aria-hidden="true"></span>
        <span class="fi-fresh-label">${esc(f.label)}<span class="fi-fresh-validity">${esc(f.validity ?? '')}</span></span>
        <span class="fi-fresh-when">${f.observedAt ? `${when(f.observedAt)}${f.state === 'stale' ? '<span class="fi-fresh-flag">à relire</span>' : ''}` : '<span class="fi-none">jamais observé</span>'}
          ${f.lastAttempt ? `<span class="fi-fresh-attempt">dernière tentative ${esc(stamp(f.lastAttempt))}</span>` : ''}</span></li>`).join('')}</ul>`,
    });
  }

  function summaryCard(sheet) {
    const id = sheet.identity;
    const row = (label, value, { mono = false, copy = '', wide = false } = {}) => `<div class="${wide ? 'wide' : ''}"><dt>${esc(label)}</dt><dd><span class="fi-summary-val${mono ? ' mono fi-break' : ''}">${value}</span>${copy ? copyButton(copy, { label: `Copier ${label}` }) : ''}</dd></div>`;
    const presence = sheet.presence ? `${esc(presenceWords(sheet.presence))}${sheet.presence.checkedAt ? `<span class="fi-faint fi-block">relevé le ${esc(stamp(sheet.presence.checkedAt))}</span>` : ''}` : '<span class="fi-none">Non relevée</span>';
    const target = sheet.presence?.computer ? `<span class="fi-nobr">${esc(sheet.presence.computer)}</span>` : '<span class="fi-none">—</span>';
    return card({
      id: 'object', icon: 'object', title: 'Résumé', sub: id.kindLabel,
      body: `<dl class="fi-mini fi-summary">
        ${row('Type', esc(id.kindLabel))}
        ${row('Nom', esc(id.name), { copy: id.name })}
        ${row('Classe', esc(id.classes?.join(', ') || id.objectClass), { mono: true })}
        ${row('GUID', esc(id.guid), { mono: true, copy: id.guid })}
        ${id.sid ? row('SID', esc(id.sid), { mono: true, copy: id.sid }) : ''}
        ${row('Créé le', when(id.created))}
        ${row('Modifié le', when(id.changed))}
        ${id.usn != null ? row('USN', esc(String(id.usn)), { mono: true }) : ''}
        ${row('DN', esc(id.dn), { mono: true, copy: id.dn, wide: true })}
        ${id.kind === 'user' || id.kind === 'computer' ? `${row('Présence', presence)}${row('Cible de présence', target)}` : ''}</dl>`,
      foot: `<button class="btn sm" type="button" data-side="copySummary">${glyph('copy')}Copier le résumé</button>
        ${id.parentDn && !/^DC=/i.test(id.dn) ? `<button class="btn sm ghost" type="button" data-side="openParent">${glyph('ou')}Ouvrir le parent</button>` : ''}
        ${id.kind === 'user' && sheet.support?.length ? `<button class="btn sm ghost" type="button" data-side="support">${glyph('lifebuoy')}Résumé support</button>` : ''}`,
    });
  }

  function sideMarkup(sheet) {
    return [presenceCard(sheet), freshCard(sheet), summaryCard(sheet)].join('');
  }

  const sideKeyOf = (sheet) => JSON.stringify([sheet.presence, sheet.linked, sheet.freshness.map((f) => [f.state, f.observedAt, f.lastAttempt]), sheet.identity, sheet.actions.find((a) => a.id === 'presence'), sheet.support?.length, sheet.settings?.freshnessText]);

  function renderSide(force = false) {
    const sheet = S.sheet;
    const key = sideKeyOf(sheet);
    if (!force && key === sideKey) return;
    sideKey = key;
    side.innerHTML = sideMarkup(sheet);
    applyVars(side);
    startFreshness(side);
  }

  async function checkPresence() {
    const button = /** @type {HTMLButtonElement|null} */ (side.querySelector('[data-side="presence"]'));
    const box = side.querySelector('.fi-presence');
    if (!box) return;
    button?.setAttribute('aria-busy', 'true');
    box.classList.add('probing');
    box.setAttribute('aria-busy', 'true');
    try {
      const r = await S.ctx.call('fiche.presence', { dn: S.sheet.identity.dn });
      box.dataset.state = r.state;
      box.querySelector('.fi-presence-label').innerHTML = nobr(r.label + (r.via ? ` · ${r.via}` : ''));
      box.querySelector('.fi-presence-detail').innerHTML = nobr(`${r.detail} Relevé le ${stamp(r.checkedAt)}.`);
      box.classList.remove('updated');
      void box.offsetWidth;
      box.classList.add('updated');
      // The header (tile, avatar dot) and the freshness of the presence follow the new observation, not only this card.
      S.notePresence?.(r);
      const chip = side.querySelector('[data-card="presence"] .fi-fresh-chip');
      if (chip) chip.outerHTML = freshChip(S.sheet, 'presence');
      const freshHost = side.querySelector('[data-card="fresh"]');
      if (freshHost) freshHost.outerHTML = freshCard(S.sheet);
      applyVars(side);
      startFreshness(side);
      sideKey = sideKeyOf(S.sheet);
      announce(`Présence${NBSP}: ${r.label}.`);
    } catch (err) {
      toast(`Présence non vérifiée${NBSP}: ${errorText(err)}`, { tone: 'warn' });
    } finally {
      button?.removeAttribute('aria-busy');
      box.classList.remove('probing');
      box.removeAttribute('aria-busy');
    }
  }

  renderSections();
  renderSide(true);

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const editBtn = t.closest('[data-edit]');
    if (editBtn) {
      if (editBtn.getAttribute('aria-disabled') === 'true') { toast(editBtn.dataset.tip || 'Indisponible.', { tone: 'info' }); return; }
      const what = editBtn.dataset.edit;
      if (what === 'start') startEdit();
      else if (what === 'cancel') stopEdit(true);
      else if (what === 'save') save();
      return;
    }
    const reset = t.closest('[data-reset]');
    if (reset) {
      const attr = reset.dataset.reset;
      const field = S.sheet.edit.fields.find((f) => f.attribute === attr);
      if (field?.type === 'dn') setDn(attr, baseline.get(attr) || null, field.display);
      else {
        const input = sectionsHost.querySelector(`#fi-f-${CSS.escape(attr)}`);
        if (input) input.value = baseline.get(attr) ?? '';
        syncDirty();
      }
      return;
    }
    const pick = t.closest('[data-pick]');
    if (pick) { pickDn(pick.dataset.pick); return; }
    const clear = t.closest('[data-clear]');
    if (clear) { setDn(clear.dataset.clear, null, null); return; }
    if (t.closest('[data-compare]')) { compare(); return; }
    const open = t.closest('[data-open]');
    if (open) { S.open(open.dataset.open); return; }
    const sideBtn = t.closest('[data-side]');
    if (sideBtn) {
      const what = sideBtn.dataset.side;
      if (sideBtn.getAttribute('aria-disabled') === 'true') { toast(sideBtn.dataset.tip || 'Indisponible.', { tone: 'info' }); return; }
      if (what === 'presence') checkPresence();
      else S.act(what);
    }
  };
  const onInput = (e) => { if (editing && e.target instanceof Element && e.target.closest('.fi-field')) syncDirty(); };
  panel.addEventListener('click', onClick);
  panel.addEventListener('input', onInput);

  return {
    edit: startEdit,
    /** Abandon confirmed by the screen guard (F5, another fiche, leaving): edit mode left, the values read come back. */
    discard() { if (editing) stopEdit(false); },
    /** Presence: read now (operator gesture) or only show and highlight the card and its button (route state). */
    presence({ run = true } = {}) {
      const target = side.querySelector('[data-card="presence"]');
      target?.scrollIntoView({ block: 'center', behavior: 'smooth' });
      target?.classList.remove('fi-focus');
      void target?.offsetWidth;
      target?.classList.add('fi-focus');
      if (run) checkPresence();
      else side.querySelector('[data-side="presence"]')?.focus({ preventScroll: true });
    },
    /** Same object, same values: only the freshness indicators follow the new read. */
    touch(sheet) {
      void sheet;
      const chip = bar.querySelector('.fi-fresh-chip');
      if (chip && !editing) bar.innerHTML = barMarkup(S.sheet);
      startFreshness(bar);
      renderSide();
    },
    update(sheet, previous) {
      if (editing) {
        checkNewerRead(sheet);
        renderSide();
        return;
      }
      if (previous && !previous.origin.preview) patchSections(sheet, previous);
      else renderSections();
      renderSide();
    },
    destroy() {
      panel.removeEventListener('click', onClick);
      panel.removeEventListener('input', onInput);
      unbindSideCopy?.();
      kv?.destroy();
      S.draft = null;
    },
  };
}

/** Cards rendered inside an already revealed tab show at once (the reveal observer only watches the first render). */
function revealNow(scope) {
  scope.querySelectorAll('.reveal').forEach((el) => { el.classList.remove('reveal'); el.classList.add('revealed', 'fi-enter'); });
}
