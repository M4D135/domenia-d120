// Paramètres › À propos (PAR-001, PAR-002): identity of Domenia and of its engines, compatibility of this workstation with
// the matrix shipped with the application (never downloaded; « Inconnu » rather than a guess), inventory of the delivered
// components (a version only when it is bound to the file and its SHA-256), local folders, commitments.
import {
  esc, glyph, icon, card, facts, notes, sectionHead, button, paint, skeleton, errorBlock, pill, tone, nobreak, reported,
} from './common.js';
import { reveal, copyText } from '../../ui.js';

const HEAD = { title: 'À propos', lead: 'Version, moteurs, compatibilité de ce poste et composants livrés : chaque affirmation repose sur ce qui est lu ici, jamais sur une supposition.', icon: 'info', tone: 'info' };

function identityCard(v, app) {
  const id = v.identity;
  const chromium = /Chrome\/([\d.]+)/.exec(navigator.userAgent)?.[1];
  return `<section class="card pr-card pr-about reveal spot" data-card="identity">
    <span class="pr-about-glow" aria-hidden="true"></span>
    <div class="pr-about-brand"><span class="pr-about-logo" aria-hidden="true">${icon('logo')}</span>
      <div><h3 class="gradient-text">Domenia 2</h3><span>Administration Active Directory · pack autonome</span></div>
      ${pill(id.mode === 'simulation' ? 'accent' : 'ok', id.modeLabel, { icon: id.mode === 'simulation' ? 'sparkles' : 'server' })}</div>
    ${facts([
      ['Version', id.version, id.informationalVersion && id.informationalVersion !== id.version ? `Exécutable ${id.informationalVersion}` : ''],
      ['.NET embarqué', id.runtime, `${id.runtimeIdentifier} · ${id.process64 ? 'processus 64 bits' : 'processus 32 bits'}`],
      ['Moteur web', id.webViewModeLabel, [id.webViewVersion ? `WebView2 ${id.webViewVersion}` : '', chromium ? `Chromium ${chromium}` : ''].filter(Boolean).join(' · ')],
      ['Système', id.operatingSystem],
      ['Démarrage', nobreak(id.modeDetail), nobreak(app?.banner ?? '')],
    ])}
    <div class="pr-actions">${button('copy-about', 'Copier ces informations', 'copy', { kind: 'ghost' })}</div>
  </section>`;
}

function compatibilityCard(c) {
  const rows = c.rows.map((r, n) => `<li data-j="${n}" data-tone="${esc(tone(r.tone))}"><span class="pr-compat-ico">${glyph(r.status === 'unsupported' ? 'x' : r.status === 'unknown' ? 'alert' : 'check')}</span>
      <div><b>${esc(r.label)}</b><span>${esc(r.observed)}</span>${r.note ? `<span class="pr-sub">${esc(r.note)}</span>` : ''}</div>${pill(tone(r.tone), r.statusLabel, { size: 'sm' })}</li>`).join('');
  return card({
    id: 'compatibility', title: 'Compatibilité de ce poste', sub: `Matrice relue le ${c.reviewedOn.split('-').reverse().join('/')} · livrée, jamais téléchargée`, iconName: 'shield', cls: 'pr-wide',
    body: `<div class="pr-verdict" data-tone="${esc(tone(c.tone))}" data-setting="compatibility"><span class="pr-verdict-ico">${glyph(c.overall === 'unsupported' ? 'x' : 'shield')}</span><b>Environnement ${esc(c.overallLabel)}</b><span>${esc(c.text)}</span></div>
      <ul class="pr-compat">${rows}</ul>
      <details class="pr-more"><summary>Environnements documentés, non relevés sur ce poste</summary><ul class="pr-lines">${c.documented.map((d) => `<li>${pill(d.status === 'unsupported' ? 'alert' : 'info', d.status === 'unsupported' ? 'non pris en charge' : 'prévu, jamais testé', { size: 'sm' })} ${esc(d.label)} · ${esc(d.note)}</li>`).join('')}</ul></details>
      <p class="pr-hint">${glyph('info')}<span>« Qualifié » exige un rapport de qualification lié au ZIP livré ; « Testé » exige une campagne de tests exécutée. Aucun des deux n’est encore revendiqué.</span></p>`,
  });
}

