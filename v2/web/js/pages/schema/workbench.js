// Filter workbench of the schema screen (SCH-004 to SCH-006): an editor that colours the RFC 4515 filter as it is typed,
// the local analysis of its cost (schema.filter.analyze: targeted, broad, unknown or invalid, with the advice of Domenia 1),
// the tree of the filter with the index use of each node, a suggested rewriting, and the draft insertion of the attribute
// chosen in the browser (schema.filter.insert). Nothing is ever sent to a controller from here.
import { openMenu } from '../../kit/menu.js';
import { debounce, writeClipboard, uid } from '../../kit/util.js';
import { applyVars, toast, announce } from '../../ui.js';
import { glyph, esc, count, NBSP, errText, highlightFilter, codeLine } from './model.js';

const LEVELS = {
  targeted: { icon: 'zap', at: 0 },
  unknown: { icon: 'info', at: 1 },
  broad: { icon: 'alert', at: 2 },
  invalid: { icon: 'x', at: 1 },
};
const INDEX_TONES = { yes: 'ok', no: 'warn', unknown: 'info' };
const LIVE_DELAY_MS = 350;

/** Ready-made filters of the « Exemples » menu (the DN of the domain completes the nested membership one). */
function examples(rootDn) {
  const base = rootDn || 'DC=example,DC=local';
  return [
    { label: 'Comptes désactivés', filter: '(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=2))' },
    { label: 'Postes dont le nom commence par PC-PAR', filter: '(&(objectCategory=computer)(name=PC-PAR-*))' },
    { label: 'Membres imbriqués d’un groupe', filter: `(memberOf:1.2.840.113556.1.4.1941:=CN=GG-Admins-Postes,OU=Sécurité,OU=Groupes,${base})` },
    { label: 'Recherche ambiguë (ANR)', filter: '(anr=martin)' },
    { label: 'Joker en tête sur la description', filter: '(&(objectClass=user)(description=*stagiaire*))' },
    { label: 'Mot de passe à changer', filter: '(&(objectCategory=person)(objectClass=user)(pwdLastSet=0))' },
    { label: 'Créés depuis le 1er janvier (attribut calculé)', filter: '(createTimeStamp>=20260101000000.0Z)' },
    { label: 'Négation seule', filter: '(!(description=*))' },
  ];
}

function treeMarkup(node, depth = 0) {
  const leaf = !node.children.length;
  const tone = INDEX_TONES[node.indexUse] ?? 'info';
  const head = `<div class="sch-tnode${leaf ? ' leaf' : ''}">
    <span class="kind">${esc(node.label)}</span>
    ${leaf ? `<code class="txt">${highlightFilter(node.text)}</code>` : ''}
    ${node.negated && leaf ? '<span class="neg" data-tip="Sous une négation : aucun index">NON</span>' : ''}
    <span class="idx ${tone}">${esc(node.indexLabel)}</span>
  </div>`;
  if (leaf) return `<li data-j="${depth}">${head}</li>`;
  return `<li data-j="${depth}">${head}<ul>${node.children.map((c) => treeMarkup(c, depth + 1)).join('')}</ul></li>`;
}

function attributeChips(a) {
  const tones = new Map();
  for (const name of a.attributes) tones.set(name, { tone: 'ok', tip: 'Indexé' });
  for (const name of a.notIndexed) tones.set(name, { tone: 'off', tip: 'Non indexé' });
  for (const name of a.unknown) tones.set(name, { tone: 'info', tip: a.schemaUsed ? 'Absent du schéma lu' : 'Index inconnu : schéma non lu' });
  for (const name of a.confidential) tones.set(name, { tone: 'warn', tip: 'Confidentiel' });
  for (const name of a.constructed) tones.set(name, { tone: 'warn', tip: 'Calculé : ne se filtre pas' });
  if (!a.schemaUsed) for (const name of a.attributes) if (!a.unknown.includes(name)) tones.set(name, { tone: 'info', tip: 'Index inconnu : schéma non lu' });
  return a.attributes.map((name, j) => {
    const t = tones.get(name) ?? { tone: 'off', tip: '' };
    return `<button class="sch-achip ${t.tone}" type="button" data-j="${j}" data-open-attr="${esc(name)}" data-tip="${esc(t.tip)}">${esc(name)}</button>`;
  }).join('');
}

