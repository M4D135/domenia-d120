import { test, assert } from './test-api.mjs';
import { createReconciliationReads } from '../../web/js/pages/rechercher/reconciliation-reads.js';

test('delta requires an acknowledged complete application for the same list', () => {
  const reads = createReconciliationReads();
  const first = reads.begin('A', true);
  assert.equal(first.incremental, false);
  assert.equal(reads.accept(first), true);
  const delta = reads.begin('A', true);
  assert.equal(delta.incremental, true);
  // Lost network reply, cancellation or UI publication refused: no acknowledgement.
  const recovery = reads.begin('A', true);
  assert.equal(recovery.incremental, false);
  assert.equal(reads.accept(delta), false);
  assert.equal(reads.begin('A', true).incremental, false);
});

test('another list or an old response cannot acknowledge ignored changes', () => {
  const reads = createReconciliationReads();
  const a = reads.begin('A', true);
  const b = reads.begin('B', true);
  reads.accept(b);
  assert.equal(reads.begin('A', true).incremental, false);
  assert.equal(reads.accept(a), false);
  assert.equal(reads.begin('B', true).incremental, true);
});

test('manual requests, new pages and evicted list state all request a complete read', () => {
  const reads = createReconciliationReads(2);
  reads.accept(reads.begin('A', true));
  const manual = reads.begin('A', false);
  assert.equal(manual.incremental, false);
  reads.accept(manual);
  reads.accept(reads.begin('B', true));
  reads.accept(reads.begin('C', true));
  assert.equal(reads.begin('A', true).incremental, false);
  assert.equal(createReconciliationReads().begin('A', true).incremental, false);
});
