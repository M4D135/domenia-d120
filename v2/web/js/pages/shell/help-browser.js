// Help browser (TRV-004, TRV-005): the 820 topics of the catalogue, searchable in full text (every word, accents and case
// ignored), grouped by screen, with the detail of a topic and the chapter of the guides for every screen.
import { icon } from '../../icons.js';
import { esc, fold, copyText, announce } from '../../ui.js';
import { highlight } from '../../kit/util.js';
import { quietCall } from '../../shell/store.js';
import { loadHelp, searchTopics, helpAreas, helpSource, topic } from '../../shell/help.js';

const KIND_LABELS = { button: 'Bouton', input: 'Champ', secret: 'Champ secret', choice: 'Case ou choix', status: 'État', tab: 'Onglet', list: 'Liste', zone: 'Zone' };
const KIND_ICONS = { button: 'zap', input: 'search', secret: 'key', choice: 'check', status: 'info', tab: 'panel', list: 'database', zone: 'object' };
// Topics offered before any search: the gestures an operator asks about first.
const FEATURED = ['BtnCommandPalette', 'BtnReadOnlyResume', 'BtnUserUnlock', 'BtnObjectReread', 'BtnExportResults', 'DgGuardReceipts', 'BtnFirstStepOu', 'BtnThemeToggle'];

const SCREENS = [
  ['accueil', 'Accueil'], ['rechercher', 'Rechercher'], ['fiche', 'Fiche'], ['comptes', 'Comptes'], ['relations', 'Utilisateurs et postes'],
  ['poste', 'Poste'], ['assistance', 'Assistance'], ['requetes', 'Atelier de requêtes'], ['audit', 'Audit AD'], ['schema', 'Schéma de l’annuaire'],
  ['synchro', 'Synchronisation'], ['machine', 'Comptes machine'], ['operations', 'Opérations'], ['parametres', 'Paramètres'],
];

