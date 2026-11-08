// Status glyphs (web/js/shell/glyphs.js; TRV-008).
import { test, eq, ok } from '../harness.mjs';
import { statusGlyph, statusBadge, STATUS_GLYPHS } from '../../../web/js/shell/glyphs.js';

test('symbole et mot, alias sans casse ni accents, inconnu jamais vert', () => {
  eq(STATUS_GLYPHS.length, 14, 'quatorze états');
  eq(statusGlyph('Échec').key, 'error', 'alias français accentué');
  eq(statusGlyph('VERIFIED').word, 'Confirmé', 'alias anglais');
  const unknown = statusGlyph('bizarre');
  eq(unknown.key, 'unknown', 'inconnu');
  eq(unknown.recognized, false, 'signalé comme non reconnu');
  ok(statusBadge('ok').includes('✓'), 'badge avec son symbole');
});
