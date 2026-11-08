// Requests in the page and the scope they hold (web/js/shell/guards.js; TRV-058, TRV-059).
import { test, eq, ok } from '../harness.mjs';
import { typedState, beginRequest, requestBlocks, pendingRequests } from '../../../web/js/shell/guards.js';

test('saisie exacte du nom, casse comprise', () => {
  eq(typedState('EXEMPLE-0001', 'EXEMPLE-0001'), { matched: true, invalid: false }, 'nom exact');
  eq(typedState('exemple-0001', 'EXEMPLE-0001'), { matched: false, invalid: true }, 'autre casse');
  eq(typedState('EXEM', 'EXEMPLE-0001'), { matched: false, invalid: false }, 'début correct');
  eq(typedState('', ''), { matched: true, invalid: false }, 'sans nom exigé');
});

test('seules les écritures du périmètre attendent ; sans périmètre, toutes', () => {
  const a = beginRequest({ scope: 'CN=PC-01', label: 'x' });
  ok(requestBlocks('write', 'cn=pc-01'), 'même cible (casse ignorée) : écriture bloquée');
  ok(requestBlocks('edit', 'CN=PC-01'), 'modification bloquée');
  eq(requestBlocks('write', 'CN=PC-02'), false, 'autre cible libre');
  eq(requestBlocks('read', 'CN=PC-01'), false, 'lecture libre');
  eq(requestBlocks('navigate'), false, 'navigation libre');
  a.end();
  const b = beginRequest({});
  ok(requestBlocks('write', 'CN=PC-02'), 'demande sans périmètre : toutes les écritures attendent');
  b.end();
  eq(pendingRequests().length, 0, 'demandes terminées retirées');
});
