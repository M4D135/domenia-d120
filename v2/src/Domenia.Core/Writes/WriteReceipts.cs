using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Receipts in plain words (pure, Domenia 1 UI-18): labels of the result and of the re-read, tone, whether a receipt still
/// holds back new writes on its target, sentences of a receipt and of the list. A receipt is uncertain while its request
/// left without a known outcome (<see cref="WriteResult.Sent"/> or <see cref="WriteResult.Unknown"/>) and no re-read settled
/// it: it then blocks new writes on its own target only (TRV-230), never the whole application, until
/// write.receipts.verify reads the object again. Nothing in a receipt is ever sent again (TRV-231).
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
        var when = WritePlans.TruncateToSecond(at);
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
        var when = WritePlans.TruncateToSecond(at);
        return receipt with
        {
            Version = receipt.Version + 1,
            At = when,
            VerifiedAt = when,
            Verification = verification.State,
            Details = receipt.Details.Add(new ReceiptDetail("Relecture", verification.Detail)),
        };
    }

    /// <summary>True while the receipt holds back new writes on its target.</summary>
    public static bool IsPending(WriteReceipt receipt)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        return (receipt.Result is WriteResult.Sent or WriteResult.Unknown) && receipt.Verification == VerificationState.Unknown;
    }

    public static string ResultLabel(WriteResult result, bool simulated) => result switch
    {
        WriteResult.Sent => "Envoyée, issue à vérifier",
        WriteResult.Applied => simulated ? "Appliquée (simulation)" : "Appliquée",
        WriteResult.NoChange => "Déjà faite : rien envoyé",
        WriteResult.NotApplied => "Non appliquée",
        _ => "Issue inconnue, à vérifier",
    };

    public static string VerificationLabel(WriteResult result, VerificationState verification) => verification switch
    {
        VerificationState.Verified => "Vérifiée par relecture",
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
            var start = receipt.Result == WriteResult.Sent
                ? "Écriture envoyée sans confirmation (application fermée ou interrompue) : issue à vérifier par une relecture."
                : "Issue inconnue après l’envoi : vérifiez par une relecture.";
            return start + NoReplay + " Les nouvelles écritures sur cet objet restent bloquées jusqu’à la vérification.";
        }
        return (receipt.Result, receipt.Verification) switch
        {
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

    /// <summary>Sentence above the receipts (Domenia 1 Get-DomeniaReceiptSummary, blocking per target).</summary>
    public static string ListSummary(int total, int pending, int unreadable)
    {
        var text = pending switch
        {
            1 => "Une écriture reste à vérifier : les nouvelles écritures sur son objet sont bloquées jusqu’à sa relecture." + NoReplay,
            > 1 => FrenchText.Integer(pending) + " écritures restent à vérifier : les nouvelles écritures sur leurs objets sont bloquées jusqu’à leur relecture." + NoReplay,
            _ => total switch
            {
                0 => "Aucun reçu d’écriture." + NoReplay,
                1 => "Aucune écriture à vérifier. Un reçu conservé ; rien n’est renvoyé automatiquement.",
                _ => "Aucune écriture à vérifier. " + FrenchText.Integer(total) + " reçus conservés ; rien n’est renvoyé automatiquement.",
            },
        };
        if (unreadable > 0)
        {
            text += " " + (unreadable == 1 ? "Un enregistrement illisible ignoré." : FrenchText.Integer(unreadable) + " enregistrements illisibles ignorés.");
        }
        return text;
    }
}
