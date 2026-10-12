// C# 5 / .NET Framework 4.7.2. Pure data evaluation; no I/O, SQL or script execution.
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Threading;

namespace M4D.Admin.Common.Query
{
    public enum FieldKind { Text, Number, Boolean, Timestamp }
    public enum QueryOperator { Equal, NotEqual, Contains, StartsWith, EndsWith, Greater, GreaterOrEqual, Less, LessOrEqual, IsMissing, IsPresent }
    public enum QueryJunction { All, Any }
    public enum MatchState { NoMatch, Match, Unknown }

    public sealed class FieldDefinition
    {
        public string Name { get; set; }
        public FieldKind Kind { get; set; }
        public bool CaseSensitive { get; set; }
        public FieldDefinition(string name, FieldKind kind) { Name = name; Kind = kind; }
    }
    public sealed class QueryClause
    {
        public string Field { get; set; }
        public QueryOperator Operator { get; set; }
        public object Value { get; set; }
        public QueryClause(string field, QueryOperator op, object value) { Field = field; Operator = op; Value = value; }
    }
    public sealed class QueryDefinition
    {
        public QueryJunction Junction { get; set; }
        public IList<QueryClause> Clauses { get; private set; }
        public QueryDefinition() { Clauses = new List<QueryClause>(); }
    }
    public sealed class QueryRecord
    {
        public string Id { get; private set; }
        public IDictionary<string, object> Values { get; private set; }
        public QueryRecord(string id, IDictionary<string, object> values)
        {
            if (values == null) throw new ArgumentNullException("values");
            Id = id ?? string.Empty;
            // The record owns its scalar values, so sorting and evaluation see the same snapshot.
            Values = new ReadOnlyDictionary<string, object>(new Dictionary<string, object>(values, StringComparer.Ordinal));
        }
    }
    public sealed class QueryOptions
    {
        public int Offset { get; set; }
        public int Limit { get; set; }
        public string SortField { get; set; }
        public bool Descending { get; set; }
        public MatchState Selection { get; set; }
        public QueryOptions() { Limit = 200; Selection = MatchState.Match; }
    }
    public sealed class QueryResult
    {
        public long Total { get; internal set; }
        public long Matched { get; internal set; }
        public long NotMatched { get; internal set; }
        public long Unknown { get; internal set; }
        public ReadOnlyCollection<QueryRecord> Rows { get; internal set; }
        public double Coverage { get { return Total == 0 ? 0.0 : (Total - Unknown) * 100.0 / Total; } }
    }
    public sealed class NumericSummary
    {
        public long Count { get; internal set; }
        public long Missing { get; internal set; }
        public decimal Sum { get; internal set; }
        public decimal? Minimum { get; internal set; }
        public decimal? Maximum { get; internal set; }
        public decimal? Average { get { return Count == 0 ? (decimal?)null : Sum / Count; } }
    }
    public sealed class ValueCount
    {
        public object Value { get; internal set; }
        public long Count { get; internal set; }
        public bool Missing { get; internal set; }
    }

    public static class QueryEngine
    {
        // Compilation validates and snapshots the definition once, outside the per-row hot path.
        public static CompiledQuery Compile(IEnumerable<FieldDefinition> fields, QueryDefinition definition)
        {
            return new CompiledQuery(fields, definition);
        }
    }

    public sealed class CompiledQuery
    {
        private sealed class Field
        {
            internal string Name;
            internal FieldKind Kind;
            internal StringComparison Comparison;
        }
        private sealed class Clause
        {
            internal Field Field;
            internal QueryOperator Operator;
            internal object Value;
        }
        private sealed class SortRow
        {
            internal QueryRecord Record;
            internal object Value;
            internal long Ordinal;
        }
        private readonly Dictionary<string, Field> fields = new Dictionary<string, Field>(StringComparer.Ordinal);
        private readonly List<Clause> clauses = new List<Clause>();
        private readonly QueryJunction junction;