function componentsCard(k) {
  const rows = k.rows.map((r, n) => `<tr data-j="${n}"><th scope="row"><b>${esc(r.name)}</b><span class="pr-sub mono">${esc(r.path)}</span></th>
      <td>${r.bound ? `<span class="pr-value">${esc(r.version)}</span>` : '<span class="pr-sub">non reliée au fichier</span>'}</td>
      <td class="num">${esc(r.bytesText)}</td>
      <td>${r.sha256Short ? `<button type="button" class="pr-sha-btn mono" data-copy="${esc(r.sha256)}" data-tip="Copier l’empreinte SHA-256 complète" aria-label="Copier l’empreinte SHA-256 de ${esc(r.name)}">${esc(r.sha256Short)}</button>` : '—'}</td>
      <td>${esc(r.licence)}<span class="pr-sub">${esc(r.provenance)}</span></td></tr>`).join('');
  return card({
    id: 'components', title: 'Composants livrés', sub: `${k.summary} Total ${k.totalText}.`, iconName: 'layers', cls: 'pr-wide',
    body: `<div class="pr-table-wrap" data-setting="components"><table class="pr-table"><thead><tr><th>Composant</th><th>Version</th><th class="num">Taille</th><th>SHA-256</th><th>Licence et provenance</th></tr></thead><tbody>${rows}</tbody></table></div>`,
  });
}

function locationsCard(v) {
  return card({
    id: 'locations', title: 'Emplacements', sub: 'Dossiers et fichiers de Domenia sur ce poste', iconName: 'folder',
    body: `<ul class="pr-places">${v.locations.map((l, n) => `<li data-j="${n}"><span class="pr-place-ico">${glyph(l.id === 'logs' ? 'file' : l.id === 'profile' ? 'monitor' : l.id === 'receipts' ? 'shield' : l.id === 'preferences' ? 'sliders' : 'folder')}</span>
        <div><b>${esc(l.label)}</b>${l.path ? `<span class="mono pr-path" data-tip="${esc(l.display)}">${esc(l.display)}</span>` : '<span class="pr-sub">aucun fichier sur le disque pour cette session</span>'}</div>
        ${l.canOpen ? button(`open:${l.id}`, 'Ouvrir', 'external', { kind: 'ghost' }) : !l.path ? pill('info', 'En mémoire', { size: 'sm' }) : pill(l.exists ? 'ok' : 'off', l.exists ? 'Présent' : 'Absent', { size: 'sm' })}</li>`).join('')}</ul>`,
  });
}

function markup(v, app) {
  return `${sectionHead(HEAD)}<div class="pr-grid">${identityCard(v, app)}${locationsCard(v)}${compatibilityCard(v.compatibility)}${componentsCard(v.components)}
    <div class="pr-footnote reveal">${notes(v.commitments)}</div></div>`;
}

export function mount(host, sctx) {
  let view = null;
  let alive = true;
  host.innerHTML = `${sectionHead(HEAD)}${skeleton(3)}`;

  async function load() {
    try {
      view = await sctx.call('settings.about');
      if (!alive) return;
      host.innerHTML = markup(view, sctx.app());
      paint(host);
      reveal(host);
    } catch (err) {
      if (!alive) return;
      host.innerHTML = `${sectionHead(HEAD)}${errorBlock(err)}`;
    }
  }

  const onClick = async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const sha = t?.closest('[data-copy]');
    if (sha) {
      const ok = await copyText(sha.dataset.copy);
      sctx.toast(ok ? 'Empreinte SHA-256 copiée.' : 'Copie impossible : presse-papiers indisponible.', { tone: ok ? 'ok' : 'warn', life: 2200 });
      return;
    }
    const act = t?.closest('[data-act]')?.dataset.act;
    if (!act) return;
    if (act === 'retry') load();
    else if (act === 'copy-about' && view) {
      const id = view.identity;
      const lines = [
        `Domenia ${id.version} (${id.modeLabel})`, `.NET ${id.runtime} · ${id.runtimeIdentifier}`, `${id.webViewModeLabel}${id.webViewVersion ? ` · WebView2 ${id.webViewVersion}` : ''}`,
        id.operatingSystem, view.compatibility.text, ...view.components.rows.map((r) => r.display),
      ];
      const ok = await copyText(lines.join('\n'));
      sctx.toast(ok ? 'Informations copiées (sans nom de compte ni chemin).' : 'Copie impossible : presse-papiers indisponible.', { tone: ok ? 'ok' : 'warn' });
    } else if (act.startsWith('open:')) {
      try { await sctx.call('settings.folder.open', { folder: act.slice(5) }); } catch (err) { sctx.toast(reported(err, 'Ouverture impossible.'), { tone: 'info' }); }
    }
  };
  host.addEventListener('click', onClick);
  load();
  return { destroy() { alive = false; host.removeEventListener('click', onClick); } };
}


