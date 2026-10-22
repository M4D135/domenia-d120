using System.Collections.Immutable;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Home page state of the session (docs/OPERATIONS.md § 3 to 7): disabled widgets, last known state, journal and read
/// counters; refreshes run one after another. The disabled widgets are remembered in the local preferences (key
/// dashboard.disabledWidgets, LocalWrite) and restored at the first call; the working OU comes from <see cref="WorkingScope"/>.
/// </summary>
public sealed class DashboardService : IDisposable
{
    /// <summary>Preference key of the disabled widgets: array of widget identifiers, catalog order.</summary>
    public const string DisabledWidgetsPreference = "dashboard.disabledWidgets";

    private static readonly (string Id, string Label)[] OnboardingSteps =
    [
        ("connect", "Connexion à l’annuaire"),
        ("scope", "Choix de l’OU de travail"),
        ("firstRead", "Première lecture"),
        ("dashboard", "Tableau de bord"),
    ];

    private readonly IDirectorySource source;
    private readonly OperationJournal journal;
    private readonly TimeProvider timeProvider;
    private readonly DashboardPolicy policy;
    private readonly WorkingScope? workingScope;
    private readonly IPreferenceStore? preferences;
    private readonly ITechnicalJournal log;
    private readonly SemaphoreSlim refreshGate = new(1, 1);
    private readonly SemaphoreSlim persistGate = new(1, 1);
    private readonly Lock gate = new();
    private int preferencesLoaded;
    private ImmutableHashSet<string> disabled = ImmutableHashSet.Create<string>(StringComparer.Ordinal);
    private DirectoryState? lastState;
    // Bumped at every store of lastState, so a summary that overlapped a refresh never brings back an older state.
    private long stateVersion;
    private int running;
    private int queued;
    // Widget refreshes and OU measures holding (or waiting for) the refresh gate; the summary's own read is not counted.
    private int measuring;
    private bool summaryDone;

