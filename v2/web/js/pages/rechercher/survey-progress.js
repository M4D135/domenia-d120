/** Accept only the confirmed plan and its current run. Preserve unrelated columns and unknown prior console values. */
export function surveyChanges(run, progress, rows) {
  if (!run || !progress || progress.planId !== run.planId || !progress.runId || !Array.isArray(progress.batch)
      || !Number.isInteger(progress.done) || progress.done < run.done || progress.done > run.total
      || progress.total !== run.total || (run.runId && progress.runId !== run.runId)) return null;
  run.runId = progress.runId;
  run.done = progress.done;
  const byId = new Map(rows.map(row => [row.id, row]));
  const changed = new Map();
  for (const item of progress.batch) {
    const row = byId.get(item.id);
    if (row) changed.set(row.id, { ...row, presence: item.presence, console: item.console ?? row.console, _pending: false });
  }
  return [...changed.values()];
}
