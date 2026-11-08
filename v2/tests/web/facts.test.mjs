import { test, assert } from './test-api.mjs';
import { explainFact } from '../../web/js/facts.js';
import { factsMarkup } from '../../web/js/pages/audit/shared.js';
import { fact } from '../../web/js/pages/poste/common.js';
import { factRows, supportGroups, supportText } from '../../web/js/pages/fiche/common.js';

const evidence = { label: 'Compte · Console', value: 'Non lu', state: 'unknown',
  source: 'CIM', limit: 'Limite non enregistrée pour cette affirmation.', hypothesis: 'À vérifier', at: null, reader: 'TEST\\lecteur' };

test('shared evidence supplies source, limit and reader without replacing page identity or state', () => {
  const legacy = { label: 'Console', value: 'Non lu', state: 'unknown', group: 'Compte', tone: 'off', id: 'console' };
  assert.equal(explainFact(legacy), legacy);
  const enriched = explainFact({ ...legacy, evidence });
  assert.equal(enriched.limit, evidence.limit);
  assert.equal(enriched.source, 'CIM');
  assert.equal(enriched.reader, evidence.reader);
  assert.equal(enriched.label, 'Console');
  assert.equal(enriched.state, 'unknown');
  assert.equal(enriched.id, 'console');
  assert.equal(enriched.hint, 'À vérifier');
});

test('real fact renderers show the shared limit and escape its text', () => {
  const f = { label: 'Console', value: 'Non lu', state: 'unknown', stateLabel: 'Inconnu', tone: 'off', group: 'Compte', evidence: { ...evidence, limit: '<script>limite</script>' } };
  for (const markup of [factsMarkup([f]), fact(f), factRows([f]), supportGroups([f])]) {
    assert.ok(markup.includes('&lt;script&gt;limite&lt;/script&gt;'));
    assert.ok(!markup.includes('<script>'));
    assert.ok(markup.includes('CIM'));
  }
});

test('the actual Fiche support summary and its copy carry the same shared evidence', () => {
  const f = { group: 'Compte', label: 'Console', value: 'Non lu', state: 'unknown', source: null, limit: null, dateText: '01/11/2026', evidence };
  const markup = supportGroups([f]);
  const copy = supportText([f], 'Compte de test');
  for (const result of [markup, copy]) {
    assert.ok(result.includes(evidence.limit), 'la limite commune reste visible dans le résumé et sa copie');
    assert.ok(result.includes(evidence.reader), 'le compte lecteur est conservé');
    assert.ok(result.includes('CIM'));
    assert.ok(result.includes('01/11/2026'), 'la date formatée reste celle du fait de fiche');
  }
});
