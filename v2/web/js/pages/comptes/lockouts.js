// Comptes screen: lockout diagnosis of one account (accounts.lockouts, Domenia 1 FIC-040, FIC-045). Read on an explicit
// gesture only (security log of the PDC emulator, SID of the account only); a refused or unavailable read never means
// « no lockout ». Renders the summary, the computers at the origin as bars, the events by day and the facts with their
// limits.
import { glyph, pill, setVars, timeline, bindTimeline } from '../../kit/index.js';
import { esc, formatNumber, formatDateTime, announce } from '../../ui.js';
import { COLON, NBSP, plural, errorSentence } from './shared.js';

export const WINDOWS = [
  { hours: 24, label: '24 h' },
  { hours: 72, label: '3 jours' },
  { hours: 168, label: '7 jours' },
  { hours: 720, label: '30 jours' },
];

/** Markup of the lockout card before any read: window choice and the explicit button. */
export function lockoutIntro(account, hours = 168) {
  const options = WINDOWS.map((w) => `<option value="${w.hours}"${w.hours === hours ? ' selected' : ''}>${esc(w.label)}</option>`).join('');
  return `<div class="cpt-lk-intro">
      <p>Lit dans le journal Sécurité de l’émulateur PDC les verrouillages (événement 4740) de ce seul compte, puis les rapproche des refus enregistrés par Domenia.</p>
      <div class="cpt-lk-row">
        <label class="cpt-lk-window"><span>Fenêtre</span><span class="k-select sm"><select data-lk-hours aria-label="Fenêtre de lecture">${options}</select></span></label>
        <button class="btn sm" type="button" data-lk-read${account ? '' : ' disabled'}>${glyph('wifi')}Lire les verrouillages</button>
        <span class="cpt-lk-net" data-tip="Lecture réseau : part seulement sur ce clic">${glyph('dot')}Lecture du journal sur demande</span>
      </div>
    </div>`;
}

/** Markup of a lockout report. */
export function lockoutReport(r) {
  const tone = r.state === 'read' ? (r.events.length ? 'warn' : 'ok') : r.state === 'refused' ? 'alert' : 'warn';
  const origins = r.origins.length
    ? `<ul class="cpt-lk-origins" aria-label="Postes à l’origine">${r.origins.map((o, n) => `<li data-j="${n}">
        <span class="cpt-lk-pc">${glyph('monitor')}<b class="mono">${esc(o.computer)}</b></span>
        <span class="cpt-lk-bar" aria-hidden="true"><i data-share="${Number(o.share) || 0}"></i></span>
        <span class="cpt-lk-n">${plural(o.count, 'fois', 'fois')}</span></li>`).join('')}</ul>`
    : '';
  const events = r.events.map((e) => ({
    when: e.at,
    title: `Verrouillé depuis ${e.callerComputer}`,
    text: `Journal de ${e.controller}`,
    tone: e.domenia.near ? 'warn' : 'alert',
    icon: 'lock',
    html: e.domenia.near ? pill('warn', e.domenia.label, { icon: 'alert', size: 'sm', tip: 'Piste à vérifier, jamais une preuve' }) : pill('off', e.domenia.label, { size: 'sm' }),
  }));
  const facts = r.facts.map((f) => `<li class="cpt-fact" data-tone="${esc(f.tone)}">
      <span class="cpt-fact-k">${esc(f.label)}</span><span class="cpt-fact-v">${esc(f.value)}</span>
      ${f.source ? `<span class="cpt-fact-src">${esc(f.source)}</span>` : ''}
      ${f.hypothesis ? `<span class="cpt-fact-hyp">${glyph('sparkles')}${esc(f.hypothesis)}</span>` : ''}
      ${f.limit ? `<span class="cpt-fact-lim">${glyph('info')}${esc(f.limit)}</span>` : ''}</li>`).join('');
  return `<div class="cpt-lk-report" data-tone="${tone}">
      <div class="cpt-lk-head">
        <span class="cpt-lk-ico">${glyph(r.state === 'read' && !r.events.length ? 'check' : 'lock')}</span>
        <div><b>${esc(r.summary)}</b><span>${esc(r.serverLabel)}</span></div>
        ${r.simulated ? pill('accent', 'Fictif', { icon: 'sparkles', size: 'sm', tip: 'Simulation : événements tirés de l’annuaire fictif' }) : ''}
      </div>
      ${origins}
      ${events.length ? `<div class="cpt-lk-events">${timeline(events, { label: 'Verrouillages du compte' })}</div>` : ''}
      <ul class="cpt-facts">${facts}</ul>
      <p class="cpt-lk-foot">${glyph('clock')}Fenêtre du ${esc(formatDateTime(r.from) ?? '—')} au ${esc(formatDateTime(r.to) ?? '—')} · ${formatNumber(r.maxEvents)}${NBSP}événements au plus${r.truncated ? ' · lecture tronquée' : ''}</p>
    </div>`;
}

/** Sets the widths of the origin bars (CSP: CSS variables only). */
export function paintReport(scope) {
  scope.querySelectorAll('.cpt-lk-bar i[data-share]').forEach((el) => setVars(el, { '--p': String(Math.max(0.04, Math.min(1, Number(el.dataset.share) / 100))) }));
  scope.querySelectorAll('.cpt-lk-origins [data-j]').forEach((el) => setVars(el, { '--j': el.dataset.j }));
  bindTimeline(scope);
}

/**
 * Wires the lockout card: the window, the button, the read and the report. Returns a function that forgets the card
 * (a late answer for another account is ignored).
 * @param {HTMLElement} host @param {{ call: Function }} ctx @param {{ dn: string, name: string }} account
 */
export function bindLockouts(host, ctx, account, { onRead } = {}) {
  let alive = true;
  let token = 0;
  const read = async () => {
    const select = host.querySelector('[data-lk-hours]');
    const hours = Number(select?.value) || 168;
    const my = ++token;
    const button = host.querySelector('[data-lk-read]');
    if (button) { button.disabled = true; button.classList.add('spinning'); }
    const out = host.querySelector('.cpt-lk-out');
    out.setAttribute('aria-busy', 'true');
    out.innerHTML = '<div class="cpt-lk-wait"><span class="k-spin" aria-hidden="true"></span>Lecture du journal Sécurité de l’émulateur PDC…</div>';
    announce('Lecture des verrouillages…');
    try {
      const report = await ctx.call('accounts.lockouts', { dn: account.dn, hours });
      if (!alive || my !== token) return;
      out.innerHTML = lockoutReport(report);
      paintReport(out);
      announce(report.summary);
      onRead?.(report);
    } catch (err) {
      console.error(err);
      if (!alive || my !== token) return;
      out.innerHTML = `<p class="cpt-inline-error">${glyph('alert')}${esc(errorSentence(err, 'Lecture des verrouillages impossible.'))}</p>`;
    } finally {
      if (alive && my === token) {
        out.removeAttribute('aria-busy');
        if (button) { button.disabled = false; button.classList.remove('spinning'); }
      }
    }
  };
  host.querySelector('[data-lk-read]')?.addEventListener('click', read);
  return { read, stop: () => { alive = false; } };
}

export const lockoutWord = (n) => `${formatNumber(n)}${NBSP}${n > 1 ? 'verrouillages' : 'verrouillage'}`;
export { COLON };
