// Tab « Diagnostic » (Domenia 1 OPE-003, OPE-004, OPE-007, OPE-008): why an action is unavailable (facts of the session, with a
// route per line), the read-only check of the application (engine, security, local storage, directory, tools, and the page
// itself), the redacted support diagnostic shown before anything is saved, and the diagnostic dossier (ZIP) with its optional
// pseudonyms. Nothing is ever sent: documents go to the documents folder of the application, after a confirmation.
import { esc, errorText, toast, announce } from '../../ui.js';
import { confirmDialog, pill, glyph, writeClipboard, NBSP } from '../../kit/index.js';
import { cardHead, errorBox, skeletonLines, toneMark, count, duration, int, maskSecrets, paintVars } from './common.js';

const STATUS = {
  ok: ['ok', 'OK', 'check'], warn: ['warn', 'À savoir', 'eye'], error: ['alert', 'Erreur', 'alert'], info: ['info', 'Sans objet', 'info'],
};

/** Version of the WebView2 engine read from the page itself (« Edg/154.0.4258.62 »), never sent anywhere but the diagnostic. */
export function webViewVersion() {
  const m = /Edg\/(\d+(?:\.\d+){1,3})/.exec(navigator.userAgent) ?? /Chrome\/(\d+(?:\.\d+){1,3})/.exec(navigator.userAgent);
  return m ? m[1] : null;
}

/** Checks of the page itself (structure, content security policy, motion): local, nothing is read elsewhere. */
function clientChecks() {
  const rows = [];
  const t0 = performance.now();
  const csp = document.querySelector('meta[http-equiv="Content-Security-Policy"]')?.getAttribute('content') ?? '';
  const strict = /connect-src 'none'/.test(csp) && /script-src 'self'/.test(csp) && /style-src 'self'/.test(csp) && !/unsafe-inline/.test(csp);
  rows.push({ category: 'Interface', test: 'Politique de sécurité du contenu', status: strict ? 'ok' : 'error', durationMs: 0,
    detail: strict ? `Stricte${NBSP}: scripts et styles de la page seulement, aucune connexion sortante, aucun style en ligne.` : 'Politique de sécurité du contenu absente ou affaiblie.' });
  const parts = ['.nav', '.topbar', '#main', '.toasts'];
  const found = parts.filter((s) => document.querySelector(s)).length;
  rows.push({ category: 'Interface', test: 'Structure de l’application', status: found === parts.length ? 'ok' : 'error', durationMs: 0,
    detail: `${found}/${parts.length} éléments présents (navigation, barre supérieure, contenu, notifications).` });
  const motion = document.documentElement.dataset.motion ?? 'full';
  rows.push({ category: 'Interface', test: 'Animations', status: 'ok', durationMs: 0,
    detail: motion === 'reduced' ? 'Animations réduites (réglage de l’opérateur).' : motion === 'system' ? 'Animations : réglage de Windows suivi.' : `Animations riches${NBSP}: transform, opacity et filter seulement.` });
  const version = webViewVersion();
  rows.push({ category: 'Interface', test: 'Moteur web', status: version ? 'ok' : 'info', durationMs: Math.round((performance.now() - t0) * 10) / 10,
    detail: version ? `WebView2 ${version}.` : 'Version du moteur web non lue.' });
  return rows;
}

/**
 * @param {HTMLElement} host
 * @param {{ ctx: any, demo: boolean, pulse: any }} env
 */
