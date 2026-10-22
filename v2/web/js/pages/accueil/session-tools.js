// Accueil: first steps (Domenia 1 point 148, ACC-015 to ACC-018), help of the screen, and the session tools of Domenia 1
// (BtnDashCheck, BtnDashClearCache, BtnDashOpenLog, ACC-019 to ACC-022): « Vérifier l’application », « Vider le cache »,
// « Ouvrir le journal ». Everything is local: no directory read, no network.
import { openDrawer } from '../../kit/drawer.js';
import { confirmDialog } from '../../kit/dialog.js';
import { createTabs } from '../../kit/tabs.js';
import { glyph } from '../../kit/glyphs.js';
import { pill } from '../../kit/status.js';
import { timeline, bindTimeline } from '../../kit/timeline.js';
import { esc, formatNumber, countUp, progressTo } from '../../ui.js';
import { plural, paint, reported, surface, localStamp, copyWithToast, sk } from './shared.js';

const loading = () => `<div class="acc-loading" aria-busy="true">${[85, 70, 55, 70].map((w) => sk(`sk-line w${w}`)).join('')}</div>`;
const LEVEL_TONE = { ERROR: 'alert', ERR: 'alert', WARN: 'warn', WARNING: 'warn', INFO: 'info', DEBUG: 'off' };

// ---------- First steps ----------

/** Markup of the first steps (buttons: each step runs its action on click, never by itself). */
export function stepsMarkup(info, { helpSeen = true } = {}) {
  if (!info) return '';
  const steps = info.steps.filter((s) => s.id !== 'rights' || !info.done || !s.done);
  const all = info.completed >= info.total;
  const items = steps.map((s, n) => {
    const state = s.done ? 'terminée' : s.current ? 'étape en cours' : s.enabled ? 'à faire' : 'pas encore disponible';
    return `<li class="step${s.done ? ' done' : ''}${s.current ? ' current' : ''}${s.id === 'rights' ? ' optional' : ''}" data-step="${esc(s.id)}" data-j="${n}"${s.current ? ' aria-current="step"' : ''}>`
      + `<button class="step-btn" type="button" data-step-act="${esc(s.id)}"${s.enabled ? '' : ' disabled'} data-tip="${esc(s.text)}">`
      + `<span class="mark" aria-hidden="true">${s.done ? glyph('check') : esc(String(s.number))}</span>`
      + `<span class="step-t"><span class="label">${esc(s.label)}</span><span class="step-a">${esc(s.done ? (s.id === 'rights' ? 'Faite' : 'Fait') : s.actionLabel)}</span></span>`
      + `<span class="visually-hidden">, ${esc(state)}. ${esc(s.text)}</span></button></li>`;
  }).join('');
  return `<div class="stepper${all ? ' complete' : ''}" role="group" aria-labelledby="stepper-title">
      <div class="stepper-head">${glyph('sparkles')}<span class="title" id="stepper-title">${all ? 'Premiers pas terminés' : 'Premiers pas'}</span><span class="count num">${formatNumber(info.completed)} / ${formatNumber(info.total)}</span>
        <span class="stepper-tools"><button class="btn ghost sm help-btn" type="button" data-act="help">${glyph('lifebuoy')}Aide${helpSeen ? '' : '<span class="new-dot" aria-hidden="true"></span><span class="visually-hidden"> (nouveau)</span>'}</button>
        <button class="btn ghost sm" type="button" data-act="steps-hide" data-tip="La carte se réaffiche depuis l’aide">${glyph('eyeOff')}Masquer</button></span></div>
      <div class="progress" role="progressbar" aria-label="Progression des premiers pas" aria-valuemin="0" aria-valuemax="${info.total}" aria-valuenow="${info.completed}" aria-valuetext="${esc(`${plural(info.completed, 'étape faite', 'étapes faites')} sur ${formatNumber(info.total)}`)}"><span></span></div>
      <ol class="steps">${items}</ol>
      ${all ? '' : `<p class="stepper-note">${glyph('clock')}<span>${esc(info.deferred)}</span></p>`}
      ${info.offline ? `<p class="stepper-note warn">${glyph('wifiOff')}<span>Hors connexion : reconnectez-vous pour poursuivre ; les données locales sont conservées.</span></p>` : ''}
    </div>`;
}

