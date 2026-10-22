// « Référence »: built-in reference of the ActiveDirectory and LAPS cmdlets (synopsis, syntax, example), to read a script
// exported by the workshop or to go further by hand. Domenia never runs them; write cmdlets are marked.
import { esc, glyph, plural, emptyState, skLines, vars } from './shared.js';
import { debounce, writeClipboard } from '../../kit/index.js';
import { reveal } from '../../ui.js';

export function mountReference(panel, store) {
  const st = { module: null, text: '', token: 0, open: null };
  panel.innerHTML = `<section class="card rq-reference spot reveal" aria-labelledby="rq-ref-title">
    <div class="card-head"><span class="card-icon">${glyph('command')}</span><div class="rq-head-titles"><h3 id="rq-ref-title">Référence des cmdlets</h3>
      <p class="rq-sub rq-ref-sub">Modules ActiveDirectory et LAPS : jamais exécutées par Domenia.</p></div></div>
    <div class="rq-ref-tools">
      <label class="rq-search">${glyph('search')}<input type="search" class="input rq-ref-find" maxlength="100" placeholder="Chercher une cmdlet, un paramètre…" aria-label="Chercher une cmdlet" autocomplete="off"></label>
      <div class="rq-ref-modules" role="group" aria-label="Module"></div>
    </div>
    <div class="rq-ref-list"></div>
  </section>`;
  const $ = (sel) => panel.querySelector(sel);

  async function load() {
    const my = ++st.token;
    const host = $('.rq-ref-list');
    host.setAttribute('aria-busy', 'true');
    if (!host.children.length) host.innerHTML = skLines(80, 70, 90, 60);
    const res = await store.call('requetes.cmdlets', { text: st.text || null, module: st.module });
    host.removeAttribute('aria-busy');
    if (!store.alive || my !== st.token) return;
    if (res.error) { host.innerHTML = emptyState('alert', 'Référence indisponible', res.message); return; }
    const d = res.data;
    if (st.open === null && d.cmdlets.length) st.open = d.cmdlets[0].name;
    $('.rq-ref-modules').innerHTML = [null, ...d.modules].map((m) => `<button type="button" class="chip sm" data-module="${esc(m ?? '')}" aria-pressed="${st.module === m}">${esc(m ?? 'Tous les modules')}</button>`).join('');
    $('.rq-ref-sub').textContent = `${plural(d.cmdlets.length, 'cmdlet affichée', 'cmdlets affichées')} sur ${d.total} · jamais exécutées par Domenia`;
    host.innerHTML = d.cmdlets.length ? `<ul class="rq-ref-items">${d.cmdlets.map((c, n) => `<li data-i="${Math.min(n, 20)}">
      <details class="rq-ref-item"${st.open === c.name ? ' open' : ''} data-name="${esc(c.name)}"><summary><span class="rq-ref-name rq-mono">${esc(c.name)}</span><span class="rq-ref-mod">${esc(c.module)}</span>
        ${c.write ? '<span class="k-pill warn sm">Écriture</span>' : '<span class="k-pill ok sm">Lecture</span>'}${c.credential ? '<span class="k-pill info sm">-Credential</span>' : ''}<span class="rq-ref-syn">${esc(c.synopsis)}</span>${glyph('chevronDown', 'rq-fold-chev')}</summary>
        <div class="rq-ref-body"><h5 class="rq-mini-title">Syntaxe</h5><pre class="rq-code">${esc(c.syntax)}</pre>
          <h5 class="rq-mini-title">Exemple</h5><pre class="rq-code">${esc(c.example)}</pre>
          <button type="button" class="btn xs ghost" data-copy="${esc(c.example)}">${glyph('copy')}Copier l’exemple</button></div></details></li>`).join('')}</ul>`
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
  $('.rq-ref-list').addEventListener('click', async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-copy]') : null;
    if (!b) return;
    await writeClipboard(b.dataset.copy);
    store.toast('Exemple copié : relisez-le avant de l’utiliser.', 'ok');
  });
  $('.rq-ref-list').addEventListener('toggle', (e) => {
    const d = e.target instanceof HTMLDetailsElement ? e.target : null;
    if (d?.open) st.open = d.dataset.name;
  }, true);
  const stopReveal = reveal(panel);
  load();
  return { destroy() { stopReveal(); } };
}