function errorMarkup(a) {
  const text = a.normalized ?? '';
  const at = Number.isInteger(a.errorPosition) ? Math.max(0, Math.min(text.length, a.errorPosition)) : null;
  const shown = at === null || !text ? esc(text)
    : `${esc(text.slice(0, at))}<mark class="sch-caret">${esc(text.slice(at, at + 1) || ' ')}</mark>${esc(text.slice(at + 1))}`;
  return `<div class="sch-error" role="alert">
    <div class="sch-error-head">${glyph('alert')}<b>${esc(a.error ?? 'Filtre non valide.')}</b></div>
    ${text ? `<pre class="sch-error-text"><code>${shown}</code></pre>` : ''}
    <p class="muted">Corrigez la syntaxe${NBSP}: rien n’a été envoyé au contrôleur.</p>
  </div>`;
}

function resultMarkup(a) {
  if (!a.valid) {
    return `<div class="sch-res invalid">${verdictMarkup(a)}${errorMarkup(a)}</div>`;
  }
  const s = a.suggestion;
  return `<div class="sch-res">
    <div class="sch-res-main">
      ${verdictMarkup(a)}
      <ul class="sch-advice-list">${a.advice.map((t, j) => `<li data-j="${j}">${glyph(j === 0 && !a.schemaUsed ? 'info' : a.level === 'targeted' && j === (a.schemaUsed ? 0 : 1) ? 'check' : 'chevronRight')}<span>${esc(t)}</span></li>`).join('')}</ul>
      ${a.attributes.length ? `<div class="sch-res-attrs"><span class="sch-label">Attributs du filtre</span><div class="sch-achips">${attributeChips(a)}</div></div>` : ''}
    </div>
    <div class="sch-res-side">
      ${s ? `<section class="sch-suggest">
        <h4>${glyph('sparkles')}Réécriture suggérée</h4>
        <ul>${s.reasons.map((r) => `<li>${esc(r)}</li>`).join('')}</ul>
        ${s.filter ? `${codeLine(s.filter, { label: 'Copier la réécriture' })}<button class="btn sm" type="button" data-use-suggestion>${glyph('check')}Utiliser cette réécriture</button>` : ''}
      </section>` : ''}
      ${a.tree ? `<section class="sch-tree"><h4>${glyph('layers')}Structure du filtre</h4><ul class="sch-troot">${treeMarkup(a.tree)}</ul></section>`
    : '<p class="muted">Structure non affichée : filtre de plus de 300 éléments.</p>'}
    </div>
  </div>`;
}

function verdictMarkup(a) {
  const level = LEVELS[a.level] ?? LEVELS.unknown;
  const stops = [['Ciblé', 'ok'], ['Inconnu', 'info'], ['Large', 'warn']]
    .map(([label, tone], n) => `<span class="stop ${tone}${n === level.at && a.level !== 'invalid' ? ' on' : ''}">${esc(label)}</span>`).join('');
  return `<div class="sch-verdict ${esc(a.tone)}" data-level="${esc(a.level)}">
    <span class="sch-verdict-ico">${glyph(level.icon)}</span>
    <div class="sch-verdict-body">
      <span class="sch-label">Coût LDAP estimé</span>
      <b class="sch-verdict-level">${esc(a.levelLabel)}</b>
      <span class="sch-verdict-sub">${esc(a.valid ? (a.schemaUsed ? 'Selon les index du schéma lu' : 'Schéma non lu : index inconnus') : 'Syntaxe à corriger')}</span>
    </div>
    <div class="sch-scale${a.level === 'invalid' ? ' off' : ''}" aria-hidden="true"><span class="track"></span><span class="needle" data-at="${level.at}"></span>${stops}</div>
  </div>`;
}

/**
 * Creates the workbench in host.
 * @param {HTMLElement} host
 * @param {any} ctx  Page context (ctx.call, ctx.navigate).
 * @param {{ rootDn: () => string, status: () => any, selected: () => ({ name: string, insertable: boolean, reason: string|null }|null),
 *   onAttribute: (name: string) => void }} o
 */