/** « 1. Trouver, 2. Consulter, 3. Préparer » (Domenia 1, ACC-018): three shortcuts, none of them reads anything by itself. */
export function journeyMarkup() {
  const step = (n, id, label, tip, ic) => `<button class="journey-btn" type="button" data-journey="${id}" data-tip="${esc(tip)}"><span class="journey-n" aria-hidden="true">${n}</span>${glyph(ic)}<span>${esc(label)}</span></button>`;
  return `<nav class="journey" aria-label="Parcours"><span class="journey-k">Parcours</span>`
    + `${step(1, 'find', 'Trouver', 'Ouvrir Rechercher sur l’OU de travail', 'search')}<span class="journey-sep" aria-hidden="true"></span>`
    + `${step(2, 'view', 'Consulter', 'Ouvrir la fiche de l’objet déjà chargé', 'object')}<span class="journey-sep" aria-hidden="true"></span>`
    + `${step(3, 'prepare', 'Préparer', 'Ouvrir l’atelier de requêtes pour comparer ou préparer un dossier', 'database')}</nav>`;
}

export function animateSteps(scope, info) {
  const bar = scope.querySelector('.stepper .progress > span');
  if (bar && info) progressTo(bar, info.total ? info.completed / info.total : 0);
}

// ---------- Help ----------

export function openHelp({ ctx, onSeen, onShowSteps, stepsHidden }) {
  const host = surface('acc-help', `
    <section class="hp-journey"><h3>Le parcours en trois temps</h3><ol>
      <li data-j="0"><span class="hp-n">1</span><div><b>Trouver</b><p>Rechercher un compte, un poste ou un groupe dans l’OU de travail, ou ouvrir les postes exacts d’un chiffre du tableau du parc.</p><button class="btn sm ghost" type="button" data-hp-go="rechercher">${glyph('search')}Rechercher</button></div></li>
      <li data-j="1"><span class="hp-n">2</span><div><b>Consulter</b><p>La fiche d’un objet rassemble ce que la base locale sait de lui ; les lectures réseau partent seulement sur votre clic.</p></div></li>
      <li data-j="2"><span class="hp-n">3</span><div><b>Préparer</b><p>Une écriture se prépare, se relit, se confirme, puis se vérifie : chaque étape laisse un reçu, rien n’est rejoué automatiquement.</p><button class="btn sm ghost" type="button" data-hp-go="ecritures">${glyph('edit')}Écritures</button></div></li>
    </ol></section>
    <section class="hp-grid">
      <article data-j="3"><h4>${glyph('ou')}OU de travail</h4><p>Défaut de toutes les sections : les postes sont mesurés dans cette OU, les comptes sur tout le domaine. Le domaine entier n’est jamais mesuré sans garde.</p></article>
      <article data-j="4"><h4>${glyph('database')}Base locale</h4><p>L’Accueil se calcule depuis la base locale, sans lecture réseau. « Contrôles du parc » la met à jour, après confirmation.</p></article>
      <article data-j="5"><h4>${glyph('monitor')}Chiffres exacts</h4><p>Chaque chiffre du tableau du parc ouvre la liste exacte de ses postes, tirée du calcul affiché.</p></article>
      <article data-j="6"><h4>${glyph('shield')}Santé du parc</h4><p>Part des postes évalués sans point critique ni à surveiller ; les postes non évalués sont comptés à part, jamais sains.</p></article>
      <article data-j="7"><h4>${glyph('lock')}Lecture seule</h4><p>Domenia démarre en lecture seule. Les préférences (OU, disposition, règles) restent sur ce poste, jamais dans l’annuaire.</p></article>
      <article data-j="8"><h4>${glyph('command')}Raccourcis</h4><p><kbd>Ctrl</kbd> <kbd>K</kbd> palette de commandes · <kbd>Alt</kbd> + flèches déplace un widget · <kbd>Échap</kbd> ferme un panneau.</p></article>
    </section>
    ${stepsHidden ? `<button class="btn sm" type="button" data-hp-steps>${glyph('eye')}Réafficher les premiers pas</button>` : ''}`);
  const drawer = openDrawer({
    title: 'Aide de l’Accueil', subtitle: 'Ce que montre l’écran, d’où viennent les chiffres et ce qui ne part jamais sans vous.',
    icon: 'lifebuoy', key: 'accueil.help', width: 640, minWidth: 380, body: host,
    actions: [{ id: 'close', label: 'Fermer', primary: true, run: (d) => d.close() }],
  });
  paint(host);
  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const go = t?.closest('[data-hp-go]');
    if (go) { drawer.close(); ctx.go(go.dataset.hpGo); return; }
    if (t?.closest('[data-hp-steps]')) { drawer.close(); onShowSteps(); }
  });
  ctx.call('accueil.help.seen').then((r) => onSeen?.(r?.helpSeen !== false)).catch((err) => reported(err));
  return drawer;
}

