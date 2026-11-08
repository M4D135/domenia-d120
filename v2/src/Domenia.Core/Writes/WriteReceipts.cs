using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Local receipts distinguish transport, re-read and manual review. Pending or unreadable evidence blocks new sends.
/// Only an explicit cancellation linked to its acknowledged delayed restart may pass that receipt. Nothing is replayed.
/// </summary>
public static class WriteReceipts
{
    /// <summary>Most rows returned by write.receipts.list (most recent first, uncertain ones always included).</summary>
    public const int ListLimit = 500;

    private const string SimulationNote = " Simulation : annuaire fictif en mémoire, aucun effet réel.";
    private const string NoReplay = " Rien n’est renvoyé automatiquement.";

    /// <summary>First version, written before the request leaves.</summary>
    public static WriteReceipt Sent(WritePlan plan, string id, DateTimeOffset at, ReceiptDetail precheck)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(precheck);
        var when = WritePlans.TruncateToSecond(at);
        return new WriteReceipt(id, 1, plan, when, when, null, null, plan.Operator, plan.Mode, plan.Simulated,
            WriteResult.Sent, VerificationState.Unknown, [precheck], null);
    }

    /// <summary>Next version with the outcome of the request.</summary>
    public static WriteReceipt Completed(WriteReceipt receipt, WriteOutcome outcome, ReceiptError? error, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        ArgumentNullException.ThrowIfNull(outcome);
        if (receipt.Result != WriteResult.Sent || receipt.CompletedAt.HasValue || receipt.Verification != VerificationState.Unknown
            || !Enum.IsDefined(outcome.Result) || outcome.Result == WriteResult.Sent)
            throw new InvalidOperationException("Une issue d’envoi est enregistrée une seule fois.");
        if (outcome.Result == WriteResult.Delivered && !WriteReceiptStates.AllowsDelivery(receipt.Plan.Kind))
            throw new InvalidOperationException("Ce type d’écriture ne peut pas être déclaré simplement livré.");
        var when = WritePlans.TruncateToSecond(at);
        if (when < receipt.At) when = receipt.At;
        return receipt with
        {
            Version = receipt.Version + 1,
            At = when,
            CompletedAt = when,
            Result = outcome.Result,
            Error = error,
            Details = receipt.Details.Add(new ReceiptDetail("Envoi", outcome.Detail)),
        };
    }

    /// <summary>Next version with a re-read of the target (after the write, or later from Opérations).</summary>
    public static WriteReceipt Verified(WriteReceipt receipt, WriteVerification verification, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        ArgumentNullException.ThrowIfNull(verification);
        if (!Enum.IsDefined(verification.State) || verification.State == VerificationState.Reviewed)
            throw new InvalidOperationException("Une relecture ne peut pas inventer une revue humaine.");
        var when = WritePlans.TruncateToSecond(at);
        if (when < receipt.At) when = receipt.At;
        return receipt with
        {
            Version = receipt.Version + 1,
            At = when,
            VerifiedAt = when,
            // A failed later read cannot erase a previous observation or the operator's explicit review.
            // Its failure is appended to Details while the last conclusive evidence remains available.
            Verification = receipt.Verification != VerificationState.Unknown && verification.State == VerificationState.Unknown
                ? receipt.Verification
                : verification.State,
            Details = receipt.Details.Add(new ReceiptDetail("Relecture", verification.Detail)),
        };
    }

    /// <summary>
    /// Next version with a manual review of the operator (Domenia 1 OPE-024): the control made with another tool, in the operator's
    /// own words (already checked by <see cref="ReceiptReviews.CheckReason"/>), quoted in the details. It settles an uncertain
    /// receipt; it is never an automatic success (tone info, label « Revue manuelle »).
    /// </summary>
    public static WriteReceipt Reviewed(WriteReceipt receipt, string reason, string reviewer, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        ArgumentNullException.ThrowIfNull(reason);
        ArgumentNullException.ThrowIfNull(reviewer);
        if (!IsPending(receipt) || !WriteReceiptStates.IsKnown(receipt))
            throw new InvalidOperationException("Seul un reçu connu encore incertain peut recevoir une revue manuelle.");
        var when = WritePlans.TruncateToSecond(at);
        if (when < receipt.At) when = receipt.At;
        // One final period stays outside the quotes (one period, never an ellipsis: Domenia 1 Get-DomeniaReceiptActionView).
        var quoted = reason.Trim();
        if (quoted.EndsWith('.') && !quoted.EndsWith("..", StringComparison.Ordinal))
        {
            quoted = quoted[..^1];
        }
        return receipt with
        {
            Version = receipt.Version + 1,
            At = when,
            VerifiedAt = when,
            Verification = VerificationState.Reviewed,
            Details = receipt.Details.Add(new ReceiptDetail("Revue manuelle", "Motif consigné par " + reviewer + FrenchText.Colon + FrenchText.Quote(quoted) + ".")),
        };
    }

    /// <summary>True while the receipt holds back admission to the write channel.</summary>
    public static bool IsPending(WriteReceipt receipt)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        return !WriteReceiptStates.IsKnown(receipt) || receipt.Verification == VerificationState.Unknown
            && receipt.Result is not (WriteResult.NoChange or WriteResult.Delivered);
    }

    public static string ResultLabel(WriteResult result, bool simulated) => result switch
    {
        WriteResult.Sent => "Envoyée, issue à vérifier",
        WriteResult.Applied => simulated ? "Appliquée (simulation)" : "Appliquée",
        WriteResult.NoChange => "Déjà faite : rien envoyé",
        WriteResult.NotApplied => "Non appliquée",
        WriteResult.Delivered => "Demande livrée, effet non vérifié",
        _ => "Issue inconnue, à vérifier",
    };

    public static string VerificationLabel(WriteResult result, VerificationState verification) => verification switch
    {
        VerificationState.Verified => "Vérifiée par relecture",
        VerificationState.Reviewed => "Revue manuelle",
        VerificationState.Mismatch => result == WriteResult.NotApplied ? "Relue : objet inchangé" : "Écart à la relecture",
        _ => result == WriteResult.Sent ? "Relecture en attente" : "Non vérifiée",
    };

    public static Tone ToneOf(WriteReceipt receipt)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        if (IsPending(receipt))
        {
            return Tone.Warn;
        }
        return (receipt.Result, receipt.Verification) switch
        {
            // A manual review is recorded, never an automatic success.
            (_, VerificationState.Reviewed) => Tone.Info,
            (WriteResult.Delivered, _) => Tone.Info,
            (WriteResult.Applied or WriteResult.NoChange, VerificationState.Verified) => Tone.Ok,
            (WriteResult.Applied or WriteResult.NoChange, VerificationState.Mismatch) => Tone.Alert,
            (WriteResult.Applied or WriteResult.NoChange, _) => Tone.Warn,
            (WriteResult.NotApplied, VerificationState.Verified) => Tone.Info,
            (WriteResult.NotApplied, _) => Tone.Alert,
            (_, VerificationState.Verified) => Tone.Ok,
            _ => Tone.Info,
        };
    }

    /// <summary>One sentence for the operator: what happened, what the re-read says and what to do.</summary>
    public static string SummaryOf(WriteReceipt receipt)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        var simulated = receipt.Simulated ? SimulationNote : "";
        if (IsPending(receipt))
        {
            var start = receipt.Result switch
            {
                WriteResult.Sent => "Écriture envoyée sans confirmation (application fermée ou interrompue) : issue à vérifier par une relecture.",
                WriteResult.Applied => "Écriture acquittée, mais état final non relu : vérifiez le reçu dans Opérations.",
                WriteResult.NotApplied => "Refus enregistré, mais état de la cible non relu : vérifiez le reçu dans Opérations.",
                _ => "Issue inconnue après l’envoi : vérifiez par une relecture.",
            };
            return start + NoReplay + " Les nouvelles écritures restent bloquées jusqu’à sa vérification ou sa revue.";
        }
        return (receipt.Result, receipt.Verification) switch
        {
            (_, VerificationState.Reviewed) => "Revue manuelle consignée : l’objet a été contrôlé avec un autre outil, ce n’est pas une vérification automatique. Ce reçu ne bloque plus les nouvelles écritures." + NoReplay + simulated,
            (WriteResult.Delivered, _) => "Demande livrée et transport terminé ; les artefacts propres à Domenia ont été nettoyés. L’effet sur le poste n’est pas prouvé par ce reçu." + NoReplay + simulated,
            (WriteResult.Applied, VerificationState.Verified) => "Écriture appliquée et vérifiée par relecture." + simulated,
            (WriteResult.Applied, VerificationState.Mismatch) => "Écriture acceptée, mais la relecture montre un autre état : vérifiez l’objet avant toute nouvelle écriture." + NoReplay + simulated,
            (WriteResult.Applied, _) => "Écriture acceptée, relecture impossible : relisez ce reçu depuis Opérations pour la vérifier." + simulated,
            (WriteResult.NoChange, _) => "L’objet était déjà dans l’état demandé : rien n’a été envoyé.",
            (WriteResult.NotApplied, _) => "Écriture refusée avant tout changement : rien n’a été modifié." + NoReplay,
            (_, VerificationState.Verified) => "Issue confirmée par une relecture : l’écriture a bien été appliquée." + simulated,
            _ => "Relecture : l’écriture n’a pas été appliquée." + NoReplay + " Préparez un nouveau plan si besoin.",
        };
    }

    public static ReceiptRow Row(WriteReceipt receipt)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        var plan = receipt.Plan;
        return new ReceiptRow(
            receipt.Id,
            plan.Kind,
            plan.Title,
            plan.Label,
            plan.Target,
            receipt.At,
            receipt.SentAt,
            receipt.CompletedAt,
            receipt.VerifiedAt,
            receipt.Operator,
            plan.Controller,
            receipt.Mode,
            receipt.Simulated,
            receipt.Result,
            ResultLabel(receipt.Result, receipt.Simulated),
            receipt.Verification,
            VerificationLabel(receipt.Result, receipt.Verification),
            IsPending(receipt),
            ToneOf(receipt),
            SummaryOf(receipt),
            receipt.Error);
    }

    public static ReceiptView View(WriteReceipt receipt)
    {
        var row = Row(receipt);
        return new ReceiptView(
            row.Id, row.Kind, row.Title, row.Label, row.Target, row.At, row.SentAt, row.CompletedAt, row.VerifiedAt, row.Operator,
            row.Controller, row.Mode, row.Simulated, row.Result, row.ResultLabel, row.Verification, row.VerificationLabel,
            row.Pending, row.Tone, row.Summary, row.Error, receipt.Details, receipt.Plan);
    }

    /// <summary>The list: uncertain receipts first, then the most recent; at most <see cref="ListLimit"/> rows.</summary>
    public static ReceiptList List(IEnumerable<WriteReceipt> receipts, int unreadable)
    {
        ArgumentNullException.ThrowIfNull(receipts);
        var all = receipts.ToList();
        var ordered = all
            .OrderByDescending(IsPending)
            .ThenByDescending(r => r.At)
            .ThenBy(r => r.Id, StringComparer.Ordinal)
            .ToList();
        var pending = ordered.Count(IsPending);
        var shown = ordered.Take(Math.Max(ListLimit, pending)).Select(Row).ToImmutableArray();
        return new ReceiptList(all.Count, pending, unreadable, shown.Length < all.Count, ListSummary(all.Count, pending, unreadable), shown);
    }

    /// <summary>
    /// Sentence above the receipts (Domenia 1 Get-DomeniaReceiptSummary): a receipt to verify holds every new write back until its
    /// verification or its review.
    /// </summary>
    public static string ListSummary(int total, int pending, int unreadable)
    {
        var text = pending switch
        {
            1 => "Une opération reste à vérifier\u00A0: les nouvelles écritures sont bloquées jusqu’à sa vérification ou sa revue." + NoReplay,
            > 1 => FrenchText.Integer(pending) + " opérations restent à vérifier\u00A0: les nouvelles écritures sont bloquées jusqu’à leur vérification ou leur revue." + NoReplay,
            _ => total switch
            {
                0 => "Aucun reçu d’écriture." + NoReplay,
                1 => "Aucune écriture à vérifier. Un reçu conservé ; rien n’est renvoyé automatiquement.",
                _ => "Aucune écriture à vérifier. " + FrenchText.Integer(total) + " reçus conservés ; rien n’est renvoyé automatiquement.",
            },
        };
        if (unreadable > 0)
        {
            text += " " + (unreadable == 1 ? "Un enregistrement illisible : écritures bloquées jusqu’à contrôle." : FrenchText.Integer(unreadable) + " enregistrements illisibles : écritures bloquées jusqu’à contrôle.");
        }
        return text;
    }
}
