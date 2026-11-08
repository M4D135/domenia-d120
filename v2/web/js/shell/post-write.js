import { consultationIdentity } from './consultation-guard.js';
import { parentDn, sameDn } from '../pages/rechercher/text.js';

export function changedBranches(receipt) {
  if (receipt?.pending !== false || receipt.verification !== 'verified' || !['applied', 'noChange'].includes(receipt.result)) return [];
  const dns = [receipt.target?.dn];
  for (const change of receipt.plan?.changes ?? []) {
    if (change.kind === 'move' && ['cn', 'distinguishedName'].includes(change.attribute)) dns.push(change.beforeValue, change.afterValue);
  }
  const parents = [];
  for (const dn of dns.slice(0, 9)) {
    if (typeof dn !== 'string' || dn.length > 4096) continue;
    const parent = parentDn(dn);
    if (parent && !parents.some(value => sameDn(value, parent))) parents.push(parent);
  }
  return parents.slice(0, 4);
}

export function publishConfirmedWrite(receipt, origin, current) {
  const branches = changedBranches(receipt);
  if (!branches.length || origin !== consultationIdentity(current)) return false;
  window.dispatchEvent(new CustomEvent('domenia:write-verified', { detail: { identity: origin, branches } }));
  return true;
}
