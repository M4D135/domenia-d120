using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Home page state of the session (docs/OPERATIONS.md § 3 to 7): disabled widgets, last known state, journal and read
/// counters. In memory only, no I/O of its own; refreshes run one after another.
/// </summary>
public sealed class DashboardService : IDisposable
{
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
    private readonly SemaphoreSlim refreshGate = new(1, 1);
    private readonly Lock gate = new();
    private ImmutableHashSet<string> disabled = ImmutableHashSet.Create<string>(StringComparer.Ordinal);
    private DirectoryState? lastState;
    // Bumped at every store of lastState, so a summary that overlapped a refresh never brings back an older state.
    private long stateVersion;
    private int running;
    private int queued;
    private bool summaryDone;

    public DashboardService(IDirectorySource source, OperationJournal journal, TimeProvider timeProvider, DashboardPolicy? policy = null)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(journal);
        ArgumentNullException.ThrowIfNull(timeProvider);
        this.source = source;
        this.journal = journal;
        this.timeProvider = timeProvider;
        this.policy = policy ?? DashboardPolicy.Default;
    }

    /// <summary>session.info: session of the source plus counters, local base state and onboarding.</summary>
    public async Task<SessionInfo> GetSessionInfoAsync(CancellationToken cancellationToken)
    {
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
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
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
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
        var summary = DashboardCalculator.Compute(Input(state, scope));
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
        if (IsDisabled(definition.Id))
        {
            throw new DomeniaOperationException(DomeniaErrors.WidgetDisabled, DomeniaErrors.WidgetDisabledMessage);
        }
        Interlocked.Increment(ref queued);
        try
        {
            await refreshGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            Interlocked.Decrement(ref queued);
        }
        Interlocked.Increment(ref running);
        try
        {
            var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
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
            var state = await source.RefreshAsync(family, cancellationToken).ConfigureAwait(false);
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
            return DashboardCalculator.ComputeWidget(definition.Id, Input(state, scope));
        }
        finally
        {
            Interlocked.Decrement(ref running);
            refreshGate.Release();
        }
    }

    /// <summary>dashboard.widget.setEnabled: idempotent, kept for the session; enabling reuses the last state in memory.</summary>
    public async Task<DashboardWidget> SetEnabledAsync(string widgetId, bool enabled, CancellationToken cancellationToken)
    {
        if (!WidgetCatalog.TryGet(widgetId, out var definition))
        {
            throw new DomeniaOperationException(DomeniaErrors.WidgetUnknown, DomeniaErrors.WidgetUnknownChangeMessage);
        }
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
        }
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var scopeLabel = Label(definition, session);
        if (!enabled)
        {
            return DashboardCalculator.Disabled(definition, scopeLabel);
        }
        if (state is null || session.Scope is null)
        {
            return DashboardCalculator.NotMeasured(definition, scopeLabel, DashboardCalculator.NoMemoryDetail);
        }
        return DashboardCalculator.ComputeWidget(definition.Id, Input(state, session.Scope));
    }

    public void Dispose() => refreshGate.Dispose();

    private bool IsDisabled(string widgetId)
    {
        lock (gate)
        {
            return disabled.Contains(widgetId);
        }
    }

    private DashboardInput Input(DirectoryState state, ScopeSelection scope)
    {
        ImmutableHashSet<string> disabledNow;
        lock (gate)
        {
            disabledNow = disabled;
        }
        // Session operations (in memory) then the journal kept by the source; the calculator orders them by date.
        var entries = journal.Snapshot().AddRange(state.Journal);
        return new DashboardInput(state, scope, policy, disabledNow, entries, timeProvider.GetUtcNow(), timeProvider.LocalTimeZone, source.Kind);
    }

    private static ScopeSelection RequireScope(SessionSnapshot session) =>
        session.Scope ?? throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, DomeniaErrors.ScopeTooWideMessage);

    private static string Label(WidgetDefinition definition, SessionSnapshot session) =>
        DashboardCalculator.ScopeLabel(definition, session.Domain?.DnsName, session.Scope);
}
