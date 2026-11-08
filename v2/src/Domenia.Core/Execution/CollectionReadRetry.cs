namespace Domenia.Core;

/// <summary>Closed outcomes of a completed native read. Never infer these from a translated error message.</summary>
public enum CollectionReadFailure
{
    Unknown, Success, Transient, Offline, Unreachable, ProtocolUnavailable, AccessDenied,
    CredentialRejected, ClassAbsent, Cancelled,
}

/// <summary>Ephemeral evidence from this attempt, never restored from a cache or supplied by the web page.</summary>
public readonly record struct CollectionRetryEvidence(CollectionReadFailure Failure, bool PhysicallyCompleted, bool Reachable);
public sealed record CollectionRetryDecision(bool Retry, TimeSpan Delay, string Reason);

public sealed record CollectionRetryPolicy(int Retries = 2, int FirstDelaySeconds = 30)
{
    public static CollectionRetryPolicy Read(IPreferenceStore? preferences)
    {
        var settings = CollectionSettingsRules.Read(preferences?.TryGet(CollectionSettingsRules.PreferenceKey, out var stored) == true ? stored : null, []);
        return new(settings.Budgets.GetValueOrDefault(CollectionSettingsRules.WmiRetries, 2),
            settings.Budgets.GetValueOrDefault(CollectionSettingsRules.WmiRetryDelaySeconds, 30));
    }
}

/// <summary>TRV-108: by default three read attempts, spaced by 30 then 120 seconds; bounded settings can reduce
/// or increase the count/delay without extending the five-minute lifetime. An existing operation owns the
/// lifetime; no timer creates work after it has ended. Each consumer keeps its per-attempt native ceilings.</summary>
public sealed class CollectionReadRetry(TimeProvider clock, CollectionRetryPolicy? policy = null)
{
    public const int MaximumAttempts = 5;
    public const int MaximumWaiting = 32;
    public static readonly TimeSpan MaximumDuration = TimeSpan.FromMinutes(5);
    private static readonly SemaphoreSlim Waiting = new(MaximumWaiting, MaximumWaiting);
    internal Func<TimeSpan, CancellationToken, Task>? DelayOverride { get; init; }

    public static CollectionRetryDecision Decide(CollectionRetryEvidence evidence, int completedAttempts,
        TimeSpan remaining, TimeSpan attemptBudget, bool isWrite = false, CollectionRetryPolicy? policy = null)
    {
        var retries = Math.Clamp(policy?.Retries ?? 2, 0, MaximumAttempts - 1);
        var firstDelay = Math.Clamp(policy?.FirstDelaySeconds ?? 30, 10, 120);
        if (isWrite) return No("Une écriture n’est jamais rejouée.");
        if (completedAttempts < 1 || completedAttempts >= retries + 1) return No("Nombre maximal d’essais atteint ; aucune reprise supplémentaire.");
        if (!Enum.IsDefined(evidence.Failure) || evidence.Failure != CollectionReadFailure.Transient)
            return No(evidence.Failure switch
            {
                CollectionReadFailure.CredentialRejected => "Identifiants rejetés ; aucune reprise automatique.",
                CollectionReadFailure.AccessDenied => "Droit refusé ; aucune reprise automatique.",
                CollectionReadFailure.ClassAbsent => "Classe ou espace de noms absent ; aucune reprise automatique.",
                CollectionReadFailure.Offline or CollectionReadFailure.Unreachable or CollectionReadFailure.ProtocolUnavailable => "Poste ou protocole non joignable ; aucune reprise immédiate.",
                CollectionReadFailure.Cancelled => "Lecture arrêtée ; aucune reprise.",
                _ => "Aucun incident transitoire qualifié.",
            });
        if (!evidence.PhysicallyCompleted) return No("Le travail précédent n’est pas terminé physiquement ; aucun nouvel envoi.");
        if (!evidence.Reachable) return No("Aucune preuve récente que le poste est joignable ; aucune reprise immédiate.");
        var delay = TimeSpan.FromSeconds(Math.Min(300, firstDelay * Math.Pow(4, completedAttempts - 1)));
        if (attemptBudget <= TimeSpan.Zero || remaining < delay + attemptBudget)
            return No("Budget total insuffisant pour une nouvelle lecture bornée.");
        return new(true, delay, "Incident transitoire : nouvel essai dans " + (int)delay.TotalSeconds
            + " s (essai " + (completedAttempts + 1) + "/" + (retries + 1) + ").");
    }

