using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Queries;

/// <summary>Availability of one requested information over the population (Domenia 1 Measure-DomeniaQueryCoverage rows).</summary>
public sealed record QueryCoverageRow(string Field, string Name, string Source, long Available, long Expired, long Error, long Partial, long Unread);

/// <summary>One distinct clock of the requested informations: dated and undated objects, oldest and newest date.</summary>
public sealed record QueryClockRow(string Clock, string Source, bool Volatile, ImmutableArray<string> Informations, long Dated, long Missing, DateTimeOffset? Oldest, DateTimeOffset? Newest);

/// <summary>Proposal of a common window (Domenia 1 Get-DomeniaQueryCoherenceProposal).</summary>
public sealed record QueryCoherenceProposal(bool Needed, decimal? Hours, long Covered, long Dated, long Undated, string Text);

public sealed record QueryCoverage(ImmutableArray<QueryCoverageRow> Rows, long Total, long Complete, long Incomplete, long MixedPeriod, long Undated, decimal CoherenceHours,
    string WindowSource, ImmutableArray<QueryClockRow> Sources, QueryCoherenceProposal Proposal);

/// <summary>One object whose requested measures are missing, failed, incomplete or too old.</summary>
public sealed record QueryCollectTarget(string Id, string Name, string Dn, ImmutableArray<string> MissingFields, ImmutableArray<string> MissingProbes, ImmutableArray<string> Families);

public sealed record QueryFieldCount(string Field, string Name, long Missing);

/// <summary>Counted remote work of a plan (Domenia 1 Measure-DomeniaCollectionPlanWorkload); no duration is ever invented.</summary>
public sealed record QueryCollectWorkload(string Mode, long Targets, long PingReads, long ConsoleReads, long InventoryReads, long ProbeReads, long SlowProbeReads, ImmutableArray<string> SlowProbes, string Level);

/// <summary>« Collecter seulement les données manquantes » (Domenia 1 New-DomeniaMissingCollectionPlan). Plan only: no network.</summary>
public sealed record QueryCollectPlan(
    ImmutableArray<QueryCollectTarget> Targets,
    long Total,
    long Reused,
    long Disabled,
    long UnknownState,
    long NotCollectable,
    bool Ping,
    bool Console,
    bool Inventory,
    bool Wmi,
    ImmutableArray<string> ProbeIds,
    ImmutableArray<QueryFieldCount> FieldCounts,
    ImmutableArray<string> Fields,
    DateTimeOffset PreparedAt,
    int CacheMinutes,
    int ReuseMaxAgeDays,
    QueryCollectWorkload Workload,
    string Text);

/// <summary>One category of a distribution (exact, never sampled).</summary>
public sealed record QueryGroupCategory(int Rank, string Label, QueryValue Value, long Count, bool Missing, decimal Share);

/// <summary>Exact distribution of the matching objects (Domenia 1 Get-DomeniaQueryGroupSummary).</summary>
public sealed record QueryGroupSummary(string Field, string FieldName, long Total, long Matched, long Unknown, long NotMatched, ImmutableArray<QueryGroupCategory> Categories, long CategoryCount, long Missing);

/// <summary>Selection of one category for a segment (value, unknown value, or « Autres valeurs » by exclusions).</summary>
public sealed record QueryGroupSelection(string Label, string Field, bool Missing, QueryValue Value, ImmutableArray<QueryValue> Excluded);

/// <summary>Chart item: the largest categories, one exact remainder and the unknown bucket (totals preserved).</summary>
public sealed record QueryGroupItem(string Label, long Value, decimal Share, QueryGroupSelection Select);

public sealed record QueryGroupPage(ImmutableArray<QueryGroupCategory> Rows, int Offset, int Limit, long Filtered, long CategoryCount, long Missing, long Matched, bool HasPrevious, bool HasNext, string Text);

/// <summary>One readable element of a definition and its before/after values (pack comparison, impact review).</summary>
public sealed record QueryDifference(string Element, string Before, string After);

/// <summary>One line of the indented outline of the advanced tree.</summary>
public sealed record QueryOutlineRow(string Path, int Depth, QueryNodeKind Kind, string Label);

/// <summary>Coverage, clocks, coherence, collection plans, distributions, segments and readable outlines. Pure.</summary>
public static class QueryAnalysis
{
    private static readonly decimal[] Windows = [1, 6, 12, 24, 48, 72, 168, 336, 720, 2160, 8760];
    private static readonly decimal[] VolatileWindows = [1, 6, 12, 24];

    /// <summary>« Toutes les instances de « Services (détail) » » and the other node labels of the tree.</summary>
    public static string NodeLabel(QueryNode node, QueryTarget target, WmiReadDefinition? read)
    {
        ArgumentNullException.ThrowIfNull(node);
        return node.Kind switch
        {
            QueryNodeKind.All => "Toutes les conditions (ET)",
            QueryNodeKind.Any => "Au moins une condition (OU)",
            QueryNodeKind.Not => "Le groupe suivant ne correspond pas (NON)",
            QueryNodeKind.Collection => QueryTexts.Quantifier(node.Quantifier ?? CollectionQuantifier.Any) + " de " + FrenchText.Quote(QueryCatalog.Find(target, node.CollectionField, read)?.Name ?? node.CollectionField ?? ""),
            _ => node.Clause is { } clause ? QueryFormat.Clause(clause, target, read) : "",
        };
    }

