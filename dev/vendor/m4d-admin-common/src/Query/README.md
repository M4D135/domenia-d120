# M4D.Admin.Common.Query

Pure C# 5 query evaluation for scalar dictionaries. No I/O, PowerShell, WPF, AD,
SQL, expressions or external packages. Compatible with .NET Framework 4.7.2.

## API

1. Declare `FieldDefinition(name, FieldKind)` for Text, Number, Boolean or Timestamp.
2. Create `QueryDefinition` with `Junction = All` (AND) or `Any` (OR) and up to 64
   `QueryClause(field, QueryOperator, value)` entries.
3. `QueryEngine.Compile(fields, definition)` validates and snapshots the query.
4. `CompiledQuery.Evaluate(dictionary)` returns Match, NoMatch or Unknown.
5. `Execute(records, options[, cancellation])` counts all three states and returns
   the selected page. `QueryOptions.Selection` can select Unknown for drilldown.
6. `Summarize(records, field)` returns count/missing/sum/min/max/average for matching
   records. `CountBy(records, field, maxBuckets)` returns typed groups and an explicit
   missing bucket. A bucket limit or decimal overflow throws; nothing is silently cut.

`QueryRecord(id, dictionary)` owns a read-only snapshot of scalar values.
Definitions, values and options must not be mutated concurrently during their copy.
Compiled queries are immutable and can be reused across threads.

## Semantics

- Field names are exact and ordinal. Text values compare ordinal-ignore-case unless
  the field declares `CaseSensitive`. Search strings are literal, never regex or code.
- Normal comparisons on absent/null/invalid values are Unknown, including NotEqual.
  AND/OR use three-valued logic (unknown AND false = false; unknown OR true = true).
- IsMissing/IsPresent test physical absence/null only, not validity. Products should
  map failed/expired observations to absent fields. Empty text is a present value.
- Numbers use invariant decimal syntax without thousands separators. NaN, infinity,
  booleans, arrays and arbitrary objects are invalid. Localized user inputs must be
  normalized explicitly by the product adapter before compilation.
- Timestamps require an offset or Z in ISO 8601 strings, DateTimeOffset, or a DateTime
  with a specified Kind. A date without a timezone is Unknown.
- Empty All matches all records; empty Any matches none. Coverage is the percentage
  whose final predicate result is known, not the percentage with every field present.
  Empty input has coverage 0, not a claim of full measurement.
- Sorting is typed and stable; missing/invalid values are last in either direction.
  Unsorted paging retains input order. Offsets are nonnegative; page limit 0–10000.
  Limit 0 computes only counts. Sorted pages materialize matching rows; adapters
  should use cancellation and a worker for large datasets. Summarize and CountBy also
  accept an optional CancellationToken overload; all methods are synchronous.
- Cancellation throws OperationCanceledException; no partial result is marked complete.
  Filtering covers the supplied snapshot only; its age and domain scope belong to
  the product adapter and must be displayed with the result.

Run `tests/Query/Test-Query.ps1` for pure tests. PowerShell 7 on macOS tests logic,
not .NET Framework/Windows PowerShell 5.1 or WPF deployment.
