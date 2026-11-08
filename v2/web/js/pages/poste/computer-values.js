// Additional D1 cards use stable keys of facts already calculated by poste.open. No bridge or collection here.
import { esc, ico, cardHead, int, facts } from './common.js';

const IDENTITY = new Set(['computer.os', 'computer.model', 'computer.cpu', 'computer.memory', 'computer.uptime', 'computer.user', 'computer.ip', 'computer.domain']);
const ACCOUNT = new Set(['computer.ad.password', 'computer.ad.lastlogon', 'computer.ad.account', 'computer.ad.ou', 'computer.ad.laps', 'computer.ad.managedby', 'computer.ad.clock']);
const PROTECTION = new Set(['computer.antivirus', 'computer.firewall', 'computer.bitlocker', 'computer.secureboot', 'computer.reboot', 'computer.hotfix']);
const COUNTS = new Set(['computer.drivers', 'computer.admins', 'computer.sessions', 'computer.autostart', 'computer.shares', 'computer.printers', 'computer.display', 'computer.physicaldisk']);

export function computerDetailCard(d, key, title) {
  const b = d.board;
  const card = (icon, content, detail = '', tone = 'off') => `<section class="card ps-card reveal" data-tone="${esc(tone ?? 'info')}">${cardHead(icon, title, esc(detail))}${content}</section>`;
  const unknown = (detail = 'Non lu pendant cet inventaire.') => card('info', '<p class="ps-faint">Non lu</p>', detail);
  const valueCard = (line, icon, missing) => line ? card(icon,
    `<p class="ps-layout-number">${esc(line.value)}</p>${line.copy ? `<button class="btn ghost sm" type="button" data-copy="${esc(line.value)}">${ico('copy')}Copier</button>` : ''}`,
    line.detail, line.state) : unknown(missing);
  if (IDENTITY.has(key)) return valueCard(b.identity?.lines.find((l) => l.key === key), 'chip');
  if (ACCOUNT.has(key)) return valueCard(b.adAccount?.lines.find((l) => l.key === key), 'object',
    key === 'computer.ad.managedby' ? 'Responsable non renseigné ou non visible dans la fiche du compte.' : 'Attribut ou référence non disponible dans la fiche du poste.');
  if (PROTECTION.has(key)) return valueCard(b.protection?.lines.find((l) => l.key === key), 'shield');
  if (key === 'computer.updates' || key === 'computer.wsus') {
    return valueCard(b.widgetValues?.find((l) => l.key === key), 'refresh', 'Configuration des mises à jour non lue ; aucune conformité déduite.');
  }
  if ((key === 'computer.display' || key === 'computer.physicaldisk') && b.widgetValues?.some((l) => l.key === key)) return valueCard(b.widgetValues.find((l) => l.key === key), 'monitor');
  if (COUNTS.has(key)) {
    const value = b.counts?.find((v) => v.key === key);
    if (!value || value.value == null) return unknown(value?.detail);
    // These cards report the existing inventory (monitors for Affichage), not an inferred graphics adapter.
    return card('layers', `<p class="ps-layout-number">${int(value.value)}</p>`, value.detail, value.state);
  }
  if (key === 'computer.certificates') {
    const section = b.sections?.find((s) => s.key === 'certificates');
    return section ? card('shield', `<p class="ps-layout-number">${esc(section.value)}</p>${facts(section.facts)}`, section.detail, section.state)
      : unknown('Magasin de certificats non lu ; disponible après un inventaire complet.');
  }
  if (key === 'computer.attention') {
    const h = b.health;
    if (!h) return unknown();
    return card('alert', h.points.length ? `<ol class="ps-points">${h.points.map((p) => `<li class="ps-point" data-level="${esc(p.level)}"><span class="ps-point-mark">${ico(p.level === 'alert' ? 'alert' : 'info')}</span><span class="ps-point-text">${esc(p.text)}</span>
      ${p.route ? `<button class="btn ghost sm" type="button" data-route="${esc(p.route.view)}/${esc(p.route.tab ?? '')}">${esc(p.route.label)}${ico('chevronRight')}</button>` : ''}</li>`).join('')}</ol>`
      : `<p>${esc(h.badge ? 'Aucun problème établi sur ce qui a été lu ; état incomplet.' : 'Aucun point à vérifier.')}</p>`, h.detail, h.state);
  }
  return null;
}