    /// <summary>Indented outline of the tree (Domenia 1 Get-DomeniaQueryExpressionOutline).</summary>
    public static ImmutableArray<QueryOutlineRow> Outline(QueryRecipe recipe)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        return [.. QueryRecipeWalk.Nodes(recipe.Expression).Select(n => new QueryOutlineRow(n.Path, n.Depth, n.Node.Kind, NodeLabel(n.Node, recipe.Target, recipe.ReadDefinition)))];
    }

    /// <summary>Every element of a probe segment: probe, then the value, the bounds or the excluded categories.</summary>
    public static string SegmentLabel(QueryProbeSegment segment, QueryTarget target)
    {
        ArgumentNullException.ThrowIfNull(segment);
        var field = QueryCatalog.Find(target, QueryCatalog.ProbePrefix + segment.Key);
        var name = field?.Name ?? segment.Key;
        string Format(decimal value) => QueryFormat.Value(QueryValue.FromNumber(value), field);
        return segment.Mode switch
        {
            "Equal" => name + " · égal à " + QueryFormat.Value(QueryValue.FromText(segment.Value ?? ""), field),
            "Range" when segment.Low is decimal low && segment.High is decimal high => name + " · de " + Format(low) + " à " + Format(high),
            "Range" when segment.Low is decimal from => name + " · à partir de " + Format(from),
            "Range" when segment.High is decimal to => name + " · jusqu’à " + Format(to),
            "Other" => name + " · autres valeurs, hors " + string.Join(", ", segment.Excluded.Order(StringComparer.Ordinal)),
            _ => name + " · " + segment.Mode,
        };
    }

    /// <summary>
    /// Availability and dates of every requested information (Domenia 1 Measure-DomeniaQueryCoverage). The spread is compared
    /// with the recipe window, or with a 24 h reference when the recipe has none; nothing is collected.
    /// </summary>
    public static QueryCoverage Coverage(CompiledQuery query, IReadOnlyList<QueryRecord> records, QueryEvaluationContext context, decimal? coherenceHours = null)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(records);
        var windowSource = "Recette";
        var window = coherenceHours ?? query.Resolved.CoherenceHours;
        if (window is null)
        {
            window = 24m;
            windowSource = "Référence";
        }
        var hours = window.Value;
        var target = query.Target;
        var read = query.Resolved.ReadDefinition;
        var fields = query.RequestedFields.Select(id => (Id: id, Field: QueryCatalog.Find(target, id, read))).Where(f => f.Field is not null).ToList();
        var counts = fields.ToDictionary(f => f.Id, _ => new long[5], StringComparer.Ordinal);
        var clocks = new Dictionary<string, (List<string> Names, long Dated, long Missing, DateTimeOffset? Oldest, DateTimeOffset? Newest)>(StringComparer.Ordinal);
        foreach (var (id, field) in fields)
        {
            if (!clocks.TryGetValue(field!.Clock, out var entry))
            {
                entry = ([], 0, 0, null, null);
            }
            if (!entry.Names.Contains(field.Name))
            {
                entry.Names.Add(field.Name);
            }
            clocks[field.Clock] = entry;
            _ = id;
        }
        var spreads = new List<decimal>();
        long total = 0, complete = 0, mixed = 0, undated = 0;
        foreach (var record in records)
        {
            if (!query.InPopulation(record, context) && query.Resolved.ObjectIds is not null)
            {
                continue;
            }
            total++;
            var all = true;
            foreach (var (id, field) in fields)
            {
                var known = record.Values.ContainsKey(id);
                var partial = false;
                if (field!.Source == QuerySource.Instance && field.ProbeId is { } probe)
                {
                    known = record.Collections.TryGetValue(probe, out var collection) && collection.Complete
                        && collection.Instances.All(i => i.Values.Keys.Any(k => string.Equals(k, field.Property, StringComparison.OrdinalIgnoreCase)) && !i.Incomplete.Contains(field.Property!, StringComparer.OrdinalIgnoreCase));
                    partial = !known && record.Collections.ContainsKey(probe);
                }
                else if (field.Source == QuerySource.Ldap || field.Source == QuerySource.Ad || field.Source == QuerySource.Local)
                {
                    known = known || field.Source == QuerySource.Ldap;
                }
                var row = counts[id];
                if (known)
                {
                    row[0]++;
                    continue;
                }
                all = false;
                var quality = record.Quality.GetValueOrDefault(field.ProbeId is { } p && field.Source == QuerySource.Instance ? QueryCatalog.ProbePrefix + p : id) ?? "";
                if (partial)
                {
                    row[3]++;
                }
                else
                {
                    switch (quality)
                    {
                        case "Expiré":
                            row[1]++;
                            break;
                        case "Erreur de lecture":
                        case "Erreur au dernier relevé":
                        case "Accès refusé":
                            row[2]++;
                            break;
                        case "Lecture incomplète":
                            row[3]++;
                            break;
                        default:
                            row[4]++;
                            break;
                    }
                }
            }
            DateTimeOffset? earliest = null;
            DateTimeOffset? latest = null;
            var missingDate = false;
            foreach (var clock in clocks.Keys.ToList())
            {
                var entry = clocks[clock];
                if (!record.Clocks.TryGetValue(clock, out var at))
                {
                    missingDate = true;
                    clocks[clock] = (entry.Names, entry.Dated, entry.Missing + 1, entry.Oldest, entry.Newest);
                    continue;
                }
                earliest = earliest is null || at < earliest ? at : earliest;
                latest = latest is null || at > latest ? at : latest;
                clocks[clock] = (entry.Names, entry.Dated + 1, entry.Missing, entry.Oldest is null || at < entry.Oldest ? at : entry.Oldest, entry.Newest is null || at > entry.Newest ? at : entry.Newest);
            }
            if (all)
            {
                complete++;
            }
            if (missingDate)
            {
                undated++;
            }
            if (earliest is DateTimeOffset e && latest is DateTimeOffset l)
            {
                var spread = (decimal)(l - e).TotalHours;
                if (spread > hours)
                {
                    mixed++;
                }
                if (!missingDate)
                {
                    spreads.Add(spread);
                }
            }
        }
        var sources = clocks.OrderBy(c => c.Key == "ad" ? 0 : 1).ThenBy(c => c.Key, StringComparer.Ordinal)
            .Select(c => new QueryClockRow(c.Key, QueryCatalog.ClockLabel(c.Key), QueryCatalog.IsVolatileClock(c.Key), [.. c.Value.Names], c.Value.Dated, c.Value.Missing, c.Value.Oldest, c.Value.Newest))
            .ToImmutableArray();
        var proposal = Propose(spreads, sources.Length, sources.Any(s => s.Volatile), undated);
        var rows = fields.Select(f => new QueryCoverageRow(f.Id, f.Field!.Name, f.Field.SourceLabel, counts[f.Id][0], counts[f.Id][1], counts[f.Id][2], counts[f.Id][3], counts[f.Id][4])).ToImmutableArray();
        return new QueryCoverage(rows, total, complete, total - complete, mixed, undated, hours, windowSource, sources, proposal);
    }

    /// <summary>
    /// Smallest usual window keeping at least <paramref name="threshold"/> of the fully dated objects coherent; never more
    /// than 24 h when an instantaneous measure is involved (Domenia 1 rule).
    /// </summary>
    public static QueryCoherenceProposal Propose(IReadOnlyList<decimal> spreads, int sourceCount, bool isVolatile, long undated, decimal threshold = 0.9m)
    {
        ArgumentNullException.ThrowIfNull(spreads);
        var dated = (long)spreads.Count;
        var undatedText = undated > 0 ? " " + FrenchText.Count(undated, "objet sans toutes les dates restera inconnu", "objets sans toutes les dates resteront inconnus") + " tant que ces informations ne sont pas relevées." : "";
        if (sourceCount < 2)
        {
            return new QueryCoherenceProposal(false, null, dated, dated, undated, "Une seule source datée : les conditions décrivent déjà la même période ; aucune fenêtre commune n’est nécessaire.");
        }
        if (dated == 0)
        {
            return new QueryCoherenceProposal(true, null, 0, 0, undated, "Les informations viennent de " + FrenchText.Count(sourceCount, "source datée", "sources datées")
                + " séparément, mais aucun objet ne possède toutes les dates demandées. Relevez les informations manquantes avant de choisir une fenêtre commune.");
        }
        var sorted = spreads.Order().ToArray();
        var candidates = isVolatile ? VolatileWindows : Windows;
        var covered = new Dictionary<decimal, long>();
        var index = 0;
        foreach (var hours in candidates)
        {
            while (index < sorted.Length && sorted[index] <= hours)
            {
                index++;
            }
            covered[hours] = index;
        }
        decimal? chosen = null;
        foreach (var hours in candidates)
        {
            if (covered[hours] / (decimal)dated >= threshold)
            {
                chosen = hours;
                break;
            }
        }
        var volatileText = isVolatile ? " La requête combine une mesure instantanée : la fenêtre proposée ne dépasse pas 24 h." : "";
        string text;
        if (chosen is null)
        {
            if (!isVolatile)
            {
                return new QueryCoherenceProposal(true, null, covered[8760], dated, undated, "Les dates sources sont dispersées sur plus d’un an pour plus de "
                    + FrenchText.Percent((double)Math.Round((1 - threshold) * 100), 0) + " des objets : relevez à nouveau ces informations plutôt que d’élargir la fenêtre." + undatedText);
            }
            chosen = 24;
            text = "Fenêtre proposée : 24 h. Seuls " + FrenchText.Integer(covered[24]) + " sur " + FrenchText.Count(dated, "objet entièrement daté", "objets entièrement datés")
                + " ont leurs dates à moins de 24 h d’écart : relancez une collecte groupée des informations instantanées pour réduire les inconnus.";
        }
        else
        {
            text = "Fenêtre proposée : " + QueryFormat.Hours(chosen.Value) + ". " + FrenchText.Integer(covered[chosen.Value]) + " sur " + FrenchText.Count(dated, "objet entièrement daté", "objets entièrement datés")
                + " ont toutes leurs dates dans cet écart ; " + FrenchText.Count(dated - covered[chosen.Value], "autre deviendra inconnu", "autres deviendront inconnus") + ".";
        }
        return new QueryCoherenceProposal(true, chosen, covered[chosen.Value], dated, undated, text + volatileText + undatedText);
    }

    /// <summary>Reuse window of one information (Domenia 1 Get-DomeniaCollectionMaxAgeSeconds): 1 min volatile, 5 min inventory, cache otherwise.</summary>
    public static double MaxAgeSeconds(QueryField field, int cacheMinutes)
    {
        ArgumentNullException.ThrowIfNull(field);
        double seconds = Math.Max(0, Math.Min(1440, cacheMinutes)) * 60;
        if (field.Clock == "inventory")
        {
            seconds = Math.Min(300, seconds);
        }
        if (field.Volatile)
        {
            seconds = Math.Min(60, seconds);
        }
        return seconds;
    }

    /// <summary>
    /// Plan of the measures to read again (Domenia 1 New-DomeniaMissingCollectionPlan): active computers whose requested
    /// measures are missing, failed, incomplete or too old. Disabled and unknown-state accounts are never targets; local and
    /// directory informations are never collected; stored WMI SELECT results are only re-read from the workstation fiche.
    /// </summary>
    public static QueryCollectPlan CollectPlan(CompiledQuery query, IReadOnlyList<QueryRecord> records, QueryEvaluationContext context, DateTimeOffset now, int cacheMinutes = 15, int reuseMaxAgeDays = 0, int concurrency = 4)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(records);
        cacheMinutes = Math.Max(0, Math.Min(1440, cacheMinutes));
        reuseMaxAgeDays = Math.Max(0, Math.Min(3650, reuseMaxAgeDays));
        var requested = new List<(string Id, QueryField Field, string Family, string? Probe, string Quality, double MaxAge)>();
        foreach (var id in query.RequestedFields)
        {
            if (requested.Count >= QueryLimits.MaxCollectFields)
            {
                throw new QueryDefinitionException("Un plan de collecte accepte au plus 256 informations distinctes.");
            }
            var field = QueryCatalog.Find(query.Target, id, query.Resolved.ReadDefinition);
            if (field is null)
            {
                continue;
            }
            var family = QueryCatalog.Family(field.Clock);
            if (family == "Local")
            {
                continue;
            }
            var quality = field.Source == QuerySource.Instance ? QueryCatalog.ProbePrefix + field.ProbeId : id;
            var maxAge = reuseMaxAgeDays > 0 ? reuseMaxAgeDays * 86400d : MaxAgeSeconds(field, cacheMinutes);
            requested.Add((id, field, family, field.ProbeId, quality, maxAge));
        }
        var targets = ImmutableArray.CreateBuilder<QueryCollectTarget>();
        var fieldMissing = new Dictionary<string, long>(StringComparer.Ordinal);
        var families = new Dictionary<string, long>(StringComparer.Ordinal) { ["Presence"] = 0, ["Console"] = 0, ["Inventory"] = 0, ["Probe"] = 0 };
        var probes = new SortedSet<string>(StringComparer.Ordinal);
        long total = 0, reused = 0, disabled = 0, unknownState = 0, notCollectable = 0;
        foreach (var record in records)
        {
            if (query.Resolved.ObjectIds is not null && !query.InPopulation(record, context))
            {
                continue;
            }
            total++;
            if (record.Active is not bool active)
            {
                unknownState++;
                continue;
            }
            if (!active)
            {
                disabled++;
                continue;
            }
            var missing = new SortedSet<string>(StringComparer.Ordinal);
            var missingProbes = new SortedSet<string>(StringComparer.Ordinal);
            var targetFamilies = new SortedSet<string>(StringComparer.Ordinal);
            var detailMissing = false;
            foreach (var entry in requested)
            {
                var known = reuseMaxAgeDays > 0 || record.Values.ContainsKey(entry.Id);
                if (entry.Field.Source == QuerySource.Instance && reuseMaxAgeDays <= 0)
                {
                    known = entry.Probe is { } p && record.Collections.TryGetValue(p, out var collection) && collection.Complete;
                }
                var fresh = known && !record.Quality.ContainsKey(entry.Quality) && record.Clocks.TryGetValue(entry.Field.Clock, out var at)
                    && at <= now.AddMinutes(1) && (now - at).TotalSeconds < entry.MaxAge;
                if (fresh)
                {
                    continue;
                }
                if (entry.Family == "Detail")
                {
                    detailMissing = true;
                    continue;
                }
                missing.Add(entry.Quality);
                targetFamilies.Add(entry.Family);
                if (entry.Probe is { } probe)
                {
                    missingProbes.Add(probe);
                }
            }
            if (detailMissing)
            {
                notCollectable++;
            }
            if (missing.Count == 0)
            {
                if (!detailMissing)
                {
                    reused++;
                }
                continue;
            }
            foreach (var id in missing)
            {
                fieldMissing[id] = fieldMissing.GetValueOrDefault(id) + 1;
            }
            foreach (var family in targetFamilies)
            {
                families[family] = families.GetValueOrDefault(family) + 1;
            }
            probes.UnionWith(missingProbes);
            targets.Add(new QueryCollectTarget(record.Id, record.Name, record.Dn, [.. missing], [.. missingProbes], [.. targetFamilies]));
        }
        var counts = fieldMissing.Select(p => new QueryFieldCount(p.Key, QueryCatalog.Find(query.Target, p.Key, query.Resolved.ReadDefinition)?.Name ?? p.Key, p.Value))
            .OrderByDescending(c => c.Missing).ThenBy(c => c.Field, StringComparer.Ordinal).ToImmutableArray();
        var ping = families["Presence"] > 0;
        var wmi = families["Console"] + families["Inventory"] + families["Probe"] > 0;
        var list = targets.ToImmutable();
        var workload = Workload(list, ping, wmi, families["Console"] > 0, families["Inventory"]);
        var plan = new QueryCollectPlan(list, total, reused, disabled, unknownState, notCollectable, ping, families["Console"] > 0, families["Inventory"] > 0, wmi, [.. probes], counts,
            [.. requested.Select(r => r.Id)], now, cacheMinutes, reuseMaxAgeDays, workload, "");
        return plan with { Text = PlanText(plan, query.Target, concurrency) };
    }

    private static QueryCollectWorkload Workload(ImmutableArray<QueryCollectTarget> targets, bool ping, bool wmi, bool console, long inventory)
    {
        var mode = ping && !wmi ? "Ping" : wmi && !ping ? "Wmi" : "PingWmi";
        var slow = new SortedDictionary<string, string>(StringComparer.Ordinal);
        long probeReads = 0, slowReads = 0;
        foreach (var target in targets)
        {
            foreach (var id in target.MissingProbes)
            {
                probeReads++;
                if (QueryProbeCatalog.Find(id) is { Slow: true } probe)
                {
                    slowReads++;
                    slow[id] = probe.Name;
                }
            }
        }
        var contacts = (long)targets.Length;
        // Same bands as the ParkSweep impact model (100 and 500 workstations); slow probes raise the level.
        var level = contacts > 500 || slowReads > 100 ? "Élevé" : contacts > 100 || slowReads > 0 ? "Modéré" : "Faible";
        return new QueryCollectWorkload(mode, contacts, mode != "Wmi" ? contacts : 0, mode != "Ping" && console ? contacts : 0, inventory, probeReads, slowReads, [.. slow.Values], level);
    }

    private static string PlanText(QueryCollectPlan plan, QueryTarget target, int concurrency)
    {
        concurrency = Math.Max(1, Math.Min(8, concurrency));
        var lines = new List<string>();
        var reuse = plan.ReuseMaxAgeDays > 0
            ? "seules les mesures absentes, en erreur, incomplètes ou de plus de " + FrenchText.Count(plan.ReuseMaxAgeDays, "jour", "jours") + " sont à relire"
            : plan.CacheMinutes > 0
                ? "mesures réutilisées si elles datent de moins de " + FrenchText.Integer(plan.CacheMinutes) + " min (1 min pour les mesures volatiles, 5 min pour l’inventaire)"
                : "relecture forcée de toutes les mesures demandées";
        lines.Add("Plan préparé sur les données locales : " + reuse + ".");
        lines.Add(FrenchText.Count(plan.Targets.Length, "poste à relire", "postes à relire") + " sur " + FrenchText.Count(plan.Total, "examiné", "examinés") + " : "
            + FrenchText.Count(plan.Reused, "déjà à jour", "déjà à jour") + " ; " + FrenchText.Count(plan.Disabled, "désactivé", "désactivés") + " et "
            + FrenchText.Count(plan.UnknownState, "à l’état AD inconnu", "à l’état AD inconnu") + " exclus.");
        if (plan.Targets.Length > 0)
        {
            var reads = new List<string>();
            if (plan.Workload.Mode != "Wmi")
            {
                reads.Add("ping ICMP");
            }
            if (plan.Workload.ConsoleReads > 0)
            {
                reads.Add("utilisateur console");
            }
            if (plan.Inventory)
            {
                reads.Add("inventaire léger sur " + FrenchText.Count(plan.Workload.InventoryReads, "poste", "postes"));
            }
            if (plan.ProbeIds.Length > 0)
            {
                var names = plan.ProbeIds.Take(5).Select(id => QueryProbeCatalog.Find(id)?.Name ?? id);
                reads.Add(FrenchText.Count(plan.ProbeIds.Length, "sonde WMI", "sondes WMI") + " (" + string.Join(" ; ", names) + (plan.ProbeIds.Length > 5 ? " ; …" : "") + ")");
            }
            lines.Add("Lectures prévues : " + string.Join(", ", reads) + ". Lecture seule ; chaque poste ne relit que ses mesures manquantes ou anciennes.");
            var top = plan.FieldCounts.Take(5).Select(c => c.Name + " (" + FrenchText.Integer(c.Missing) + ")").ToList();
            if (top.Count > 0)
            {
                lines.Add("Informations les plus manquantes : " + string.Join(" ; ", top) + ".");
            }
            var cost = "Coût : " + plan.Workload.Level + " · " + FrenchText.Count(plan.Workload.Targets, "poste contacté", "postes contactés");
            if (plan.Workload.ProbeReads > 0)
            {
                cost += ", au plus " + FrenchText.Count(plan.Workload.ProbeReads, "lecture de sonde", "lectures de sondes");
            }
            if (plan.Workload.SlowProbeReads > 0)
            {
                cost += " dont " + FrenchText.Integer(plan.Workload.SlowProbeReads) + " sur des sondes lentes (" + string.Join(" ; ", plan.Workload.SlowProbes) + ")";
            }
            lines.Add(cost + " ; " + FrenchText.Count(concurrency, "poste", "postes") + " au maximum en parallèle. Durée non estimée : aucun relevé comparable n’est chronométré.");
        }
        if (plan.NotCollectable > 0)
        {
            lines.Add(FrenchText.Count(plan.NotCollectable, "poste attend", "postes attendent") + " aussi une lecture WMI avancée : elle se relance depuis l’onglet WMI avancé, pas dans cette collecte.");
        }
        if (target != QueryTarget.Computer)
        {
            lines.Add("Les comptes utilisateurs et les groupes ne se collectent pas : leurs informations viennent de l’annuaire.");
        }
        return string.Join("\n", lines);
    }

    /// <summary>Display text of one category value (typed value kept apart for exact drill-down).</summary>
    public static string GroupLabel(object? value, QueryField? field) => value switch
    {
        null => "Valeur inconnue",
        bool b => b ? "Oui" : "Non",
        _ => QueryFormat.Raw(value, field) is { Length: > 0 } text ? text : "(vide)",
    };

    /// <summary>
    /// Exact distribution of the matching population (Domenia 1 Get-DomeniaQueryGroupSummary): at most 100 000 distinct values,
    /// refused beyond without any partial distribution; total checked against the number of matching objects.
    /// </summary>
    public static QueryGroupSummary Group(CompiledQuery query, IReadOnlyList<QueryRecord> population, IReadOnlyList<MatchState> verdicts, int maxCategories = QueryLimits.MaxCategories)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(population);
        ArgumentNullException.ThrowIfNull(verdicts);
        var groupBy = query.Resolved.GroupBy ?? throw new QueryDefinitionException("Choisissez une information de répartition.");
        var field = QueryCatalog.Find(query.Target, groupBy, query.Resolved.ReadDefinition);
        var buckets = new Dictionary<string, (QueryValue Value, string Label, long Count)>(StringComparer.Ordinal);
        long matched = 0, unknown = 0, notMatched = 0, missing = 0;
        for (var i = 0; i < population.Count; i++)
        {
            switch (verdicts[i])
            {
                case MatchState.Unknown:
                    unknown++;
                    continue;
                case MatchState.NoMatch:
                    notMatched++;
                    continue;
            }
            matched++;
            if (!population[i].Values.TryGetValue(groupBy, out var raw))
            {
                missing++;
                continue;
            }
            var value = QueryValue.FromRaw(raw);
            var key = value.Kind + ":" + (value.Kind == QueryValueKind.Text ? (value.Text ?? "").ToUpperInvariant() : value.Invariant);
            if (buckets.TryGetValue(key, out var bucket))
            {
                buckets[key] = (bucket.Value, bucket.Label, bucket.Count + 1);
            }
            else
            {
                if (buckets.Count >= maxCategories)
                {
                    throw new QueryDefinitionException("Plus de " + FrenchText.Integer(maxCategories) + " valeurs distinctes pour cette répartition : choisissez une information moins détaillée ou réduisez le périmètre. Aucune répartition partielle n’est publiée.");
                }
                buckets[key] = (value, GroupLabel(raw, field), 1);
            }
        }
        if (buckets.Values.Sum(b => b.Count) + missing != matched)
        {
            throw new QueryDefinitionException("Répartition incohérente avec le nombre d’objets correspondants : aucun graphique publié.");
        }
        var ordered = buckets.Values.OrderByDescending(b => b.Count).ThenBy(b => b.Value.Kind == QueryValueKind.Number ? b.Value.Number.ToString("000000000000.############", CultureInfo.InvariantCulture) : FrenchText.Fold(b.Label), StringComparer.Ordinal).ToList();
        var categories = ordered.Select((b, i) => new QueryGroupCategory(i + 1, b.Label, b.Value, b.Count, false, Share(b.Count, matched))).ToImmutableArray();
        return new QueryGroupSummary(groupBy, field?.Name ?? groupBy, population.Count, matched, unknown, notMatched, categories, categories.Length, missing);
    }

    private static decimal Share(long count, long total) => total > 0 ? Math.Round(100m * count / total, 1) : 0m;

    /// <summary>Chart items: the <paramref name="top"/> largest categories, then « Autres valeurs » and « Valeur inconnue ».</summary>
    public static ImmutableArray<QueryGroupItem> Items(QueryGroupSummary summary, int top = 10)
    {
        ArgumentNullException.ThrowIfNull(summary);
        top = Math.Max(1, Math.Min(64, top));
        var items = ImmutableArray.CreateBuilder<QueryGroupItem>();
        var shown = summary.Categories.Take(top).ToList();
        foreach (var category in shown)
        {
            items.Add(new QueryGroupItem(category.Label, category.Count, category.Share, new QueryGroupSelection(category.Label, summary.Field, false, category.Value, [])));
        }
        var others = summary.Categories.Skip(top).Sum(c => c.Count);
        if (others > 0)
        {
            items.Add(new QueryGroupItem("Autres valeurs", others, Share(others, summary.Matched), new QueryGroupSelection("Autres valeurs", summary.Field, false, QueryValue.None, [.. shown.Select(c => c.Value)])));
        }
        if (summary.Missing > 0)
        {
            items.Add(new QueryGroupItem("Valeur inconnue", summary.Missing, Share(summary.Missing, summary.Matched), new QueryGroupSelection("Valeur inconnue", summary.Field, true, QueryValue.None, [])));
        }
        return items.ToImmutable();
    }

    /// <summary>One page of the complete distribution, filtered by label (accent and case insensitive), unknown bucket last.</summary>
    public static QueryGroupPage Page(QueryGroupSummary summary, int offset, int limit, string? text)
    {
        ArgumentNullException.ThrowIfNull(summary);
        if (offset < 0 || limit < 1 || limit > QueryLimits.MaxGroupPage)
        {
            throw new QueryDefinitionException("Page de répartition invalide (1 à 500 valeurs).");
        }
        var filter = (text ?? "").Trim();
        if (filter.Length > 256)
        {
            throw new QueryDefinitionException("Filtre de répartition limité à 256 caractères.");
        }
        var all = summary.Categories.ToList();
        if (summary.Missing > 0)
        {
            all.Add(new QueryGroupCategory(0, "Valeur inconnue", QueryValue.None, summary.Missing, true, Share(summary.Missing, summary.Matched)));
        }
        var terms = filter.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(FrenchText.Fold).ToList();
        var filtered = all.Where(c => terms.All(t => FrenchText.Fold(c.Label).Contains(t, StringComparison.Ordinal))).ToList();
        if (filtered.Count > 0 && offset >= filtered.Count)
        {
            offset = (filtered.Count - 1) / limit * limit;
        }
        if (filtered.Count == 0)
        {
            offset = 0;
        }
        return new QueryGroupPage([.. filtered.Skip(offset).Take(limit)], offset, limit, filtered.Count, summary.CategoryCount, summary.Missing, summary.Matched,
            offset > 0, offset + limit < filtered.Count, filter);
    }

    /// <summary>Recipe restricted to one category (Domenia 1 New-DomeniaQuerySegmentRecipe): refinements in AND, name suffixed.</summary>
    public static QueryRecipe SegmentRecipe(QueryRecipe recipe, QueryGroupSelection selection)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        ArgumentNullException.ThrowIfNull(selection);
        var refinements = recipe.Refinements.ToList();
        if (selection.Missing)
        {
            refinements.Add(new QueryClause(selection.Field, QueryOperator.IsMissing, QueryValue.None));
        }
        else if (selection.Excluded.Length > 0)
        {
            refinements.Add(new QueryClause(selection.Field, QueryOperator.IsPresent, QueryValue.None));
            refinements.AddRange(selection.Excluded.Select(v => new QueryClause(selection.Field, QueryOperator.NotEqual, v)));
        }
        else
        {
            refinements.Add(new QueryClause(selection.Field, QueryOperator.Equal, selection.Value));
        }
        var name = recipe.Name + " · " + selection.Label;
        return recipe with { Name = name.Length > QueryLimits.MaxNameLength ? name[..QueryLimits.MaxNameLength] : name, Refinements = [.. refinements] };
    }

    /// <summary>French description of every element of a definition (Domenia 1 Get-DomeniaQueryDefinitionSummary).</summary>
    public static ImmutableArray<(string Element, ImmutableArray<string> Values)> Summary(QueryRecipe recipe)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        var read = recipe.ReadDefinition;
        var list = new List<(string, ImmutableArray<string>)>
        {
            ("Nom", [recipe.Name]),
            ("Cible", [QueryTexts.TargetLabel(recipe.Target)]),
            ("Combinaison", [QueryTexts.Junction(recipe.Junction)]),
            ("Condition", [.. recipe.Clauses.Select(c => QueryFormat.Clause(c, recipe.Target, read))]),
            ("Segment", [.. recipe.Refinements.Select(c => QueryFormat.Clause(c, recipe.Target, read))]),
            ("Conditions avancées", [.. Outline(recipe).Select(r => new string('·', r.Depth) + (r.Depth > 0 ? " " : "") + r.Label)]),
            ("Répartition", [recipe.GroupBy is { } g ? QueryCatalog.Find(recipe.Target, g, read)?.Name ?? g : "Compteur d’objets"]),
            ("Paramètre", [.. QueryEngine.ParameterRows(recipe).Select(p => p.Label + " (" + p.FieldName + ") = " + p.ValueLabel)]),
            ("Cohérence des dates", [recipe.CoherenceHours is decimal h ? "Écart maximal " + QueryFormat.Hours(h) : "Aucune contrainte"]),
            ("Sélection figée", [recipe.ObjectIds is { } ids ? FrenchText.Count(ids.Length, "GUID", "GUID") + " · empreinte " + QueryRecipeJson.Sha256(string.Join("\n", ids.Select(QueryRecipeJson.NormalizeGuid).Order(StringComparer.Ordinal)))[..12] : "Aucune"]),
            ("Segment de sonde", [recipe.ProbeSelection is { } s ? SegmentLabel(s, recipe.Target) : "Aucun"]),
            ("SELECT mémorisé", [read?.CanonicalQuery ?? "Aucun"]),
        };
        return [.. list];
    }

    /// <summary>Readable before/after rows between two definitions; only differences are listed (a new recipe lists its content).</summary>
    public static ImmutableArray<QueryDifference> Compare(QueryRecipe? before, QueryRecipe after)
    {
        ArgumentNullException.ThrowIfNull(after);
        var rows = new List<QueryDifference>();
        var lists = new Dictionary<string, (string Removed, string Added)>(StringComparer.Ordinal)
        {
            ["Condition"] = ("Condition retirée", "Condition ajoutée"),
            ["Segment"] = ("Segment retiré", "Segment ajouté"),
            ["Paramètre"] = ("Paramètre retiré", "Paramètre ajouté"),
        };
        var newSummary = Summary(after);
        var oldSummary = before is null ? null : Summary(before).ToDictionary(e => e.Element, e => e.Values, StringComparer.Ordinal);
        string[] quiet = ["Aucune contrainte", "Aucune", "Aucun", "Compteur d’objets"];
        foreach (var (element, values) in newSummary)
        {
            var afterValues = values.Where(v => v.Length > 0).ToList();
            if (oldSummary is null)
            {
                if (afterValues.Count == 1 && quiet.Contains(afterValues[0]))
                {
                    continue;
                }
                rows.AddRange(afterValues.Select(v => new QueryDifference(element, "", v)));
                continue;
            }
            var beforeValues = oldSummary.GetValueOrDefault(element, []).Where(v => v.Length > 0).ToList();
            if (lists.TryGetValue(element, out var names))
            {
                rows.AddRange(beforeValues.Where(v => !afterValues.Contains(v)).Select(v => new QueryDifference(names.Removed, v, "")));
                rows.AddRange(afterValues.Where(v => !beforeValues.Contains(v)).Select(v => new QueryDifference(names.Added, "", v)));
            }
            else if (!beforeValues.SequenceEqual(afterValues, StringComparer.Ordinal))
            {
                rows.Add(new QueryDifference(element, string.Join(" ; ", beforeValues), string.Join(" ; ", afterValues)));
            }
        }
        if (before is not null && rows.Count == 0)
        {
            var b = QueryRecipeJson.Fingerprint(before);
            var a = QueryRecipeJson.Fingerprint(after);
            if (!string.Equals(a, b, StringComparison.Ordinal))
            {
                rows.Add(new QueryDifference("Autre élément de la définition", "empreinte " + b[..12], "empreinte " + a[..12]));
            }
        }
        return [.. rows];
    }

    /// <summary>« 3 différences : Condition ajoutée, Répartition » (Domenia 1 Format-DomeniaQueryChangeSummary).</summary>
    public static string ChangeSummary(IReadOnlyList<QueryDifference> changes, bool isNew)
    {
        ArgumentNullException.ThrowIfNull(changes);
        if (isNew)
        {
            return "Nouvelle requête";
        }
        if (changes.Count == 0)
        {
            return "Aucune différence de définition";
        }
        var kinds = changes.Select(c => c.Element).Distinct(StringComparer.Ordinal).ToList();
        return FrenchText.Count(changes.Count, "différence", "différences") + " : " + string.Join(", ", kinds.Take(3)) + (kinds.Count > 3 ? ", …" : "");
    }
}