        internal CompiledQuery(IEnumerable<FieldDefinition> definitions, QueryDefinition query)
        {
            if (definitions == null) throw new ArgumentNullException("definitions");
            if (query == null) throw new ArgumentNullException("query");
            if (!Enum.IsDefined(typeof(QueryJunction), query.Junction)) throw new ArgumentException("Invalid junction.");
            junction = query.Junction;
            foreach (FieldDefinition definition in definitions)
            {
                if (definition == null || string.IsNullOrWhiteSpace(definition.Name) || definition.Name.Length > 128)
                    throw new ArgumentException("A field needs a name of 1 to 128 characters.");
                if (!Enum.IsDefined(typeof(FieldKind), definition.Kind)) throw new ArgumentException("Invalid field kind.");
                if (fields.Count >= 4096) throw new ArgumentException("Too many fields.");
                if (fields.ContainsKey(definition.Name)) throw new ArgumentException("Duplicate field: " + definition.Name);
                fields.Add(definition.Name, new Field { Name = definition.Name, Kind = definition.Kind,
                    Comparison = definition.CaseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase });
            }
            if (query.Clauses.Count > 64) throw new ArgumentException("A query supports up to 64 clauses.");
            foreach (QueryClause source in query.Clauses)
            {
                Field field;
                if (source == null || source.Field == null || !fields.TryGetValue(source.Field, out field))
                    throw new ArgumentException("Unknown field.");
                if (!Enum.IsDefined(typeof(QueryOperator), source.Operator)) throw new ArgumentException("Invalid operator.");
                bool existence = source.Operator == QueryOperator.IsMissing || source.Operator == QueryOperator.IsPresent;
                bool text = source.Operator == QueryOperator.Contains || source.Operator == QueryOperator.StartsWith || source.Operator == QueryOperator.EndsWith;
                bool range = source.Operator == QueryOperator.Greater || source.Operator == QueryOperator.GreaterOrEqual || source.Operator == QueryOperator.Less || source.Operator == QueryOperator.LessOrEqual;
                if (text && field.Kind != FieldKind.Text) throw new ArgumentException("Text operator on a non-text field.");
                if (range && field.Kind == FieldKind.Boolean) throw new ArgumentException("Boolean ranges are not supported.");
                object value = null;
                if (!existence && !TryValue(field.Kind, source.Value, out value)) throw new ArgumentException("Invalid value for " + field.Name);
                if (value is string && ((string)value).Length > 4096) throw new ArgumentException("Query text exceeds 4096 characters.");
                if (text && ((string)value).Length == 0) throw new ArgumentException("Empty text search.");
                clauses.Add(new Clause { Field = field, Operator = source.Operator, Value = value });
            }
        }

        // Strong Kleene logic: unknown AND false = false; unknown OR true = true.
        // Empty All selects all rows, empty Any selects none. Missing is never a normal value.
        public MatchState Evaluate(IDictionary<string, object> values)
        {
            if (values == null) throw new ArgumentNullException("values");
            bool unknown = false;
            foreach (Clause clause in clauses)
            {
                MatchState state = EvaluateClause(values, clause);
                if (junction == QueryJunction.All && state == MatchState.NoMatch) return MatchState.NoMatch;
                if (junction == QueryJunction.Any && state == MatchState.Match) return MatchState.Match;
                unknown |= state == MatchState.Unknown;
            }
            if (unknown) return MatchState.Unknown;
            return junction == QueryJunction.All ? MatchState.Match : MatchState.NoMatch;
        }

        private static MatchState EvaluateClause(IDictionary<string, object> values, Clause clause)
        {
            object raw, value;
            bool present = values.TryGetValue(clause.Field.Name, out raw) && raw != null;
            if (clause.Operator == QueryOperator.IsMissing) return present ? MatchState.NoMatch : MatchState.Match;
            if (clause.Operator == QueryOperator.IsPresent) return present ? MatchState.Match : MatchState.NoMatch;
            if (!present || !TryValue(clause.Field.Kind, raw, out value)) return MatchState.Unknown;
            bool result;
            if (clause.Operator == QueryOperator.Contains) result = ((string)value).IndexOf((string)clause.Value, clause.Field.Comparison) >= 0;
            else if (clause.Operator == QueryOperator.StartsWith) result = ((string)value).StartsWith((string)clause.Value, clause.Field.Comparison);
            else if (clause.Operator == QueryOperator.EndsWith) result = ((string)value).EndsWith((string)clause.Value, clause.Field.Comparison);
            else
            {
                int comparison = Compare(clause.Field, value, clause.Value);
                switch (clause.Operator)
                {
                    case QueryOperator.Equal: result = comparison == 0; break;
                    case QueryOperator.NotEqual: result = comparison != 0; break;
                    case QueryOperator.Greater: result = comparison > 0; break;
                    case QueryOperator.GreaterOrEqual: result = comparison >= 0; break;
                    case QueryOperator.Less: result = comparison < 0; break;
                    case QueryOperator.LessOrEqual: result = comparison <= 0; break;
                    default: throw new InvalidOperationException("Uncompiled operator.");
                }
            }
            return result ? MatchState.Match : MatchState.NoMatch;
        }