// ---------- « Vérifier l’application » ----------

export function openSelfCheck({ ctx, onDone }) {
  const host = surface('acc-check', loading());
  const drawer = openDrawer({
    title: 'Vérifier l’application', subtitle: 'Session, base locale, préférences, reçus et catalogues ; lecture locale seulement.',
    icon: 'shield', key: 'accueil.check', width: 640, minWidth: 380, body: host,
    actions: [
      { id: 'copy', label: 'Copier le résultat', icon: 'copy', run: () => { if (last) copyWithToast(ctx, text(last), 'Résultat de la vérification copié dans le presse-papiers.'); } },
      { id: 'again', label: 'Relancer', icon: 'refresh', run: () => run() },
      { id: 'close', label: 'Fermer', primary: true, run: (d) => d.close() },
    ],
  });
  let last = null;
  const text = (r) => [`Domenia — vérification du ${localStamp(r.checkedAt)}`, r.summary, ...r.checks.map((c) => `${c.label} : ${c.detail}`)].join('\n');
  async function run() {
    host.innerHTML = loading();
    drawer.setBusy(true);
    try {
      const r = await ctx.call('accueil.selfCheck');
      last = r;
      const total = r.checks.length || 1;
      host.innerHTML = `<div class="ck-head" data-tone="${r.failures ? 'alert' : r.warnings ? 'warn' : 'ok'}">
          <span class="ck-ico">${glyph(r.failures ? 'alert' : r.warnings ? 'info' : 'check')}</span>
          <div><h3>${esc(r.summary)}</h3><p>Vérifiée le ${esc(localStamp(r.checkedAt))}</p></div>
          <div class="ck-counts"><span class="ok"><b class="num" data-count="${r.ok}">0</b>conformes</span><span class="warn"><b class="num" data-count="${r.warnings}">0</b>à surveiller</span><span class="alert"><b class="num" data-count="${r.failures}">0</b>en échec</span></div></div>
        <div class="ck-bar" aria-hidden="true"><span class="ok" data-grow="${r.ok}"></span><span class="warn" data-grow="${r.warnings}"></span><span class="alert" data-grow="${r.failures}"></span><span class="info" data-grow="${Math.max(0, total - r.ok - r.warnings - r.failures)}"></span></div>
        <ul class="ck-list">${r.checks.map((c, n) => `<li data-tone="${esc(c.tone)}" data-j="${Math.min(n, 14)}"><span class="ck-dot">${glyph(c.tone === 'ok' ? 'check' : c.tone === 'alert' ? 'alert' : 'info')}</span><div><b>${esc(c.label)}</b><p>${esc(c.detail)}</p></div>${pill(c.tone === 'ok' ? 'ok' : c.tone === 'alert' ? 'alert' : c.tone === 'warn' ? 'warn' : 'info', c.tone === 'ok' ? 'Conforme' : c.tone === 'alert' ? 'Échec' : c.tone === 'warn' ? 'À surveiller' : 'Information', { size: 'sm' })}</li>`).join('')}</ul>`;
      paint(host);
      host.querySelectorAll('[data-count]').forEach((el, n) => countUp(el, Number(el.dataset.count), { delay: 60 + n * 60 }));
      onDone?.(r);
    } catch (err) {
      host.innerHTML = `<div class="acc-err" role="alert">${glyph('alert')}<span>${esc(reported(err))}</span></div>`;
    } finally {
      drawer.setBusy(false);
    }
  }
  run();
  return drawer;
}

