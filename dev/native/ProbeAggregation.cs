using System;
using System.Collections.Generic;
using System.Globalization;

namespace Domenia.Native {
    public sealed class ProbeSelection {
        public string Key { get; set; }
        public string Mode { get; set; }
        public string Value { get; set; }
        public double Low { get; set; }
        public double High { get; set; }
        public string[] Excluded { get; set; }
        public bool Numeric { get; set; }
        public bool Matches(Dictionary<string, object> fields) {
            object raw; if (!fields.TryGetValue("_probe:" + Key, out raw)) return false;
            var values = raw as object[]; if (values == null) return false;
            foreach (object value in values) {
                string text = Convert.ToString(value, CultureInfo.InvariantCulture);
                double n, wanted;
                if (Mode == "Range" && ProbeResult.Number(text, out n) && n > Low && n <= High) return true;
                if (Mode == "Equal") {
                    if (Numeric && ProbeResult.Number(text, out n) && ProbeResult.Number(Value, out wanted) && n == wanted) return true;
                    if (!Numeric && String.Equals(text, Value, StringComparison.OrdinalIgnoreCase)) return true;
                }
                if (Mode == "Other") {
                    bool excluded = false;
                    foreach (string item in Excluded) if (String.Equals(text, item, StringComparison.OrdinalIgnoreCase)) { excluded = true; break; }
                    if (!excluded) return true;
                }
            }
            return false;
        }
    }
    public sealed class ValueGroup {
        public string Label { get; set; }
        public double Value { get; set; }
    }
    // One accumulator per requested probe. It retains normalized values, never raw observations.
    public sealed class ProbeSamples {
        public readonly List<object> Values = new List<object>();
        private readonly Dictionary<string, ValueGroup> groups = new Dictionary<string, ValueGroup>(StringComparer.OrdinalIgnoreCase);
        private readonly SortedDictionary<double, int> numbers = new SortedDictionary<double, int>();
        private readonly List<object[]> uniqueRows = new List<object[]>();
        public int Machines { get; private set; }
        public int Skipped { get; private set; }
        public DateTime? Newest { get; private set; }
        public DateTime? Oldest { get; private set; }
        public bool Numeric { get { return Values.Count > 0 && NumericCount == Values.Count; } }
        public int NumericCount { get; private set; }
        public double Sum { get; private set; }
        public double Min { get; private set; }
        public double Max { get; private set; }
        public double[] Distinct { get { var a = new double[numbers.Count]; numbers.Keys.CopyTo(a, 0); return a; } }
        public void Skip() { Skipped++; }
        public void AddUnique(object[] values, DateTime at) {
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var unique = new List<object>();
            foreach (object value in values) if (seen.Add(Convert.ToString(value, CultureInfo.InvariantCulture))) unique.Add(value);
            var row = unique.ToArray();
            if (row.Length > 0) uniqueRows.Add(row);
            Add(row, at);
        }
        public void Add(object[] values, DateTime at) {
            if (values == null || values.Length == 0) return;
            Machines++; if (!Newest.HasValue || at > Newest.Value) Newest = at; if (!Oldest.HasValue || at < Oldest.Value) Oldest = at;
            foreach (object value in values) {
                Values.Add(value);
                string text = Convert.ToString(value, CultureInfo.InvariantCulture); ValueGroup group;
                if (!groups.TryGetValue(text, out group)) { group = new ValueGroup { Label = text }; groups.Add(text, group); } group.Value++;
                if (value is double || value is int || value is long) {
                    double n = Convert.ToDouble(value, CultureInfo.InvariantCulture); int count;
                    numbers.TryGetValue(n, out count); numbers[n] = count + 1;
                    if (NumericCount == 0 || n < Min) Min = n; if (NumericCount == 0 || n > Max) Max = n;
                    Sum += n; NumericCount++;
                }
            }
        }
        public int CountEqual(double value) { int n; return numbers.TryGetValue(value, out n) ? n : 0; }
        public int CountRange(double low, double high) {
            int n = 0;
            if (uniqueRows.Count > 0) {
                foreach (var row in uniqueRows) foreach (object value in row) {
                    double number;
                    if (ProbeResult.Number(Convert.ToString(value, CultureInfo.InvariantCulture), out number) && number > low && number <= high) { n++; break; }
                }
            } else foreach (var p in numbers) if (p.Key > low && p.Key <= high) n += p.Value;
            return n;
        }
        public int CountOther(string[] excluded) {
            var known = new HashSet<string>(excluded, StringComparer.OrdinalIgnoreCase);
            int n = 0;
            if (uniqueRows.Count > 0) {
                foreach (var row in uniqueRows) foreach (object value in row)
                    if (!known.Contains(Convert.ToString(value, CultureInfo.InvariantCulture))) { n++; break; }
            } else foreach (var group in groups) if (!known.Contains(group.Key)) n += (int)group.Value.Value;
            return n;
        }
        public ValueGroup[] Groups() {
            var result = new List<ValueGroup>(groups.Values);
            result.Sort(delegate(ValueGroup a, ValueGroup b) { int order = b.Value.CompareTo(a.Value); return order != 0 ? order : StringComparer.InvariantCultureIgnoreCase.Compare(a.Label, b.Label); });
            return result.ToArray();
        }
    }
    public sealed class ProbeBatch {
        public readonly Dictionary<string, ProbeSamples> Buckets = new Dictionary<string, ProbeSamples>(StringComparer.Ordinal);
        public ProbeBatch(string[] ids) { foreach (string id in ids) if (!Buckets.ContainsKey(id)) Buckets.Add(id, new ProbeSamples()); }
        public string[] Add(Observation observation, DateTime now, int maxDays) {
            var deferred = new List<string>();
            if (observation.Probes == null) return deferred.ToArray();
            foreach (var p in Buckets) {
                ProbeResult result;
                if (!observation.Probes.TryGetValue(p.Key, out result) || result == null || !result.IsFresh(now, maxDays)) continue;
                if (!String.IsNullOrEmpty(result.Skipped)) { p.Value.Skip(); continue; }
                if (!result.Prepared) { deferred.Add(p.Key); continue; }
                if (result.Definition != null && result.Definition.Mode == "All") p.Value.AddUnique(result.Values, result.At.Value);
                else p.Value.Add(result.Values, result.At.Value);
            }
            return deferred.ToArray();
        }
    }
}
