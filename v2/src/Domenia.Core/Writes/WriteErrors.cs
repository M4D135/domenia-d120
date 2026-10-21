namespace Domenia.Core;

/// <summary>Error codes and messages of the write circuit (docs/OPERATIONS.md § 12, docs/WRITES.md). Every one says what was sent: nothing.</summary>
public static class WriteErrors
{
    public const string PlanUnknown = "write.planUnknown";
    public const string PlanUnknownMessage = "Plan d’écriture inconnu ou expiré : rien n’a été envoyé. Préparez de nouveau l’écriture.";

    public const string TokenInvalid = "write.tokenInvalid";
    public const string TokenInvalidMessage = "Jeton de confirmation refusé : rien n’a été envoyé. Préparez de nouveau l’écriture.";

    public const string TokenExpired = "write.tokenExpired";
    public const string TokenExpiredMessage = "Confirmation expirée (plan de plus de 5 min) : rien n’a été envoyé. Préparez de nouveau l’écriture pour relire l’objet.";

    public const string TokenUsed = "write.tokenUsed";
    public const string TokenUsedMessage = "Ce plan a déjà servi : une écriture ne part qu’une fois et n’est jamais rejouée. Préparez de nouveau l’écriture si besoin.";

    public const string PlanChanged = "write.planChanged";
    public const string PlanChangedMessage = "Le plan ne correspond plus à son empreinte : rien n’a été envoyé.";

    public const string ConfirmationMismatch = "write.confirmationMismatch";
    public const string ConfirmationMismatchMessage = "Le nom saisi ne correspond pas à la cible : rien n’a été envoyé. Préparez de nouveau l’écriture.";

    /// <summary>Preconditions changed since the plan; the message is the executor's reason, which always ends by saying nothing was sent.</summary>
    public const string Stale = "write.stale";

    public const string TargetPending = "write.targetPending";
    public const string TargetPendingMessage = "Une écriture précédente sur cet objet reste à vérifier : relisez son reçu dans Opérations avant d’en préparer une autre.";

    /// <summary>The target is already in the requested state; the message is the executor's (« Ce compte n’est pas verrouillé… »).</summary>
    public const string NothingToDo = "write.nothingToDo";

    public const string TargetUnknown = "write.targetUnknown";
    public const string TargetUnknownMessage = "Objet introuvable dans l’annuaire : aucune écriture préparée.";

    /// <summary>Kept on a receipt whose request left without a known outcome.</summary>
    public const string OutcomeUnknown = "write.outcomeUnknown";
    public const string OutcomeUnknownMessage = "Issue inconnue après l’envoi : vérifiez l’objet par une relecture avant toute nouvelle écriture. Rien n’est renvoyé automatiquement.";

    public const string ReceiptUnavailable = "receipt.unavailable";
    public const string ReceiptUnavailableMessage = "Reçus d’écriture illisibles ou impossibles à enregistrer : rien n’a été envoyé.";

    /// <summary>Same code when the receipts cannot be read for now: no write is prepared until they can be (fail closed).</summary>
    public const string ReceiptsUnreadableMessage = "Reçus d’écriture illisibles pour l’instant (fichier verrouillé ou accès refusé)\u00A0: aucune écriture n’est préparée tant qu’ils ne sont pas relus.";

    public const string ReceiptUnknown = "receipt.unknown";
    public const string ReceiptUnknownMessage = "Reçu introuvable : rien n’a été lu.";

    public static DomeniaOperationException Refusal(string code, string message) => new(code, message);
}
