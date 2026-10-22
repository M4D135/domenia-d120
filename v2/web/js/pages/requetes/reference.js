// « Référence »: the ActiveDirectory and LAPS cmdlets (Domenia 1 hidden « Référence » tab, code kept active): the help of the
// modules installed on this computer, read locally from their help files on the operator's gesture (never PowerShell, never
// the network), or the reference delivered with Domenia. Filter by text and module, full help of the selected cmdlet, copy of
// the command, the syntax, the help or the example. Domenia never runs them; write cmdlets are marked.
import { esc, glyph, plural, emptyState, skLines, vars, dateText } from './shared.js';
import { debounce, writeClipboard } from '../../kit/index.js';
import { reveal, inkFollow } from '../../ui.js';

const SOURCES = [
  { id: 'auto', label: 'Automatique' },
  { id: 'installed', label: 'Modules installés' },
  { id: 'builtin', label: 'Référence intégrée' },
];

export function mountReference(panel, store) {
  const st = { module: null, text: '', token: 0, open: null, source: 'auto', cmdlets: [] };
  panel.innerHTML = `<section class="card rq-reference spot reveal" aria-labelledby="rq-ref-title">
    <div class="card-head"><span class="card-icon">${glyph('command')}</span><div class="rq-head-titles"><h3 id="rq-ref-title">Référence des cmdlets</h3>
      <p class="rq-sub rq-ref-sub">Modules ActiveDirectory et LAPS : jamais exécutées par Domenia.</p></div>
      <div class="segmented rq-ref-source" role="radiogroup" aria-label="Source de la référence"><span class="thumb" aria-hidden="true"></span>${SOURCES.map((s) => `<button type="button" role="radio" data-source="${s.id}" aria-checked="${s.id === 'auto'}">${esc(s.label)}</button>`).join('')}</div></div>
    <div class="rq-ref-tools">
      <label class="rq-search">${glyph('search')}<input type="search" class="input rq-ref-find" maxlength="100" placeholder="Chercher une cmdlet, un paramètre…" aria-label="Chercher une cmdlet" autocomplete="off"></label>
      <div class="rq-ref-modules" role="group" aria-label="Module"></div>
    </div>
    <p class="rq-ref-origin rq-note"></p>
    <div class="rq-ref-list"></div>
  </section>`;
  const $ = (sel) => panel.querySelector(sel);

  async function load() {
    const my = ++st.token;
    const host = $('.rq-ref-list');
    host.setAttribute('aria-busy', 'true');
    if (!host.children.length) host.innerHTML = skLines(80, 70, 90, 60);
    const res = await store.call('requetes.cmdlets', { text: st.text || null, module: st.module, source: st.source });
    host.removeAttribute('aria-busy');
    if (!store.alive || my !== st.token) return;
    if (res.error) { host.innerHTML = emptyState('alert', 'Référence indisponible', res.message); return; }
    const d = res.data;
    st.cmdlets = d.cmdlets;
    if (st.open === null && d.cmdlets.length) st.open = d.cmdlets[0].name;
    $('.rq-ref-modules').innerHTML = [null, ...d.modules].map((m) => `<button type="button" class="chip sm" data-module="${esc(m ?? '')}" aria-pressed="${st.module === m}">${esc(m ?? 'Tous les modules')}</button>`).join('');
    $('.rq-ref-sub').textContent = `${plural(d.cmdlets.length, 'cmdlet affichée', 'cmdlets affichées')} sur ${d.total} · jamais exécutées par Domenia`;
    const i = d.installed;
    $('.rq-ref-origin').innerHTML = d.source === 'installed'
      ? `${glyph('check')}Aide des modules installés sur ce poste (${esc(i.modules.join(', '))}, ${plural(i.files, 'fichier d’aide', 'fichiers d’aide')}), lue localement ${esc(dateText(i.readAt))}.`
      : i ? `${glyph('info')}Aucun module ActiveDirectory ni LAPS trouvé sur ce poste (outils RSAT absents) : référence intégrée à Domenia.`
        : `${glyph('info')}Référence intégrée à Domenia. « Modules installés » lit l’aide des modules de ce poste, localement.`;
    host.innerHTML = d.cmdlets.length ? `<ul class="rq-ref-items">${d.cmdlets.map((c, n) => `<li data-i="${Math.min(n, 20)}">
      <details class="rq-ref-item"${st.open === c.name ? ' open' : ''} data-name="${esc(c.name)}"><summary><span class="rq-ref-name rq-mono">${esc(c.name)}</span><span class="rq-ref-mod">${esc(c.module)}</span>
        ${c.write ? '<span class="k-pill warn sm">Écriture</span>' : '<span class="k-pill ok sm">Lecture</span>'}${c.credential ? '<span class="k-pill info sm">-Credential</span>' : ''}${c.parameterCount ? `<span class="k-pill off sm">${plural(c.parameterCount, 'paramètre', 'paramètres')}</span>` : ''}<span class="rq-ref-syn">${esc(c.synopsis)}</span>${glyph('chevronDown', 'rq-fold-chev')}</summary>
        <div class="rq-ref-body">
          <div class="rq-ref-copy" role="group" aria-label="Copier">
            <button type="button" class="btn xs subtle" data-copy="name" data-n="${n}">${glyph('copy')}Copier la commande</button>
            <button type="button" class="btn xs ghost" data-copy="syntax" data-n="${n}">${glyph('copy')}Copier la syntaxe</button>
            <button type="button" class="btn xs ghost" data-copy="help" data-n="${n}">${glyph('copy')}Copier l’aide</button>
            <button type="button" class="btn xs ghost" data-copy="example" data-n="${n}">${glyph('copy')}Copier l’exemple</button>
          </div>
          <h5 class="rq-mini-title">Syntaxe</h5><pre class="rq-code">${esc(c.syntax)}</pre>
          <h5 class="rq-mini-title">Exemple</h5><pre class="rq-code">${esc(c.example)}</pre>
          ${c.parameters?.length ? `<h5 class="rq-mini-title">Paramètres</h5><p class="rq-ref-params">${c.parameters.map((p) => `<span class="chip sm rq-mono">-${esc(p)}</span>`).join('')}</p>` : ''}
          <details class="rq-ref-help"><summary>Aide complète</summary><pre class="rq-code">${esc(c.help)}</pre></details>
        </div></details></li>`).join('')}</ul>`
      : emptyState('search', 'Aucune cmdlet', 'Aucune cmdlet ne contient ce texte.');
    vars(host);
  }

  $('.rq-ref-find').addEventListener('input', debounce((e) => { st.text = e.target.value.trim(); load(); }, 220));
  $('.rq-ref-modules').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-module]') : null;
    if (!b) return;
    st.module = b.dataset.module || null;
    load();
  });
  panel.querySelectorAll('[data-source]').forEach((b) => b.addEventListener('click', () => {
    st.source = b.dataset.source;
    st.module = null;
    panel.querySelectorAll('[data-source]').forEach((x) => x.setAttribute('aria-checked', String(x === b)));
    ink.update();
    load();
  }));
  const ink = inkFollow($('.rq-ref-source'), '[data-source]', '[aria-checked="true"]');
  $('.rq-ref-list').addEventListener('click', async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-copy]') : null;
    if (!b) return;
    const c = st.cmdlets[Number(b.dataset.n)];
    if (!c) return;
    const text = { name: c.name, syntax: c.syntax, help: c.help, example: c.example }[b.dataset.copy];
    await writeClipboard(text);
    store.toast({ name: 'Commande copiée.', syntax: 'Syntaxe copiée.', help: 'Aide copiée.', example: 'Exemple copié : relisez-le avant de l’utiliser.' }[b.dataset.copy], 'ok');
  });
  $('.rq-ref-list').addEventListener('toggle', (e) => {
    const d = e.target instanceof HTMLDetailsElement && e.target.classList.contains('rq-ref-item') ? e.target : null;
    if (d?.open) st.open = d.dataset.name;
  }, true);
  const stopReveal = reveal(panel);
  load();
  return { destroy() { stopReveal(); ink.stop(); } };
}