export function createWorkbench(host, ctx, o) {
  const id = uid('sch-f');
  const schemaRead = () => !!o.status()?.read;
  host.innerHTML = `<div class="sch-wb">
    <div class="sch-wb-editor">
      <div class="sch-wb-top"><label class="sch-label" for="${id}">Filtre LDAP (RFC 4515)</label><span class="sch-wb-count" aria-live="off"></span></div>
      <div class="sch-editor">
        <pre class="sch-hl" aria-hidden="true"><code></code></pre>
        <textarea id="${id}" class="sch-input" rows="2" spellcheck="false" autocomplete="off" autocapitalize="off" maxlength="32768"
          placeholder="(&amp;(objectCategory=computer)(name=PC-*))" aria-describedby="${id}-hint"></textarea>
      </div>
      <div class="sch-wb-bar" role="toolbar" aria-label="Actions du filtre">
        <button class="btn primary sm" type="button" data-wb="analyze">${glyph('gauge')}Analyser<kbd>Entrée</kbd></button>
        <button class="btn sm" type="button" data-wb="insert">${glyph('plus')}<span class="label">Ajouter l’attribut choisi</span></button>
        <button class="btn sm" type="button" data-wb="examples" aria-haspopup="menu">${glyph('sparkles')}Exemples${glyph('chevronDown')}</button>
        <button class="btn ghost sm" type="button" data-wb="clear">${glyph('x')}Effacer</button>
        <span class="sch-wb-spacer"></span>
        <button class="btn ghost sm" type="button" data-wb="send" data-tip="Ouvre l’atelier de requêtes avec ce filtre en brouillon : rien n’est exécuté">${glyph('external')}Atelier de requêtes</button>
      </div>
      <p class="sch-wb-hint" id="${id}-hint">${glyph('shield')}<span></span></p>
    </div>
    <div class="sch-wb-result" aria-live="polite">
      <div class="sch-wb-idle">${glyph('gauge')}<div><b>Aucun filtre analysé</b><span>Saisissez un filtre, choisissez un exemple, ou ajoutez l’attribut choisi dans le catalogue.</span></div></div>
    </div>
  </div>`;
  const input = /** @type {HTMLTextAreaElement} */ (host.querySelector('.sch-input'));
  const hl = /** @type {HTMLElement} */ (host.querySelector('.sch-hl code'));
  const pre = /** @type {HTMLElement} */ (host.querySelector('.sch-hl'));
  const result = /** @type {HTMLElement} */ (host.querySelector('.sch-wb-result'));
  const counter = /** @type {HTMLElement} */ (host.querySelector('.sch-wb-count'));
  const insertButton = /** @type {HTMLButtonElement} */ (host.querySelector('[data-wb="insert"]'));
  let alive = true;
  let request = 0;
  let last = null;

  const paint = () => {
    // A trailing newline keeps the coloured copy as tall as the field.
    hl.innerHTML = `${highlightFilter(input.value)}\n`;
    const n = input.value.length;
    counter.textContent = n ? count(n, 'caractère', 'caractères') : '';
  };
  const syncScroll = () => { pre.scrollTop = input.scrollTop; pre.scrollLeft = input.scrollLeft; };

  async function analyze({ quiet = false } = {}) {
    const text = input.value;
    const my = ++request;
    if (!text.trim()) {
      last = null;
      result.innerHTML = `<div class="sch-wb-idle">${glyph('gauge')}<div><b>Aucun filtre analysé</b><span>Saisissez un filtre à analyser.</span></div></div>`;
      return;
    }
    result.setAttribute('aria-busy', 'true');
    try {
      const a = await ctx.call('schema.filter.analyze', { filter: text });
      if (!alive || my !== request) return;
      last = a;
      result.innerHTML = resultMarkup(a);
      applyVars(result);
      result.querySelector('.sch-scale .needle')?.style.setProperty('--at', String(LEVELS[a.level]?.at ?? 1));
      if (!quiet) announce(a.text);
    } catch (err) {
      if (!alive || my !== request) return;
      result.innerHTML = `<div class="sch-error" role="alert"><div class="sch-error-head">${glyph('alert')}<b>${esc(errText(err, 'Analyse impossible.'))}</b></div></div>`;
    } finally {
      if (my === request) result.removeAttribute('aria-busy');
    }
  }
  const live = debounce(() => analyze({ quiet: true }), LIVE_DELAY_MS);

  function setFilter(text, { run = true, focus = false } = {}) {
    input.value = String(text ?? '').replace(/[\r\n]+/g, ' ');
    paint();
    if (focus) input.focus();
    if (run) analyze();
  }

  async function insert(name) {
    if (!name) return;
    if (!schemaRead()) {
      toast('Lisez d’abord le schéma : l’exemple de critère dépend du type de l’attribut.', { tone: 'info' });
      return;
    }
    try {
      const r = await ctx.call('schema.filter.insert', { filter: input.value, attribute: name });
      if (!alive) return;
      if (r.changed) {
        setFilter(r.filter, { run: false });
        last = r.analysis;
        result.innerHTML = resultMarkup(r.analysis);
        applyVars(result);
        result.querySelector('.sch-scale .needle')?.style.setProperty('--at', String(LEVELS[r.analysis.level]?.at ?? 1));
        input.focus();
        // Selects the placeholder value of the example so that typing replaces it.
        const at = input.value.lastIndexOf('valeur');
        if (at >= 0) input.setSelectionRange(at, at + 'valeur'.length);
        host.closest('.sch-workbench')?.classList.add('flash');
        setTimeout(() => host.closest('.sch-workbench')?.classList.remove('flash'), 900);
      }
      toast(r.message, { tone: r.changed ? 'ok' : 'warn' });
    } catch (err) {
      toast(errText(err, 'Ajout impossible.'), { tone: 'alert' });
    }
  }

  /** The hint under the editor says which index knowledge the analysis uses (schema read or not). */
  function refreshHint() {
    const status = o.status();
    const base = `L’analyse se fait sur ce poste, sans interroger l’annuaire${NBSP}: attributs indexés ou non, joker en tête, négation, attribut calculé.`;
    const tail = status?.read
      ? ` Index du schéma lu sur ${status.server ?? 'le contrôleur'}${status.truncated ? ' (lecture incomplète)' : ''}.`
      : ' Sans schéma lu, les index restent inconnus.';
    host.querySelector('.sch-wb-hint span').textContent = base + tail;
  }

  function refreshInsert() {
    const sel = o.selected();
    const read = schemaRead();
    let reason = '';
    if (!read) reason = 'Lisez d’abord le schéma.';
    else if (!sel) reason = 'Choisissez d’abord un attribut dans le catalogue ou dans les attributs d’une classe.';
    else if (!sel.insertable) reason = sel.reason ?? 'Attribut inutilisable dans un filtre.';
    insertButton.querySelector('.label').textContent = sel && read ? `Ajouter ${sel.name}` : 'Ajouter l’attribut choisi';
    if (reason) {
      insertButton.setAttribute('aria-disabled', 'true');
      insertButton.dataset.tip = reason;
    } else {
      insertButton.removeAttribute('aria-disabled');
      insertButton.dataset.tip = `Ajoute un exemple de critère sur ${sel.name}, à compléter`;
    }
  }

  input.addEventListener('input', () => {
    if (/[\r\n]/.test(input.value)) {
      const pos = input.selectionStart;
      input.value = input.value.replace(/[\r\n]+/g, ' ');
      input.setSelectionRange(pos, pos);
    }
    paint();
    live();
  });
  input.addEventListener('scroll', syncScroll);
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      live.cancel?.();
      analyze();
    }
  });
  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const b = t.closest('[data-wb]');
    if (b) {
      if (b.getAttribute('aria-disabled') === 'true') return;
      const what = b.getAttribute('data-wb');
      if (what === 'analyze') analyze();
      else if (what === 'clear') { setFilter('', { run: true, focus: true }); }
      else if (what === 'insert') insert(o.selected()?.name);
      else if (what === 'send') {
        if (!input.value.trim()) { toast('Saisissez d’abord un filtre.', { tone: 'info' }); return; }
        ctx.navigate('requetes', { filtre: input.value.trim() });
      } else if (what === 'examples') {
        openMenu(b, [{ heading: 'Exemples à analyser' }, ...examples(o.rootDn()).map((x) => ({
          label: x.label, icon: 'sparkles', run: () => setFilter(x.filter, { focus: true }),
        }))], { label: 'Exemples de filtres', placement: 'bottom-start' });
      }
      return;
    }
    if (t.closest('[data-use-suggestion]') && last?.suggestion?.filter) {
      setFilter(last.suggestion.filter, { focus: true });
      toast('Réécriture reprise dans le filtre : vérifiez les valeurs avant de l’utiliser.', { tone: 'info' });
      return;
    }
    const copy = t.closest('[data-copy]');
    if (copy) {
      writeClipboard(copy.getAttribute('data-copy') ?? '').then(() => toast('Copié dans le presse-papiers.', { tone: 'ok', life: 2200 }));
      return;
    }
    const attr = t.closest('[data-open-attr]');
    if (attr && schemaRead()) o.onAttribute(attr.getAttribute('data-open-attr'));
  });

  paint();
  refreshInsert();
  refreshHint();

  return {
    setFilter,
    insert,
    analyze,
    refreshInsert,
    refreshHint,
    focus: () => input.focus(),
    value: () => input.value,
    destroy() { alive = false; live.cancel?.(); },
  };
}

