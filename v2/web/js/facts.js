// Shared evidence is supplied by DomeniaFact. Preserve page identity, grouping and visual state.
// Legacy responses remain readable; no network work or inferred observation happens here.
export function explainFact(fact) {
  const evidence = fact?.evidence;
  if (!evidence) return fact;
  return {
    ...fact,
    source: evidence.source,
    limit: evidence.limit,
    hypothesis: evidence.hypothesis,
    hint: evidence.hypothesis ?? fact.hint,
    at: evidence.at,
    reader: evidence.reader,
  };
}
