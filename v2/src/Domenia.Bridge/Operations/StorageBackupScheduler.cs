using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>What the automatic backup did last in this session (shown by the schedule of the page).</summary>
public sealed record BackupSchedulerState(DateTimeOffset? LastAttempt, DateTimeOffset? LastSuccess, string? LastFailure, DateTimeOffset? LastFailureAt, string? LastReason);

/// <summary>
/// Automatic backup of the local base while Domenia is open (Domenia 1 PAR-036, Invoke-DomeniaScheduledBackup): checked every
/// minute, only when the operator enabled it in Paramètres; deferred while an operation or a local save is under way; 15
/// minutes between two tries; stopped by a backup dated after the clock of the workstation. Each backup goes through the
/// write circuit like any other (plan sealed by the engine, receipt written before, re-read after): the consent is the
/// schedule the operator enabled, limited to a verified copy of the base, which never modifies the base itself. Nothing
/// runs without a local base (directory mode of this version) nor in memory-only sessions (capture, E2E, tests).
/// </summary>
public sealed class StorageBackupScheduler : IDisposable
{
    /// <summary>Period of the check (Domenia 1: one check a minute).</summary>
    public static readonly TimeSpan Period = TimeSpan.FromMinutes(1);

    private readonly EngineContext context;
    private readonly Lock gate = new();
    private readonly CancellationTokenSource stop = new();
    private Task? loop;
    private BackupSchedulerState state = new(null, null, null, null, null);
    private int ticking;

    private StorageBackupScheduler(EngineContext context) => this.context = context;

