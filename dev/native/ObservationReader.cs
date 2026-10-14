// DOMENIA local observation decoder. C# 5 / .NET Framework 4.7.2; no PowerShell or network dependency.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;

namespace Domenia.Native {
    internal static class ObservationWire {
        internal const int MaximumUtf8Bytes = 262144;
        internal static byte[] Encode(string json) {
            if (String.IsNullOrEmpty(json) || json.Length > MaximumUtf8Bytes || Encoding.UTF8.GetByteCount(json) > MaximumUtf8Bytes)
                throw new ArgumentException("Observation UTF-8 size outside supported bounds.");
            return Encoding.UTF8.GetBytes(json);
        }
    }
    public sealed class ProbeDefinition {
        public string Id { get; set; }
        public string Mode { get; set; }
        public string Transform { get; set; }
        public bool QueryNumeric { get; set; }
    }
    [DataContract]
    public sealed class Inventory {
        [DataMember] public string CheckedUtc { get; set; }
        [DataMember] public string Model { get; set; }
        [DataMember] public string Manufacturer { get; set; }
        [DataMember] public string Build { get; set; }
        [DataMember] public string OsCaption { get; set; }
        [DataMember] public string LastBootUtc { get; set; }
        [DataMember] public double? RamBytes { get; set; }
        [DataMember] public double? DiskSize { get; set; }
        [DataMember] public double? DiskFree { get; set; }
    }
    [DataContract]
    public sealed class ProbeResult {
        private static readonly object[] EmptyValues = new object[0];
        [DataMember] public string CheckedUtc { get; set; }
        [DataMember] public string AttemptedUtc { get; set; }
        [DataMember] public bool? Succeeded { get; set; }
        [DataMember] public string Error { get; set; }
        [DataMember] public string Skipped { get; set; }
        [DataMember] public bool Truncated { get; set; }
        [DataMember] public long? Count { get; set; }
        [DataMember] public bool? CountComplete { get; set; }
        [DataMember] public long? StoredCount { get; set; }
        [DataMember] public string LimitReason { get; set; }
        [DataMember] public string DefinitionHash { get; set; }
        [DataMember] public string[][] Rows { get; set; }
        public object[] Values { get; private set; }
        public bool Prepared { get; private set; }
        public DateTime? At { get; private set; }
        public ProbeDefinition Definition { get; private set; }
        internal void Prepare(ProbeDefinition definition, DateTime now) {
            Definition = definition; At = Time.Parse(CheckedUtc); Values = EmptyValues;
            Prepared = definition != null && definition.Transform != "Release";
            if (!Prepared) { if (definition == null) Rows = null; return; }
            // Failed or incomplete values remain unknown. Full last-success details are retained by the canonical store.
            if (!String.IsNullOrEmpty(Error) || !String.IsNullOrEmpty(Skipped) || Succeeded == false || (definition.Mode == "Count" && CountComplete == false) || (Truncated && definition.Mode != "Count")) { Rows = null; return; }
            var raw = new List<string>();
            if (definition.Mode == "Count") { if (Count.HasValue) raw.Add(Count.Value.ToString(CultureInfo.InvariantCulture)); }
            else if (Rows != null) {
                foreach (var row in Rows) { if (row != null && row.Length > 0) raw.Add(row[0]); if (definition.Mode != "All") break; }
            }
            var values = new List<object>();
            foreach (string input in raw) {
                string text = input ?? String.Empty, transform = definition.Transform ?? String.Empty;
                if (String.IsNullOrWhiteSpace(text) && !transform.StartsWith("Map:", StringComparison.Ordinal)) continue;
                double n; DateTime? date;
                switch (transform) {
                    case "GB": if (Number(text, out n)) values.Add(Math.Round(n / 1073741824.0, 1)); break;
                    case "GBfromKB": if (Number(text, out n)) values.Add(Math.Round(n / 1048576.0, 1)); break;
                    case "MB": if (Number(text, out n)) values.Add(Math.Round(n / 1048576.0)); break;
                    case "Mbps": if (Number(text, out n)) values.Add(Math.Round(n / 1000000.0)); break;
                    case "Number": if (Number(text, out n)) values.Add(n); break;
                    case "DaysSince": date = Time.Parse(text); if (date.HasValue) values.Add(Math.Round((now - date.Value).TotalDays)); break;
                    case "Year": date = Time.Parse(text); if (date.HasValue) values.Add(date.Value.Year.ToString(CultureInfo.InvariantCulture)); break;
                    case "PercentFree":
                        double size;
                        if (Rows != null && Rows.Length > 0 && Rows[0] != null && Rows[0].Length > 1 && Number(Rows[0][0], out n) && Number(Rows[0][1], out size) && size > 0) values.Add(Math.Round(100 * n / size));
                        break;
                    default:
                        if (transform.StartsWith("Map:", StringComparison.Ordinal)) {
                            string mapped = text;
                            foreach (string pair in transform.Substring(4).Split(';')) { string[] parts = pair.Split('='); if (parts.Length == 2 && String.Equals(parts[0], text, StringComparison.OrdinalIgnoreCase)) { mapped = parts[1]; break; } }
                            values.Add(mapped);
                        } else values.Add(text.Trim());
                        break;
                }
            }
            Values = values.ToArray();
            // The on-disk original remains intact. The dashboard needs normalized values, not a second raw graph.
            Rows = null;
        }
        internal static bool Number(string text, out double number) {
            return Double.TryParse(text ?? String.Empty, NumberStyles.Float, CultureInfo.InvariantCulture, out number) && !Double.IsNaN(number) && !Double.IsInfinity(number);
        }
        public bool IsFresh(DateTime now, int maxDays) { return At.HasValue && At.Value <= now.AddMinutes(5) && (now - At.Value).TotalDays <= Math.Max(1, maxDays); }
    }
    internal static class Time {
        internal static DateTime? Parse(string text) { DateTime value; return DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out value) ? (DateTime?)value : null; }
    }
    [DataContract]
    public sealed class ObservationIdentity {
        [DataMember] public string Key { get; set; }
        [DataMember] public string Guid { get; set; }
        [DataMember] public string UserGuid { get; set; }
        [DataMember] public string UserDn { get; set; }
        [DataMember] public string UserUsn { get; set; }
        [DataMember] public string LinkUser { get; set; }
    }
    // Preparation of a fleet collection never materializes the probe graph.
    // Full JSON is retained until admission, then only the bounded active jobs decode it.
    public sealed class ObservationIdentityReader {
        private readonly DataContractJsonSerializer serializer = new DataContractJsonSerializer(typeof(ObservationIdentity));
        public ObservationIdentity Read(string json) {
            using (var stream = new MemoryStream(ObservationWire.Encode(json), false)) {
                var result = (ObservationIdentity)serializer.ReadObject(stream);
                if (result == null) throw new SerializationException("Missing observation.");
                return result;
            }
        }
    }
    [DataContract]
    public sealed class Observation {
        [DataMember] public int Version { get; set; }
        [DataMember] public string Key { get; set; }
        [DataMember] public string Guid { get; set; }
        [DataMember] public string CheckedUtc { get; set; }
        [DataMember] public long Revision { get; set; }
        [DataMember] public string PresenceCheckedUtc { get; set; }
        [DataMember] public string PresenceAttemptUtc { get; set; }
        [DataMember] public string PresenceError { get; set; }
        [DataMember] public string ConsoleCheckedUtc { get; set; }
        [DataMember] public string UserCheckedUtc { get; set; }
        [DataMember] public string ConsoleAttemptUtc { get; set; }
        [DataMember] public string ConsoleError { get; set; }
        [DataMember] public string InventoryCheckedUtc { get; set; }
        [DataMember] public string InventoryAttemptUtc { get; set; }
        [DataMember] public string InventoryError { get; set; }
        [DataMember] public Dictionary<string, ObservationTime> Times { get; set; }
        [DataMember] public string ObservedUtc { get; set; }
        [DataMember] public string Presence { get; set; }
        [DataMember] public string LinkUser { get; set; }
        [DataMember] public string Computer { get; set; }
        [DataMember] public string Outcome { get; set; }
        [DataMember] public string Detail { get; set; }
        [DataMember] public string RawAccount { get; set; }
        [DataMember] public string UserGuid { get; set; }
        [DataMember] public string UserDn { get; set; }
        [DataMember] public string UserUsn { get; set; }
        [DataMember] public Inventory Inventory { get; set; }
        [DataMember] public Dictionary<string, ProbeResult> Probes { get; set; }
        public string[] CopyQueryProbesTo(Dictionary<string, object> values, DateTime now, int maxDays) {
            var deferred = new List<string>();
            if (Probes == null) return deferred.ToArray();
            foreach (var pair in Probes) {
                ProbeResult result = pair.Value;
                if (result == null || result.Definition == null) continue;
                if (!result.Prepared) { deferred.Add(pair.Key); continue; }
                if (!result.IsFresh(now, maxDays) || result.Values.Length == 0) continue;
                values["_probe:" + pair.Key] = result.Values;
                if (result.Definition.QueryNumeric) {
                    double n; if (ProbeResult.Number(Convert.ToString(result.Values[0], CultureInfo.InvariantCulture), out n)) values["probe:" + pair.Key] = n;
                } else {
                    var texts = new string[result.Values.Length];
                    for (int i = 0; i < texts.Length; i++) texts[i] = Convert.ToString(result.Values[i], CultureInfo.InvariantCulture);
                    values["probe:" + pair.Key] = String.Join(" ; ", texts);
                }
            }
            return deferred.ToArray();
        }
    }
    [DataContract]
    public sealed class ObservationTime {
        [DataMember] public string ObservedUtc { get; set; }
        [DataMember] public string LastAttemptUtc { get; set; }
        [DataMember] public bool Succeeded { get; set; }
    }
    public sealed class ObservationReader {
        private readonly DataContractJsonSerializer serializer;
        private readonly DataContractJsonSerializer probeSerializer;
        private readonly Dictionary<string, ProbeDefinition> definitions;
        public ObservationReader(ProbeDefinition[] catalog) {
            definitions = new Dictionary<string, ProbeDefinition>(StringComparer.Ordinal);
            foreach (var d in catalog) { if (d == null || String.IsNullOrEmpty(d.Id) || definitions.ContainsKey(d.Id)) throw new ArgumentException("Invalid probe catalog."); definitions.Add(d.Id, d); }
            serializer = new DataContractJsonSerializer(typeof(Observation), new DataContractJsonSerializerSettings { UseSimpleDictionaryFormat = true, MaxItemsInObjectGraph = 200000 });
            probeSerializer = new DataContractJsonSerializer(typeof(ProbeResult), new DataContractJsonSerializerSettings { UseSimpleDictionaryFormat = true, MaxItemsInObjectGraph = 200000 });
        }
        // A dashboard decodes each persisted family separately; it never concatenates all instance graphs.
        // Instances are intentionally not part of ProbeResult. The canonical StoreRead retains their full data.
        public ProbeResult ReadProbe(string id, string json, DateTime now) {
            if (String.IsNullOrEmpty(id) || id.Length > 128) throw new ArgumentException("Invalid probe identity.");
            ProbeResult result;
            using (var stream = new MemoryStream(ObservationWire.Encode(json), false)) result = (ProbeResult)probeSerializer.ReadObject(stream);
            if (result == null) throw new SerializationException("Missing probe result.");
            ProbeDefinition definition; definitions.TryGetValue(id, out definition);
            result.Prepare(definition, now);
            return result;
        }
        public Observation Read(string json, DateTime now) {
            Observation observation;
            using (var stream = new MemoryStream(ObservationWire.Encode(json), false)) observation = (Observation)serializer.ReadObject(stream);
            if (observation == null) throw new SerializationException("Missing observation.");
            if (observation.Probes != null) foreach (var pair in observation.Probes) { ProbeDefinition definition; definitions.TryGetValue(pair.Key, out definition); if (pair.Value != null) pair.Value.Prepare(definition, now); }
            return observation;
        }
    }
}