    /// <param name="workingScope">Working OU of the session; without it, the default scope of the source.</param>
    /// <param name="preferences">Where the disabled widgets are remembered; without it, they last for the session only.</param>
    public DashboardService(
        IDirectorySource source,
        OperationJournal journal,
        TimeProvider timeProvider,
        DashboardPolicy? policy = null,
        WorkingScope? workingScope = null,
        IPreferenceStore? preferences = null,
        ITechnicalJournal? log = null)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(journal);
        ArgumentNullException.ThrowIfNull(timeProvider);
        this.source = source;
        this.journal = journal;
        this.timeProvider = timeProvider;
        this.policy = policy ?? DashboardPolicy.Default;
        this.workingScope = workingScope;
        this.preferences = preferences;
        this.log = log ?? SilentTechnicalJournal.Instance;
    }

    /// <summary>The home page service shared by every module of the context.</summary>
    public static DashboardService From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new DashboardService(c.Directory, c.Journal, c.Clock, null, WorkingScope.From(c), c.Preferences, c.Log));
    }

    /// <summary>session.info: session of the source plus counters, local base state and onboarding.</summary>
    public async Task<SessionInfo> GetSessionInfoAsync(CancellationToken cancellationToken)
    {
        var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
        var now = timeProvider.GetUtcNow();
        var store = session.Store;
        var cacheState = store.LastReadAt switch
        {
            null => CacheState.Empty,
            DateTimeOffset read when now - read < TimeSpan.FromDays(1) => CacheState.Fresh,
            DateTimeOffset read when now - read <= TimeSpan.FromDays(7) => CacheState.Aging,
            _ => CacheState.Stale,
        };
        bool dashboardDone;
        lock (gate)
        {
            dashboardDone = summaryDone;
        }
        bool[] done =
        [
            session.Connection != ConnectionState.Disconnected,
            session.Scope is not null,
            store.LastReadAt is not null,
            dashboardDone,
        ];
        var steps = OnboardingSteps.Select((s, i) => new OnboardingStep(s.Id, s.Label, done[i])).ToImmutableArray();
        return new SessionInfo(
            new SessionConnection(session.Connection, SessionTexts.ConnectionLabel(session.Connection)),
            session.Domain,
            session.Controller,
            session.Account,
            session.Authentication,
            session.Scope,
            session.Rights,
            session.ReadOnly,
            new TaskCounters(Volatile.Read(ref running), Volatile.Read(ref queued)),
            new CacheInfo(cacheState, SessionTexts.CacheLabel(cacheState), store.LastReadAt, store.Objects, store.Complete),
            new OnboardingInfo(steps, done.Count(d => d), steps.Length));
    }

    /// <summary>dashboard.summary: every widget from the last known state; never measures anything.</summary>
    public async Task<DashboardSummary> GetSummaryAsync(CancellationToken cancellationToken)
    {
        LoadPreferences();
        var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
        long versionAtRead;
        lock (gate)
        {
            versionAtRead = stateVersion;
        }
        DirectoryState state;
        Interlocked.Increment(ref running);
        try
        {
            state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            Interlocked.Decrement(ref running);
        }
        var scope = RequireScope(session);
        var summary = DashboardCalculator.Compute(Input(state, scope, session));
        lock (gate)
        {
            // A refresh (or another summary) stored a state since this read started: that one is at least as recent.
            if (stateVersion == versionAtRead)
            {
                lastState = state;
                stateVersion++;
            }
            summaryDone = true;
        }
        return summary;
    }

    /// <summary>dashboard.widget.refresh: measures the widget's family again, then returns the widget.</summary>
    public async Task<DashboardWidget> RefreshAsync(string widgetId, CancellationToken cancellationToken)
    {
        if (!WidgetCatalog.TryGet(widgetId, out var definition))
        {
            throw new DomeniaOperationException(DomeniaErrors.WidgetUnknown, DomeniaErrors.WidgetUnknownReadMessage);
        }
        LoadPreferences();
        if (IsDisabled(definition.Id))
        {
            throw new DomeniaOperationException(DomeniaErrors.WidgetDisabled, DomeniaErrors.WidgetDisabledMessage);
        }
        Interlocked.Increment(ref queued);
        Interlocked.Increment(ref measuring);
        try
        {
            await refreshGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            Interlocked.Decrement(ref measuring);
            throw;
        }
        finally
        {
            Interlocked.Decrement(ref queued);
        }
        Interlocked.Increment(ref running);
        try
        {
            var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
            if (IsDisabled(definition.Id))
            {
                // Disabled while waiting: nothing is read.
                return DashboardCalculator.Disabled(definition, Label(definition, session));
            }
            var family = definition.Family switch
            {
                WidgetFamily.Directory => MeasureFamily.Directory,
                WidgetFamily.Presence => MeasureFamily.Presence,
                WidgetFamily.Inventory => MeasureFamily.Inventory,
                _ => MeasureFamily.LocalComputation,
            };
            // Workstation measures are bounded to the working OU (never the domain root, checked by the source).
            var state = await source.RefreshAsync(family, session.Scope, cancellationToken).ConfigureAwait(false);
            var scope = RequireScope(session);
            lock (gate)
            {
                // Refreshes run one after another: the state of the latest one is the most recent.
                lastState = state;
                stateVersion++;
            }
            journal.Add(new JournalEntry(timeProvider.GetUtcNow(), "Actualisation" + FrenchText.Colon + definition.Title, Tone.Ok));
            if (IsDisabled(definition.Id))
            {
                // Disabled during the measure: the result is not published.
                return DashboardCalculator.Disabled(definition, Label(definition, session));
            }
            return DashboardCalculator.ComputeWidget(definition.Id, Input(state, scope, session));
        }
        finally
        {
            Interlocked.Decrement(ref running);
            Interlocked.Decrement(ref measuring);
            refreshGate.Release();
        }
    }

    /// <summary>
    /// Measures one family again for an explicit refresh of the working OU (accueil.refresh.run, docs/ops/accueil.md § 5): same
    /// gate as the widget refreshes (one after another) and same state in memory, so every widget sees the new readings. Bounded
    /// to the working OU by the source (never the domain root). Returns the new state; the caller writes the journal.
    /// </summary>
    public Task<DirectoryState> MeasureAsync(MeasureFamily family, CancellationToken cancellationToken) =>
        MeasureAsync((session, token) => source.RefreshAsync(family, session.Scope, token), cancellationToken);

    /// <summary>
    /// Runs a measure of the explicit OU refresh that the source alone cannot express (WMI of the workstations that answered the
    /// ping only, ACC-004), under the same gate as every other measure, and keeps its state as the last known one.
    /// </summary>
    public async Task<DirectoryState> MeasureAsync(Func<SessionSnapshot, CancellationToken, Task<DirectoryState>> measure, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(measure);
        Interlocked.Increment(ref queued);
        Interlocked.Increment(ref measuring);
        try
        {
            await refreshGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            Interlocked.Decrement(ref measuring);
            throw;
        }
        finally
        {
            Interlocked.Decrement(ref queued);
        }
        Interlocked.Increment(ref running);
        try
        {
            var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
            var state = await measure(session, cancellationToken).ConfigureAwait(false);
            lock (gate)
            {
                lastState = state;
                stateVersion++;
            }
            return state;
        }
        finally
        {
            Interlocked.Decrement(ref running);
            Interlocked.Decrement(ref measuring);
            refreshGate.Release();
        }
    }

    /// <summary>Widget refreshes and OU measures running or waiting: an explicit OU refresh is refused meanwhile (ACC-001).</summary>
    public int Measuring => Volatile.Read(ref measuring);

    /// <summary>
    /// dashboard.widget.setEnabled: idempotent; a change is remembered in the preferences (LocalWrite) and kept for the
    /// session even if the preferences cannot be written (journal entry). Enabling reuses the last state in memory.
    /// </summary>
    public async Task<DashboardWidget> SetEnabledAsync(string widgetId, bool enabled, CancellationToken cancellationToken)
    {
        if (!WidgetCatalog.TryGet(widgetId, out var definition))
        {
            throw new DomeniaOperationException(DomeniaErrors.WidgetUnknown, DomeniaErrors.WidgetUnknownChangeMessage);
        }
        LoadPreferences();
        bool changed;
        DirectoryState? state;
        lock (gate)
        {
            var next = enabled ? disabled.Remove(definition.Id) : disabled.Add(definition.Id);
            changed = !ReferenceEquals(next, disabled);
            disabled = next;
            state = lastState;
        }
        if (changed)
        {
            var label = (enabled ? "Mesure réactivée" : "Mesure désactivée") + FrenchText.Colon + definition.Title;
            journal.Add(new JournalEntry(timeProvider.GetUtcNow(), label, Tone.Info));
            await RememberDisabledAsync(cancellationToken).ConfigureAwait(false);
        }
        var session = await SessionAsync(cancellationToken).ConfigureAwait(false);
        var scopeLabel = Label(definition, session);
        if (!enabled)
        {
            return DashboardCalculator.Disabled(definition, scopeLabel);
        }
        if (state is null || session.Scope is null)
        {
            return DashboardCalculator.NotMeasured(definition, scopeLabel, DashboardCalculator.NoMemoryDetail);
        }
        return DashboardCalculator.ComputeWidget(definition.Id, Input(state, session.Scope, session));
    }

    public void Dispose()
    {
        refreshGate.Dispose();
        persistGate.Dispose();
    }

    /// <summary>Session of the source, with the working OU of the session in place of the default scope.</summary>
    private async Task<SessionSnapshot> SessionAsync(CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        return workingScope is null ? session : await workingScope.ApplyAsync(session, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Restores the disabled widgets once, at the first call (always off the UI thread). Unknown identifiers are ignored;
    /// an unreadable value is traced and the widgets stay enabled.
    /// </summary>
    private void LoadPreferences()
    {
        if (preferences is null || Volatile.Read(ref preferencesLoaded) != 0)
        {
            return;
        }
        var restored = ImmutableHashSet.Create<string>(StringComparer.Ordinal);
        if (preferences.TryGet(DisabledWidgetsPreference, out var value))
        {
            if (value.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in value.EnumerateArray())
                {
                    if (item.ValueKind == JsonValueKind.String && WidgetCatalog.TryGet(item.GetString()!, out var definition))
                    {
                        restored = restored.Add(definition.Id);
                    }
                }
            }
            else
            {
                log.Warning("Préférence dashboard.disabledWidgets illisible : tous les widgets restent actifs.");
            }
        }
        lock (gate)
        {
            // A change made meanwhile by this session wins over the remembered state.
            if (preferencesLoaded == 0)
            {
                disabled = disabled.Union(restored);
                preferencesLoaded = 1;
            }
        }
    }

    /// <summary>Writes the current set (never an older one: writes run one after another and read the latest set).</summary>
    private async Task RememberDisabledAsync(CancellationToken cancellationToken)
    {
        if (preferences is null)
        {
            return;
        }
        await persistGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ImmutableHashSet<string> current;
            lock (gate)
            {
                current = disabled;
            }
            string[] ids = [.. WidgetCatalog.All.Select(w => w.Id).Where(current.Contains)];
            await preferences.SetAsync(DisabledWidgetsPreference, JsonSerializer.SerializeToElement(ids), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // The choice stays for the session; the operator is told it will not survive a restart.
            log.Warning($"Préférences non enregistrées (widgets) : {ex.GetType().Name}.");
            journal.Add(new JournalEntry(timeProvider.GetUtcNow(), "Préférences non enregistrées" + FrenchText.Colon + "l’état des widgets vaut pour cette session", Tone.Warn));
        }
        finally
        {
            persistGate.Release();
        }
    }

    private bool IsDisabled(string widgetId)
    {
        lock (gate)
        {
            return disabled.Contains(widgetId);
        }
    }

    private DashboardInput Input(DirectoryState state, ScopeSelection scope, SessionSnapshot session)
    {
        ImmutableHashSet<string> disabledNow;
        lock (gate)
        {
            disabledNow = disabled;
        }
        // Session operations (in memory) then the journal kept by the source; the calculator orders them by date.
        var entries = journal.Snapshot().AddRange(state.Journal);
        return new DashboardInput(state, scope, policy, disabledNow, entries, timeProvider.GetUtcNow(), timeProvider.LocalTimeZone, source.Kind, session.Domain?.RootDn);
    }

    private static ScopeSelection RequireScope(SessionSnapshot session) =>
        session.Scope ?? throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, DomeniaErrors.ScopeTooWideMessage);

    private static string Label(WidgetDefinition definition, SessionSnapshot session) =>
        DashboardCalculator.ScopeLabel(definition, session.Domain?.DnsName, session.Scope, session.Domain?.RootDn);
}