export function renderHelpBrowser(panel, ctx) {
  let query = '';
  // « ?ecran=<id> » opens the topics of one screen (the help coverage of the overview leads here).
  let area = /^[a-z]{3,20}$/.test(ctx?.params?.ecran ?? '') ? ctx.params.ecran : '';
  let selected = '';
  let limit = 60;
  panel.innerHTML = `<div class="sh-helpb">
    <div class="sh-helpb-list card">
      <label class="sh-pick-find">${icon('search')}<span class="visually-hidden">Chercher dans l’aide</span>
        <input class="input" type="search" data-hb-q placeholder="Chercher : verrouillage, export, lecture seule…" autocomplete="off" spellcheck="false"></label>
      <div class="sh-helpb-areas" role="group" aria-label="Écrans" data-hb-areas></div>
      <p class="sh-helpb-count faint" aria-live="polite" data-hb-count>Lecture du catalogue…</p>
      <ol class="sh-helpb-items" data-hb-items aria-busy="true"></ol>
      <button class="btn sm ghost sh-helpb-more" type="button" data-hb-more hidden>${icon('arrowDown')}Afficher plus de sujets</button>
    </div>
    <div class="sh-helpb-side">
      <article class="sh-helpb-detail card" data-hb-detail aria-live="polite"></article>
      <section class="sh-helpb-guides card">
        <h3 class="sh-sub">${icon('file')}Guides par écran</h3>
        <ul class="sh-helpb-guide-list" data-hb-guides><li class="faint">Chapitres des guides…</li></ul>
      </section>
    </div>
  </div>`;
  const list = panel.querySelector('[data-hb-items]');
  const count = panel.querySelector('[data-hb-count]');
  const more = panel.querySelector('[data-hb-more]');
  const detail = panel.querySelector('[data-hb-detail]');

  const areaLabel = (id) => helpAreas().find(([a]) => a === id)?.[1] ?? id;
  const paintAreas = () => {
    panel.querySelector('[data-hb-areas]').innerHTML = `<button class="k-facet" type="button" data-hb-area="" aria-pressed="${!area}">Tous</button>`
      + helpAreas().map(([id, label]) => `<button class="k-facet" type="button" data-hb-area="${esc(id)}" aria-pressed="${area === id}">${esc(label)}</button>`).join('');
  };
  const paintList = () => {
    const { total, items } = searchTopics(query, { area, limit });
    const f = fold(query.trim());
    count.textContent = `${total} sujet${total > 1 ? 's' : ''}${query ? ` pour « ${query.trim()} »` : ''}${area ? ` · ${areaLabel(area)}` : ''} sur ${helpSource()?.count ?? 820}.`;
    list.removeAttribute('aria-busy');
    list.innerHTML = items.length
      ? items.map((t) => `<li><button type="button" class="sh-helpb-item" data-hb-key="${esc(t.name)}" aria-pressed="${t.name === selected}">${icon(KIND_ICONS[t.kind] ?? 'info')}<span><strong>${highlight(t.title, f)}</strong><span class="sh-pick-path">${esc(areaLabel(t.area))} · ${esc(KIND_LABELS[t.kind] ?? 'Zone')}</span></span></button></li>`).join('')
      : `<li class="sh-empty-mini">${icon('search')}<p><strong>Aucun sujet</strong> ne contient tous ces mots.</p></li>`;
    more.hidden = total <= items.length;
  };
  // Before any choice: what the catalogue is, and a few topics to start with.
  const intro = () => {
    selected = '';
    list.querySelectorAll('[data-hb-key]').forEach((b) => b.setAttribute('aria-pressed', 'false'));
    const featured = FEATURED.map((name) => searchTopics(name, { limit: 400 }).items.find((t) => t.name === name)).filter(Boolean);
    detail.innerHTML = `<header class="sh-helpb-detail-head"><span class="card-icon">${icon('sparkles')}</span><div><h3>Une aide pour chaque contrôle</h3><p class="faint">${helpSource()?.count ?? 820} sujets repris de Domenia 1, classés par écran</p></div></header>
      <p class="sh-helpb-text">Le texte d’un sujet est celui de l’infobulle, de la description lue par le lecteur d’écran et du panneau F1. Cherchez avec quelques mots : tous doivent être présents, sans tenir compte des accents ni des majuscules.</p>
      <h4 class="sh-helpb-featured-title">Pour commencer</h4>
      <div class="sh-helpb-featured">${featured.map((t) => `<button class="chip" type="button" data-hb-key="${esc(t.name)}">${icon(KIND_ICONS[t.kind] ?? 'info')}${esc(t.title)}</button>`).join('')}</div>
      <ul class="sh-helpb-tips">
        <li><kbd>F1</kbd><span>sur n’importe quel écran : l’aide de l’élément survolé ou qui a le focus.</span></li>
        <li><kbd>Ctrl</kbd><kbd>K</kbd><span>la palette cherche aussi dans ces sujets.</span></li>
      </ul>`;
  };
  const show = async (key) => {
    selected = key;
    const t = await topic(key);
    list.querySelectorAll('[data-hb-key]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.hbKey === key)));
    detail.innerHTML = `<header class="sh-helpb-detail-head"><span class="card-icon">${icon(KIND_ICONS[t.kind] ?? 'info')}</span><div><h3>${esc(t.title)}</h3><p class="faint">${esc(areaLabel(t.area))} · ${esc(KIND_LABELS[t.kind] ?? 'Zone')}</p></div></header>
      <p class="sh-helpb-text">${esc(t.text)}</p>
      <dl class="sh-kv"><div class="sh-kv-row"><dt>Clé du contrôle</dt><dd class="mono">${esc(t.name)}</dd></div><div class="sh-kv-row"><dt>Infobulle</dt><dd>${t.kind === 'list' || t.kind === 'zone' ? 'Aucune sur une zone (le texte reste lu au focus et dans F1)' : t.kind === 'button' ? 'Première phrase sur un bouton icône, texte entier sinon' : 'Texte entier'}</dd></div></dl>
      <div class="sh-helpb-actions"><button class="btn sm subtle" type="button" data-hb-copy>${icon('copy')}Copier le texte</button><button class="btn sm ghost" type="button" data-hb-key-copy>${icon('copy')}Copier la clé</button></div>`;
  };
  panel.addEventListener('input', (e) => {
    if (!(e.target instanceof HTMLInputElement) || !e.target.matches('[data-hb-q]')) return;
    query = e.target.value;
    limit = 60;
    paintList();
  });
  panel.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const a = t?.closest('[data-hb-area]');
    if (a) { area = a.dataset.hbArea; limit = 60; paintAreas(); paintList(); return; }
    const k = t?.closest('[data-hb-key]');
    if (k) { show(k.dataset.hbKey); return; }
    if (t?.closest('[data-hb-more]')) { limit += 120; paintList(); return; }
    if (t?.closest('[data-hb-copy]') && selected) topic(selected).then((x) => copyText(`${x.title}\r\n${x.text}`)).then((ok) => announce(ok ? 'Texte d’aide copié.' : 'Copie impossible.'));
    if (t?.closest('[data-hb-key-copy]') && selected) copyText(selected).then((ok) => announce(ok ? 'Clé copiée.' : 'Copie impossible.'));
    const g = t?.closest('[data-hb-guide]');
    if (g && g.getAttribute('aria-disabled') !== 'true') {
      quietCall('shell.guide.open', { page: g.dataset.hbGuide }).then((r) => {
        const note = g.closest('li').querySelector('.sh-helpb-guide-note');
        if (note && r) note.textContent = r.message;
      }).catch((err) => console.warn(err));
    }
  });
  loadHelp().then(() => {
    if (area && !helpAreas().some(([a]) => a === area)) area = '';
    paintAreas();
    paintList();
    intro();
    if (area) panel.querySelector(`[data-hb-area="${CSS.escape(area)}"]`)?.scrollIntoView({ block: 'nearest', inline: 'center' });
  }).catch(() => { count.textContent = 'Catalogue d’aide indisponible.'; list.removeAttribute('aria-busy'); });
  Promise.all(SCREENS.map(([id]) => quietCall('shell.guide.info', { page: id }).catch(() => null))).then((guides) => {
    panel.querySelector('[data-hb-guides]').innerHTML = SCREENS.map(([id, label], n) => {
      const g = guides[n];
      return `<li><span class="sh-helpb-guide-screen">${esc(label)}</span><span class="sh-helpb-guide-chapter">${esc(g ? `${g.guideTitle}, chapitre ${g.chapter}` : '—')}<span class="faint">${esc(g?.title ?? '')}</span></span>
        <button class="btn xs ghost" type="button" data-hb-guide="${id}"${g?.found ? '' : ` aria-disabled="true" data-reason="${esc(g?.message ?? 'Guide indisponible dans cet aperçu.')}"`}>${icon('external')}Ouvrir</button><span class="sh-helpb-guide-note faint"></span></li>`;
    }).join('');
  });
}
