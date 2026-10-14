using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using M4D.Admin.Common.Query;

public static class QueryTests
{
    private static int count;
    private static FieldDefinition[] Fields() { return new[] { new FieldDefinition("name", FieldKind.Text), new FieldDefinition("n", FieldKind.Number), new FieldDefinition("active", FieldKind.Boolean), new FieldDefinition("at", FieldKind.Timestamp) }; }
    private static Dictionary<string, object> Values(params object[] entries)
    { var result = new Dictionary<string, object>(); for (int i = 0; i < entries.Length; i += 2) result.Add((string)entries[i], entries[i + 1]); return result; }
    private static CompiledQuery Compile(string field, QueryOperator op, object value)
    { var q = new QueryDefinition(); q.Clauses.Add(new QueryClause(field, op, value)); return QueryEngine.Compile(Fields(), q); }
    private static void Assert(bool good, string name) { count++; if (!good) throw new Exception(name); }
    private static void Throws(Action body, string name) { bool thrown = false; try { body(); } catch (ArgumentException) { thrown = true; } Assert(thrown, name); }
    public static int Run()
    {
        count = 0;
        CultureInfo before = Thread.CurrentThread.CurrentCulture;
        try
        {
            foreach (string culture in new[] { "fr-FR", "en-US", "tr-TR" })
            {
                Thread.CurrentThread.CurrentCulture = CultureInfo.GetCultureInfo(culture);
                Assert(Compile("name", QueryOperator.Equal, "PC-I").Evaluate(Values("name", "pc-i")) == MatchState.Match, "ordinal text " + culture);
                Assert(Compile("name", QueryOperator.Contains, "$(x)").Evaluate(Values("name", "before $(x) after")) == MatchState.Match, "literal text");
                Assert(Compile("name", QueryOperator.StartsWith, "pc-").Evaluate(Values("name", "PC-X")) == MatchState.Match, "prefix");
                Assert(Compile("name", QueryOperator.EndsWith, "-x").Evaluate(Values("name", "PC-X")) == MatchState.Match, "suffix");
                Assert(Compile("n", QueryOperator.Greater, "1.5").Evaluate(Values("n", 1.6)) == MatchState.Match, "decimal range");
                Assert(Compile("n", QueryOperator.Equal, 1.5m).Evaluate(Values("n", "1,5")) == MatchState.Unknown, "comma never thousands");
                Assert(Compile("n", QueryOperator.NotEqual, 0).Evaluate(Values()) == MatchState.Unknown, "missing != zero");
                Assert(Compile("n", QueryOperator.Equal, 0).Evaluate(Values("n", double.NaN)) == MatchState.Unknown, "NaN");
                Assert(Compile("n", QueryOperator.Equal, 0).Evaluate(Values("n", double.PositiveInfinity)) == MatchState.Unknown, "Infinity");
                Assert(Compile("n", QueryOperator.Equal, 0).Evaluate(Values("n", true)) == MatchState.Unknown, "bool not zero");
                Assert(Compile("at", QueryOperator.Equal, "2026-10-12T15:00:00Z").Evaluate(Values("at", "2026-10-12T17:00:00+02:00")) == MatchState.Match, "UTC instant");
                Assert(Compile("at", QueryOperator.Greater, "2026-10-12T15:00:00Z").Evaluate(Values("at", "2026-10-12T15:00:00")) == MatchState.Unknown, "timezone required");
                Assert(Compile("active", QueryOperator.Equal, true).Evaluate(Values("active", false)) == MatchState.NoMatch, "disabled included");
            }
            var q = new QueryDefinition(); q.Clauses.Add(new QueryClause("n", QueryOperator.Less, 10)); q.Clauses.Add(new QueryClause("active", QueryOperator.Equal, true));
            Assert(QueryEngine.Compile(Fields(), q).Evaluate(Values("active", false)) == MatchState.NoMatch, "unknown AND false");
            Assert(QueryEngine.Compile(Fields(), q).Evaluate(Values("active", true)) == MatchState.Unknown, "unknown AND true");
            q.Junction = QueryJunction.Any;
            Assert(QueryEngine.Compile(Fields(), q).Evaluate(Values("active", true)) == MatchState.Match, "unknown OR true");
            Assert(QueryEngine.Compile(Fields(), q).Evaluate(Values("active", false)) == MatchState.Unknown, "unknown OR false");
            var compiled = QueryEngine.Compile(Fields(), q);
            q.Clauses[0].Value = 0; q.Junction = QueryJunction.All; q.Clauses.Clear();
            Assert(compiled.Evaluate(Values("n", 5)) == MatchState.Match, "compiled snapshot");
            Assert(Compile("n", QueryOperator.IsMissing, null).Evaluate(Values("n", null)) == MatchState.Match, "explicit null missing");
            Assert(Compile("n", QueryOperator.IsPresent, null).Evaluate(Values("n", "invalid")) == MatchState.Match, "presence distinct from validity");
            Assert(Compile("name", QueryOperator.Equal, "").Evaluate(Values("name", "")) == MatchState.Match, "empty text value");
            Assert(Compile("name", QueryOperator.Equal, "1").Evaluate(Values("name", 1)) == MatchState.Unknown, "no arbitrary ToString");
            Assert(Compile("n", QueryOperator.LessOrEqual, 0).Evaluate(Values("n", 0)) == MatchState.Match, "inclusive lower");
            Assert(Compile("n", QueryOperator.GreaterOrEqual, 0).Evaluate(Values("n", 0)) == MatchState.Match, "inclusive upper");
            Throws(delegate { Compile("unknown", QueryOperator.Equal, 1); }, "field whitelist");
            Throws(delegate { Compile("n", QueryOperator.Contains, "1"); }, "operator type");
            Throws(delegate { Compile("name", QueryOperator.Contains, ""); }, "empty contains");
            Throws(delegate { Compile("active", QueryOperator.Less, true); }, "boolean range");
            Throws(delegate { Compile("n", QueryOperator.Equal, "1,5"); }, "bad operand");
            Throws(delegate { Compile("n", (QueryOperator)999, 0); }, "bad enum");
            Throws(delegate { QueryEngine.Compile(new[] { new FieldDefinition("n", FieldKind.Number), new FieldDefinition("n", FieldKind.Text) }, new QueryDefinition()); }, "duplicate fields");
            var invalid = new QueryDefinition(); for (int i = 0; i < 65; i++) invalid.Clauses.Add(new QueryClause("n", QueryOperator.Equal, i));
            Throws(delegate { QueryEngine.Compile(Fields(), invalid); }, "clause bound");
            var all = QueryEngine.Compile(Fields(), new QueryDefinition());
            Assert(all.Evaluate(Values()) == MatchState.Match, "empty All");
            Assert(QueryEngine.Compile(Fields(), new QueryDefinition { Junction = QueryJunction.Any }).Evaluate(Values()) == MatchState.NoMatch, "empty Any");
            var source = Values("n", 20, "name", "a"); var record = new QueryRecord("A", source); source["n"] = 100;
            Assert((int)record.Values["n"] == 20, "record snapshot");
            var records = new[] { record, new QueryRecord("B", Values("n", 10, "name", "A")), new QueryRecord("C", Values("name", "b")), new QueryRecord("D", Values("n", 10, "name", "b")) };
            var page = all.Execute(records, new QueryOptions { SortField = "n", Offset = 1, Limit = 2 });
            Assert(page.Rows.Count == 2 && page.Rows[0].Id == "D" && page.Rows[1].Id == "A", "stable sort and page");
            page = all.Execute(records, new QueryOptions { SortField = "n", Descending = true });
            Assert(page.Rows[0].Id == "A" && page.Rows[3].Id == "C", "missing last descending");
            page = Compile("n", QueryOperator.Less, 15).Execute(records, new QueryOptions { Selection = MatchState.Unknown });
            Assert(page.Total == 4 && page.Matched == 2 && page.NotMatched == 1 && page.Unknown == 1 && page.Coverage == 75, "coverage");
            Assert(page.Rows.Count == 1 && page.Rows[0].Id == "C", "unknown drilldown");
            Assert(all.Execute(records, new QueryOptions { Offset = int.MaxValue }).Rows.Count == 0, "far offset");
            Assert(all.Execute(records, new QueryOptions { Limit = 0 }).Total == 4, "count only");
            Throws(delegate { all.Execute(records, new QueryOptions { Limit = 10001 }); }, "page bound");
            Throws(delegate { all.Execute(records, new QueryOptions { Offset = -1 }); }, "offset bound");
            Throws(delegate { all.Execute(records, new QueryOptions { SortField = "wrong" }); }, "sort whitelist");
            Assert(all.Execute(new QueryRecord[0], null).Coverage == 0, "empty coverage");
            var summary = all.Summarize(records, "n");
            Assert(summary.Count == 3 && summary.Missing == 1 && summary.Sum == 40 && summary.Minimum == 10 && summary.Maximum == 20 && summary.Average == 40m / 3, "summary");
            var groups = all.CountBy(records, "name", 10);
            Assert(groups.Count == 2 && groups[0].Count == 2 && groups[1].Count == 2, "case insensitive grouping");
            groups = all.CountBy(records, "n", 10);
            Assert(groups.Count == 3 && groups[2].Missing && groups[2].Count == 1, "missing bucket");
            bool overflow = false; try { all.Summarize(new[] { new QueryRecord("x", Values("n", decimal.MaxValue)), new QueryRecord("y", Values("n", 1)) }, "n"); } catch (OverflowException) { overflow = true; }
            Assert(overflow, "sum cannot silently overflow");
            bool limited = false; try { all.CountBy(records, "name", 1); } catch (InvalidOperationException) { limited = true; }
            Assert(limited, "buckets never silently truncated");
            var cancel = new CancellationTokenSource(); cancel.Cancel(); bool cancelled = false;
            try { all.Execute(records, null, cancel.Token); } catch (OperationCanceledException) { cancelled = true; }
            Assert(cancelled, "cancel throws instead of complete result");
            cancelled = false;
            try { all.Execute(new QueryRecord[0], null, cancel.Token); } catch (OperationCanceledException) { cancelled = true; }
            Assert(cancelled, "empty execute cancelled");
            cancelled = false;
            try { all.Summarize(new QueryRecord[0], "n", cancel.Token); } catch (OperationCanceledException) { cancelled = true; }
            Assert(cancelled, "empty summary cancelled");
            cancelled = false;
            try { all.CountBy(records, "name", 10, cancel.Token); } catch (OperationCanceledException) { cancelled = true; }
            Assert(cancelled, "grouping cancelled");
            var sensitive = new[] { new FieldDefinition("name", FieldKind.Text) { CaseSensitive = true } };
            var exact = new QueryDefinition(); exact.Clauses.Add(new QueryClause("name", QueryOperator.Equal, "PC"));
            Assert(QueryEngine.Compile(sensitive, exact).Evaluate(Values("name", "pc")) == MatchState.NoMatch, "case sensitive field");
            var fleet = new List<QueryRecord>();
            for (int i = 0; i < 20000; i++) fleet.Add(new QueryRecord(i.ToString(CultureInfo.InvariantCulture), Values("name", "PC-" + i.ToString("D5"), "n", i)));
            groups = all.CountBy(fleet, "name", 100000);
            Assert(groups.Count == 20000 && groups[19999].Count == 1, "20000 exact distinct categories");
            limited = false;
            try { all.CountBy(fleet, "name", 19999); } catch (InvalidOperationException) { limited = true; }
            Assert(limited, "distinct budget remains explicit");
            Throws(delegate { all.CountBy(fleet, "name", 100001); }, "maximum category budget");
            var snapshot = all.PrepareSnapshot(fleet, new QueryOptions { SortField = "name", Descending = true }, 20000);
            Assert(snapshot.Total == 20000 && snapshot.Matched == 20000 && snapshot.SelectedCount == 20000, "prepared complete 20000 population");
            Assert(snapshot.ReadPage(0, 200)[0].Id == "19999" && snapshot.ReadPage(19800, 200)[199].Id == "0", "prepared stable first and last pages");
            Assert(snapshot.ReadPage(10000, 200).Count == 200 && snapshot.ReadPage(20000, 200).Count == 0, "prepared crossing 10000 boundary");
            fleet.Clear();
            Assert(snapshot.SelectedCount == 20000 && snapshot.ReadPage(0, 1)[0].Id == "19999", "prepared membership independent of mutable source list");
            limited = false;
            try { all.PrepareSnapshot(records, new QueryOptions { SortField = "name" }, 3); } catch (InvalidOperationException) { limited = true; }
            Assert(limited, "prepared sorted overflow refuses partial result");
            limited = false;
            try { all.PrepareSnapshot(records, null, 3); } catch (InvalidOperationException) { limited = true; }
            Assert(limited, "prepared unsorted overflow refuses partial result");
            var unknownSnapshot = Compile("n", QueryOperator.Less, 15).PrepareSnapshot(records, new QueryOptions { Selection = MatchState.Unknown }, 20);
            Assert(unknownSnapshot.Unknown == 1 && unknownSnapshot.ReadPage(0, 10)[0].Id == "C", "prepared unknown selection");
            Throws(delegate { snapshot.ReadPage(0, 10001); }, "prepared page bounded");
            cancelled = false;
            try { all.PrepareSnapshot(records, null, 20, cancel.Token); } catch (OperationCanceledException) { cancelled = true; }
            Assert(cancelled, "prepared cancellation cannot publish partial result");
            return count;
        }
        finally { Thread.CurrentThread.CurrentCulture = before; }
    }
}