    /// <summary>The scheduler of a context (one per context, disposed with it).</summary>
    public static StorageBackupScheduler From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new StorageBackupScheduler(c));
    }

    /// <summary>Last attempt, success and failure of this session.</summary>
    public BackupSchedulerState State
    {
        get
        {
            lock (gate)
            {
                return state;
            }
        }
    }

    /// <summary>Starts the minute check (once); only for a persistent session of the application.</summary>
    public void Start()
    {
        lock (gate)
        {
            if (loop is not null || stop.IsCancellationRequested)
            {
                return;
            }
            loop = Task.Run(() => RunAsync(stop.Token));
        }
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(Period, context.Clock);
        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
            {
                await TickAsync(cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            // Closing: the loop ends.
        }
    }

    /// <summary>
    /// One check (public for the tests): decides with <see cref="StoragePolicyRules.BackupDecision"/> and, when due, plans then
    /// executes one scheduled backup through the write circuit. Returns the reason of the decision (« scheduled » when a backup
    /// was made, « disabled », « busy », « recent », « retryCooldown », « invalidClock », « unavailable », « running »).
    /// </summary>
    public async Task<string> TickAsync(CancellationToken cancellationToken)
    {
        if (Interlocked.Exchange(ref ticking, 1) != 0)
        {
            return "running";
        }
        try
        {
            var policy = StoragePolicyRules.Read(context.Preferences.TryGet(StoragePolicyRules.PreferenceKey, out var stored) ? stored : null, out _);
            if (!policy.AutomaticBackup)
            {
                return Remember("disabled");
            }
            var reader = context.Readers.Find<ISettingsReader>();
            var executor = context.Writers.Find<IStorageBackupExecutor>();
            if (reader is null || executor is null)
            {
                return Remember("unavailable");
            }
            var store = await reader.LocalStoreAsync(cancellationToken).ConfigureAwait(false);
            if (!store.Available || store.Maintenance.Recovery || store.Maintenance.Locked)
            {
                return Remember("unavailable");
            }
            var now = context.Clock.GetUtcNow();
            var last = store.Backups.Where(StoragePolicyRules.IsVerified).OrderByDescending(b => b.At).FirstOrDefault();
            var (due, reason) = StoragePolicyRules.BackupDecision(policy, last?.At, State.LastAttempt, StorageViewBuilder.BackupBusy(store), now);
            if (!due)
            {
                return Remember(reason);
            }
            lock (gate)
            {
                state = state with { LastAttempt = now, LastReason = reason };
            }
            await BackupAsync(executor, policy, now, cancellationToken).ConfigureAwait(false);
            return reason;
        }
        finally
        {
            Volatile.Write(ref ticking, 0);
        }
    }

    private string Remember(string reason)
    {
        lock (gate)
        {
            state = state with { LastReason = reason };
        }
        return reason;
    }

    private async Task BackupAsync(IStorageBackupExecutor executor, StoragePolicy policy, DateTimeOffset now, CancellationToken cancellationToken)
    {
        try
        {
            var annex = await SettingsAnnex.SnapshotAsync(context, cancellationToken).ConfigureAwait(false);
            var draft = await executor.PlanBackupAsync(policy, annex, StorageWritePlans.ScheduledSeries, cancellationToken).ConfigureAwait(false);
            var circuit = WriteCircuit.From(context);
            var planned = await circuit.PlanAsync(draft, cancellationToken).ConfigureAwait(false);
            // The plan is executed once, at once, by the schedule the operator enabled; a refusal is reported, never retried
            // before the next period (15 minutes at least).
            var receipt = await circuit.ExecuteAsync(planned.Plan.Id, planned.Token, null, null, CancellationToken.None).ConfigureAwait(false);
            lock (gate)
            {
                state = receipt.Result is WriteResult.Applied && receipt.Verification == VerificationState.Verified
                    ? state with { LastSuccess = now, LastFailure = null, LastFailureAt = null }
                    : state with { LastFailure = receipt.Summary, LastFailureAt = now };
            }
            context.Log.Info($"Sauvegarde automatique de la base locale : {receipt.Result}, relecture {receipt.Verification}.");
        }
        catch (DomeniaOperationException ex)
        {
            lock (gate)
            {
                state = state with { LastFailure = ex.Message, LastFailureAt = now };
            }
            context.Log.Warning($"Sauvegarde automatique non faite ({ex.Code}).");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or JsonException)
        {
            lock (gate)
            {
                state = state with { LastFailure = "Sauvegarde automatique impossible pour l’instant" + FrenchText.Colon + "nouvel essai dans 15" + FrenchText.Nbsp + "min.", LastFailureAt = now };
            }
            context.Log.Warning($"Sauvegarde automatique impossible ({ex.GetType().Name}).");
        }
    }

    public void Dispose()
    {
        stop.Cancel();
        stop.Dispose();
    }
}

/// <summary>The approved preferences of the session joined to a backup (PAR-034): the keys of the closed list that are set.</summary>
public static class SettingsAnnex
{
    /// <summary>Approved keys read for the annex: fixed keys and the working OU of the domain of the session.</summary>
    public static async Task<IReadOnlyDictionary<string, JsonElement>> ValuesAsync(EngineContext context, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(context);
        var keys = new List<string> { DashboardService.DisabledWidgetsPreference, CollectionSettingsRules.PreferenceKey, StoragePolicyRules.PreferenceKey, PreferenceApproval.ZoomKey };
        var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        if (session.Domain?.RootDn is string root)
        {
            try
            {
                keys.Add(WorkingScope.PreferenceKey(root));
            }
            catch (FormatException)
            {
                context.Log.Warning("Racine du domaine illisible : OU de travail absente de l’annexe des préférences.");
            }
        }
        var values = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var key in keys)
        {
            if (context.Preferences.TryGet(key, out var value))
            {
                values[key] = value;
            }
        }
        return values;
    }

    /// <summary>Canonical document of the annex (approved and valid values only).</summary>
    public static async Task<string> SnapshotAsync(EngineContext context, CancellationToken cancellationToken) =>
        BackupPreferencesRules.Snapshot(await ValuesAsync(context, cancellationToken).ConfigureAwait(false));
}