// ---------- « Vider le cache » ----------

export async function clearCache({ ctx, onCleared }) {
  const ok = await confirmDialog({
    title: 'Vider le cache de l’Accueil ?', icon: 'trash', confirmLabel: 'Vider le cache',
    message: 'Les calculs gardés en mémoire (tableau du parc, listes de postes, historique recalculé) seront refaits à la prochaine lecture. Aucune mesure enregistrée n’est perdue et aucun objet Active Directory n’est modifié.',
  });
  if (!ok) return;
  try {
    const r = await ctx.call('accueil.cache.clear');
    ctx.toast(r.text, { tone: 'ok' });
    onCleared?.(r);
  } catch (err) {
    ctx.toast(reported(err), { tone: 'alert' });
  }
}

// ---------- « Ouvrir le journal » ----------

export function openJournal({ ctx }) {
  const host = surface('acc-journal', '<div class="jr-tabs"></div>');
  let tabs = null;
  let tail = null;
  const drawer = openDrawer({
    title: 'Journal', subtitle: 'Opérations de la session et journal technique de Domenia, sans aucun secret.',
    icon: 'file', key: 'accueil.journal', width: 760, minWidth: 420, body: host,
    actions: [
      { id: 'copy', label: 'Copier le journal technique', icon: 'copy', run: () => { if (tail?.lines?.length) copyWithToast(ctx, tail.lines.map((l) => `${l.at} [${l.level}] ${l.text}`).join('\r\n'), 'Journal technique copié dans le presse-papiers.'); } },
      { id: 'close', label: 'Fermer', primary: true, run: (d) => d.close() },
    ],
    onClose: () => tabs?.destroy?.(),
  });

  function operations(panel) {
    panel.innerHTML = loading();
    ctx.call('accueil.journal').then((r) => {
      panel.innerHTML = `<p class="jr-lead">${plural(r.total, 'opération', 'opérations')} dans le journal de la session et de la source.</p>`
        + timeline((r.rows ?? []).slice(0, 200).map((x) => ({ when: x.at, title: x.label, tone: x.tone, icon: x.tone === 'ok' ? 'check' : x.tone === 'alert' ? 'alert' : x.tone === 'warn' ? 'info' : 'dot' })), { label: 'Journal des opérations', empty: 'Aucune opération dans le journal.' });
      bindTimeline(panel);
    }).catch((err) => { panel.innerHTML = `<div class="acc-err">${glyph('alert')}<span>${esc(reported(err))}</span></div>`; });
  }

  function technical(panel) {
    panel.innerHTML = loading();
    ctx.call('accueil.log.tail').then((r) => {
      tail = r;
      panel.innerHTML = `<p class="jr-lead"><code>${esc(r.path)}</code> · ${esc(r.summary)}${r.truncated ? ' Début du fichier non affiché.' : ''}</p>`
        + (r.lines?.length ? `<ol class="jr-lines">${r.lines.map((l, n) => `<li data-j="${Math.min(n, 16)}"><time datetime="${esc(l.at)}">${esc(localStamp(l.at))}</time>${pill(LEVEL_TONE[String(l.level).toUpperCase()] ?? 'off', l.level, { size: 'sm', dot: false })}<pre>${esc(l.text)}</pre></li>`).join('')}</ol>`
          : `<div class="acc-empty">${glyph('file')}<p>${esc(r.available ? 'Journal technique vide.' : r.summary)}</p></div>`);
      paint(panel);
    }).catch((err) => { panel.innerHTML = `<div class="acc-err">${glyph('alert')}<span>${esc(reported(err))}</span></div>`; });
  }

  tabs = createTabs(host.querySelector('.jr-tabs'), {
    label: 'Journal', key: 'accueil.journal',
    tabs: [
      { id: 'ops', label: 'Opérations', icon: 'activity', render: operations },
      { id: 'tech', label: 'Journal technique', icon: 'file', render: technical },
    ],
  });
  return drawer;
}