    private static CollectionRetryDecision No(string reason) => new(false, TimeSpan.Zero, reason);

    /// <summary>A success cannot hide a refusal or an unclassified failure in another source.</summary>
    public static CollectionReadFailure Combine(IEnumerable<CollectionReadFailure> failures)
    {
        var values = failures.ToArray();
        if (values.Length == 0 || values.Any(value => !Enum.IsDefined(value))) return CollectionReadFailure.Unknown;
        foreach (var failure in new[] { CollectionReadFailure.CredentialRejected, CollectionReadFailure.AccessDenied,
            CollectionReadFailure.ClassAbsent, CollectionReadFailure.ProtocolUnavailable, CollectionReadFailure.Offline,
            CollectionReadFailure.Unreachable, CollectionReadFailure.Cancelled, CollectionReadFailure.Unknown,
            CollectionReadFailure.Transient })
            if (values.Contains(failure)) return failure;
        return CollectionReadFailure.Success;
    }

    /// <summary>The consumer revalidates the same target/account/session before each send and after each answer.
    /// Acknowledgment runs before any wait, so cancellation cannot erase completed, qualified observations.</summary>
    public async Task<T> RunAsync<T>(Func<CancellationToken, Task<T>> read,
        Func<T, CollectionRetryEvidence> evidence, Action ensureCurrent,
        TimeSpan attemptBudget, CancellationToken token, Func<T, Task>? acknowledge = null,
        Action<CollectionRetryDecision>? onRetry = null, bool isWrite = false)
    {
        ArgumentNullException.ThrowIfNull(read);
        ArgumentNullException.ThrowIfNull(evidence);
        ArgumentNullException.ThrowIfNull(ensureCurrent);
        if (attemptBudget <= TimeSpan.Zero || attemptBudget > MaximumDuration) throw new ArgumentOutOfRangeException(nameof(attemptBudget));
        var started = clock.GetTimestamp();
        // Admission, account/identity qualification and every native send share the same deadline. A consumer
        // still waits for physical termination after cancellation; the deadline never releases a native lease.
        using var deadline = new CancellationTokenSource(MaximumDuration, clock);
        using var execution = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
        var hasPrevious = false;
        T previous = default!;
        for (var attempt = 1; ; attempt++)
        {
            token.ThrowIfCancellationRequested();
            ensureCurrent();
            if (hasPrevious && deadline.IsCancellationRequested) return previous;
            execution.Token.ThrowIfCancellationRequested();
            T value;
            try { using var measuredAttempt = ReadPerformance.Attempt(attempt - 1); value = await read(execution.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (deadline.IsCancellationRequested && !token.IsCancellationRequested && hasPrevious)
            {
                ensureCurrent();
                return previous; // The preceding qualified observation was acknowledged before this attempt.
            }
            ensureCurrent();
            // A partial answer may arrive while the native worker is stopping. Let the consumer persist it,
            // but never schedule another attempt after either cancellation or the total deadline.
            if (token.IsCancellationRequested || deadline.IsCancellationRequested) return value;
            var elapsed = clock.GetElapsedTime(started);
            var remaining = elapsed < TimeSpan.Zero ? TimeSpan.Zero : MaximumDuration - elapsed;
            var decision = Decide(evidence(value), attempt, remaining, attemptBudget, isWrite || PhysicalWorkBudget.InWriteContext, policy);
            if (!decision.Retry) return value;
            if (!Waiting.Wait(0)) return value;
            try
            {
                if (acknowledge is not null) await acknowledge(value).ConfigureAwait(false);
                previous = value; hasPrevious = true;
                onRetry?.Invoke(decision);
                await (DelayOverride?.Invoke(decision.Delay, execution.Token) ?? Task.Delay(decision.Delay, clock, execution.Token)).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (deadline.IsCancellationRequested && !token.IsCancellationRequested)
            { ensureCurrent(); return value; }
            finally { Waiting.Release(); }
            token.ThrowIfCancellationRequested();
            // TimeProvider may move backwards; neither that nor an overslept delay extends ownership.
            elapsed = clock.GetElapsedTime(started);
            if (elapsed < TimeSpan.Zero || MaximumDuration - elapsed < attemptBudget) return value;
        }
    }
}
