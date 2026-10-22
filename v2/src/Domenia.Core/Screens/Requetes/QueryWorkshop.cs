using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core.Queries.Ldap;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Core.Queries;

/// <summary>Population evaluated by one preview, described so that a figure is never compared with another population.</summary>
public sealed record QueryPopulation(string Domain, string ScopeDn, string ScopeLabel, bool Subtree, QueryTarget Target, string TargetLabel, string RecipeName, string Fingerprint, long DatasetVersion,
    DateTimeOffset EvaluatedAt, string Source, string Text);

/// <summary>
/// One evaluated preview, kept frozen: the definition, the records and the verdicts of that instant. Pages, distributions,
/// details, explanations and exports read it, never the draft modified since (Domenia 1 rule).
/// </summary>
public sealed class QueryEvaluation
{
    internal QueryEvaluation(string id, CompiledQuery query, ImmutableArray<QueryRecord> population, ImmutableArray<MatchState> verdicts, int total, QueryPopulation description, ScopeSelection? scope,
        QueryEvaluationContext context, LdapTranslation ldap)
    {
        Id = id;
        Query = query;
        Population = population;
        Verdicts = verdicts;
        Total = total;
        Description = description;
        Scope = scope;
        Context = context;
        Ldap = ldap;
        Matched = verdicts.Count(v => v == MatchState.Match);
        Unknown = verdicts.Count(v => v == MatchState.Unknown);
        NotMatched = verdicts.Length - Matched - Unknown;
    }

    public string Id { get; }

    public CompiledQuery Query { get; }

    /// <summary>Objects of the population (after frozen selection, probe segment and refinements).</summary>
    public ImmutableArray<QueryRecord> Population { get; }

    public ImmutableArray<MatchState> Verdicts { get; }

    /// <summary>Objects of the scope before the segment (« recensés »).</summary>
    public int Total { get; }

    public int Matched { get; }

    public int Unknown { get; }

    public int NotMatched { get; }

    public QueryPopulation Description { get; }

    public ScopeSelection? Scope { get; }

    public QueryEvaluationContext Context { get; }

    public LdapTranslation Ldap { get; }

    private QueryGroupSummary? groups;

    public QueryGroupSummary? Groups
    {
        get
        {
            if (Query.Resolved.GroupBy is null)
            {
                return null;
            }
            return groups ??= QueryAnalysis.Group(Query, Population, Verdicts);
        }
    }

    public int IndexOf(string id) => Population.IndexOf(Population.FirstOrDefault(r => r.Id == id)!);
}

/// <summary>Collection plan kept between its display and the operator's confirmation: exactly what was shown is collected.</summary>
public sealed record QueryCollectTicket(string Id, QueryCollectPlan Plan, string Fingerprint, DateTimeOffset ExpiresAt);

/// <summary>GUIDs frozen for Recherche (« Appliquer aux résultats de Recherche »), with the recipe and the instant.</summary>
public sealed record QuerySearchSelection(string RecipeId, string RecipeName, QueryTarget Target, ImmutableArray<string> Ids, DateTimeOffset At, string Fingerprint);

/// <summary>
/// Session state of the query workshop (shared by every operation of the screen): frozen previews (the six most recent),
/// collection tickets, the selection frozen for Recherche, the WMI metadata read and the SELECT tests of each workstation,
/// the workshop scope chosen for the domain. In memory only, except the scope and the draft (local preferences).
/// </summary>
public sealed class QueryWorkshop
{
    public const string ScopePrefix = "requetes.scope.";
    public const string DraftKey = "requetes.draft";
    private const int MaxEvaluations = 6;
    private static readonly TimeSpan TicketLife = TimeSpan.FromMinutes(10);

    private readonly Lock gate = new();
    private readonly LinkedList<QueryEvaluation> evaluations = new();
    private readonly Dictionary<string, QueryCollectTicket> tickets = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (object Value, DateTimeOffset At)> wmiCache = new(StringComparer.Ordinal);
    private readonly Dictionary<Guid, (WmiTested Tested, WmiSelectResult Result)> tests = new();
    private readonly IPreferenceStore preferences;
    private readonly TimeProvider clock;
    private QuerySearchSelection? search;