        private Field GetField(string name)
        {
            Field field;
            if (name == null || !fields.TryGetValue(name, out field)) throw new ArgumentException("Unknown field: " + name);
            return field;
        }

        public QueryResult Execute(IEnumerable<QueryRecord> records, QueryOptions options)
        {
            return Execute(records, options, CancellationToken.None);
        }
        public QueryResult Execute(IEnumerable<QueryRecord> records, QueryOptions options, CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested();
            if (records == null) throw new ArgumentNullException("records");
            if (options == null) options = new QueryOptions();
            int offset = options.Offset, limit = options.Limit;
            MatchState selection = options.Selection;
            bool descending = options.Descending;
            if (offset < 0 || limit < 0 || limit > 10000) throw new ArgumentOutOfRangeException("options", "Offset must be nonnegative; limit is 0 to 10000.");
            if (!Enum.IsDefined(typeof(MatchState), selection)) throw new ArgumentException("Invalid selection.");
            Field sort = string.IsNullOrEmpty(options.SortField) ? null : GetField(options.SortField);
            QueryResult result = new QueryResult();
            List<QueryRecord> page = new List<QueryRecord>();
            List<SortRow> sorted = sort == null || limit == 0 ? null : new List<SortRow>();
            long selected = 0;
            foreach (QueryRecord record in records)
            {
                cancellation.ThrowIfCancellationRequested();
                if (record == null) throw new ArgumentException("Null record.");
                MatchState state = Evaluate(record.Values);
                result.Total++;
                if (state == MatchState.Match) result.Matched++;
                else if (state == MatchState.Unknown) result.Unknown++;
                else result.NotMatched++;
                if (state != selection) continue;
                if (sorted != null)
                {
                    object raw, value = null;
                    if (record.Values.TryGetValue(sort.Name, out raw)) TryValue(sort.Kind, raw, out value);
                    sorted.Add(new SortRow { Record = record, Value = value, Ordinal = selected });
                }
                else if (selected >= offset && page.Count < limit) page.Add(record);
                selected++;
            }
            if (sorted != null)
            {
                sorted.Sort(delegate(SortRow left, SortRow right)
                {
                    // Missing values stay last in both directions. Input order breaks ties deterministically.
                    int value = left.Value == null ? (right.Value == null ? 0 : 1) : right.Value == null ? -1 :
                        (descending ? Compare(sort, right.Value, left.Value) : Compare(sort, left.Value, right.Value));
                    return value == 0 ? left.Ordinal.CompareTo(right.Ordinal) : value;
                });
                cancellation.ThrowIfCancellationRequested();
                for (long index = offset; index < sorted.Count && page.Count < limit; index++) page.Add(sorted[(int)index].Record);
            }
            result.Rows = page.AsReadOnly();
            cancellation.ThrowIfCancellationRequested();
            return result;
        }

        // Aggregations concern matching records only. Unknown records remain visible in Execute's coverage.
        public NumericSummary Summarize(IEnumerable<QueryRecord> records, string fieldName)
        {
            return Summarize(records, fieldName, CancellationToken.None);
        }
        public NumericSummary Summarize(IEnumerable<QueryRecord> records, string fieldName, CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested();
            if (records == null) throw new ArgumentNullException("records");
            Field field = GetField(fieldName);
            if (field.Kind != FieldKind.Number) throw new ArgumentException("A numeric field is required.");
            NumericSummary summary = new NumericSummary();
            foreach (QueryRecord record in records)
            {
                cancellation.ThrowIfCancellationRequested();
                if (record == null) throw new ArgumentException("Null record.");
                if (Evaluate(record.Values) != MatchState.Match) continue;
                object raw, value;
                if (!record.Values.TryGetValue(field.Name, out raw) || !TryValue(field.Kind, raw, out value)) { summary.Missing++; continue; }
                decimal number = (decimal)value;
                // Overflow throws; it must not silently publish a corrupt total.
                summary.Sum = checked(summary.Sum + number);
                summary.Count++;
                if (!summary.Minimum.HasValue || number < summary.Minimum.Value) summary.Minimum = number;
                if (!summary.Maximum.HasValue || number > summary.Maximum.Value) summary.Maximum = number;
            }
            cancellation.ThrowIfCancellationRequested();
            return summary;
        }

