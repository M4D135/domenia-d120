// Attributes tab: every attribute read, sorted, dates converted, binary in hexadecimal, sensitive attributes excluded and
// counted (FIC-002, « Copier tout »), and the raw attribute editor under the SE-02 rule (FIC-001): valid name,
// Security.AllowRawAttributeWrite, block list shown (improvement), syntax of the chosen attribute, typed confirmation.
import { createGrid, glyph, pill, writeClipboard, int } from '../../kit/index.js';
import { esc, errorText, toast, applyVars } from '../../ui.js';
import { write } from './actions.js';
import { tabular } from './common.js';

const SYNTAX = { dn: 'Nom distinctif', date: 'Date', flags: 'Indicateurs', guid: 'GUID', sid: 'SID', int: 'Entier', bool: 'Booléen', binary: 'Binaire', text: 'Texte' };

/**
 * @param {HTMLElement} panel
 * @param {any} S
 */
export function mountAttributes(panel, S) {
  let data = null;
  let grid = null;
  let token = 0;

  panel.innerHTML = `<div class="fi-attrs grid">
    <div class="span-8 card fi-card fi-attrs-grid"></div>
    <aside class="span-4 fi-raw-host"></aside></div>`;
  const gridHost = /** @type {HTMLElement} */ (panel.querySelector('.fi-attrs-grid'));
  const rawHost = /** @type {HTMLElement} */ (panel.querySelector('.fi-raw-host'));

  function buildGrid() {
    grid?.destroy();
    grid = createGrid(gridHost, {
      key: 'fiche.attributes',
      label: 'Attributs bruts de l’objet',
      rowId: (r) => r.name,
      selection: 'single',
      loading: true,
      height: '560px',
      density: 'compact',
      quickPlaceholder: 'Filtrer les attributs et leurs valeurs…',
      columns: [
        { id: 'name', label: 'Attribut', mono: true, required: true, width: 230 },
        { id: 'display', label: 'Valeur', width: 460 },
        { id: 'syntax', label: 'Syntaxe', type: 'enum', width: 130, options: Object.entries(SYNTAX).map(([value, label]) => ({ value, label, tone: value === 'date' ? 'info' : value === 'dn' ? 'accent' : 'off' })) },
        { id: 'multi', label: 'Multivaluée', type: 'bool', width: 110 },
        { id: 'writable', label: 'Modifiable', type: 'bool', width: 110, tip: 'Selon la liste de blocage et les attributs tenus par l’annuaire' },
      ],
      empty: { icon: 'hash', title: 'Aucun attribut lu', text: 'La lecture de l’objet n’a rendu aucun attribut affichable.' },
      onActivate: (r) => choose(r),
      contextMenu: ({ row }) => (row ? [
        { heading: row.name },
        { label: 'Copier la valeur', icon: 'copy', run: () => copy(row.values.join(' ; '), 'Valeur copiée.') },
        { label: 'Copier le nom', icon: 'copy', run: () => copy(row.name, 'Nom copié.') },
        '-',
        { label: 'Modifier dans l’éditeur brut', icon: 'edit', disabled: !row.writable || !data?.rawWrite.allowed, reason: row.blocked ?? data?.rawWrite.reason ?? '', run: () => choose(row) },
      ] : []),
    });
    grid.slot.innerHTML = `<div class="fi-grid-actions"><button class="btn sm" type="button" data-a="copyAll">${glyph('copy')}Copier tout</button></div>`;
  }

  function rawMarkup() {
    const rw = data?.rawWrite;
    const allowed = rw?.allowed;
    return `<section class="card fi-card fi-raw fi-enter">
      <div class="card-head"><span class="card-icon" data-tone="${allowed ? 'warn' : 'off'}">${glyph('edit')}</span>
        <div class="fi-card-titles"><h3>Écriture brute d’un attribut</h3><p class="fi-card-sub">Règle appliquée par la page puis revérifiée par le moteur</p></div>
        <span class="meta">${pill(allowed ? 'warn' : 'off', allowed ? 'Autorisée' : 'Désactivée', { size: 'sm', icon: allowed ? 'alert' : 'lock' })}</span></div>
      ${allowed ? '' : `<p class="fi-raw-off">${glyph('lock')}${esc(rw?.reason ?? 'Écriture brute désactivée.')}</p>`}
      <form class="fi-raw-form" novalidate>
        <label class="fi-field-label" for="fi-raw-name">Attribut</label>
        <input id="fi-raw-name" class="input mono" list="fi-raw-names" maxlength="127" autocomplete="off" spellcheck="false" placeholder="description, info, extensionAttribute1…"${allowed ? '' : ' disabled'}>
        <datalist id="fi-raw-names">${(data?.rows ?? []).filter((r) => r.writable).map((r) => `<option value="${esc(r.name)}"></option>`).join('')}</datalist>
        <p class="fi-raw-syntax fi-faint" aria-live="polite">Choisissez un attribut : sa syntaxe et sa valeur actuelle s’affichent ici.</p>
        <label class="fi-field-label" for="fi-raw-value">Nouvelle valeur</label>
        <textarea id="fi-raw-value" class="input mono" rows="3" maxlength="4096" spellcheck="false" placeholder="Vide = effacement"${allowed ? '' : ' disabled'}></textarea>
        <div class="fi-raw-actions">
          <button class="btn sm ghost fi-write" type="button" data-a="clear"${allowed ? '' : ' disabled'}>${glyph('x')}Effacer…</button>
          <button class="btn sm danger fi-write" type="submit"${allowed ? '' : ' disabled'}>${glyph('edit')}Écrire…</button></div>
      </form>
      <details class="fi-blocklist"><summary>${glyph('shield')}Liste de blocage active (${int(rw?.blockList?.length ?? 0)} attributs)${rw?.blockSensitive ? '' : ' · inactive'}</summary>
        <p class="fi-blocklist-items">${(rw?.blockList ?? []).map((n) => `<span class="mono">${esc(n)}</span>`).join('')}</p></details>
      <p class="fi-note">${glyph('info')}${esc(data?.note ?? '')}</p>
    </section>`;
  }

  function choose(row) {
    const name = /** @type {HTMLInputElement|null} */ (rawHost.querySelector('#fi-raw-name'));
    const value = /** @type {HTMLTextAreaElement|null} */ (rawHost.querySelector('#fi-raw-value'));
    if (!name || name.disabled) {
      toast(data?.rawWrite.reason ?? 'Écriture brute désactivée.', { tone: 'info' });
      return;
    }
    name.value = row.name;
    if (value) value.value = row.multi ? '' : (row.values[0] ?? '');
    describe();
    value?.focus();
  }

  function describe() {
    const name = /** @type {HTMLInputElement|null} */ (rawHost.querySelector('#fi-raw-name'));
    const out = rawHost.querySelector('.fi-raw-syntax');
    if (!name || !out) return;
    const row = (data?.rows ?? []).find((r) => r.name.toLowerCase() === name.value.trim().toLowerCase());
    if (!name.value.trim()) { out.textContent = 'Choisissez un attribut : sa syntaxe et sa valeur actuelle s’affichent ici.'; return; }
    if (!row) { out.textContent = 'Attribut absent de l’objet : il sera ajouté (syntaxe vérifiée par le contrôleur).'; return; }
    out.innerHTML = `${pill(row.writable ? 'info' : 'alert', SYNTAX[row.syntax] ?? row.syntax, { size: 'sm' })} ${row.multi ? 'Multivaluée : l’écriture brute ne remplace qu’une valeur unique.' : `Valeur actuelle : <span class="mono">${esc(row.display)}</span>`}${row.blocked ? ` · <b>${esc(row.blocked)}</b>` : ''}`;
  }

  async function submit(clear) {
    const name = /** @type {HTMLInputElement} */ (rawHost.querySelector('#fi-raw-name')).value.trim();
    const value = clear ? null : /** @type {HTMLTextAreaElement} */ (rawHost.querySelector('#fi-raw-value')).value;
    if (!/^[A-Za-z][A-Za-z0-9-]{0,126}$/.test(name)) { toast('Nom d’attribut invalide.', { tone: 'warn' }); return; }
    const row = (data?.rows ?? []).find((r) => r.name.toLowerCase() === name.toLowerCase());
    if (row && !row.writable) { toast(row.blocked ?? 'Attribut bloqué.', { tone: 'warn' }); return; }
    await write(S.ctx, 'fiche.rawAttribute.plan', { dn: S.sheet.identity.dn, attribute: name, value: value === '' ? null : value },
      { subtitle: `${S.sheet.identity.name} · ${name}`, onDone: () => { S.reload({ quiet: true }); load(); } });
  }

  async function copy(text, done) {
    const ok = await writeClipboard(text);
    toast(ok ? done : 'Copie impossible.', { tone: ok ? 'ok' : 'warn', life: 2400 });
  }

  async function load() {
    const my = ++token;
    try {
      data = await S.ctx.call('fiche.attributes', { dn: S.sheet.identity.dn });
      if (my !== token || !S.alive) return;
      grid.setRows(data.rows, { keepSelection: true, keepScroll: true });
      rawHost.innerHTML = rawMarkup();
      applyVars(rawHost);
    } catch (err) {
      if (my !== token) return;
      grid.setError(errorText(err), { retry: () => load() });
    }
  }

  buildGrid();
  rawHost.innerHTML = rawMarkup();
  load();

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const b = t?.closest('[data-a]');
    if (!b) return;
    if (b.dataset.a === 'copyAll' && data) copy(tabular(data.rows, [{ label: 'Attribut', get: (r) => r.name }, { label: 'Valeur', get: (r) => r.display }]), `${data.rows.length} attributs copiés (sans les attributs sensibles).`);
    else if (b.dataset.a === 'clear') submit(true);
  };
  const onSubmit = (e) => { if (e.target instanceof HTMLFormElement && e.target.matches('.fi-raw-form')) { e.preventDefault(); submit(false); } };
  const onInput = (e) => { if (e.target instanceof Element && e.target.matches('#fi-raw-name')) describe(); };
  panel.addEventListener('click', onClick);
  panel.addEventListener('submit', onSubmit);
  panel.addEventListener('input', onInput);
  return {
    focusEditor() { rawHost.querySelector('#fi-raw-name')?.focus(); rawHost.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); },
    update() {},
    refresh: load,
    destroy() {
      panel.removeEventListener('click', onClick);
      panel.removeEventListener('submit', onSubmit);
      panel.removeEventListener('input', onInput);
      grid?.destroy();
    },
  };
}
