using System.Collections.Concurrent;

namespace Domenia.Core;

/// <summary>Event data of « write.execute:stage »: the stage reached and its French label.</summary>
public sealed record WriteStageEvent(WriteStage Stage, string Label);

/// <summary>
/// The single write channel of the engine (docs/WRITES.md, Domenia 1 TRV-213 to TRV-235, TRV-281). Every write of every screen
/// goes through it, in this order:
/// <list type="number">
/// <item>plan: the screen's executor reads the target and drafts the change; the circuit seals it (identifier, account, mode,
/// fingerprint, one to five minutes) and issues a single-use token bound to the fingerprint (<see cref="PlanAsync"/>);</item>
/// <item>confirmation by the operator in the page (typed name when the plan asks for it, checked again here);</item>
/// <item>execution (<see cref="ExecuteAsync"/>): token checked then consumed, writes one at a time, any uncertain receipt refuses
/// it (Domenia 1 Assert-WriteAllowed: a receipt to verify holds every new write back), preconditions read again, receipt written BEFORE sending (nothing is sent without it), write sent
/// once and never cancelled, outcome recorded, target read again, receipt completed and journalled;</item>
/// <item>later re-reads from Opérations (<see cref="VerifyAsync"/>): they read, they never write again.</item>
/// </list>
/// Nothing is ever retried or replayed: not by the circuit, not at startup, not from a receipt.
/// </summary>
public sealed partial class WriteCircuit : IDisposable
{
    /// <summary>The generic execution operation: the only operation of class Write the admission guards accept.</summary>
    public const string ExecuteOperation = "write.execute";

    /// <summary>Most plans kept waiting for their confirmation.</summary>
    public const int PlanCapacity = 64;

    private readonly WriteExecutors writers;
    private readonly IReceiptStore receipts;
    private readonly IDirectorySource directory;
    private readonly OperationJournal journal;
    private readonly TimeProvider clock;
    private readonly ITechnicalJournal log;
    private readonly AppMode mode;
    private readonly ConfirmationTokens tokens = new();
    private readonly Lock gate = new();
    private readonly Dictionary<string, WritePlan> plans = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> reservations = new(StringComparer.Ordinal);
    private readonly HashSet<string> executing = new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> preparedTicks = new(StringComparer.Ordinal);
    private readonly Dictionary<string, WritePlanOrigin> origins = new(StringComparer.Ordinal);
    private int inFlight;
    private RuntimeConfiguration configuration = RuntimeConfiguration.Default;
    public bool InFlight => Volatile.Read(ref inFlight) != 0;
    // Versions written (or attempted) during this session: they hold even when the disk refused them, and the latest wins.
    private readonly ConcurrentDictionary<string, WriteReceipt> session = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim writeGate = new(1, 1);

    public WriteCircuit(WriteExecutors writers, IReceiptStore receipts, IDirectorySource directory, OperationJournal journal, TimeProvider clock, ITechnicalJournal log, AppMode mode)
    {
        ArgumentNullException.ThrowIfNull(writers);
        ArgumentNullException.ThrowIfNull(receipts);
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(journal);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        this.writers = writers;
        this.receipts = receipts;
        this.directory = directory;
        this.journal = journal;
        this.clock = clock;
        this.log = log;
        this.mode = mode;
    }

