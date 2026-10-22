using System.Collections.Concurrent;

namespace Domenia.Core;

/// <summary>Event data of « write.execute:stage »: the stage reached and its French label.</summary>
public sealed record WriteStageEvent(WriteStage Stage, string Label);

/// <summary>
/// The single write channel of the engine (docs/WRITES.md, Domenia 1 TRV-213 to TRV-235, TRV-281). Every write of every screen
/// goes through it, in this order:
/// <list type="number">
/// <item>plan: the screen's executor reads the target and drafts the change; the circuit seals it (identifier, account, mode,
/// fingerprint, five minutes) and issues a single-use token bound to the fingerprint (<see cref="PlanAsync"/>);</item>
/// <item>confirmation by the operator in the page (typed name when the plan asks for it, checked again here);</item>
/// <item>execution (<see cref="ExecuteAsync"/>): token checked then consumed, writes one at a time, uncertain receipts of the
/// same target refuse it, preconditions read again, receipt written BEFORE sending (nothing is sent without it), write sent
/// once and never cancelled, outcome recorded, target read again, receipt completed and journalled;</item>
/// <item>later re-reads from Opérations (<see cref="VerifyAsync"/>): they read, they never write again.</item>
/// </list>
/// Nothing is ever retried or replayed: not by the circuit, not at startup, not from a receipt.
/// </summary>
public sealed class WriteCircuit : IDisposable
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
        return context.Shared(static c => new WriteCircuit(c.Writers, c.Receipts, c.Directory, c.Journal, c.Clock, c.Log, c.Mode));
    }

    /// <summary>French label of a stage of write.execute.</summary>
    public static string StageLabel(WriteStage stage) => stage switch
    {
        WriteStage.Checking => "Relecture de l’objet avant l’envoi",
        WriteStage.Sending => "Reçu enregistré, envoi du changement",
        _ => "Relecture après l’écriture",
    };

    /// <summary>
    /// Seals the draft of an executor into a plan and issues its token. Refused when no executor of this mode runs the kind
    /// (source.unavailable), when an uncertain receipt holds the target (write.targetPending) or when the receipts cannot be
    /// read (receipt.unavailable). Nothing is written.
    /// </summary>
    public async Task<PlannedWrite> PlanAsync(WritePlanDraft draft, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(draft);
        if (writers.ForKind(draft.Kind) is null)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        }
        var account = await directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        await EnsureTargetFreeAsync(draft.Target.ObjectGuid, WriteErrors.ReceiptsUnreadableMessage, cancellationToken).ConfigureAwait(false);
        var now = clock.GetUtcNow();
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), account.Account.Login, mode, now, clock.LocalTimeZone);
        var token = tokens.Issue(plan.Id, plan.Fingerprint, plan.ExpiresAt, now);
        lock (gate)
        {
            PurgeLocked(now);
            plans[plan.Id] = plan;
        }
        log.Info($"Plan d’écriture {plan.Kind} préparé ({plan.Changes.Length} changement(s), confirmation {(plan.Confirmation.TypedNameRequired ? "par saisie du nom" : "simple")}).");
        return new PlannedWrite(plan, token);
    }

    /// <summary>
    /// write.execute: runs a confirmed plan once and returns its receipt. Refusals before sending: write.planUnknown,
    /// write.tokenUsed, write.tokenInvalid, write.planChanged, write.tokenExpired, write.confirmationMismatch, write.targetPending,
    /// write.stale, receipt.unavailable. Once the receipt is written, the request leaves and the call always ends with a receipt
    /// (applied, already done, refused or unknown), whatever happens.
    /// </summary>
    public async Task<ReceiptView> ExecuteAsync(string planId, string token, string? typedName, Action<WriteStage>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(planId);
        ArgumentNullException.ThrowIfNull(token);
        WritePlan? plan;
        lock (gate)
        {
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
                throw WriteErrors.Refusal(WriteErrors.TokenExpired, WriteErrors.TokenExpiredMessage);
        }
        if (plan.Confirmation.TypedNameRequired && !string.Equals(typedName, plan.Confirmation.TypedName, StringComparison.Ordinal))
        {
            // Fail closed: the page never sends a name that differs, so the plan is spent.
            tokens.Consume(planId);
            Note(plan, "nom saisi différent de la cible", Tone.Warn, prefix: "Écriture non envoyée");
            throw WriteErrors.Refusal(WriteErrors.ConfirmationMismatch, WriteErrors.ConfirmationMismatchMessage);
        }
        if (!tokens.Consume(planId))
        {
            // The second click of a double click, or a second page: the plan already left (or was refused).
            throw WriteErrors.Refusal(WriteErrors.TokenUsed, WriteErrors.TokenUsedMessage);
        }
        log.Info($"Écriture {plan.Kind} confirmée par l’opérateur.");
        await writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await RunAsync(plan, progress, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            writeGate.Release();
        }
    }

    /// <summary>write.receipts.list: every receipt of this mode, uncertain ones first.</summary>
    public async Task<ReceiptList> ListAsync(CancellationToken cancellationToken)
    {
        var (all, unreadable) = await ReadAsync(WriteErrors.ReceiptsUnreadableMessage, cancellationToken).ConfigureAwait(false);
        return WriteReceipts.List(all, unreadable);
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
    /// back new writes on its target.
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
            var verification = await ReadBackAsync(executor, receipt.Plan, cancellationToken).ConfigureAwait(false);
            var next = WriteReceipts.Verified(receipt, verification, clock.GetUtcNow());
            await KeepAsync(next).ConfigureAwait(false);
            Note(next.Plan, Outcome(next), WriteReceipts.ToneOf(next), prefix: "Relecture du reçu");
            log.Info($"Relecture du reçu d’une écriture {receipt.Plan.Kind} : {verification.State}.");
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
    /// receipt takes a new version « Revue manuelle » that stops holding back new writes on its target. Nothing is read in the
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
            return WriteReceipts.View(next);
        }
        finally
        {
            writeGate.Release();
        }
    }

    public void Dispose() => writeGate.Dispose();

    private async Task<ReceiptView> RunAsync(WritePlan plan, Action<WriteStage>? progress, CancellationToken cancellationToken)
    {
        await EnsureTargetFreeAsync(plan.Target.ObjectGuid, WriteErrors.ReceiptUnavailableMessage, cancellationToken).ConfigureAwait(false);
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

        // The receipt is durable BEFORE the request leaves (TRV-281): without it, nothing is sent.
        var receipt = WriteReceipts.Sent(plan, WritePlans.NewId(), clock.GetUtcNow(), new ReceiptDetail("Préconditions", precheck.Detail));
        try
        {
            await receipts.AppendAsync(receipt, CancellationToken.None).ConfigureAwait(false);
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
        try
        {
            outcome = await executor.ExecuteAsync(plan, CancellationToken.None).ConfigureAwait(false);
            if (outcome.Result is WriteResult.Sent or WriteResult.Unknown)
            {
                // An executor never reports « sent »: an answer without an outcome is an unknown outcome.
                error = new ReceiptError(WriteErrors.OutcomeUnknown, WriteErrors.OutcomeUnknownMessage);
                outcome = new WriteOutcome(WriteResult.Unknown, outcome.Detail);
            }
        }
        catch (DomeniaOperationException ex)
        {
            // Expected refusal before anything was applied (rights, conflict detected by the controller…).
            outcome = new WriteOutcome(WriteResult.NotApplied, ex.Message);
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
        receipt = WriteReceipts.Completed(receipt, outcome, error, clock.GetUtcNow());
        await KeepAsync(receipt).ConfigureAwait(false);

        progress?.Invoke(WriteStage.Verifying);
        var verification = await ReadBackAsync(executor, plan, cancellationToken).ConfigureAwait(false);
        receipt = WriteReceipts.Verified(receipt, verification, clock.GetUtcNow());
        await KeepAsync(receipt).ConfigureAwait(false);

        Note(plan, Outcome(receipt), WriteReceipts.ToneOf(receipt));
        log.Info($"Écriture {plan.Kind} : {receipt.Result}, relecture {receipt.Verification}.");
        return WriteReceipts.View(receipt);
    }

    /// <summary>Re-read of the target: any failure is an unknown verification, never an exception for the caller.</summary>
    private async Task<WriteVerification> ReadBackAsync(IWriteExecutor executor, WritePlan plan, CancellationToken cancellationToken)
    {
        try
        {
            return await executor.VerifyAsync(plan, cancellationToken).ConfigureAwait(false);
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
    /// Fail closed (TRV-230): an uncertain receipt of the same target refuses the write; receipts that cannot be read refuse
    /// every write.
    /// </summary>
    private async Task EnsureTargetFreeAsync(string objectGuid, string unreadableMessage, CancellationToken cancellationToken)
    {
        var (all, _) = await ReadAsync(unreadableMessage, cancellationToken).ConfigureAwait(false);
        if (all.Any(r => WriteReceipts.IsPending(r) && string.Equals(r.Plan.Target.ObjectGuid, objectGuid, StringComparison.OrdinalIgnoreCase)))
        {
            throw WriteErrors.Refusal(WriteErrors.TargetPending, WriteErrors.TargetPendingMessage);
        }
    }

    /// <summary>Receipts of the store merged with the versions of this session (the latest version of each wins).</summary>
    private async Task<(List<WriteReceipt> All, int Unreadable)> ReadAsync(string unreadableMessage, CancellationToken cancellationToken)
    {
        ReceiptLog stored;
        try
        {
            stored = await receipts.ReadAllAsync(cancellationToken).ConfigureAwait(false);
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
            (WriteResult.Applied, VerificationState.Verified) => "relecture conforme",
            (WriteResult.Applied, VerificationState.Mismatch) => "écart à la relecture",
            (WriteResult.Applied, _) => "relecture impossible",
            (WriteResult.NoChange, _) => "déjà dans l’état demandé",
            (WriteResult.NotApplied, _) => "refus avant tout changement",
            (_, VerificationState.Verified) => "issue confirmée par relecture",
            _ => "non appliquée selon la relecture",
        };
    }

    private void PurgeLocked(DateTimeOffset now)
    {
        foreach (var id in plans.Where(p => now >= p.Value.ExpiresAt + WritePlans.Lifetime).Select(p => p.Key).ToList())
        {
            plans.Remove(id);
        }
        while (plans.Count >= PlanCapacity)
        {
            plans.Remove(plans.MinBy(p => p.Value.CreatedAt).Key);
        }
    }
}