        public ReadOnlyCollection<ValueCount> CountBy(IEnumerable<QueryRecord> records, string fieldName, int maxBuckets)
        {
            return CountBy(records, fieldName, maxBuckets, CancellationToken.None);
        }
        public ReadOnlyCollection<ValueCount> CountBy(IEnumerable<QueryRecord> records, string fieldName, int maxBuckets, CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested();
            if (records == null) throw new ArgumentNullException("records");
            if (maxBuckets < 1 || maxBuckets > 10000) throw new ArgumentOutOfRangeException("maxBuckets");
            Field field = GetField(fieldName);
            IEqualityComparer<object> comparer = field.Kind == FieldKind.Text ? (IEqualityComparer<object>)new TextComparer(field.Comparison) : EqualityComparer<object>.Default;
            Dictionary<object, ValueCount> counts = new Dictionary<object, ValueCount>(comparer);
            ValueCount missing = new ValueCount { Missing = true };
            foreach (QueryRecord record in records)
            {
                cancellation.ThrowIfCancellationRequested();
                if (record == null) throw new ArgumentException("Null record.");
                if (Evaluate(record.Values) != MatchState.Match) continue;
                object raw, value;
                if (!record.Values.TryGetValue(field.Name, out raw) || !TryValue(field.Kind, raw, out value)) { missing.Count++; continue; }
                ValueCount bucket;
                if (!counts.TryGetValue(value, out bucket))
                {
                    if (counts.Count >= maxBuckets) throw new InvalidOperationException("Aggregation exceeds the bucket limit.");
                    bucket = new ValueCount { Value = value };
                    counts.Add(value, bucket);
                }
                bucket.Count++;
            }
            List<ValueCount> result = new List<ValueCount>(counts.Values);
            result.Sort(delegate(ValueCount left, ValueCount right) { return Compare(field, left.Value, right.Value); });
            if (missing.Count > 0) result.Add(missing);
            cancellation.ThrowIfCancellationRequested();
            return result.AsReadOnly();
        }

        private sealed class TextComparer : IEqualityComparer<object>
        {
            private readonly StringComparer comparer;
            internal TextComparer(StringComparison comparison) { comparer = comparison == StringComparison.Ordinal ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase; }
            public new bool Equals(object left, object right) { return comparer.Equals((string)left, (string)right); }
            public int GetHashCode(object value) { return comparer.GetHashCode((string)value); }
        }
        private static int Compare(Field field, object left, object right)
        {
            if (field.Kind == FieldKind.Text) return string.Compare((string)left, (string)right, field.Comparison);
            if (field.Kind == FieldKind.Number) return ((decimal)left).CompareTo((decimal)right);
            if (field.Kind == FieldKind.Boolean) return ((bool)left).CompareTo((bool)right);
            return ((DateTimeOffset)left).CompareTo((DateTimeOffset)right);
        }
        private static bool TryValue(FieldKind kind, object raw, out object value)
        {
            value = null;
            if (raw == null) return false;
            if (kind == FieldKind.Text) { if (!(raw is string)) return false; value = raw; return true; }
            if (kind == FieldKind.Boolean)
            {
                if (raw is bool) { value = raw; return true; }
                bool boolean;
                if (raw is string && bool.TryParse((string)raw, out boolean)) { value = boolean; return true; }
                return false;
            }
            if (kind == FieldKind.Timestamp)
            {
                if (raw is DateTimeOffset) { value = ((DateTimeOffset)raw).ToUniversalTime(); return true; }
                if (raw is DateTime)
                {
                    DateTime date = (DateTime)raw;
                    if (date.Kind == DateTimeKind.Unspecified) return false;
                    value = new DateTimeOffset(date).ToUniversalTime(); return true;
                }
                string text = raw as string;
                DateTimeOffset stamp;
                // A timezone is required: parsing must never depend on the current workstation's zone.
                if (text != null && (text.EndsWith("Z", StringComparison.OrdinalIgnoreCase) ||
                    (text.Length >= 6 && (text[text.Length - 6] == '+' || text[text.Length - 6] == '-') && text[text.Length - 3] == ':')) &&
                    DateTimeOffset.TryParseExact(text, new[] { "yyyy-MM-dd'T'HH:mm:ssK", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK" }, CultureInfo.InvariantCulture, DateTimeStyles.None, out stamp))
                { value = stamp.ToUniversalTime(); return true; }
                return false;
            }
            if (raw is bool || raw is char || raw is DateTime || raw is DateTimeOffset || raw.GetType().IsEnum) return false;
            if (!(raw is string || raw is byte || raw is sbyte || raw is short || raw is ushort || raw is int || raw is uint || raw is long || raw is ulong || raw is float || raw is double || raw is decimal)) return false;
            decimal number;
            // No thousands separators. For example "1,5" must not turn into 15 on a French workstation.
            if (!decimal.TryParse(Convert.ToString(raw, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out number)) return false;
            value = number; return true;
        }
    }
}