    public QueryWorkshop(IPreferenceStore preferences, TimeProvider clock)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        ArgumentNullException.ThrowIfNull(clock);
        this.preferences = preferences;
        this.clock = clock;
    }

    public static QueryWorkshop From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new QueryWorkshop(c.Preferences, c.Clock));
    }

    public static string NewId() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));

    /// <summary>Evaluates a compiled query on the records of the scope and keeps the frozen result.</summary>
    public QueryEvaluation Evaluate(CompiledQuery query, ImmutableArray<QueryRecord> records, QueryDataset dataset, ScopeSelection? scope, DateTimeOffset now, string domain)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(dataset);
        var context = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), now);
        var population = records.Where(r => query.InPopulation(r, context)).ToImmutableArray();
        var verdicts = population.Select(r => query.Evaluate(r, context)).ToImmutableArray();
        var ldap = QueryLdap.Translate(query.Resolved, now);
        var scopeLabel = scope is null ? domain : scope.Label;
        var (_, many) = QueryTexts.Noun(query.Target);
        var text = "Population : " + FrenchText.Count(population.Length, QueryTexts.Noun(query.Target).One, many) + " de " + (scope is null || ScopeRules.IsDomainRoot(scope, dataset.Directory.Domain.RootDn) ? "tout le domaine " + domain : "l’OU " + scopeLabel + (scope.Subtree ? " et ses sous-OU" : " (sans sous-OU)"))
            + " · " + QueryTexts.TargetLabel(query.Target).ToLowerInvariant() + " · requête « " + query.Recipe.Name + " » (empreinte " + query.Fingerprint[..12] + ") · " + dataset.SourceLabel
            + " · calcul du " + QueryFormat.LocalDate(now, TimeZoneInfo.Utc) + " UTC.";
        var description = new QueryPopulation(domain, scope?.Dn ?? dataset.Directory.Domain.RootDn, scopeLabel, scope?.Subtree ?? true, query.Target, QueryTexts.TargetLabel(query.Target), query.Recipe.Name,
            query.Fingerprint, dataset.Version, now, dataset.SourceLabel, text);
        var evaluation = new QueryEvaluation(NewId(), query, population, verdicts, records.Length, description, scope, context, ldap);
        lock (gate)
        {
            evaluations.AddFirst(evaluation);
            while (evaluations.Count > MaxEvaluations)
            {
                evaluations.RemoveLast();
            }
        }
        return evaluation;
    }

    public QueryEvaluation RequireEvaluation(string id)
    {
        lock (gate)
        {
            return evaluations.FirstOrDefault(e => e.Id == id) ?? throw new DomeniaOperationException(QueryErrors.EvaluationUnknown, QueryErrors.EvaluationUnknownMessage);
        }
    }

    public QueryCollectTicket Keep(QueryCollectPlan plan, string fingerprint)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var now = clock.GetUtcNow();
        var ticket = new QueryCollectTicket(NewId(), plan, fingerprint, now + TicketLife);
        lock (gate)
        {
            foreach (var key in tickets.Where(t => t.Value.ExpiresAt < now).Select(t => t.Key).ToList())
            {
                tickets.Remove(key);
            }
            tickets[ticket.Id] = ticket;
        }
        return ticket;
    }

    /// <summary>Takes a ticket once: a confirmed collection never runs twice from the same plan.</summary>
    public QueryCollectTicket? Take(string id)
    {
        lock (gate)
        {
            if (!tickets.Remove(id, out var ticket) || ticket.ExpiresAt < clock.GetUtcNow())
            {
                return null;
            }
            return ticket;
        }
    }

    public QuerySearchSelection? Search
    {
        get
        {
            lock (gate)
            {
                return search;
            }
        }
        set
        {
            lock (gate)
            {
                search = value;
            }
        }
    }

    public T? Cached<T>(string key, TimeSpan life) where T : class
    {
        lock (gate)
        {
            return wmiCache.TryGetValue(key, out var entry) && entry.Value is T value && clock.GetUtcNow() - entry.At < life ? value : null;
        }
    }

    public void Cache(string key, object value)
    {
        lock (gate)
        {
            if (wmiCache.Count > 256)
            {
                wmiCache.Clear();
            }
            wmiCache[key] = (value, clock.GetUtcNow());
        }
    }

    public void Tested(Guid computer, WmiTested tested, WmiSelectResult result)
    {
        lock (gate)
        {
            tests[computer] = (tested, result);
        }
    }

    public (WmiTested Tested, WmiSelectResult Result)? LastTest(Guid computer)
    {
        lock (gate)
        {
            return tests.TryGetValue(computer, out var entry) ? entry : null;
        }
    }

    /// <summary>Workshop scope chosen for this domain (section choice of its own), or null to follow the working OU.</summary>
    public ScopeSelection? StoredScope(string rootDn)
    {
        if (!preferences.TryGet(ScopePrefix + QueryLibrary.RootKey(rootDn), out var value) || value.ValueKind != JsonValueKind.Object)
        {
            return null;
        }
        if (value.TryGetProperty("dn", out var dn) && dn.ValueKind == JsonValueKind.String && value.TryGetProperty("subtree", out var subtree) && subtree.ValueKind is JsonValueKind.True or JsonValueKind.False)
        {
            var label = value.TryGetProperty("label", out var l) && l.ValueKind == JsonValueKind.String ? l.GetString()! : dn.GetString()!;
            return new ScopeSelection(dn.GetString()!, label, subtree.GetBoolean());
        }
        return null;
    }

    /// <summary>Remembers (or forgets, with null) the workshop scope; false when the preferences could not be written.</summary>
    public async Task<bool> StoreScopeAsync(string rootDn, ScopeSelection? scope, CancellationToken cancellationToken)
    {
        var key = ScopePrefix + QueryLibrary.RootKey(rootDn);
        try
        {
            await preferences.SetAsync(key, scope is null ? null : JsonSerializer.SerializeToElement(new { dn = scope.Dn, label = scope.Label, subtree = scope.Subtree }), cancellationToken).ConfigureAwait(false);
            return preferences.Persistent;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