    /// <summary>The write circuit shared by every module of the context.</summary>
    public static WriteCircuit From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new WriteCircuit(c.Writers, c.Receipts, c.Directory, c.Journal, c.Clock, c.Log, c.Mode) { configuration = c.Configuration });
    }

    /// <summary>French label of a stage of write.execute.</summary>
    public static string StageLabel(WriteStage stage) => stage switch
    {
        WriteStage.Checking => "Relecture de l’objet avant l’envoi",
        WriteStage.Sending => "Reçu enregistré, envoi du changement",
        WriteStage.Slow => "Envoi plus long que prévu ; reçu conservé, aucune nouvelle tentative",
        WriteStage.Prolonged => "Envoi toujours actif, issue non confirmée ; canal occupé jusqu’à la fin réelle",
        _ => "Relecture après l’écriture",
    };

    /// <summary>
    /// Seals the draft of an executor into a plan and issues its token. Refused when no executor of this mode runs the kind
    /// (source.unavailable), when an uncertain receipt holds the target (write.targetPending) or any other object
    /// (write.receiptsPending: every new write waits for the receipts to verify, Domenia 1 OPE-025 and OPE-026) or when the receipts
    /// cannot be read (receipt.unavailable). Nothing is written.
    /// </summary>
    public async Task<PlannedWrite> PlanAsync(WritePlanDraft draft, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(draft);
        lock (gate) { EnsureOpenLocked(); }
        if (writers.ForKind(draft.Kind) is null)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        }
        var account = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        RequireConnectedSession(account, draft.Kind);
        if (draft.Origin is { } origin && !origin.Matches(account))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "La session a changé depuis la lecture de l’objet ; préparez un nouveau plan."); }
        var now = clock.GetUtcNow();
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), account.Account.Login, mode, now, clock.LocalTimeZone,
            TimeSpan.FromMinutes(configuration.Integer("Security", "WritePlanMaxAgeMinutes", 5)));
        await EnsureWritesFreeAsync(plan, WriteErrors.ReceiptsUnreadableMessage, cancellationToken).ConfigureAwait(false);
        RequireCapability(account, plan.Kind, plan.Target, plan.Changes);
        string token;
        lock (gate)
        {
            EnsureOpenLocked();
            var issued = clock.GetUtcNow();
            if (issued < plan.CreatedAt || issued >= plan.ExpiresAt)
                throw WriteErrors.Refusal(WriteErrors.TokenExpired, WriteErrors.TokenExpiredMessage);
            var requestKey = WritePlans.ComputeRequestFingerprint(plan);
            PurgeLocked(issued, requestKey);
            if (writers.ForKind(draft.Kind) is IWritePlanBinder binder) { binder.Bind(draft, plan); }
            token = tokens.Issue(plan.Id, plan.Fingerprint, plan.ExpiresAt, issued);
            plans[plan.Id] = plan;
            origins[plan.Id] = draft.Origin ?? WritePlanOrigin.From(account);
            preparedTicks[plan.Id] = clock.GetTimestamp();
            reservations[requestKey] = plan.Id;
        }
        log.Info($"Plan d’écriture {plan.Kind} préparé ({plan.Changes.Length} changement(s), confirmation {(plan.Confirmation.TypedNameRequired ? "par saisie du nom" : "simple")}).");
        return new PlannedWrite(plan, token);
    }

    /// <summary>
    /// write.execute: runs a confirmed plan once and returns its receipt. Refusals before sending: write.planUnknown,
    /// write.tokenUsed, write.tokenInvalid, write.planChanged, write.tokenExpired, write.confirmationMismatch, write.targetPending,
    /// write.receiptsPending, write.stale, receipt.unavailable. Once the receipt is written, the request leaves and the call always ends with a receipt
    /// (applied, already done, refused or unknown), whatever happens.
    /// </summary>
    public async Task<ReceiptView> ExecuteAsync(string planId, string token, string? typedName, Action<WriteStage>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(planId);
        ArgumentNullException.ThrowIfNull(token);
        WritePlan? plan;
        lock (gate)
        {
            EnsureOpenLocked();
            plans.TryGetValue(planId, out plan);
        }
        if (plan is null)
        {
            throw WriteErrors.Refusal(WriteErrors.PlanUnknown, WriteErrors.PlanUnknownMessage);
        }
        // Recomputed from the plan as it is now: a plan changed after sealing never matches its token.
        var fingerprint = WritePlans.ComputeFingerprint(plan);
        switch (tokens.Check(planId, token, fingerprint, clock.GetUtcNow()))
        {
            case TokenCheck.Unknown:
                throw WriteErrors.Refusal(WriteErrors.PlanUnknown, WriteErrors.PlanUnknownMessage);
            case TokenCheck.Used:
                throw WriteErrors.Refusal(WriteErrors.TokenUsed, WriteErrors.TokenUsedMessage);
            case TokenCheck.Invalid:
                log.Warning($"Écriture {plan.Kind} refusée : jeton de confirmation non conforme.");
                throw WritePlans.IsIntact(plan)
                    ? WriteErrors.Refusal(WriteErrors.TokenInvalid, WriteErrors.TokenInvalidMessage)
                    : WriteErrors.Refusal(WriteErrors.PlanChanged, WriteErrors.PlanChangedMessage);
            case TokenCheck.Expired:
                lock (gate) { if (!executing.Contains(plan.Id)) InvalidateTimeLocked(plan); }
                throw WriteErrors.Refusal(WriteErrors.TokenExpired, WriteErrors.TokenExpiredMessage);
        }
        RequirePlanTime(plan);
        if (plan.Confirmation.TypedNameRequired && !string.Equals(typedName, plan.Confirmation.TypedName, StringComparison.Ordinal))
        {
            // Fail closed: the page never sends a name that differs, so the plan is spent.
            lock (gate)
            {
                if (!tokens.Consume(planId)) throw WriteErrors.Refusal(WriteErrors.TokenUsed, WriteErrors.TokenUsedMessage);
                ReleaseReservationLocked(plan);
            }
            Note(plan, "nom saisi différent de la cible", Tone.Warn, prefix: "Écriture non envoyée");
            throw WriteErrors.Refusal(WriteErrors.ConfirmationMismatch, WriteErrors.ConfirmationMismatchMessage);
        }
        lock (gate)
        {
            if (!tokens.Consume(planId)) throw WriteErrors.Refusal(WriteErrors.TokenUsed, WriteErrors.TokenUsedMessage);
            executing.Add(planId);
        }
        log.Info($"Écriture {plan.Kind} confirmée par l’opérateur.");
        var acquired = false;
        try
        {
            await writeGate.WaitAsync(cancellationToken).ConfigureAwait(false); acquired = true;
            RequirePlanTime(plan);
            lock (gate) { EnsureOpenLocked(); Interlocked.Increment(ref consultationVersion); Volatile.Write(ref inFlight, 1); }
            return await RunAsync(plan, progress, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            lock (gate) { executing.Remove(planId); ReleaseReservationLocked(plan); }
            if (acquired)
            {
                Interlocked.Increment(ref consultationVersion);
                Volatile.Write(ref inFlight, 0);
                writeGate.Release();
            }
        }
    }

    /// <summary>write.receipts.list: every receipt of this mode, uncertain ones first.</summary>
    public async Task<ReceiptList> ListAsync(CancellationToken cancellationToken)
    {
        var (all, unreadable) = await ReadAsync(WriteErrors.ReceiptsUnreadableMessage, cancellationToken).ConfigureAwait(false);
        return WriteReceipts.List(all, unreadable) with { InFlight = InFlight };
    }

    /// <summary>write.receipts.get: one receipt with its details and plan (receipt.unknown otherwise).</summary>
    public async Task<ReceiptView> GetAsync(string id, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(id);
        var (all, _) = await ReadAsync(WriteErrors.ReceiptsUnreadableMessage, cancellationToken).ConfigureAwait(false);
        var receipt = all.FirstOrDefault(r => string.Equals(r.Id, id, StringComparison.Ordinal))
            ?? throw WriteErrors.Refusal(WriteErrors.ReceiptUnknown, WriteErrors.ReceiptUnknownMessage);
        return WriteReceipts.View(receipt);
    }

    /// <summary>
    /// write.receipts.verify: reads the target of a receipt again and records what is observed (a new version). Only a read
    /// leaves; the write is never sent again. An uncertain receipt settled by the re-read (verified or mismatch) stops holding
    /// back new writes; the writes are admitted again once no receipt remains to verify.
    /// </summary>
    public async Task<ReceiptView> VerifyAsync(string id, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(id);
        await writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var (all, _) = await ReadAsync(WriteErrors.ReceiptsUnreadableMessage, cancellationToken).ConfigureAwait(false);
            var receipt = all.FirstOrDefault(r => string.Equals(r.Id, id, StringComparison.Ordinal))
                ?? throw WriteErrors.Refusal(WriteErrors.ReceiptUnknown, WriteErrors.ReceiptUnknownMessage);
            var executor = writers.ForKind(receipt.Plan.Kind)
                ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
            var verification = await ReadBackAsync(executor, receipt.Plan, receipt.Result, cancellationToken).ConfigureAwait(false);
            var next = WriteReceipts.Verified(receipt, verification, clock.GetUtcNow());
            await KeepAsync(next).ConfigureAwait(false);
            Note(next.Plan, Outcome(next), WriteReceipts.ToneOf(next), prefix: "Relecture du reçu");
            log.Info($"Relecture du reçu d’une écriture {receipt.Plan.Kind} : {verification.State}.");
            Settled(all, receipt, next);
            return WriteReceipts.View(next);
        }
        finally
        {
            writeGate.Release();
        }
    }

    /// <summary>
    /// operations.receipts.review: records the manual review of an uncertain receipt (Domenia 1 OPE-024). The operator checked the
    /// object with another tool and describes the control (12 to 240 characters, never anything that looks like a secret); the
    /// receipt takes a new version « Revue manuelle » that stops holding back new writes (once no other receipt waits). Nothing is read in the
    /// directory and nothing is ever sent again; a receipt already settled is never changed (receipt.resolved).
    /// </summary>
    public async Task<ReceiptView> ReviewAsync(string id, string reason, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(id);
        ArgumentNullException.ThrowIfNull(reason);
        var check = ReceiptReviews.CheckReason(reason);
        if (!check.Valid)
        {
            throw new DomeniaOperationException(ReceiptReviews.ReasonInvalid, ReceiptReviews.ReasonInvalidPrefix + check.Message);
        }
        var account = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        await writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var (all, _) = await ReadAsync(WriteErrors.ReceiptsUnreadableMessage, cancellationToken).ConfigureAwait(false);
            var receipt = all.FirstOrDefault(r => string.Equals(r.Id, id, StringComparison.Ordinal))
                ?? throw WriteErrors.Refusal(WriteErrors.ReceiptUnknown, WriteErrors.ReceiptUnknownMessage);
            if (!WriteReceipts.IsPending(receipt))
            {
                throw new DomeniaOperationException(ReceiptReviews.Resolved, ReceiptReviews.ResolvedMessage);
            }
            var next = WriteReceipts.Reviewed(receipt, check.Text, account.Account.Login, clock.GetUtcNow());
            await KeepAsync(next).ConfigureAwait(false);
            Note(next.Plan, "revue manuelle consignée", Tone.Info, prefix: "Revue du reçu");
            // The motive is the operator's own text: it goes to the receipt only, never to the technical journal.
            log.Info($"Revue manuelle consignée pour un reçu d’écriture {receipt.Plan.Kind} ({check.Text.Length} caractères).");
            Settled(all, receipt, next);
            return WriteReceipts.View(next);
        }
        finally
        {
            writeGate.Release();
        }
    }

    public void Dispose() => writeGate.Dispose();

    private void RequireConnectedSession(SessionSnapshot snapshot, string kind)
    {
        if (Domenia.Core.Poste.RemoteWriteAccess.IsRemoteKind(kind))
            Domenia.Core.Poste.RemoteWriteAccess.Evaluate(mode, snapshot,
                requiresWinRm: kind == Domenia.Core.Poste.PosteRemoteWrites.GpUpdateKind,
                winRmEnabled: configuration.Poste.Options.UseWinRm).Require();
        if (mode == AppMode.Directory && writers.ForKind(kind) is IDirectoryMutationExecutor && snapshot.Connection != ConnectionState.Connected)
            throw WriteErrors.Refusal("write.sessionRequired", "Annuaire non connecté : aucun plan ni envoi d’écriture autorisé. Connectez-vous puis préparez un nouveau plan.");
    }

    private async Task<ReceiptView> RunAsync(WritePlan plan, Action<WriteStage>? progress, CancellationToken cancellationToken)
    {
        WritePlanOrigin? origin;
        lock (gate) { origins.TryGetValue(plan.Id, out origin); }
        var expected = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        RequireConnectedSession(expected, plan.Kind);
        if (origin is null || !origin.Matches(expected))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Ce plan appartient à une autre session ; aucune écriture envoyée."); }
        RequireCapability(expected, plan.Kind, plan.Target, plan.Changes);
        using var lease = (directory as IDirectoryWriteLeaseSource)?.AcquireWriteLease(expected);
        await EnsureWritesFreeAsync(plan, WriteErrors.ReceiptUnavailableMessage, cancellationToken).ConfigureAwait(false);
        var executor = writers.ForKind(plan.Kind)
            ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);

        progress?.Invoke(WriteStage.Checking);
        var precheck = await executor.CheckAsync(plan, cancellationToken).ConfigureAwait(false);
        if (!precheck.Current)
        {
            Note(plan, "préconditions changées depuis le plan", Tone.Warn, prefix: "Écriture non envoyée");
            log.Info($"Écriture {plan.Kind} non envoyée : préconditions changées depuis le plan.");
            throw new DomeniaOperationException(WriteErrors.Stale, precheck.Detail);
        }
        var current = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        RequireConnectedSession(current, plan.Kind);
        if (!origin.Matches(current))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "La session a changé pendant les préconditions ; aucune écriture envoyée."); }

        RequirePlanTime(plan);
        // The receipt is durable BEFORE the request leaves (TRV-281): without it, nothing is sent.
        var receipt = WriteReceipts.Sent(plan, WritePlans.NewId(), clock.GetUtcNow(), new ReceiptDetail("Préconditions", precheck.Detail));
        try
        {
            await receipts.AppendAsync(receipt, CancellationToken.None).ConfigureAwait(false);
        }
        catch (ReceiptCapacityException capacityError)
        {
            log.Warning(capacityError.Message);
            throw WriteErrors.Refusal("receipt.capacity", capacityError.Message);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Reçu d’écriture non enregistré ({ex.GetType().Name}) : rien n’est envoyé.");
            Note(plan, "reçu impossible à enregistrer", Tone.Alert, prefix: "Écriture non envoyée");
            throw WriteErrors.Refusal(WriteErrors.ReceiptUnavailable, WriteErrors.ReceiptUnavailableMessage);
        }
        Remember(receipt);

        // From here on the write is under way: never cancelled halfway, never retried.
        progress?.Invoke(WriteStage.Sending);
        WriteOutcome outcome;
        ReceiptError? error = null;
        using (var attempt = DirectoryWriteEvidence.BeginAttempt())
        {
            try
            {
                RequirePlanTime(plan); // The durable append may have waited past the confirmation deadline.
                using (var wait = new WriteWaitObserver(clock, TimeSpan.FromSeconds(configuration.Integer("Async", "WriteSoftTimeoutSeconds", 90)),
                    TimeSpan.FromSeconds(configuration.Integer("Async", "WriteHardTimeoutSeconds", 300)), stage =>
                    {
                        log.Warning("Écriture " + plan.Kind + " : " + StageLabel(stage) + ".");
                        progress?.Invoke(stage);
                    }))
                    outcome = await executor.ExecuteAsync(plan, CancellationToken.None).ConfigureAwait(false);
                if (!Enum.IsDefined(outcome.Result) || outcome.Result is WriteResult.Sent or WriteResult.Unknown
                    || outcome.Result == WriteResult.Delivered && !WriteReceiptStates.AllowsDelivery(plan.Kind))
                {
                    // An executor never reports « sent »: an answer without an outcome is an unknown outcome.
                    error = new ReceiptError(WriteErrors.OutcomeUnknown, WriteErrors.OutcomeUnknownMessage);
                    outcome = new WriteOutcome(WriteResult.Unknown, outcome.Detail);
                }
            }
            catch (DomeniaOperationException ex)
            {
                var proven = attempt.IsProvenRejection(ex);
                if (proven) RememberCapabilityRefusal(expected, plan, executor, ex);
                // A local/transport exception after durable Sent cannot prove that no mutation happened.
                outcome = proven
                    ? new WriteOutcome(WriteResult.NotApplied, ex.Message)
                    : new WriteOutcome(WriteResult.Unknown, WriteErrors.OutcomeUnknownMessage);
                error = new ReceiptError(ex.Code, ex.Message);
            }
    #pragma warning disable CA1031 // The request left: whatever the failure, the receipt must say « unknown », never lose it.
            catch (Exception ex)
    #pragma warning restore CA1031
            {
                log.Error($"Écriture {plan.Kind} : issue inconnue après l’envoi.", ex);
                outcome = new WriteOutcome(WriteResult.Unknown, WriteErrors.OutcomeUnknownMessage);
                error = new ReceiptError(WriteErrors.OutcomeUnknown, WriteErrors.OutcomeUnknownMessage);
            }
        }
        receipt = WriteReceipts.Completed(receipt, outcome, error, clock.GetUtcNow());
        await KeepAsync(receipt).ConfigureAwait(false);

        progress?.Invoke(WriteStage.Verifying);
        var verification = await ReadBackAsync(executor, plan, receipt.Result, cancellationToken).ConfigureAwait(false);
        receipt = WriteReceipts.Verified(receipt, verification, clock.GetUtcNow());
        await KeepAsync(receipt).ConfigureAwait(false);

        Note(plan, Outcome(receipt), WriteReceipts.ToneOf(receipt));
        log.Info($"Écriture {plan.Kind} : {receipt.Result}, relecture {receipt.Verification}.");
        return WriteReceipts.View(receipt);
    }

    /// <summary>Re-read of the target: any failure is an unknown verification, never an exception for the caller.</summary>
    private async Task<WriteVerification> ReadBackAsync(IWriteExecutor executor, WritePlan plan, WriteResult result, CancellationToken cancellationToken)
    {
        try
        {
            if (result == WriteResult.Delivered)
                return new(VerificationState.Unknown, "Transport livré et terminé ; aucune preuve automatique de l’effet métier.");
            var reading = executor is IWriteOutcomeVerifier aware
                ? await aware.VerifyOutcomeAsync(plan, result, cancellationToken).ConfigureAwait(false)
                : await executor.VerifyAsync(plan, cancellationToken).ConfigureAwait(false);
            return Enum.IsDefined(reading.State) && reading.State != VerificationState.Reviewed ? reading
                : new(VerificationState.Unknown, "État de relecture non reconnu ; aucune preuve déduite.");
        }
        catch (OperationCanceledException)
        {
            return new WriteVerification(VerificationState.Unknown, "Relecture interrompue (fermeture de l’application) : relisez ce reçu depuis Opérations.");
        }
        catch (DomeniaOperationException ex)
        {
            return new WriteVerification(VerificationState.Unknown, "Relecture impossible : " + ex.Message);
        }
#pragma warning disable CA1031 // A failed re-read proves nothing: it is recorded as unknown, the receipt stays readable.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            log.Error($"Relecture d’une écriture {plan.Kind} impossible.", ex);
            return new WriteVerification(VerificationState.Unknown, "Relecture impossible : le détail technique est dans le journal.");
        }
    }

    /// <summary>
    /// Fail closed (Domenia 1 Assert-WriteAllowed, TRV-230, OPE-025, OPE-026): an uncertain receipt refuses every new write — its
    /// own target with write.targetPending, any other object with write.receiptsPending — until a conclusive re-read or a manual
    /// review settles it, never by time nor by a restart; receipts that cannot be read refuse every write.
    /// </summary>
    private async Task EnsureWritesFreeAsync(WritePlan proposed, string unreadableMessage, CancellationToken cancellationToken)
    {
        var (all, unreadable) = await ReadAsync(unreadableMessage, cancellationToken).ConfigureAwait(false);
        if (unreadable != 0) throw WriteErrors.Refusal(WriteErrors.ReceiptUnavailable, unreadableMessage);
        var pending = all.Where(r => WriteReceiptStates.BlocksWrite(r, proposed)).ToList();
        if (pending.Count == 0)
        {
            return;
        }
        if (pending.Any(r => string.Equals(r.Plan.Target.ObjectGuid, proposed.Target.ObjectGuid, StringComparison.OrdinalIgnoreCase)
            || WriteReceiptStates.SameAddress(r.Plan.Target.Dn, proposed.Target.Dn)))
        {
            throw WriteErrors.Refusal(WriteErrors.TargetPending, WriteErrors.TargetPendingMessage);
        }
        log.Info($"Écriture refusée avant tout envoi : {pending.Count} reçu(s) à vérifier bloquent les nouvelles écritures.");
        throw WriteErrors.Refusal(WriteErrors.ReceiptsPending, WriteErrors.ReceiptsPendingMessage(pending.Count));
    }

    /// <summary>
    /// After a re-read or a review: when it settled the last receipt to verify, the writes are admitted again, which is said in
    /// both journals (Domenia 1 Complete-DomeniaReceiptRefresh: the uncertainty is lifted only by an explicit check, in WARN).
    /// </summary>
    private void Settled(IReadOnlyList<WriteReceipt> before, WriteReceipt previous, WriteReceipt next)
    {
        if (!WriteReceipts.IsPending(previous) || WriteReceipts.IsPending(next))
        {
            return;
        }
        var others = before.Count(r => WriteReceipts.IsPending(r) && !string.Equals(r.Id, previous.Id, StringComparison.Ordinal));
        if (others > 0)
        {
            return;
        }
        log.Warning("Incertitude levée uniquement après vérification ou revue explicite des reçus durables : écritures de nouveau admises.");
        journal.Add(new JournalEntry(clock.GetUtcNow(), "Écritures de nouveau admises" + FrenchText.Colon + "plus aucun reçu à vérifier.", Tone.Info));
    }

    /// <summary>Receipts of the store merged with the versions of this session (the latest version of each wins).</summary>
    private async Task<(List<WriteReceipt> All, int Unreadable)> ReadAsync(string unreadableMessage, CancellationToken cancellationToken)
    {
        ReceiptLog stored;
        try
        {
            stored = await receipts.ReadAllAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (ReceiptCapacityException error)
        {
            log.Warning(error.Message);
            throw WriteErrors.Refusal("receipt.capacity", error.Message);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Reçus d’écriture illisibles ({ex.GetType().Name}) : aucune écriture n’est admise tant qu’ils ne sont pas relus.");
            throw WriteErrors.Refusal(WriteErrors.ReceiptUnavailable, unreadableMessage);
        }
        var merged = new Dictionary<string, WriteReceipt>(StringComparer.Ordinal);
        foreach (var receipt in stored.Receipts.Concat(session.Values))
        {
            if (!merged.TryGetValue(receipt.Id, out var known) || known.Version < receipt.Version)
            {
                merged[receipt.Id] = receipt;
            }
        }
        return ([.. merged.Values], stored.Unreadable);
    }

    /// <summary>Keeps a later version: in memory for the session first, then on disk; a refusal of the disk is said, never hidden.</summary>
    private async Task KeepAsync(WriteReceipt receipt)
    {
        Remember(receipt);
        try
        {
            await receipts.AppendAsync(receipt, CancellationToken.None).ConfigureAwait(false);
        }
        catch (ReceiptCapacityException error)
        {
            log.Warning(error.Message);
            journal.Add(new(clock.GetUtcNow(), "Journal des reçus saturé. Cette version reste en mémoire.", Tone.Warn));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warning($"Version {receipt.Version} d’un reçu d’écriture non enregistrée ({ex.GetType().Name}) : elle vaut pour cette session.");
            journal.Add(new JournalEntry(clock.GetUtcNow(), "Reçu d’écriture non enregistré sur le disque" + FrenchText.Colon + receipt.Plan.Label + " · " + receipt.Plan.Target.Name, Tone.Warn));
        }
    }

    private void Remember(WriteReceipt receipt) =>
        session.AddOrUpdate(receipt.Id, receipt, (_, known) => known.Version < receipt.Version ? receipt : known);

    private void Note(WritePlan plan, string outcome, Tone tone, string? prefix = null)
    {
        var head = prefix ?? (plan.Label + (plan.Simulated ? " (simulation)" : ""));
        var text = prefix is null
            ? head + FrenchText.Colon + plan.Target.Name + " · " + outcome
            : head + FrenchText.Colon + plan.Label + " · " + plan.Target.Name + " · " + outcome;
        journal.Add(new JournalEntry(clock.GetUtcNow(), text, tone));
    }

    /// <summary>Short outcome for the operations journal (« relecture conforme », « issue à vérifier »…).</summary>
    private static string Outcome(WriteReceipt receipt)
    {
        if (WriteReceipts.IsPending(receipt))
        {
            return "issue à vérifier";
        }
        return (receipt.Result, receipt.Verification) switch
        {
            (_, VerificationState.Reviewed) => "revue manuelle consignée",
            (WriteResult.Delivered, _) => "demande livrée, effet non vérifié",
            (WriteResult.Applied, VerificationState.Verified) => "relecture conforme",
            (WriteResult.Applied, VerificationState.Mismatch) => "écart à la relecture",
            (WriteResult.Applied, _) => "relecture impossible",
            (WriteResult.NoChange, _) => "déjà dans l’état demandé",
            (WriteResult.NotApplied, _) => "refus avant tout changement",
            (_, VerificationState.Verified) => "issue confirmée par relecture",
            _ => "non appliquée selon la relecture",
        };
    }

    private void ReleaseReservationLocked(WritePlan plan)
    {
        var key = WritePlans.ComputeRequestFingerprint(plan);
        if (reservations.TryGetValue(key, out var id) && id == plan.Id) reservations.Remove(key);
    }
    private void RequirePlanTime(WritePlan plan)
    {
        lock (gate)
        {
            var now = clock.GetUtcNow();
            if (!TimeIsCurrent(plan, now))
            {
                InvalidateTimeLocked(plan);
                throw WriteErrors.Refusal(WriteErrors.TokenExpired, "Horloge incohérente ou délai du plan écoulé ; préparez une nouvelle confirmation. Aucun envoi.");
            }
        }
    }
    private bool TimeIsCurrent(WritePlan plan, DateTimeOffset now)
    {
        if (now < plan.CreatedAt || now >= plan.ExpiresAt || !preparedTicks.TryGetValue(plan.Id, out var ticks)) return false;
        var elapsed = clock.GetElapsedTime(ticks);
        return elapsed >= TimeSpan.Zero && elapsed < plan.ExpiresAt - plan.CreatedAt;
    }
    private void InvalidateTimeLocked(WritePlan plan)
    {
        if (preparedTicks.Remove(plan.Id)) ReleaseReservationLocked(plan);
    }
    private void PurgeLocked(DateTimeOffset now, string requestKey)
    {
        foreach (var plan in plans.Values.Where(p => !executing.Contains(p.Id)).ToArray())
        {
            if (!TimeIsCurrent(plan, now)) InvalidateTimeLocked(plan);
        }
        if (reservations.ContainsKey(requestKey))
            throw WriteErrors.Refusal("write.reserved", "Une demande identique attend déjà sa confirmation ou son résultat. Utilisez son plan ou attendez son expiration.");
        if (plans.Count < PlanCapacity) return;
        var reserved = reservations.Values.ToHashSet(StringComparer.Ordinal);
        var oldest = plans.Values.Where(p => !reserved.Contains(p.Id) && !executing.Contains(p.Id)).MinBy(p => p.CreatedAt);
        if (oldest is null) throw WriteErrors.Refusal("write.planCapacity", "64 confirmations sont déjà en attente. Terminez un plan ou attendez son expiration.");
        plans.Remove(oldest.Id);
        origins.Remove(oldest.Id);
        preparedTicks.Remove(oldest.Id);
        tokens.Forget(oldest.Id);
    }
}
