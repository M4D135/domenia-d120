using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Domenia.Core;

/// <summary>
/// Collective plans of the Comptes screen (Domenia 1 TRV-229, docs/WRITES.md § 1 « une écriture collective aura son propre plan
/// avec un aperçu exact »). The engine seals the exact preview: identifier, action, date, the targets (DN and GUID) in their
/// order, the number of targets and the fingerprint of all of it. The page confirms by typing the number (from two targets
/// on), which the engine checks again; only then does it hand out the plan of each target, once per target, for a sealed GUID
/// only. A target whose GUID changed since the preview gets no plan. Nothing here writes: every target still goes through
/// its own plan, write.execute, receipt and re-read. Thread safe; shared by the modules of the context.
/// </summary>
public sealed class AccountsBatchSeals : IDisposable
{
    /// <summary>Time left to confirm a preview, and between two plans of a confirmed batch (sliding).</summary>
    public static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(10);

    /// <summary>Most batches kept at once (the oldest goes first).</summary>
    public const int Capacity = 16;

    public const string Unknown = "accounts.batchUnknown";
    public const string Expired = "accounts.batchExpired";
    public const string CountMismatch = "accounts.batchCountMismatch";
    public const string Unconfirmed = "accounts.batchUnconfirmed";
    public const string AlreadyIssued = "accounts.batchIssued";
    public const string TargetChanged = "accounts.batchTargetChanged";
    public const string TypedNameRequired = "accounts.batchTypedName";

    private readonly Lock gate = new();
    private readonly Dictionary<string, Sealed> batches = new(StringComparer.Ordinal);
    private readonly Dictionary<string, CancellationTokenSource> previews = new(StringComparer.Ordinal);
    private readonly TimeProvider clock;

    public AccountsBatchSeals(TimeProvider clock)
    {
        ArgumentNullException.ThrowIfNull(clock);
        this.clock = clock;
    }

