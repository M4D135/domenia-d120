using System.Collections.Immutable;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Domenia.Core.Accueil;

/// <summary>
/// State and rules of the home page beyond its ten widgets (docs/ops/accueil.md): the fleet board of Domenia 1 with its exact
/// sets, its layout and its catalog, the explicit OU refresh, provenance and collection clocks, analysis, health rules,
/// BitLocker presence, favourites, first steps, last view and the session tools. Preferences are LocalWrite under the prefix
/// « accueil. »; nothing here writes the directory or a workstation. Shared by the module of the screen.
/// </summary>
public sealed partial class AccueilService : IDisposable
{
    public const string LayoutPreference = "accueil.layout";
    public const string FirstStepsPreference = "accueil.firstSteps";
    public const string HelpPreference = "accueil.helpSeen";
    public const int MaxFavorites = 12;
    public const int MaxTargets = 2000;
    public const string BitLockerRunning = "bitlocker.running";
    public const string BitLockerRunningMessage = "Une lecture de la présence BitLocker est déjà en cours" + FrenchText.Colon + "attendez sa fin. Rien n’a été relancé.";
    public const string BoardReplaced = "board.replaced";
    public const string BoardReplacedMessage = "Ce chiffre vient d’un calcul remplacé : la vue a été recalculée. Cliquez de nouveau sur le chiffre pour ouvrir ses postes exacts.";
    public const string RunsPreference = "accueil.runs.";
    public const string SnapshotsPreference = "accueil.snapshots.";
    public const int MaxStoredRuns = 300;
    public const int MaxManualSnapshots = 20;
    /// <summary>Days of daily snapshots kept per OU (the fleet.trend* widgets show 90 days; about 200 KiB for 4 OUs).</summary>
    public const int MaxDailyDays = 90;
    public const int MaxDailyScopes = 4;
    private static readonly TimeSpan LastViewInterval = TimeSpan.FromMinutes(1);
    public const string TargetsUnknown = "targets.unknown";
    public const string TargetsUnknownMessage = "Ensemble de postes introuvable dans ce calcul : rien n’a été lu.";

    private static readonly JsonSerializerOptions Json = CreateJson();

    private readonly EngineContext context;
    private readonly DashboardService dashboard;
    private readonly WorkingScope workingScope;
    private readonly Lock gate = new();
    private readonly SemaphoreSlim persist = new(1, 1);
    private FleetComputation? latest;
    private long revisionCounter;
    private ImmutableArray<FleetLayoutItem>? layout;
    private HealthPolicyBook? book;
    private readonly List<CollectionRun> sessionRuns = [];
    private readonly Dictionary<string, BitLockerPresence> bitlocker = new(StringComparer.Ordinal);
    private ProbeReadings probes = ProbeReadings.Empty;
    private readonly Dictionary<string, FleetSnapshot> todaySnapshots = new(StringComparer.Ordinal);
    private readonly List<(string ScopeKey, FleetSnapshot Snapshot)> manualSnapshots = [];
    private readonly Dictionary<string, ImmutableArray<FleetSnapshot>> historyCache = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (FleetMatrix Matrix, ImmutableDictionary<string, ImmutableArray<Guid>> Targets)> pivots = new(StringComparer.Ordinal);
    private readonly List<(DateTimeOffset At, int Milliseconds)> calculations = [];
    private bool selfCheckPassed;
    private SelfCheckSummary? lastCheck;
    // Domain whose recorded runs and snapshots were read back from the preferences (ACC-022, ACC-040); null: not read yet.
    private string? persistedDomain;
    private readonly Dictionary<string, FleetSnapshot> dailySnapshots = new(StringComparer.Ordinal);
    private (string Key, DateTimeOffset SavedAt)? lastViewSaved;

    public AccueilService(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        this.context = context;
        dashboard = DashboardService.From(context);
        workingScope = WorkingScope.From(context);
    }