export function createDiagnostics(host, env) {
  const { ctx } = env;
  let alive = true;
  let report = null;
  let preview = null;

  host.innerHTML = `<div class="grid op-diag">
    <section class="card span-7 op-why-card spot" data-card="why" aria-busy="true">${skeletonLines(5)}</section>
    <section class="card span-5 op-check-card spot" data-card="check">
      ${cardHead('shield', 'Vérifier l’application', 'Lecture seule · aucune écriture effectuée')}
      <p class="op-card-lead">Contrôle le moteur, la politique d’écriture, le stockage local, l’annuaire de la session, les outils Windows et la page elle-même.</p>
      <ul class="op-check-scope" aria-label="Ce qui est vérifié">${[['chip', 'Moteur'], ['shield', 'Politique d’écriture'], ['database', 'Stockage local'], ['edit', 'Exécuteurs'], ['domain', 'Annuaire'], ['tools', 'Outils Windows'], ['layers', 'WAPT'], ['monitor', 'Interface']].map(([i, t], n) => `<li data-i="${n}">${glyph(i)}${t}</li>`).join('')}</ul>
      <div class="op-check-actions op-card-actions">
        <button class="btn subtle sm" type="button" data-check="quick">${glyph('zap')}Vérification rapide</button>
        <button class="btn subtle sm" type="button" data-check="full">${glyph('gauge')}Vérification complète</button>
      </div>
      <div class="op-check-result" aria-live="polite"><p class="op-check-idle">${glyph('info')}Aucune vérification dans cette session. La complète mesure aussi des recherches répétées.</p></div>
    </section>
    <section class="card span-6 op-redacted-card spot" data-card="redacted">
      ${cardHead('file', 'Diagnostic expurgé', 'Pour le support · construit sur liste blanche')}
      <p class="op-card-lead">Versions, compteurs, mesures, codes d’erreur et traces par référence courte. Vous voyez ce qu’il contient avant tout enregistrement${NBSP}; rien n’est envoyé.</p>
      <div class="op-redacted-body"><div class="op-redacted-columns">
        <section class="op-redacted-col" data-kind="has"><h4>${glyph('check')}Contient</h4><ul><li>Versions de Domenia, .NET, Windows et WebView2</li><li>Compteurs de la session</li><li>Mesures par opération du pont</li><li>Codes d’erreur et leur nombre</li><li>Traces par référence courte</li><li>Lenteurs expliquées</li></ul></section>
        <section class="op-redacted-col" data-kind="never"><h4>${glyph('lock')}Ne contient jamais</h4><ul><li>Mots de passe, clés, jetons</li><li>Messages d’erreur</li><li>Noms de comptes, de postes, de groupes</li><li>Chemins AD, adresses, chemins de fichiers</li><li>Contenu des journaux</li></ul></section>
      </div></div>
      <div class="op-card-actions"><button class="btn subtle sm" type="button" data-diag="preview">${glyph('eye')}Préparer l’aperçu</button>
        <button class="btn subtle sm" type="button" data-diag="save" disabled>${glyph('download')}Enregistrer…</button></div>
    </section>
    <section class="card span-6 op-dossier-card spot" data-card="dossier">
      ${cardHead('folder', 'Dossier de diagnostic (ZIP)', 'État du moteur, configuration expurgée, dernière vérification')}
      <ul class="op-dossier-files">
        <li>${glyph('file')}<span><b>runtime.json</b> versions, mode, identités, domaine, contrôleur, tâches, stockage</span></li>
        <li>${glyph('file')}<span><b>configuration-expurgee.json</b> décision du mode, clés sensibles masquées</span></li>
        <li>${glyph('file')}<span><b>verification.csv</b> dernière vérification de l’application</span></li>
        <li>${glyph('file')}<span><b>LISEZMOI.txt</b> ce que contient le dossier, et ce qu’il ne contient jamais</span></li>
      </ul>
      <label class="op-switch big"><input class="switch" type="checkbox" data-anon><span><b>Remplacer les noms par des pseudonymes</b><small>Compte, domaine, contrôleur et poste deviennent compte-1, domaine-1…</small></span></label>
      <p class="op-dossier-warn" data-anon-note>${glyph('alert')}<span>Sans pseudonymes, les identités, noms de postes, domaines et chemins figurent en clair${NBSP}: relisez avant tout partage. Journaux bruts toujours exclus.</span></p>
      <div class="op-card-actions"><button class="btn subtle sm" type="button" data-diag="dossier">${glyph('download')}Enregistrer le dossier…</button></div>
    </section>
  </div>`;

  host.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('button') : null;
    if (!b || b.disabled) return;
    if (b.dataset.check) runCheck(b.dataset.check === 'full', b);
    else if (b.dataset.diag === 'preview') previewDiagnostic(b);
    else if (b.dataset.diag === 'save') saveDiagnostic(b);
    else if (b.dataset.diag === 'dossier') saveDossier(b);
    else if (b.dataset.route) ctx.navigate(...route(b.dataset.route));
    else if (b.dataset.copyReport !== undefined) copyReport();
    else if (b.dataset.exportReport !== undefined) exportReport();
  });
  host.querySelector('[data-anon]').addEventListener('change', (e) => {
    host.querySelector('[data-anon-note]').hidden = e.target.checked;
  });

  function route(text) {
    const [id, query] = text.split('?');
    return [id, Object.fromEntries(new URLSearchParams(query ?? ''))];
  }

  function loadWhy() {
    const card = host.querySelector('[data-card="why"]');
    card.setAttribute('aria-busy', 'true');
    return ctx.call('operations.blockers').then((r) => {
      if (!alive) return;
      card.removeAttribute('aria-busy');
      card.innerHTML = `${cardHead('info', 'Pourquoi une action est indisponible ?', 'États de la session · rien n’est testé ni modifié', `<button class="btn ghost xs" type="button" data-diag-refresh>${glyph('refresh')}Relire</button>`)}
        <ul class="op-why">${r.lines.map((l, n) => `<li data-tone="${esc(l.tone)}" data-i="${n}">${toneMark(l.tone)}<span>${esc(l.text)}</span>${l.route ? `<button class="btn ghost xs" type="button" data-route="${esc(l.route)}">${esc(l.routeLabel)}${glyph('chevronRight')}</button>` : ''}</li>`).join('')}</ul>
        <h4 class="op-why-h">Transports</h4>
        <ul class="op-transports">${r.transports.map((t) => `<li>${glyph('link')}<span>${esc(t)}</span></li>`).join('')}</ul>
        <p class="op-note">${esc(r.note)}</p>`;
      card.querySelector('[data-diag-refresh]')?.addEventListener('click', loadWhy);
    }).catch((err) => {
      console.error(err);
      if (!alive) return;
      card.removeAttribute('aria-busy');
      card.innerHTML = errorBox(errorText(err, 'Bilan illisible.'));
    });
  }

  async function runCheck(full, button) {
    const box = host.querySelector('.op-check-result');
    host.querySelectorAll('[data-check]').forEach((b) => { b.disabled = true; });
    button.setAttribute('aria-busy', 'true');
    box.setAttribute('aria-busy', 'true');
    box.innerHTML = `<div class="op-check-run"><span class="k-spin" aria-hidden="true"></span><span>${full ? 'Vérification complète' : 'Vérification rapide'} en lecture seule…</span></div>`;
    try {
      const server = await ctx.call('operations.check.run', { full });
      if (!alive) return;
      const client = clientChecks();
      const rows = [...server.rows, ...client];
      const ok = rows.filter((r) => r.status === 'ok').length;
      const errors = rows.filter((r) => r.status === 'error').length;
      const warns = rows.filter((r) => r.status === 'warn').length;
      const infos = rows.filter((r) => r.status === 'info').length;
      const total = rows.reduce((s, r) => s + (r.durationMs || 0), 0);
      report = { ...server, rows, ok, errors, warnings: warns, totalMs: total,
        summary: `${int(ok)} OK · ${count(errors, 'erreur', 'erreurs')} · ${count(warns, 'point à savoir', 'points à savoir')}${infos ? ` · ${int(infos)} pour information` : ''} · ${duration(total)}. Aucune écriture effectuée.` };
      box.innerHTML = reportMarkup(report);
      paintVars(box);
      announce(report.summary);
      toast(`Vérification ${full ? 'complète' : 'rapide'}${NBSP}: ${report.summary}`, { tone: errors ? 'warn' : 'ok', life: 6000 });
    } catch (err) {
      console.error(err);
      if (!alive) return;
      box.innerHTML = errorBox(errorText(err, 'Vérification impossible.'));
    } finally {
      box.removeAttribute('aria-busy');
      button.removeAttribute('aria-busy');
      host.querySelectorAll('[data-check]').forEach((b) => { b.disabled = false; });
    }
  }

  function reportText() {
    if (!report) return '';
    return [`Domenia · vérification ${report.full ? 'complète' : 'rapide'} · ${report.summary}`,
      ...report.rows.map((r) => `${r.category}\t${r.test}\t${STATUS[r.status]?.[1] ?? r.status}\t${Math.round(r.durationMs)} ms\t${r.detail}`)].join('\r\n');
  }

  function copyReport() {
    writeClipboard(maskSecrets(reportText())).then((ok) => toast(ok ? `Rapport de vérification copié. Noms et chemins y figurent${NBSP}: relisez avant tout envoi.` : `Copie impossible${NBSP}: le presse-papiers est indisponible.`, { tone: ok ? 'ok' : 'warn' }));
  }

  function exportReport() {
    if (!report) return;
    const cell = (v) => { let t = String(v ?? ''); if (/^[=+\-@]/.test(t)) t = `'${t}`; return /[;"\r\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t; };
    const csv = ['Catégorie;Test;État;Durée (ms);Détail', ...report.rows.map((r) => [r.category, r.test, STATUS[r.status]?.[1] ?? r.status, Math.round(r.durationMs), r.detail].map(cell).join(';'))].join('\r\n') + '\r\n';
    ctx.call('operations.export.save', { subject: 'verification', csv }).then((r) => toast(r.saved ? `Rapport enregistré${NBSP}: ${r.name}` : r.message, { tone: r.saved ? 'ok' : 'info', life: 6000 }))
      .catch((err) => toast(`Export impossible${NBSP}: ${errorText(err)}`, { tone: 'alert' }));
  }

  function figures() {
    const pulse = env.pulse?.state();
    const theme = document.documentElement.dataset.theme;
    return {
      webView: webViewVersion(),
      theme: ['dark', 'light', 'contrast'].includes(theme) ? theme : null,
      interfaceP50Ms: pulse?.p50 ?? null,
      interfaceP95Ms: pulse?.p95 ?? null,
      interfaceSamples: pulse?.count ?? null,
    };
  }

  async function previewDiagnostic(button) {
    const body = host.querySelector('.op-redacted-body');
    button.setAttribute('aria-busy', 'true');
    body.setAttribute('aria-busy', 'true');
    body.innerHTML = skeletonLines(4);
    try {
      preview = await ctx.call('operations.diagnostic.preview', figures());
      if (!alive) return;
      body.innerHTML = `<ul class="op-preview">${preview.preview.map((line, n) => `<li data-never="${line.startsWith('Jamais') ? 'true' : 'false'}" data-i="${n}">${glyph(line.startsWith('Jamais') ? 'lock' : 'check')}<span>${esc(line)}</span></li>`).join('')}</ul>
        <p class="op-preview-meta">${esc(preview.format)} · ${int(preview.bytes)} octets · empreinte <span class="mono">${esc(preview.sha256.slice(0, 12))}</span></p>
        <div class="op-tech"><button class="op-more" type="button" aria-expanded="false" aria-controls="op-diag-json">${glyph('chevronRight')}Contenu exact (JSON)</button>
          <pre class="op-pre mono" id="op-diag-json" hidden>${esc(preview.json)}</pre></div>`;
      body.querySelector('.op-more').addEventListener('click', (e) => {
        const b = e.currentTarget;
        const open = b.getAttribute('aria-expanded') !== 'true';
        b.setAttribute('aria-expanded', String(open));
        body.querySelector('#op-diag-json').hidden = !open;
      });
      host.querySelector('[data-diag="save"]').disabled = false;
    } catch (err) {
      console.error(err);
      body.innerHTML = errorBox(errorText(err, 'Diagnostic impossible.'));
    } finally {
      body.removeAttribute('aria-busy');
      button.removeAttribute('aria-busy');
    }
  }

  async function saveDiagnostic(button) {
    if (!preview) return;
    const ok = await confirmDialog({
      title: 'Enregistrer le diagnostic expurgé ?',
      message: `Un fichier JSON daté est écrit dans le dossier des documents de Domenia, sans jamais remplacer un fichier existant. Rien n’est envoyé. Il ne contient ni nom, ni message, ni chemin, ni secret.`,
      confirmLabel: 'Enregistrer', icon: 'download',
    });
    if (!ok || !alive) return;
    button.setAttribute('aria-busy', 'true');
    try {
      const result = await ctx.call('operations.diagnostic.save', figures());
      toast(result.saved ? `Diagnostic enregistré${NBSP}: ${result.path}` : result.message, { tone: result.saved ? 'ok' : 'info', life: 8000 });
    } catch (err) {
      console.error(err);
      toast(`Diagnostic non enregistré${NBSP}: ${errorText(err)}`, { tone: 'alert', life: 7000 });
    } finally {
      button.removeAttribute('aria-busy');
    }
  }

  async function saveDossier(button) {
    const anonymize = host.querySelector('[data-anon]').checked;
    const ok = await confirmDialog({
      title: 'Enregistrer le dossier de diagnostic ?',
      message: anonymize
        ? 'Une archive ZIP datée est écrite dans le dossier des documents, noms remplacés par des pseudonymes. Rien n’est envoyé ni remplacé.'
        : `Une archive ZIP datée est écrite dans le dossier des documents. Les identités, noms de postes, domaines et chemins y figurent en clair${NBSP}: relisez-la avant tout partage. Rien n’est envoyé ni remplacé.`,
      confirmLabel: 'Enregistrer le dossier', icon: 'folder',
    });
    if (!ok || !alive) return;
    button.setAttribute('aria-busy', 'true');
    try {
      const result = await ctx.call('operations.dossier.save', { anonymize, webView: webViewVersion() });
      toast(result.saved ? `Dossier enregistré${NBSP}: ${result.path}` : result.message, { tone: result.saved ? 'ok' : 'info', life: 8000 });
    } catch (err) {
      console.error(err);
      toast(`Dossier non enregistré${NBSP}: ${errorText(err)}`, { tone: 'alert', life: 7000 });
    } finally {
      button.removeAttribute('aria-busy');
    }
  }

  loadWhy();
  paintVars(host);
  return {
    refresh: loadWhy,
    /** Open states of the captures: a quick check (a read of the fictitious directory in simulation) or the preview (local). */
    runQuick: () => runCheck(false, host.querySelector('[data-check="quick"]')),
    preview: () => previewDiagnostic(host.querySelector('[data-diag="preview"]')),
    destroy() { alive = false; },
  };
}

function reportMarkup(report) {
  const groups = new Map();
  report.rows.forEach((r) => { if (!groups.has(r.category)) groups.set(r.category, []); groups.get(r.category).push(r); });
  const bar = (n, cls) => (n ? `<i class="${cls}" data-grow="${n}"></i>` : '');
  return `<div class="op-check-summary">
      <div class="op-check-meter" aria-hidden="true">${bar(report.ok, 'ok')}${bar(report.warnings, 'warn')}${bar(report.errors, 'alert')}${bar(report.rows.length - report.ok - report.warnings - report.errors, 'info')}</div>
      <p><b>${esc(report.summary)}</b></p></div>
    <div class="op-check-groups">${[...groups.entries()].map(([cat, rows]) => `<section class="op-check-group"><h4>${esc(cat)}</h4><ul>${rows.map((r) => {
      const [tone, label, iconName] = STATUS[r.status] ?? STATUS.info;
      return `<li data-tone="${tone}">${pill(tone, label, { icon: iconName, size: 'sm' })}<div><b>${esc(r.test)}</b><p>${esc(r.detail)}</p></div><time>${esc(duration(r.durationMs))}</time></li>`;
    }).join('')}</ul></section>`).join('')}</div>
    <div class="op-card-actions"><button class="btn ghost sm" type="button" data-copy-report>${glyph('copy')}Copier le rapport</button>
      <button class="btn ghost sm" type="button" data-export-report>${glyph('csv')}Exporter en CSV</button></div>`;
}