    /// <summary>The batches shared by the modules of the context.</summary>
    public static AccountsBatchSeals From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new AccountsBatchSeals(c.Clock));
    }

    /// <summary>Fingerprint of an exact list: SHA-256 of « action|date|count|guid,guid,… » (GUIDs in their order).</summary>
    public static string Fingerprint(AccountsBatchAction action, DateOnly? date, IReadOnlyList<string> guids)
    {
        ArgumentNullException.ThrowIfNull(guids);
        var text = AccountsBatch.ActionId(action) + "|" + (date?.ToString("yyyy'-'MM'-'dd", CultureInfo.InvariantCulture) ?? "never") + "|"
            + guids.Count.ToString(CultureInfo.InvariantCulture) + "|" + string.Join(',', guids.Select(g => g.ToLowerInvariant()));
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    }

    /// <summary>Seals <paramref name="preview"/> (its targets only, in order) and returns it with its seal.</summary>
    public AccountsBatchPreview Seal(AccountsBatchPreview preview, string? operatorDn)
    {
        ArgumentNullException.ThrowIfNull(preview);
        var now = clock.GetUtcNow();
        var targets = preview.Targets.Select(t => new SealedTarget(t.Dn, t.Guid, t.Name)).ToImmutableArray();
        var fingerprint = Fingerprint(preview.Action, preview.Date, [.. targets.Select(t => t.Guid)]);
        var id = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
        var typed = preview.Confirmation == "typed";
        var batch = new Sealed(id, preview.Action, preview.Date, targets, fingerprint, typed, operatorDn, now + Lifetime);
        lock (gate)
        {
            PurgeLocked(now);
            while (batches.Count >= Capacity)
            {
                batches.Remove(batches.Values.OrderBy(b => b.ExpiresAt).First().Id);
            }
            batches[id] = batch;
        }
        return preview with { Batch = new AccountsBatchSeal(id, fingerprint, targets.Length, typed, batch.ExpiresAt, false) };
    }

    /// <summary>
    /// accounts.batch.confirm: the number typed by the operator, checked by the engine (case of a typed confirmation). A wrong
    /// number spends the batch: the preview is to be read again. Errors: accounts.batchUnknown, accounts.batchExpired,
    /// accounts.batchCountMismatch.
    /// </summary>
    public AccountsBatchSeal Confirm(string id, string? typedCount)
    {
        ArgumentNullException.ThrowIfNull(id);
        var now = clock.GetUtcNow();
        lock (gate)
        {
            var batch = FindLocked(id, now);
            if (batch.Confirmed)
            {
                return View(batch);
            }
            if (batch.Targets.Length == 0)
            {
                batches.Remove(id);
                throw new DomeniaOperationException(Unknown, "Aucun compte à traiter dans cet aperçu" + FrenchText.Colon + "rien n’est préparé.");
            }
            var expected = batch.Targets.Length.ToString(CultureInfo.InvariantCulture);
            if (batch.TypedRequired && !string.Equals(typedCount?.Trim(), expected, StringComparison.Ordinal))
            {
                batches.Remove(id);
                throw new DomeniaOperationException(CountMismatch, "Le nombre saisi ne correspond pas au nombre exact de comptes" + FrenchText.Colon + "rien n’a été préparé. Relisez l’aperçu puis confirmez de nouveau.");
            }
            batch.Confirmed = true;
            batch.ExpiresAt = now + Lifetime;
            return View(batch);
        }
    }

    /// <summary>
    /// The sealed target at <paramref name="index"/> of a confirmed batch, handed out once: its DN to read and its GUID to
    /// compare. Errors: accounts.batchUnknown, accounts.batchExpired, accounts.batchUnconfirmed, accounts.batchIssued,
    /// arguments are checked by the caller.
    /// </summary>
    public (AccountsBatchAction Action, DateOnly? Date, string Dn, string Guid, string? OperatorDn) Issue(string id, int index)
    {
        ArgumentNullException.ThrowIfNull(id);
        var now = clock.GetUtcNow();
        lock (gate)
        {
            var batch = FindLocked(id, now);
            if (!batch.Confirmed)
            {
                throw new DomeniaOperationException(Unconfirmed, "Ce lot n’est pas confirmé" + FrenchText.Colon + "aucun plan n’est préparé avant la confirmation.");
            }
            if (index < 0 || index >= batch.Targets.Length)
            {
                throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Arguments invalides" + FrenchText.Colon + FrenchText.Quote("index") + " doit désigner un compte de l’aperçu scellé.");
            }
            if (!batch.Issued.Add(index))
            {
                throw new DomeniaOperationException(AlreadyIssued, "Ce compte du lot a déjà reçu son plan" + FrenchText.Colon + "une écriture n’est jamais rejouée.");
            }
            batch.ExpiresAt = now + Lifetime;
            var target = batch.Targets[index];
            return (batch.Action, batch.Date, target.Dn, target.Guid, batch.OperatorDn);
        }
    }

    /// <summary>
    /// Registers the cancellation of a running preview read under the ticket of the page (the caller owns and disposes the
    /// source; a former read of the same ticket is cancelled).
    /// </summary>
    public CancellationTokenSource Track(string ticket)
    {
        ArgumentNullException.ThrowIfNull(ticket);
        var source = new CancellationTokenSource();
        CancellationTokenSource? previous;
        lock (gate)
        {
            previews.Remove(ticket, out previous);
            previews[ticket] = source;
        }
        CancelQuietly(previous);
        return source;
    }

    /// <summary>Forgets the ticket of a preview read that ended (the caller disposes its source).</summary>
    public void Untrack(string ticket, CancellationTokenSource source)
    {
        ArgumentNullException.ThrowIfNull(ticket);
        ArgumentNullException.ThrowIfNull(source);
        lock (gate)
        {
            if (previews.TryGetValue(ticket, out var current) && ReferenceEquals(current, source))
            {
                previews.Remove(ticket);
            }
        }
    }

    /// <summary>accounts.batch.cancel: stops the preview read of this ticket (nothing was prepared); false when none runs.</summary>
    public bool Cancel(string ticket)
    {
        ArgumentNullException.ThrowIfNull(ticket);
        CancellationTokenSource? source;
        lock (gate)
        {
            if (!previews.TryGetValue(ticket, out source))
            {
                return false;
            }
        }
        // Outside the lock: the cancelled read may end on this thread and forget its ticket.
        CancelQuietly(source);
        return true;
    }

    public void Dispose()
    {
        List<CancellationTokenSource> running;
        lock (gate)
        {
            running = [.. previews.Values];
            previews.Clear();
            batches.Clear();
        }
        running.ForEach(CancelQuietly);
    }

    /// <summary>Cancels a read whose owner may have just disposed its source (it ended meanwhile: nothing to stop).</summary>
    private static void CancelQuietly(CancellationTokenSource? source)
    {
        try
        {
            source?.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // The read ended between the lookup and the cancel: nothing to stop.
        }
    }

    private Sealed FindLocked(string id, DateTimeOffset now)
    {
        if (!batches.TryGetValue(id, out var batch))
        {
            throw new DomeniaOperationException(Unknown, "Aperçu collectif inconnu" + FrenchText.Colon + "rien n’a été préparé. Relisez l’aperçu.");
        }
        if (batch.ExpiresAt <= now)
        {
            batches.Remove(id);
            throw new DomeniaOperationException(Expired, "Aperçu collectif expiré (plus de " + FrenchText.Integer((long)Lifetime.TotalMinutes) + " min sans geste)" + FrenchText.Colon + "rien n’a été préparé. Relisez l’aperçu.");
        }
        return batch;
    }

    private void PurgeLocked(DateTimeOffset now)
    {
        foreach (var id in batches.Values.Where(b => b.ExpiresAt <= now).Select(b => b.Id).ToList())
        {
            batches.Remove(id);
        }
    }

    private static AccountsBatchSeal View(Sealed batch) =>
        new(batch.Id, batch.Fingerprint, batch.Targets.Length, batch.TypedRequired, batch.ExpiresAt, batch.Confirmed);

    private sealed record SealedTarget(string Dn, string Guid, string Name);

    private sealed class Sealed(string id, AccountsBatchAction action, DateOnly? date, ImmutableArray<SealedTarget> targets, string fingerprint, bool typedRequired, string? operatorDn, DateTimeOffset expiresAt)
    {
        public string Id { get; } = id;

        public AccountsBatchAction Action { get; } = action;

        public DateOnly? Date { get; } = date;

        public ImmutableArray<SealedTarget> Targets { get; } = targets;

        public string Fingerprint { get; } = fingerprint;

        public bool TypedRequired { get; } = typedRequired;

        public string? OperatorDn { get; } = operatorDn;

        public DateTimeOffset ExpiresAt { get; set; } = expiresAt;

        public bool Confirmed { get; set; }

        public HashSet<int> Issued { get; } = [];
    }
}