    /// <summary>The home page service shared by every module of the context.</summary>
    public static AccueilService From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new AccueilService(c));
    }

    private IAccueilReader Reader => context.Readers.Require<IAccueilReader>();

    private DateTimeOffset Now => context.Clock.GetUtcNow();

    private TimeZoneInfo Zone => context.Clock.LocalTimeZone;

    // ---------------------------------------------------------------- board

    /// <summary>accueil.board: the fleet board of the working OU, from the local base (no network, no measure).</summary>
    public async Task<FleetBoard> BoardAsync(CancellationToken cancellationToken) => (await ComputeAsync(cancellationToken).ConfigureAwait(false)).Board;

    private async Task<FleetComputation> ComputeAsync(CancellationToken cancellationToken)
    {
        var (session, scope, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        LoadPersisted(domainDn);
        var reader = Reader;
        var watch = Stopwatch.StartNew();
        var state = await context.Directory.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var facts = await reader.FactsAsync(cancellationToken).ConfigureAwait(false);
        var storedProbes = await reader.StoredProbesAsync(cancellationToken).ConfigureAwait(false);
        var history = await HistoryAsync(reader, scope, cancellationToken).ConfigureAwait(false);
        var items = LayoutItems();
        var policyBook = HealthBook(domainDn);
        var querySnapshot = items.Any(i => i.Source == FleetWidgetSource.Query) || policyBook.Default.CustomRules.Any(r => r.Measure == "Query")
            || policyBook.Scopes.Any(s => s.Overrides.CustomRules is { } rules && rules.Any(r => r.Measure == "Query"))
            ? await ReadQueriesAsync(cancellationToken).ConfigureAwait(false) : null;
        // Every board count and drill-down uses the directory/observation snapshot captured by the query reader.
        if (querySnapshot?.Dataset is { } queryData) { state = state with { Directory = queryData.Directory, Observations = queryData.Observations }; }
        BitLockerPresence? presence;
        ProbeReadings readings;
        lock (gate)
        {
            presence = BitLockerFor(scope) ?? StoredBitLocker(facts, scope);
            probes = probes.Merge(storedProbes);
            readings = probes;
        }
        var input = new FleetBoardInput(state, scope, domainDn, session.Domain?.DnsName ?? domainDn, policyBook, facts with { Runs = AllRuns(facts) }, presence, readings,
            items, history, Now, Zone, Queries: querySnapshot);
        var computation = FleetBoardCalculator.Compute(input);
        computation = FleetQueryWidgets.Apply(computation, input, querySnapshot, cancellationToken);
        var revision = Interlocked.Increment(ref revisionCounter).ToString("x8", CultureInfo.InvariantCulture) + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(4));
        // Freshness of the branch for the header (ACC-020): the last complete AD read covering it, never the global date of the
        // base; a partial read never replaces that date.
        var freshness = CollectionClocks.Directory(input.Facts.Runs, new StoreStatus(state.Directory.ReadAt, state.Directory.ObjectCount, state.Directory.CoversScope(scope)), scope, domainDn, Now, Zone);
        computation = computation with { Board = computation.Board with { Revision = revision, Directory = freshness }, Explanation = computation.Explanation with { Revision = revision } };
        watch.Stop();
        var newDay = false;
        lock (gate)
        {
            latest = computation;
            pivots.Clear();
            calculations.Add((Now, (int)watch.ElapsedMilliseconds));
            if (calculations.Count > 5)
            {
                calculations.RemoveAt(0);
            }
            // First calculation of the day for an OU: the daily local snapshot (ACC-040), kept in the local preferences.
            var key = ScopeKey(scope);
            var today = LocalDays.DateOf(Now, Zone);
            if (!todaySnapshots.TryGetValue(key, out var taken) || taken.Day != today)
            {
                var daily = computation.Board.Snapshot with { Id = "jour-" + today.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), Kind = "daily", Label = FleetAnalysis.DailyLabel(today) + " (premier calcul)" };
                todaySnapshots[key] = daily;
                dailySnapshots[key + "|" + today.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)] = daily;
                newDay = true;
            }
        }
        if (newDay)
        {
            await PersistSnapshotsAsync(domainDn, cancellationToken).ConfigureAwait(false);
        }
        if (!ReadFirstSteps().DashboardSeen)
        {
            await RememberAsync(FirstStepsPreference, MergeFirstSteps(dashboardSeen: true), cancellationToken).ConfigureAwait(false);
        }
        return computation;
    }

    /// <summary>Durations of the last five calculations (improvement of ACC-032).</summary>
    public ImmutableArray<(DateTimeOffset At, int Milliseconds)> Calculations
    {
        get
        {
            lock (gate)
            {
                return [.. calculations];
            }
        }
    }

    /// <summary>accueil.targets: the exact workstations of one figure, from the calculation that produced it (point 73).</summary>
    public TargetList Targets(string revision, string key)
    {
        FleetComputation? computation;
        Dictionary<string, (FleetMatrix Matrix, ImmutableDictionary<string, ImmutableArray<Guid>> Targets)> tables;
        lock (gate)
        {
            computation = latest;
            tables = new(pivots, StringComparer.Ordinal);
        }
        if (computation is null || !string.Equals(computation.Board.Revision, revision, StringComparison.Ordinal))
        {
            throw new DomeniaOperationException(BoardReplaced, BoardReplacedMessage);
        }
        ImmutableArray<Guid> guids;
        string label;
        if (computation.Targets.TryGetValue(key, out var found))
        {
            guids = found;
            label = computation.TargetLabels.GetValueOrDefault(key) ?? LabelOf(computation, key);
        }
        else if (tables.Values.Select(t => t.Targets).FirstOrDefault(t => t.ContainsKey(key)) is { } table)
        {
            guids = table[key];
            label = PivotLabel(key);
        }
        else
        {
            throw new DomeniaOperationException(TargetsUnknown, TargetsUnknownMessage);
        }
        var rows = guids.Select(g => computation.Rows.GetValueOrDefault(g)).OfType<FleetTargetRow>()
            .OrderBy(r => r.Name, StringComparer.OrdinalIgnoreCase).Take(MaxTargets).ToImmutableArray();
        return new TargetList(key, label, guids.Length, guids.Length > MaxTargets, rows, revision);
    }

    private static string LabelOf(FleetComputation computation, string key)
    {
        var bar = key.IndexOf('|', StringComparison.Ordinal);
        var widget = bar < 0 ? key : key[..bar];
        var title = computation.Board.Entries.TryGetValue(widget, out var entry) ? entry.Title : widget;
        return bar < 0 ? title : title + " · " + key[(bar + 1)..];
    }

    private static string PivotLabel(string key)
    {
        // pivot:<table>:<kind>:<row>|<column>
        var parts = key.Split(':', 4);
        var table = FleetAnalysis.Tables.FirstOrDefault(t => parts.Length > 1 && t.Id == parts[1]);
        var tail = parts.Length == 4 ? parts[3].Replace("|", " · ", StringComparison.Ordinal).TrimEnd(' ', '·') : parts.Length == 3 ? parts[2] : "";
        return (table?.Title ?? "Tableau croisé") + (tail.Length > 0 ? FrenchText.Colon + tail : "");
    }

    // ---------------------------------------------------------------- layout and catalog

    /// <summary>accueil.widgets.catalog: built-in widgets, representations, sizes, presets and the probe catalog.</summary>
    public static WidgetCatalogView Catalog()
    {
        var groups = FleetCatalog.Groups.Select(g => new WidgetGroupView(g, [.. FleetCatalog.All.Where(w => w.Group == g)
            .Select(w => new FleetWidgetView(w.Key, w.Title, w.Group, w.Kind, w.Visual, FleetCatalog.VisualsFor(w.Kind), w.Size, w.Description, w.Default))])).ToImmutableArray();
        var probeGroups = ProbeCatalog.All.GroupBy(p => p.Category).Select(g => new ProbeCategoryView(g.Key, [.. g.Select(p =>
            new ProbeView(p.Id, p.Name, p.Category, p.Mode, p.Transform, ProbeCatalog.Visuals(p), ProbeCatalog.Visuals(p).Contains(p.Visual) ? p.Visual : ProbeCatalog.Visuals(p)[0],
                p.Slow, p.SkipOnDc, p.Origin, ProbeCatalog.Contract(p).Summary))])).ToImmutableArray();
        return new WidgetCatalogView(groups, FleetCatalog.VisualNames, FleetCatalog.SizeNames, FleetCatalog.Presets, probeGroups, ProbeCatalog.All.Length, false,
            "Bibliothèque non lue pour cette session. Ouvrez le catalogue pour lire les requêtes enregistrées.");
    }

    /// <summary>accueil.probe: contract, check and isolation of one probe (ACC-063).</summary>
    public static ProbeContract Probe(string id)
    {
        var probe = ProbeCatalog.Find(id) ?? throw new DomeniaOperationException("probe.unknown", "Sonde inconnue du catalogue : rien n’a été lu.");
        return ProbeCatalog.Contract(probe);
    }

    public FleetLayoutView Layout()
    {
        var items = LayoutItems();
        return new FleetLayoutView(items, !FleetCatalog.IsDefault(items), FleetCatalog.MaxItems);
    }

    /// <summary>accueil.layout.save: cleans and remembers the layout (LocalWrite, never the directory).</summary>
    public async Task<FleetLayoutView> SaveLayoutAsync(IReadOnlyList<FleetLayoutItem> items, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(items);
        var clean = Clean(items);
        lock (gate)
        {
            layout = clean;
        }
        await RememberAsync(LayoutPreference, JsonSerializer.SerializeToElement(new StoredLayout(1, [.. clean.Select(StoredItem.From)]), Json), cancellationToken).ConfigureAwait(false);
        return new FleetLayoutView(clean, !FleetCatalog.IsDefault(clean), FleetCatalog.MaxItems);
    }

    /// <summary>accueil.layout.reset: the delivered layout, or a preset applied to the current one.</summary>
    public Task<FleetLayoutView> ResetLayoutAsync(string? preset, CancellationToken cancellationToken)
    {
        if (preset is not null && FleetCatalog.Presets.All(p => p.Id != preset))
        {
            throw new DomeniaOperationException("layout.preset", "Disposition prédéfinie inconnue : rien n’a été changé.");
        }
        var items = preset is null ? FleetCatalog.DefaultLayout() : FleetCatalog.ApplyPreset(preset, LayoutItems());
        return SaveLayoutAsync(items, cancellationToken);
    }

    private ImmutableArray<FleetLayoutItem> LayoutItems()
    {
        lock (gate)
        {
            if (layout is ImmutableArray<FleetLayoutItem> known)
            {
                return known;
            }
        }
        var loaded = FleetCatalog.DefaultLayout();
        if (context.Preferences.TryGet(LayoutPreference, out var value))
        {
            try
            {
                var stored = value.Deserialize<StoredLayout>(Json);
                if (stored is { Version: 1, Items: not null })
                {
                    loaded = Clean([.. stored.Items.Select(i => i.ToItem())]);
                }
            }
            catch (JsonException)
            {
                context.Log.Warning("Préférence accueil.layout illisible : disposition livrée.");
            }
        }
        lock (gate)
        {
            layout ??= loaded;
            return layout.Value;
        }
    }

    /// <summary>After an explicit conditional import, the actual Fleet consumer rereads the stored choice, including an empty list.</summary>
    public void ReloadStoredLayout()
    {
        lock (gate) { layout = null; }
    }

    /// <summary>
    /// Clean layout (ConvertTo-DomeniaBoardCleanLayout): unknown widgets dropped, representations and sizes corrected, titles
    /// bounded, identifiers unique, 64 widgets at most.
    /// </summary>
    public static ImmutableArray<FleetLayoutItem> Clean(IEnumerable<FleetLayoutItem> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        var result = new List<FleetLayoutItem>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var position = 0;
        foreach (var item in items)
        {
            position++;
            if (result.Count >= FleetCatalog.MaxItems)
            {
                break;
            }
            string group;
            string visual;
            switch (item.Source)
            {
                case FleetWidgetSource.Builtin when FleetCatalog.TryGet(item.Key, out var definition):
                    group = definition.Group;
                    visual = FleetCatalog.ResolveVisual(item.Visual, definition.Kind);
                    break;
                case FleetWidgetSource.Probe when ProbeCatalog.Find(item.Key) is ProbeDefinition probe:
                    group = probe.Category;
                    var allowed = ProbeCatalog.Visuals(probe);
                    visual = allowed.Contains(item.Visual, StringComparer.Ordinal) ? item.Visual : allowed[0];
                    break;
                case FleetWidgetSource.Query when item.Key.Length is > 0 and <= 80 && item.Key.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '.' or '-'):
                    group = "Requêtes";
                    visual = item.Visual is "Pie" or "Bar" or "Column" or "Kpi" or "Text" ? item.Visual : "Kpi";
                    break;
                default:
                    continue;
            }
            var title = item.Title?.Trim();
            if (title is { Length: 0 } || (title is not null && title.Any(char.IsControl)))
            {
                title = null;
            }
            if (title is { Length: > FleetCatalog.MaxTitleLength })
            {
                title = title[..FleetCatalog.MaxTitleLength];
            }
            var id = item.Id;
            if (string.IsNullOrEmpty(id) || id.Length > 64 || !id.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.') || !ids.Add(id))
            {
                id = (item.Source switch { FleetWidgetSource.Builtin => "b-", FleetWidgetSource.Probe => "p-", _ => "q-" }) + item.Key + "-" + position.ToString(CultureInfo.InvariantCulture);
                ids.Add(id);
            }
            result.Add(new FleetLayoutItem(id, item.Source, item.Key, visual, FleetCatalog.IsSize(item.Size) ? item.Size : "M", title, item.Paused, group));
        }
        return [.. result];
    }

    // ---------------------------------------------------------------- provenance and collection clocks

    /// <summary>accueil.provenance: base freshness, measures of the active workstations and the three clocks (ACC-020 to ACC-023).</summary>
    public async Task<FleetProvenance> ProvenanceAsync(CancellationToken cancellationToken)
    {
        var (session, scope, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        LoadPersisted(domainDn);
        var state = await context.Directory.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var facts = await Reader.FactsAsync(cancellationToken).ConfigureAwait(false);
        var runs = AllRuns(facts);
        var now = Now;
        var zone = Zone;
        var store = new StoreStatus(state.Directory.ReadAt, state.Directory.ObjectCount, state.Directory.CoversScope(scope));
        var directory = CollectionClocks.Directory(runs, store, scope, domainDn, now, zone);
        var computers = state.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(scope, c.DistinguishedName)).ToList();
        var observations = state.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var total = computers.Count;
        var ping = CollectionClocks.Family("ping", [.. computers.Select(c => observations.TryGetValue(c.ObjectGuid, out var o) && o.Presence.HasReading
            ? (MeasureState.Known, o.Presence.CheckedAt) : (observations.TryGetValue(c.ObjectGuid, out var p) ? Unread(p.Presence.State) : MeasureState.Absent, (DateTimeOffset?)null))], total, now, 30, zone);
        var console = CollectionClocks.Family("console", [.. computers.Select(c => facts.Machines.TryGetValue(c.ObjectGuid, out var f) && f.ConsoleAt is not null
            ? (MeasureState.Known, f.ConsoleAt) : (MeasureState.NotRead, (DateTimeOffset?)null))], total, now, 30, zone);
        var inventory = CollectionClocks.Family("inventaire WMI", [.. computers.Select(c => observations.TryGetValue(c.ObjectGuid, out var o) && o.Inventory.HasReading
            ? (MeasureState.Known, o.Inventory.CheckedAt) : (observations.TryGetValue(c.ObjectGuid, out var p) ? Unread(p.Inventory.State) : MeasureState.Absent, (DateTimeOffset?)null))], total, now, 30, zone);
        var clocks = Enum.GetValues<CollectionFamily>().Select(f => CollectionClocks.Clock(runs, f, scope, domainDn, now, zone)).ToImmutableArray();
        var presence = ProvenanceRuns(clocks);
        BitLockerPresence? bit;
        lock (gate)
        {
            bit = BitLockerFor(scope) ?? StoredBitLocker(facts, scope);
        }
        var scopeText = (ScopeRules.IsDomainRoot(scope, domainDn) ? "Tout le domaine (consultation)" : scope.Label + (scope.Subtree ? " et ses sous-OU" : " sans les sous-OU"))
            + " · " + FleetBoardCalculator.Plural(state.Directory.Computers.Count(c => ScopeRules.Contains(scope, c.DistinguishedName)), "poste recensé dans la base", "postes recensés dans la base");
        _ = session;
        return new FleetProvenance(scope, scopeText, directory, ping, console, inventory, clocks, now,
            "Vue recalculée le " + CollectionClocks.Local(now, zone) + " ; aucune lecture AD ou poste pendant ce calcul.",
            "Postes actifs" + FrenchText.Colon + ping.Text + " · " + inventory.Text, presence.Text, presence.Warning, bit?.At);
    }

    private static MeasureState Unread(MeasureState state) => state == MeasureState.Known ? MeasureState.Expired : state == MeasureState.NotRead ? MeasureState.Absent : state;

    private static (string Text, bool Warning) ProvenanceRuns(ImmutableArray<CollectionClock> clocks)
    {
        var parts = clocks.Where(c => c.Family != CollectionFamily.Directory && c.Text.Length > 0)
            .Select(c => (c.Family == CollectionFamily.Presence ? "ping " : "WMI ") + c.Text).ToList();
        var text = parts.Count > 0 ? "Relevés de l’OU" + FrenchText.Colon + string.Join(" · ", parts) : "Relevés de l’OU : aucun relevé ping ou WMI enregistré pour ce périmètre.";
        return (text, clocks.Any(c => c.Warning));
    }

    /// <summary>accueil.collections: « Relevés par OU », 300 rows at most, newest first (ACC-022).</summary>
    public async Task<CollectionRunList> CollectionsAsync(CancellationToken cancellationToken)
    {
        var (_, _, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        LoadPersisted(domainDn);
        var facts = await Reader.FactsAsync(cancellationToken).ConfigureAwait(false);
        var runs = AllRuns(facts);
        return new CollectionRunList(runs.Length, CollectionClocks.Rows(runs));
    }

    private ImmutableArray<CollectionRun> AllRuns(AccueilFacts facts)
    {
        lock (gate)
        {
            return [.. facts.Runs, .. sessionRuns];
        }
    }

    // ---------------------------------------------------------------- analysis

    /// <summary>accueil.analysis.snapshots: daily snapshots of the OU, manual snapshots and the current view.</summary>
    public async Task<SnapshotList> SnapshotsAsync(CancellationToken cancellationToken)
    {
        var computation = await CurrentAsync(cancellationToken).ConfigureAwait(false);
        var all = await AllSnapshotsAsync(computation, cancellationToken).ConfigureAwait(false);
        return new SnapshotList([.. all.OrderByDescending(s => s.ComputedAt).Select(s => new SnapshotItem(s.Id, s.Kind, s.Label, s.Day, s.ComputedAt))], FleetAnalysis.Tables);
    }

    /// <summary>accueil.analysis.compare: two readings compared (ACC-009).</summary>
    public async Task<FleetComparison> CompareAsync(string before, string after, CancellationToken cancellationToken)
    {
        var computation = await CurrentAsync(cancellationToken).ConfigureAwait(false);
        var all = await AllSnapshotsAsync(computation, cancellationToken).ConfigureAwait(false);
        var a = all.FirstOrDefault(s => s.Id == before);
        var b = all.FirstOrDefault(s => s.Id == after);
        if (a is null || b is null)
        {
            throw new DomeniaOperationException("snapshot.unknown", "Relevé introuvable : choisissez deux relevés de la liste.");
        }
        if (a.Id == b.Id)
        {
            throw new DomeniaOperationException("snapshot.same", "Choisissez deux relevés différents.");
        }
        return FleetAnalysis.Compare(a, b);
    }

    /// <summary>accueil.analysis.pivots: one cross table of the current calculation (ACC-010).</summary>
    public async Task<FleetMatrix> PivotsAsync(string table, string? filter, CancellationToken cancellationToken)
    {
        if (FleetAnalysis.Tables.All(t => t.Id != table))
        {
            throw new DomeniaOperationException("pivot.unknown", "Tableau croisé inconnu : rien n’a été calculé.");
        }
        var computation = await CurrentAsync(cancellationToken).ConfigureAwait(false);
        var result = FleetAnalysis.Pivot(table, computation.Dimensions, filter, computation.Board.Revision);
        lock (gate)
        {
            pivots[table + "|" + (filter ?? "")] = result;
        }
        return result.Matrix;
    }

    /// <summary>
    /// accueil.snapshot.take: a manual dated snapshot of the current view (improvement of ACC-040: before and after a campaign).
    /// It is taken from the calculation shown (CurrentAsync), never from a new one: the board on screen keeps its revision and
    /// its figures still open their exact workstations afterwards.
    /// </summary>
    public async Task<SnapshotItem> TakeSnapshotAsync(string? label, CancellationToken cancellationToken)
    {
        var computation = await CurrentAsync(cancellationToken).ConfigureAwait(false);
        var text = string.IsNullOrWhiteSpace(label) ? "Instantané manuel" : label.Trim();
        if (text.Length > 80 || text.Any(char.IsControl))
        {
            throw new DomeniaOperationException("snapshot.label", "Nom d’instantané invalide : 80 caractères au plus, sans caractère de contrôle.");
        }
        FleetSnapshot snapshot;
        lock (gate)
        {
            snapshot = computation.Board.Snapshot with
            {
                Id = "manuel-" + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(4)),
                Kind = "manual",
                Label = text + " · " + CollectionClocks.Local(computation.Board.ComputedAt, Zone),
            };
            manualSnapshots.Add((ScopeKey(computation.Board.Scope), snapshot));
            while (manualSnapshots.Count > MaxManualSnapshots)
            {
                manualSnapshots.RemoveAt(0);
            }
        }
        var (_, _, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        await PersistSnapshotsAsync(domainDn, cancellationToken).ConfigureAwait(false);
        context.Journal.Add(new JournalEntry(Now, "Instantané manuel du parc" + FrenchText.Colon + text, Tone.Info));
        return new SnapshotItem(snapshot.Id, snapshot.Kind, snapshot.Label, snapshot.Day, snapshot.ComputedAt);
    }

    private async Task<ImmutableArray<FleetSnapshot>> AllSnapshotsAsync(FleetComputation computation, CancellationToken cancellationToken)
    {
        var scope = computation.Board.Scope;
        var history = await HistoryAsync(Reader, scope, cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            var key = ScopeKey(scope);
            var manual = manualSnapshots.Where(m => m.ScopeKey == key).Select(m => m.Snapshot);
            return [.. history, .. manual, computation.Board.Snapshot];
        }
    }

    private async Task<FleetComputation> CurrentAsync(CancellationToken cancellationToken)
    {
        FleetComputation? computation;
        lock (gate)
        {
            computation = latest;
        }
        if (computation is not null)
        {
            var (_, scope, _) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
            if (ScopeRules.SameScope(scope, computation.Board.Scope))
            {
                return computation;
            }
        }
        return await ComputeAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task<ImmutableArray<FleetSnapshot>> HistoryAsync(IAccueilReader reader, ScopeSelection scope, CancellationToken cancellationToken)
    {
        var key = ScopeKey(scope);
        ImmutableArray<FleetSnapshot>? cached = null;
        lock (gate)
        {
            if (historyCache.TryGetValue(key, out var known))
            {
                cached = known;
            }
        }
        var history = cached ?? await reader.HistoryAsync(scope, cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            historyCache[key] = history;
            // Daily snapshots kept in the preferences fill the days the base does not hold; the snapshot of today wins.
            var kept = dailySnapshots.Where(p => p.Key.StartsWith(key + "|", StringComparison.Ordinal)).Select(p => p.Value)
                .Where(d => history.All(h => h.Day != d.Day)).ToList();
            var merged = history.Concat(kept);
            if (todaySnapshots.TryGetValue(key, out var today))
            {
                merged = merged.Where(h => h.Day != today.Day).Append(today);
            }
            return [.. merged.OrderBy(h => h.Day).ThenBy(h => h.ComputedAt)];
        }
    }

    // ---------------------------------------------------------------- health rules

    /// <summary>accueil.health.policy: the policy of one scope with its origins (ACC-024 to ACC-028).</summary>
    public async Task<HealthPolicyView> HealthPolicyAsync(string? scopeDn, CancellationToken cancellationToken)
    {
        var (_, scope, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        var policyBook = HealthBook(domainDn);
        var target = NormalizeScope(scopeDn, domainDn);
        var resolved = HealthRules.Resolve(policyBook, target);
        var now = Now;
        var origins = HealthRules.Origins(policyBook, target, now);
        var rules = HealthRules.Catalog.Select(r => new HealthRuleView(r.Id, r.Name, r.Fleet,
            HealthRules.State(resolved.Policy, r.Id, now) switch { HealthRuleState.Disabled => "disabled", HealthRuleState.Suspended => "suspended", _ => "on" },
            origins.First(o => o.Kind == "Contrôle" && o.Id == r.Id).Origin, HealthRules.Suspension(resolved.Policy, r.Id, now))).ToImmutableArray();
        var scopes = HealthRules.EditorScopes(policyBook, ScopeRules.IsDomainRoot(scope, domainDn) ? null : scope.Dn);
        return new HealthPolicyView(target.Length == 0 ? null : target, HealthRules.ScopeLabel(target, domainDn), resolved.Local, resolved.Policy, origins, scopes, rules,
            HealthRules.Thresholds, HealthRules.SuspensionHours, HealthRules.MaxCustomRules, queryLibrary is not null);
    }

    /// <summary>accueil.health.save: saves the policy of a scope, only its differences for an OU (LocalWrite).</summary>
    public async Task<HealthPolicyView> SaveHealthAsync(string? scopeDn, HealthPolicy policy, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(policy);
        var (_, _, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        var target = NormalizeScope(scopeDn, domainDn);
        await healthWrites.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var next = HealthRules.SetScopePolicy(HealthBook(domainDn), target, policy, Now);
            await BindHealthQueriesAsync(domainDn, target, policy, cancellationToken).ConfigureAwait(false);
            await SaveBookAsync(next, cancellationToken).ConfigureAwait(false);
            await ReleaseObsoleteHealthQueriesAsync(domainDn, target, policy, cancellationToken).ConfigureAwait(false);
        }
        finally { healthWrites.Release(); }
        context.Journal.Add(new JournalEntry(Now, "Règles de santé enregistrées" + FrenchText.Colon + HealthRules.ScopeLabel(target, domainDn), Tone.Info));
        return await HealthPolicyAsync(target.Length == 0 ? null : target, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>accueil.health.revert: « Revenir aux règles héritées » (removes the exception of one OU).</summary>
    public async Task<HealthPolicyView> RevertHealthAsync(string scopeDn, CancellationToken cancellationToken)
    {
        var (_, _, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        var target = NormalizeScope(scopeDn, domainDn);
        await healthWrites.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var next = HealthRules.RemoveScope(HealthBook(domainDn), target);
            await SaveBookAsync(next, cancellationToken).ConfigureAwait(false);
            await ReleaseObsoleteHealthQueriesAsync(domainDn, target, HealthPolicy.Default, cancellationToken).ConfigureAwait(false);
        }
        finally { healthWrites.Release(); }
        context.Journal.Add(new JournalEntry(Now, "Règles héritées rétablies" + FrenchText.Colon + HealthRules.ScopeLabel(target, domainDn), Tone.Info));
        return await HealthPolicyAsync(target, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>accueil.health.exceptions: every local exception of the domain (ACC-026).</summary>
    public async Task<HealthExceptions> HealthExceptionsAsync(CancellationToken cancellationToken)
    {
        var (_, _, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        var rows = HealthRules.Exceptions(HealthBook(domainDn), Now);
        // An exception whose OU disappeared is signalled (Domenia 1: « OU disparue signalée »), checked in the local OU index
        // only, never on the network; without an index nothing is claimed missing.
        var index = context.Readers.Find<IOrganizationalUnitIndex>();
        if (index is null)
        {
            return new HealthExceptions(rows);
        }
        var checkedRows = new List<HealthExceptionRow>(rows.Length);
        foreach (var row in rows)
        {
            var known = HealthRules.SameDn(row.ScopeDn, domainDn) || await index.FindLocalAsync(row.ScopeDn, cancellationToken).ConfigureAwait(false) is not null;
            checkedRows.Add(known ? row : row with { Missing = true });
        }
        return new HealthExceptions([.. checkedRows]);
    }

    /// <summary>accueil.health.explain: « Comprendre le score » of the current calculation (ACC-030).</summary>
    public async Task<FleetExplanation> ExplainAsync(CancellationToken cancellationToken) => (await CurrentAsync(cancellationToken).ConfigureAwait(false)).Explanation;

    private static string NormalizeScope(string? scopeDn, string domainDn)
    {
        if (string.IsNullOrEmpty(scopeDn) || HealthRules.SameDn(scopeDn, domainDn))
        {
            return "";
        }
        if (!HealthRules.IsOu(scopeDn) || !HealthRules.IsInDomain(scopeDn, domainDn))
        {
            throw HealthRules.Invalid("OU de politique invalide ou hors du domaine.");
        }
        return scopeDn;
    }

    private HealthPolicyBook HealthBook(string domainDn)
    {
        lock (gate)
        {
            if (book is not null && HealthRules.SameDn(book.DomainDn, domainDn))
            {
                return book;
            }
        }
        var loaded = HealthPolicyBook.Empty(domainDn);
        var key = "accueil.health." + DomainHash(domainDn);
        if (context.Preferences.TryGet(key, out var value))
        {
            try
            {
                loaded = HealthPolicyJson.ReadBook(value, domainDn, Now);
            }
            catch (Exception ex) when (ex is JsonException or DomeniaOperationException or FormatException or InvalidOperationException)
            {
                context.Log.Warning("Règles de santé mémorisées illisibles (" + ex.GetType().Name + ") : règles par défaut.");
            }
        }
        lock (gate)
        {
            book = loaded;
            return loaded;
        }
    }

    private async Task SaveBookAsync(HealthPolicyBook next, CancellationToken cancellationToken)
    {
        await persist.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await context.Preferences.SetAsync("accueil.health." + DomainHash(next.DomainDn), HealthPolicyJson.Write(next), cancellationToken).ConfigureAwait(false);
            lock (gate) { book = next; latest = null; localWriteFailures = 0; }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            lock (gate) { localWriteFailures++; }
            context.Log.Warning("Règles de santé non enregistrées : " + ex.GetType().Name + ".");
            throw new DomeniaOperationException(HealthRules.InvalidCode, "Les règles de santé n’ont pas été enregistrées. Votre brouillon est conservé ; aucune nouvelle politique appliquée.");
        }
        finally { persist.Release(); }
    }

    // ---------------------------------------------------------------- BitLocker presence (ACC-057)

    /// <summary>accueil.bitlocker.read: presence of the recovery objects of the working OU; never the domain root, never a key.</summary>
    public async Task<BitLockerSummary> ReadBitLockerAsync(CancellationToken cancellationToken)
    {
        var (_, scope, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        ScopeRules.EnsureNotDomainRoot(scope, domainDn);
        lock (gate)
        {
            if (run is not null)
            {
                throw new DomeniaOperationException(RefreshRunning, "Une actualisation de l’OU est en cours" + FrenchText.Colon + "la lecture BitLocker attend sa fin. Rien n’a été lu.");
            }
            // One BitLocker read at a time: a second one (double click, two pages) is refused, so the flag that holds the
            // refreshes back can never be lowered by the first read while another one still runs.
            if (bitLockerReading)
            {
                throw new DomeniaOperationException(BitLockerRunning, BitLockerRunningMessage);
            }
            bitLockerReading = true;
        }
        BitLockerPresence presence;
        try
        {
            presence = await Reader.ReadBitLockerAsync(scope, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            lock (gate)
            {
                bitLockerReading = false;
            }
        }
        lock (gate)
        {
            bitlocker[ScopeKey(scope)] = presence;
            latest = null;
        }
        var state = await context.Directory.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var active = state.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(scope, c.DistinguishedName)).ToList();
        var withKey = active.Count(c => presence.Machines.TryGetValue(c.ObjectGuid, out var f) && f.Keys > 0);
        var read = presence.Truncated ? active.Count(c => presence.Machines.ContainsKey(c.ObjectGuid)) : active.Count;
        var text = !presence.ClassPresent
            ? "Classe de récupération BitLocker absente du schéma : présence non disponible dans ce domaine."
            : FleetBoardCalculator.Plural(withKey, "poste avec au moins une clé visible", "postes avec au moins une clé visible") + " sur " + FrenchText.Integer(active.Count)
              + " · " + FleetBoardCalculator.Plural(read - withKey, "sans clé visible", "sans clé visible") + (presence.Truncated ? " · lecture tronquée à 100 000 objets" : "") + ". Aucune clé n’est lue ni affichée.";
        context.Journal.Add(new JournalEntry(Now, "Présence BitLocker de l’OU " + scope.Label + FrenchText.Colon + FrenchText.Integer(withKey) + " postes avec clé sur " + FrenchText.Integer(active.Count), Tone.Ok));
        return new BitLockerSummary("OU " + scope.Label, read, withKey, read - withKey, presence.At, presence.Truncated, presence.ClassPresent, text);
    }

    private BitLockerPresence? BitLockerFor(ScopeSelection scope) => Covering(bitlocker.Values, scope);

    /// <summary>Newest BitLocker presence read kept by the local base that covers the scope (a read of the session wins).</summary>
    private static BitLockerPresence? StoredBitLocker(AccueilFacts facts, ScopeSelection scope) =>
        Covering(facts.BitLocker.OrderByDescending(p => p.At), scope);

    private static BitLockerPresence? Covering(IEnumerable<BitLockerPresence> reads, ScopeSelection scope)
    {
        foreach (var presence in reads)
        {
            var read = new ScopeSelection(presence.ScopeDn, presence.ScopeDn, presence.Subtree);
            if (ScopeRules.SameScope(read, scope) || (presence.Subtree && (HealthRules.SameDn(presence.ScopeDn, scope.Dn) || ScopeRules.Contains(read, scope.Dn))))
            {
                return presence;
            }
        }
        return null;
    }

    // ---------------------------------------------------------------- working OU: root, favourites

    /// <summary>accueil.scope.reset: back to the default working OU of the source (ACC-014), remembered like a choice.</summary>
    public async Task<SessionInfo> ResetScopeAsync(CancellationToken cancellationToken)
    {
        var raw = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var root = raw.Scope ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        await workingScope.SetAsync(raw, root.Dn, root.Subtree, cancellationToken).ConfigureAwait(false);
        await StopForScopeChangeAsync().ConfigureAwait(false);
        return await dashboard.GetSessionInfoAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>accueil.favorites: favourite working OUs of the domain, checked in the local OU index (never the network).</summary>
    public async Task<ScopeFavorites> FavoritesAsync(CancellationToken cancellationToken)
    {
        var raw = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var domainDn = raw.Domain?.RootDn ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        var stored = StoredFavorites(domainDn);
        var index = context.Readers.Find<IOrganizationalUnitIndex>();
        var items = new List<ScopeFavorite>();
        foreach (var f in stored)
        {
            var root = HealthRules.SameDn(f.Dn, domainDn);
            var entry = root || index is null ? null : await index.FindLocalAsync(f.Dn, cancellationToken).ConfigureAwait(false);
            var path = root ? raw.Domain?.DnsName ?? domainDn : entry?.Path ?? f.Dn;
            items.Add(new ScopeFavorite(f.Id, f.Name, f.Dn, f.Subtree, path, root || entry is not null));
        }
        return new ScopeFavorites([.. items], MaxFavorites);
    }

    /// <summary>accueil.favorite.save: adds or renames a favourite (LocalWrite), 12 at most.</summary>
    public async Task<ScopeFavorites> SaveFavoriteAsync(string name, string dn, bool subtree, CancellationToken cancellationToken)
    {
        var raw = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var domainDn = raw.Domain?.RootDn ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        var label = name.Trim();
        if (label.Length is < 1 or > 60 || label.Any(char.IsControl))
        {
            throw new DomeniaOperationException("favorite.invalid", "Nom de favori invalide : 1 à 60 caractères, sans caractère de contrôle.");
        }
        if (!HealthRules.IsInDomain(dn, domainDn))
        {
            throw new DomeniaOperationException(DomeniaErrors.ScopeOutsideDomain, DomeniaErrors.ScopeOutsideDomainMessage);
        }
        var root = HealthRules.SameDn(dn, domainDn);
        if (!root)
        {
            var index = context.Readers.Find<IOrganizationalUnitIndex>();
            if (index is null || await index.FindLocalAsync(dn, cancellationToken).ConfigureAwait(false) is null)
            {
                throw new DomeniaOperationException(DomeniaErrors.ScopeUnknown, "OU introuvable : le favori n’a pas été enregistré.");
            }
        }
        var list = StoredFavorites(domainDn).Where(f => !(HealthRules.SameDn(f.Dn, dn) && f.Subtree == (subtree || root))).ToList();
        if (list.Count >= MaxFavorites)
        {
            throw new DomeniaOperationException("favorite.full", "Douze favoris au plus : retirez-en un avant d’en ajouter un autre.");
        }
        list.Add(new StoredFavorite(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(6)), label, dn, subtree || root));
        await RememberAsync("accueil.favorites." + DomainHash(domainDn), JsonSerializer.SerializeToElement(list, Json), cancellationToken).ConfigureAwait(false);
        return await FavoritesAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>accueil.favorite.drop: removes a favourite (LocalWrite).</summary>
    public async Task<ScopeFavorites> DropFavoriteAsync(string id, CancellationToken cancellationToken)
    {
        var raw = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var domainDn = raw.Domain?.RootDn ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        var list = StoredFavorites(domainDn);
        if (list.All(f => f.Id != id))
        {
            throw new DomeniaOperationException("favorite.unknown", "Favori introuvable : rien n’a été retiré.");
        }
        await RememberAsync("accueil.favorites." + DomainHash(domainDn), JsonSerializer.SerializeToElement(list.Where(f => f.Id != id).ToList(), Json), cancellationToken).ConfigureAwait(false);
        return await FavoritesAsync(cancellationToken).ConfigureAwait(false);
    }

    private List<StoredFavorite> StoredFavorites(string domainDn)
    {
        if (!context.Preferences.TryGet("accueil.favorites." + DomainHash(domainDn), out var value))
        {
            return [];
        }
        try
        {
            return [.. (value.Deserialize<List<StoredFavorite>>(Json) ?? []).Where(f => f.Id.Length > 0 && f.Name.Length > 0 && f.Dn.Length > 0).Take(MaxFavorites)];
        }
        catch (JsonException)
        {
            context.Log.Warning("Favoris mémorisés illisibles : liste vide.");
            return [];
        }
    }

    // ---------------------------------------------------------------- first steps, help, last view

    /// <summary>accueil.firstSteps: the four steps of the first run (ACC-015, ACC-016) from what the session already knows.</summary>
    public async Task<FirstStepsInfo> FirstStepsAsync(CancellationToken cancellationToken)
    {
        var raw = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var session = await workingScope.ApplyAsync(raw, cancellationToken).ConfigureAwait(false);
        var connected = session.Connection != ConnectionState.Disconnected && session.Domain?.DnsName is not null;
        var offline = session.Connection == ConnectionState.Disconnected && session.Domain?.DnsName is not null;
        var scoped = session.Scope is not null;
        var read = false;
        var interrupted = false;
        if (connected && scoped && session.Domain?.RootDn is string rootDn)
        {
            var facts = await Reader.FactsAsync(cancellationToken).ConfigureAwait(false);
            var freshness = CollectionClocks.Directory(AllRuns(facts), session.Store, session.Scope!, rootDn, Now, Zone);
            read = freshness.At is not null && freshness.Status is "complete" or "partial";
            interrupted = freshness.Partial;
        }
        var prefs = ReadFirstSteps();
        var seen = prefs.DashboardSeen && read;
        var connectionText = connected
            ? "Connecté à " + session.Domain!.DnsName + " avec " + session.Account.Login + "."
            : offline ? "Hors connexion : reconnectez-vous pour poursuivre les premiers pas. Les données locales déjà enregistrées sont conservées." : "Se connecter à l’annuaire avec son compte habituel.";
        var ouText = scoped ? "OU de travail" + FrenchText.Colon + session.Scope!.Label + "." : "Choisir l’OU de travail : elle est le défaut des sections qui n’ont pas encore leur propre choix.";
        var baseText = read ? "Première lecture de cette OU enregistrée dans la base locale." : "Faire la première lecture de cette OU dans la base locale (menu de « Tout actualiser », « Mettre à jour la base locale de l’OU »).";
        if (interrupted)
        {
            baseText = read
                ? "Dernière tentative interrompue : la lecture complète précédente de cette OU reste disponible. Actualisez la base pour la compléter."
                : "Lecture de cette OU interrompue ou incomplète : reprenez-la. Les données déjà enregistrées sont conservées ; la couverture complète reste inconnue.";
        }
        var dashboardText = seen ? "Vue d’ensemble calculée depuis la base locale ; une tuile ouvre la liste exacte de ses postes." : "Ouvrir le tableau de bord : le calcul part à ce clic, depuis la base locale, puis la vue s’affiche.";
        var raws = new (string Id, string Label, string Text, bool Done, bool Enabled, string Action)[]
        {
            ("connect", "Connexion à l’annuaire", connectionText, connected, true, "Voir la session"),
            ("scope", "Choix de l’OU de travail", ouText, scoped, connected, "Choisir l’OU"),
            ("firstRead", "Première lecture", baseText, read, connected && scoped, "Mettre à jour la base locale"),
            ("dashboard", "Tableau de bord", dashboardText, seen, read, "Voir le tableau de bord"),
        };
        string? next = raws.Where(r => !r.Done).Select(r => r.Id).FirstOrDefault();
        var steps = raws.Select((r, i) => new FirstStep(r.Id, i + 1, r.Label, r.Text, r.Done, r.Enabled, r.Id == next, r.Action)).ToList();
        bool passed;
        lock (gate)
        {
            passed = selfCheckPassed;
        }
        // Optional fifth step (improvement of ACC-015): check the application and the rights once.
        steps.Add(new FirstStep("rights", 5, "Vérifier l’application", passed ? "Vérification de l’application passée pendant cette session." : "Facultatif : lancer « Vérifier l’application » pour contrôler la session, la base et les préférences.",
            passed, true, false, "Vérifier l’application"));
        var completed = raws.Count(r => r.Done);
        // Once the four steps are done, the card goes away for good (Home.FirstStepsDone); only the help shows it again.
        var finished = prefs.Finished;
        if (completed == raws.Length && !finished)
        {
            finished = true;
            await RememberAsync(FirstStepsPreference, MergeFirstSteps(finished: true), cancellationToken).ConfigureAwait(false);
        }
        return new FirstStepsInfo([.. steps], next, next is null, "Plus tard, au moment où ils servent" + FrenchText.Colon + "le compte pour les postes (Comptes et accès) et les sauvegardes de la base locale.",
            prefs.Dismissed, ReadHelpSeen(), interrupted, offline, completed, raws.Length, finished);
    }

    /// <summary>accueil.firstSteps.dismiss: hides or shows the first steps card again (LocalWrite).</summary>
    public async Task<FirstStepsInfo> DismissFirstStepsAsync(bool dismissed, CancellationToken cancellationToken)
    {
        await RememberAsync(FirstStepsPreference, MergeFirstSteps(dismissed: dismissed), cancellationToken).ConfigureAwait(false);
        return await FirstStepsAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>accueil.help.seen: the help of the page was opened once; the « Nouveau » mark goes away (ACC-017).</summary>
    public async Task<bool> HelpSeenAsync(CancellationToken cancellationToken)
    {
        if (!ReadHelpSeen())
        {
            await RememberAsync(HelpPreference, JsonSerializer.SerializeToElement(true), cancellationToken).ConfigureAwait(false);
        }
        return true;
    }

    private bool ReadHelpSeen() => context.Preferences.TryGet(HelpPreference, out var value) && value.ValueKind == JsonValueKind.True;

    private StoredFirstSteps ReadFirstSteps()
    {
        if (context.Preferences.TryGet(FirstStepsPreference, out var value))
        {
            try
            {
                return value.Deserialize<StoredFirstSteps>(Json) ?? new StoredFirstSteps(false, false);
            }
            catch (JsonException)
            {
                context.Log.Warning("Préférence accueil.firstSteps illisible" + FrenchText.Colon + "premiers pas affichés.");
            }
        }
        return new StoredFirstSteps(false, false);
    }

    private JsonElement MergeFirstSteps(bool? dismissed = null, bool? dashboardSeen = null, bool? finished = null)
    {
        var current = ReadFirstSteps();
        return JsonSerializer.SerializeToElement(new StoredFirstSteps(dismissed ?? current.Dismissed, dashboardSeen ?? current.DashboardSeen, finished ?? current.Finished), Json);
    }

    /// <summary>accueil.lastView: the last overview computed for the same base and OU, dated, never presented as current.</summary>
    public async Task<LastViewNotice> LastViewAsync(CancellationToken cancellationToken)
    {
        var (_, scope, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        var facts = await Reader.FactsAsync(cancellationToken).ConfigureAwait(false);
        var none = new LastViewNotice(false, "Lancez « Recalculer la vue » : le tableau du parc se remplit depuis la base locale.", null, -1, -1, null);
        if (!context.Preferences.TryGet("accueil.lastView." + DomainHash(domainDn), out var value))
        {
            return none;
        }
        StoredLastView? view;
        try
        {
            view = value.Deserialize<StoredLastView>(Json);
        }
        catch (JsonException)
        {
            return none;
        }
        if (view is null || view.Version != 1 || view.StoreId != facts.StoreId || view.ScopeKey != ScopeKey(scope) || view.ComputedUtc > Now + TimeSpan.FromMinutes(5) || view.Machines < 0)
        {
            return none;
        }
        var count = FleetBoardCalculator.Plural(view.Machines, "poste actif", "postes actifs") + (view.Problems >= 0 && view.Problems <= view.Machines ? ", dont " + FrenchText.Integer(view.Problems) + " à traiter" : "");
        var text = "Dernière vue enregistrée, non recalculée : calcul du " + CollectionClocks.Local(view.ComputedUtc, Zone) + ", " + count + "."
            + (view.Observations.Length > 0 ? "\n" + view.Observations : "") + "\nLancez « Recalculer la vue » pour l’actualiser depuis la base locale.";
        return new LastViewNotice(true, text, view.ComputedUtc, view.Machines, view.Problems, view.ScopeName);
    }

    /// <summary>accueil.lastView.save: keeps the summary of the calculation <paramref name="revision"/> for the next start (LocalWrite).</summary>
    public async Task<LastViewNotice> SaveLastViewAsync(string revision, CancellationToken cancellationToken)
    {
        FleetComputation? computation;
        lock (gate)
        {
            computation = latest;
        }
        if (computation is null || computation.Board.Revision != revision)
        {
            throw new DomeniaOperationException(BoardReplaced, "Vue remplacée par un calcul plus récent : rien n’a été enregistré.");
        }
        var (_, _, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        var board = computation.Board;
        var observations = "Mesures" + FrenchText.Colon + FleetBoardCalculator.Plural(board.Snapshot.Figures.PingRead, "poste relevé par ping", "postes relevés par ping")
            + ", " + FleetBoardCalculator.Plural(board.Snapshot.Figures.WmiRead, "inventaire WMI", "inventaires WMI") + ".";
        // Written when the counts change, else at most once a minute (the board is computed every 15 s during a refresh).
        var key = string.Join("|", domainDn, board.Population.StoreId, ScopeKey(board.Scope), board.Snapshot.Figures.Machines, board.Snapshot.Figures.Problems, observations);
        var now = Now;
        bool skip;
        lock (gate)
        {
            skip = lastViewSaved is { } saved && saved.Key == key && now - saved.SavedAt < LastViewInterval;
            if (!skip)
            {
                lastViewSaved = (key, now);
            }
        }
        if (!skip)
        {
            var stored = new StoredLastView(1, board.Population.StoreId, ScopeKey(board.Scope), board.ScopeLabel.Length > 256 ? board.ScopeLabel[..256] : board.ScopeLabel,
                board.ComputedAt, board.Snapshot.Figures.Machines, board.Snapshot.Figures.Problems, observations);
            await RememberAsync("accueil.lastView." + DomainHash(domainDn), JsonSerializer.SerializeToElement(stored, Json), cancellationToken).ConfigureAwait(false);
        }
        return await LastViewAsync(cancellationToken).ConfigureAwait(false);
    }

    // ---------------------------------------------------------------- session tools (ACC-019)

    /// <summary>accueil.selfCheck: « Vérifier l’application », read only.</summary>
    public async Task<SelfCheckResult> SelfCheckAsync(CancellationToken cancellationToken)
    {
        var checks = new List<SelfCheckItem>();
        var now = Now;
        checks.Add(new SelfCheckItem("mode", "Mode de fonctionnement", Tone.Info, context.Decision.Mode == AppMode.Simulation ? "Simulation : " + context.Decision.Detail : "Annuaire Active Directory : " + context.Decision.Detail));
        SessionSnapshot? session = null;
        try
        {
            var raw = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
            session = await workingScope.ApplyAsync(raw, cancellationToken).ConfigureAwait(false);
            checks.Add(new SelfCheckItem("source", "Source de l’annuaire", session.Connection == ConnectionState.Disconnected ? Tone.Alert : Tone.Ok,
                SessionTexts.ConnectionLabel(session.Connection) + (session.Domain?.DnsName is string dns ? " · " + dns : "") + (session.Controller is ControllerIdentity dc ? " · " + dc.DnsName : "")));
        }
        catch (DomeniaOperationException ex)
        {
            checks.Add(new SelfCheckItem("source", "Source de l’annuaire", Tone.Alert, ex.Message));
        }
        var watch = Stopwatch.StartNew();
        try
        {
            var state = await context.Directory.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
            watch.Stop();
            checks.Add(new SelfCheckItem("local", "Lecture locale", state.Directory.Complete ? Tone.Ok : Tone.Warn,
                FleetBoardCalculator.Plural(state.Directory.ObjectCount, "objet", "objets") + " lus en " + FrenchText.Integer(watch.ElapsedMilliseconds) + " ms" + (state.Directory.Complete ? " · lecture complète" : " · lecture incomplète : chiffres possiblement sous-estimés")));
            var future = state.Directory.ReadAt > now + CollectionClocks.ClockTolerance;
            checks.Add(new SelfCheckItem("clock", "Horloge du poste", future ? Tone.Alert : Tone.Ok,
                future ? "Date de lecture postérieure à l’horloge du poste : vérifier l’heure de Windows." : "Aucune date future dans la base locale (tolérance de 2 minutes)."));
        }
        catch (DomeniaOperationException ex)
        {
            checks.Add(new SelfCheckItem("local", "Lecture locale", Tone.Alert, ex.Message));
        }
        if (session?.Scope is ScopeSelection scope)
        {
            var root = session.Domain?.RootDn is string r && ScopeRules.IsDomainRoot(scope, r);
            checks.Add(new SelfCheckItem("scope", "OU de travail", root ? Tone.Warn : Tone.Ok,
                root ? "Tout le domaine : consultation seulement, les mesures de postes restent refusées." : scope.Label + (scope.Subtree ? " et ses sous-OU" : " sans les sous-OU") + " · vérifiée dans l’index local des OU."));
        }
        else
        {
            checks.Add(new SelfCheckItem("scope", "OU de travail", Tone.Warn, "Aucune OU de travail : la mesure des postes attend une OU."));
        }
        checks.Add(new SelfCheckItem("preferences", "Préférences locales", context.Preferences.Persistent ? Tone.Ok : Tone.Info,
            context.Preferences.Persistent ? "Enregistrées dans le dossier de données de Domenia (%LOCALAPPDATA%\\Domenia)." : "En mémoire seulement pour cette session (capture, E2E ou dossier de données indisponible)."));
        try
        {
            var log = await context.Receipts.ReadAllAsync(cancellationToken).ConfigureAwait(false);
            checks.Add(new SelfCheckItem("receipts", "Reçus d’écriture", log.Unreadable > 0 ? Tone.Warn : Tone.Ok,
                FleetBoardCalculator.Plural(log.Receipts.Length, "reçu conservé", "reçus conservés") + (log.Unreadable > 0 ? " · " + FleetBoardCalculator.Plural(log.Unreadable, "enregistrement illisible ignoré", "enregistrements illisibles ignorés") : "")
                + (context.Receipts.Persistent ? "" : " · en mémoire seulement")));
        }
        catch (IOException)
        {
            checks.Add(new SelfCheckItem("receipts", "Reçus d’écriture", Tone.Alert, "Reçus illisibles pour l’instant : aucune écriture ne sera préparée tant qu’ils ne sont pas relus."));
        }
        var readers = context.Readers.Interfaces;
        checks.Add(new SelfCheckItem("readers", "Lecteurs d’écran", readers.Count > 0 ? Tone.Ok : Tone.Alert,
            readers.Count > 0 ? FleetBoardCalculator.Plural(readers.Count, "interface servie", "interfaces servies") + FrenchText.Colon + string.Join(", ", readers) : "Aucun lecteur pour la source de ce mode."));
        checks.Add(new SelfCheckItem("writers", "Exécuteurs d’écriture", Tone.Info,
            context.Writers.Kinds.Count > 0 ? FleetBoardCalculator.Plural(context.Writers.Kinds.Count, "type d’écriture servi", "types d’écriture servis") + FrenchText.Colon + string.Join(", ", context.Writers.Kinds) : "Aucune écriture servie dans ce mode."));
        var contracts = ProbeCatalog.All.Select(ProbeCatalog.Contract).ToList();
        var refused = contracts.Count(c => !c.Valid);
        checks.Add(new SelfCheckItem("probes", "Catalogue des sondes WMI", refused > 0 ? Tone.Warn : Tone.Ok,
            FleetBoardCalculator.Plural(contracts.Count, "sonde", "sondes") + " · " + FleetBoardCalculator.Plural(contracts.Count - refused, "contrat valide", "contrats valides") + (refused > 0 ? " · " + FleetBoardCalculator.Plural(refused, "refus", "refus") : "")
            + " · documentation revue le 13/10/2026."));
        checks.Add(new SelfCheckItem("lifecycle", "Table des fins de service", Tone.Info, FleetBoardCalculator.Plural(WindowsLifecycle.Entries.Length, "ligne", "lignes") + " · revue le 08/10/2026 · livrée avec Domenia, jamais téléchargée."));
        checks.Add(new SelfCheckItem("journal", "Journal des opérations", Tone.Ok, FleetBoardCalculator.Plural(context.Journal.Snapshot().Length, "entrée de la session", "entrées de la session") + " (200 au plus)."));
        var failures = checks.Count(c => c.Tone == Tone.Alert);
        var warnings = checks.Count(c => c.Tone == Tone.Warn);
        var ok = checks.Count - failures - warnings;
        lock (gate)
        {
            selfCheckPassed |= failures == 0;
        }
        var summary = failures > 0 ? FleetBoardCalculator.Plural(failures, "contrôle en échec", "contrôles en échec") + " : voir le détail."
            : warnings > 0 ? FleetBoardCalculator.Plural(warnings, "point à surveiller", "points à surveiller") + ", aucun échec."
            : "Tous les contrôles sont passés.";
        var tone = failures > 0 ? Tone.Alert : warnings > 0 ? Tone.Warn : Tone.Ok;
        lock (gate)
        {
            lastCheck = new SelfCheckSummary(now, summary, tone);
        }
        context.Journal.Add(new JournalEntry(now, "Vérification de l’application" + FrenchText.Colon + summary.TrimEnd('.'), tone));
        return new SelfCheckResult(now, ok, warnings, failures, summary, [.. checks]);
    }

    /// <summary>accueil.cache.clear: empties the caches of the page in memory (calculations, exact sets, cross tables); never a measure.</summary>
    public CacheClearResult ClearCache()
    {
        var items = new List<CacheClearItem>();
        lock (gate)
        {
            items.Add(new CacheClearItem("Calcul du tableau du parc et ensembles exacts", latest is null ? 0 : latest.Targets.Count));
            items.Add(new CacheClearItem("Tableaux croisés", pivots.Count));
            items.Add(new CacheClearItem("Historique des instantanés relu", historyCache.Count));
            items.Add(new CacheClearItem("Disposition et règles relues des préférences", (layout is null ? 0 : 1) + (book is null ? 0 : 1)));
            latest = null;
            pivots.Clear();
            historyCache.Clear();
            layout = null;
            book = null;
        }
        context.Journal.Add(new JournalEntry(Now, "Cache de l’Accueil vidé" + FrenchText.Colon + "aucune mesure perdue, aucun objet Active Directory modifié", Tone.Info));
        return new CacheClearResult([.. items], "Cache vidé : la prochaine vue se recalcule depuis la base locale. Les mesures relevées et les préférences sont conservées ; aucun objet Active Directory n’est modifié.");
    }

    /// <summary>accueil.journal: the operations journal of the session and the journal kept by the source, newest first.</summary>
    public async Task<JournalView> JournalAsync(CancellationToken cancellationToken)
    {
        var state = await context.Directory.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var rows = context.Journal.Snapshot().AddRange(state.Journal).OrderByDescending(e => e.At).ToImmutableArray();
        return new JournalView(rows.Length, rows);
    }

    /// <summary>accueil.session.details: what « Détails de la session » adds to session.info (ACC-019), read in memory or locally.</summary>
    public async Task<SessionDetails> SessionDetailsAsync(CancellationToken cancellationToken)
    {
        var facts = await Reader.FactsAsync(cancellationToken).ConfigureAwait(false);
        var (_, _, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        LoadPersisted(domainDn);
        lock (gate)
        {
            var text = facts.Associations > 0
                ? FleetBoardCalculator.Plural(facts.Associations, "lien utilisateur–poste connu", "liens utilisateur–poste connus") + " dans " + (context.Directory.Kind == DirectorySourceKind.Simulation ? "l’annuaire fictif" : "la base locale")
                : "Aucun lien utilisateur–poste enregistré";
            return new SessionDetails(facts.Associations, text, lastCheck, [.. calculations.Select(c => new CalculationTime(c.At, c.Milliseconds))], localWriteFailures,
                facts.Runs.Length + sessionRuns.Count, manualSnapshots.Count + dailySnapshots.Count);
        }
    }

    // ---------------------------------------------------------------- local records (ACC-022, ACC-040)

    /// <summary>
    /// Reads back, once per domain, the collection runs and the snapshots kept in the local preferences: every run is admitted
    /// again by <see cref="CollectionClocks.Create"/> (a date in the future or outside the domain is dropped), 300 runs at most.
    /// </summary>
    private void LoadPersisted(string domainDn)
    {
        lock (gate)
        {
            if (persistedDomain is not null && HealthRules.SameDn(persistedDomain, domainDn))
            {
                return;
            }
            persistedDomain = domainDn;
            sessionRuns.Clear();
            dailySnapshots.Clear();
            manualSnapshots.Clear();
        }
        var now = Now;
        var runs = new List<CollectionRun>();
        var refused = 0;
        if (context.Preferences.TryGet(RunsPreference + DomainHash(domainDn), out var value))
        {
            try
            {
                foreach (var r in value.Deserialize<StoredRuns>(Json)?.Runs ?? [])
                {
                    try
                    {
                        runs.Add(CollectionClocks.Create(r.Family, domainDn, r.ScopeDn, r.Subtree, r.Status, r.StartedAt, r.FinishedAt, r.Error, r.Targets, r.Done, r.Succeeded, r.Failed, r.Controller, now));
                    }
                    catch (ArgumentException)
                    {
                        // Refused by the admission rules (future date, outside the domain…): never shown, never replayed.
                        refused++;
                    }
                }
            }
            catch (JsonException)
            {
                context.Log.Warning("Relevés enregistrés illisibles" + FrenchText.Colon + "liste vide.");
            }
            if (refused > 0)
            {
                context.Log.Warning(FleetBoardCalculator.Plural(refused, "relevé enregistré écarté", "relevés enregistrés écartés") + " à la relecture (date future ou hors du domaine).");
            }
        }
        var daily = new Dictionary<string, FleetSnapshot>(StringComparer.Ordinal);
        var manual = new List<(string ScopeKey, FleetSnapshot Snapshot)>();
        if (context.Preferences.TryGet(SnapshotsPreference + DomainHash(domainDn), out var snaps))
        {
            try
            {
                var stored = snaps.Deserialize<StoredSnapshots>(Json);
                foreach (var d in stored?.Daily ?? [])
                {
                    if (d.Snapshot is { } snap && snap.ComputedAt <= now + CollectionClocks.ClockTolerance && d.ScopeKey.Length > 0)
                    {
                        daily[d.ScopeKey + "|" + snap.Day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)] = snap with { Kind = "daily" };
                    }
                }
                foreach (var m in stored?.Manual ?? [])
                {
                    if (m.Snapshot is { } snap && snap.ComputedAt <= now + CollectionClocks.ClockTolerance && m.ScopeKey.Length > 0)
                    {
                        manual.Add((m.ScopeKey, snap with { Kind = "manual" }));
                    }
                }
            }
            catch (JsonException)
            {
                context.Log.Warning("Instantanés enregistrés illisibles" + FrenchText.Colon + "historique de la base seulement.");
            }
        }
        lock (gate)
        {
            sessionRuns.InsertRange(0, runs.OrderBy(r => r.FinishedAt).TakeLast(MaxStoredRuns));
            foreach (var (k, v) in daily)
            {
                dailySnapshots.TryAdd(k, v);
            }
            manualSnapshots.InsertRange(0, manual.TakeLast(MaxManualSnapshots));
        }
    }

    /// <summary>Keeps the 300 newest runs of the domain in the local preferences (LocalWrite, never the directory).</summary>
    private async Task PersistRunsAsync(string domainDn, CancellationToken cancellationToken)
    {
        StoredRuns stored;
        lock (gate)
        {
            stored = new StoredRuns(1, [.. sessionRuns.OrderBy(r => r.FinishedAt).TakeLast(MaxStoredRuns).Select(r => new StoredRun(r.Family, r.ScopeDn, r.Subtree, r.Status,
                r.StartedAt, r.FinishedAt, r.Error, r.Targets, r.Done, r.Succeeded, r.Failed, r.Controller))]);
        }
        await RememberAsync(RunsPreference + DomainHash(domainDn), JsonSerializer.SerializeToElement(stored, Json), cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Keeps the daily snapshots (90 days of the 4 most recent OUs) and the manual snapshots (20) of the domain in the local
    /// preferences: counts and fingerprints only, never a workstation name.
    /// </summary>
    private async Task PersistSnapshotsAsync(string domainDn, CancellationToken cancellationToken)
    {
        StoredSnapshots stored;
        lock (gate)
        {
            var oldest = LocalDays.DateOf(Now, Zone).AddDays(-MaxDailyDays);
            var scopes = dailySnapshots.GroupBy(p => p.Key[..p.Key.LastIndexOf('|')], StringComparer.Ordinal)
                .OrderByDescending(g => g.Max(p => p.Value.ComputedAt)).Take(MaxDailyScopes).Select(g => g.Key).ToHashSet(StringComparer.Ordinal);
            foreach (var stale in dailySnapshots.Where(p => p.Value.Day < oldest || !scopes.Contains(p.Key[..p.Key.LastIndexOf('|')])).Select(p => p.Key).ToList())
            {
                dailySnapshots.Remove(stale);
            }
            stored = new StoredSnapshots(1,
                [.. dailySnapshots.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => new StoredSnapshot(p.Key[..p.Key.LastIndexOf('|')], p.Value))],
                [.. manualSnapshots.TakeLast(MaxManualSnapshots).Select(m => new StoredSnapshot(m.ScopeKey, m.Snapshot))]);
        }
        await RememberAsync(SnapshotsPreference + DomainHash(domainDn), JsonSerializer.SerializeToElement(stored, Json), cancellationToken).ConfigureAwait(false);
    }

    public void Dispose()
    {
        persist.Dispose();
        StopRunForDispose();
    }

    // ---------------------------------------------------------------- shared helpers

    /// <summary>Session with its working OU, the scope (required) and the domain root.</summary>
    private async Task<(SessionSnapshot Session, ScopeSelection Scope, string DomainDn)> ScopeAsync(CancellationToken cancellationToken)
    {
        var raw = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var session = await workingScope.ApplyAsync(raw, cancellationToken).ConfigureAwait(false);
        var domainDn = session.Domain?.RootDn ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        var scope = session.Scope ?? throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, DomeniaErrors.ScopeTooWideMessage);
        return (session, scope, domainDn);
    }

    public static string ScopeKey(ScopeSelection scope)
    {
        ArgumentNullException.ThrowIfNull(scope);
        return CollectionClocks.Key(scope.Dn, scope.Subtree);
    }

    /// <summary>SHA-256 of the canonical root DN, as the working OU preference (one value per domain).</summary>
    public static string DomainHash(string rootDn)
    {
        string canonical;
        try
        {
            canonical = DistinguishedName.Format(DistinguishedName.Parse(rootDn)).ToUpperInvariant();
        }
        catch (FormatException)
        {
            canonical = rootDn.ToUpperInvariant();
        }
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
    }

    /// <summary>
    /// Writes one preference; a failure never fails the operation: the value stays for the session and the journal says so
    /// (PLATFORM.md § 5).
    /// </summary>
    private async Task RememberAsync(string key, JsonElement value, CancellationToken cancellationToken)
    {
        await persist.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await context.Preferences.SetAsync(key, value, cancellationToken).ConfigureAwait(false);
            lock (gate)
            {
                localWriteFailures = 0;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            lock (gate)
            {
                localWriteFailures++;
            }
            context.Log.Warning("Préférences non enregistrées (accueil)" + FrenchText.Colon + ex.GetType().Name + ".");
            context.Journal.Add(new JournalEntry(Now, "Préférences non enregistrées" + FrenchText.Colon + "le choix vaut pour cette session", Tone.Warn));
        }
        finally
        {
            persist.Release();
        }
    }

    private static JsonSerializerOptions CreateJson()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = false };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return options;
    }

    private sealed record StoredLayout(int Version, StoredItem[] Items);

    private sealed record StoredItem(string? Id, FleetWidgetSource Source, string Key, string? Visual, string? Size, string? Title, bool Paused)
    {
        public static StoredItem From(FleetLayoutItem item) => new(item.Id, item.Source, item.Key, item.Visual, item.Size, item.Title, item.Paused);

        public FleetLayoutItem ToItem() => new(Id ?? "", Source, Key ?? "", Visual ?? "", Size ?? "M", Title, Paused, "");
    }

    private sealed record StoredFavorite(string Id, string Name, string Dn, bool Subtree);

    private sealed record StoredFirstSteps(bool Dismissed, bool DashboardSeen, bool Finished = false);

    private sealed record StoredRun(CollectionFamily Family, string ScopeDn, bool Subtree, CollectionStatus Status, DateTimeOffset StartedAt, DateTimeOffset FinishedAt,
        string? Error, long? Targets, long? Done, long? Succeeded, long? Failed, string? Controller);

    private sealed record StoredRuns(int Version, StoredRun[] Runs);

    private sealed record StoredSnapshot(string ScopeKey, FleetSnapshot? Snapshot);

    private sealed record StoredSnapshots(int Version, StoredSnapshot[] Daily, StoredSnapshot[] Manual);

    private sealed record StoredLastView(int Version, string StoreId, string ScopeKey, string ScopeName, DateTimeOffset ComputedUtc, int Machines, int Problems, string Observations);
}
