using System.Collections.Immutable;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>Result of the check of a review motive (Domenia 1 Test-DomeniaReceiptReviewReason).</summary>
public sealed record ReviewReasonCheck(bool Valid, string Text, int Length, string Message);

/// <summary>
/// What the detail of a receipt offers (Domenia 1 Get-DomeniaReceiptActionView, improved): the sentence of the selection, whether
/// a re-read can be asked (a read, never the write again), whether a manual review can be recorded, and why not.
/// </summary>
public sealed record ReceiptActions(string Selection, bool CanVerify, string? VerifyWhy, bool CanReview, string? ReviewWhy, ImmutableArray<string> Templates);

/// <summary>The oldest receipt to verify, shown when the pill is hovered (Domenia 1 OPE-026 improvement).</summary>
/// <param name="Text">« Le plus ancien : Déverrouillage du compte · Lucas Moreau, envoyée le 22/10/2026 à 09:41. »</param>
public sealed record PendingOldest(string Id, string Label, string Target, string TargetKind, DateTimeOffset At, string Text);

/// <summary>
/// The header pill « opérations à vérifier » (Domenia 1 Get-DomeniaPendingOperationsView): never « 0 opération ». While it is
/// visible, every new write stays blocked (Domenia 1 Assert-WriteAllowed, OPE-025, OPE-026).
/// </summary>
public sealed record PendingPill(bool Visible, string Text, string Help, PendingOldest? Oldest);

/// <summary>
/// Manual reviews of uncertain receipts and the masking of what looks like a secret (Domenia 1 Domenia-Safety.Model.ps1 and
/// Protect-DomeniaSecretText). Pure: no clock, no culture.
/// </summary>
public static partial class ReceiptReviews
{
    public const int MinLength = 12;
    public const int MaxLength = 240;

    public const string Resolved = "receipt.resolved";
    public const string ResolvedMessage = "Ce reçu est déjà résolu : il ne bloque plus aucune écriture et n’est pas modifié.";

    public const string ReasonInvalid = "receipt.reviewInvalid";
    public const string ReasonInvalidPrefix = "Motif de la revue : ";

    /// <summary>
    /// Checks the motive of a manual review: 12 to 240 characters once trimmed (the bounds of the receipts), and nothing that looks
    /// like a secret (what <see cref="Mask"/> would hide). The message is shown live under the field.
    /// </summary>
    public static ReviewReasonCheck CheckReason(string? reason)
    {
        var text = (reason ?? "").Trim();
        var length = text.Length;
        if (length == 0)
        {
            return new ReviewReasonCheck(false, text, 0, "décrivez le contrôle réalisé (12 à 240 caractères).");
        }
        if (length < MinLength)
        {
            return new ReviewReasonCheck(false, text, length, FrenchText.Count(length, "caractère", "caractères") + FrenchText.Colon + "12 au minimum.");
        }
        if (length > MaxLength)
        {
            return new ReviewReasonCheck(false, text, length, FrenchText.Count(length, "caractère", "caractères") + FrenchText.Colon + "240 au maximum.");
        }
        if (LooksSecret(text))
        {
            return new ReviewReasonCheck(false, text, length, "le motif ressemble à un secret : décrivez le contrôle sans recopier de mot de passe, de clé ni de jeton.");
        }
        return new ReviewReasonCheck(true, text, length, FrenchText.Integer(length) + " / 240 caractères.");
    }

    /// <summary>True when <see cref="Mask"/> would change the text.</summary>
    public static bool LooksSecret(string? text) => !string.IsNullOrEmpty(text) && !string.Equals(Mask(text), text, StringComparison.Ordinal);

    /// <summary>
    /// Masks what looks like a secret before a text reaches a journal, a trace or an export (Domenia 1 Protect-DomeniaSecretText):
    /// BitLocker recovery passwords, HTTP authorization schemes, JSON members and key=value forms of passwords, secrets, tokens
    /// and keys (in French and in English), password switches of command lines. Defence in depth, not a promise to recognise every
    /// possible secret.
    /// </summary>
    public static string Mask(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }
        try
        {
            var masked = RecoveryPassword().Replace(text, "[clé de récupération masquée]");
            masked = Authorization().Replace(masked, "$1 ***");
            masked = JsonMember().Replace(masked, "$1\"***\"");
            masked = KeyValue().Replace(masked, "$1$2***");
            masked = Switch().Replace(masked, "$1$2 ***");
            return masked;
        }
        catch (RegexMatchTimeoutException)
        {
            // Fail closed: a text that cannot be checked in time is withheld whole.
            return "[texte masqué]";
        }
    }

    /// <summary>
    /// The actions of a receipt. A re-read is offered whenever the executor of its kind exists in this mode (Domenia 2 exposes every
    /// postcondition, Domenia 1 only offered it for attribute changes); a manual review only for an uncertain receipt.
    /// </summary>
    public static ReceiptActions Actions(ReceiptView receipt, bool executorAvailable, bool busy, bool simulation)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        var head = receipt.Label + " · " + receipt.Target.Name + " · " + (receipt.Pending ? "à vérifier" : receipt.VerificationLabel.ToLowerInvariant()) + ".";
        var templates = Templates(receipt.Controller, simulation);
        if (busy)
        {
            const string Wait = "Écriture ou relecture en cours : vérification et revue reprennent à sa fin.";
            return new ReceiptActions(head + " " + Wait, false, Wait, false, Wait, templates);
        }
        string? verifyWhy = executorAvailable
            ? null
            : "Relecture indisponible dans ce mode : aucun lecteur de ce type d’écriture n’est branché. Contrôlez l’objet avec un autre outil, puis consignez votre revue.";
        if (!receipt.Pending)
        {
            var text = head + " Ce reçu est résolu : il ne bloque plus aucune écriture.";
            if (executorAvailable)
            {
                text += " Une nouvelle relecture reste possible : seule une lecture part.";
            }
            return new ReceiptActions(text, executorAvailable, verifyWhy, false, "Ce reçu est déjà résolu : aucune revue n’est nécessaire.", templates);
        }
        var advice = executorAvailable
            ? " Relecture possible sur le contrôleur initial ; à défaut, contrôlez avec un autre outil puis consignez votre revue."
            : " " + verifyWhy;
        return new ReceiptActions(head + advice, executorAvailable, verifyWhy, true, null, templates);
    }

    /// <summary>Frequent motives offered as a starting point (Domenia 1 OPE-024 improvement); the operator completes them.</summary>
    public static ImmutableArray<string> Templates(string? controller, bool simulation)
    {
        var dc = string.IsNullOrWhiteSpace(controller) ? "le contrôleur de la session" : controller;
        return
        [
            "Vérifié dans la console Utilisateurs et ordinateurs Active Directory sur " + dc + " : état attendu constaté.",
            "Contrôlé avec Get-ADUser sur " + dc + " : valeur attendue relue.",
            "Confirmé par l’utilisateur : ouverture de session réussie après l’intervention.",
            simulation
                ? "Simulation : objet contrôlé dans l’annuaire fictif depuis la fiche de Domenia."
                : "Vérifié sur le poste concerné : état attendu constaté.",
        ];
    }

    /// <summary>Help of the pill, word for word Domenia 1 (Get-DomeniaPendingOperationsView).</summary>
    public const string PillHelp = "Une écriture envoyée attend une vérification ou une revue\u00A0: les nouvelles écritures restent bloquées. Ouvre la liste des reçus\u00A0; rien n’est rejoué.";

    /// <summary>The pill of the header: visible only while a receipt waits for a check.</summary>
    public static PendingPill Pill(int pending) => Pill(pending, null, TimeZoneInfo.Utc);

    /// <summary>
    /// The pill with its oldest receipt to verify (<paramref name="oldest"/>, or null): its operation, its object and when it left,
    /// in the local time of <paramref name="zone"/>.
    /// </summary>
    public static PendingPill Pill(int pending, ReceiptRow? oldest, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        if (pending <= 0)
        {
            return new PendingPill(false, "", "", null);
        }
        var text = pending == 1 ? "1 opération à vérifier" : FrenchText.Integer(pending) + " opérations à vérifier";
        PendingOldest? first = null;
        if (oldest is not null)
        {
            var local = TimeZoneInfo.ConvertTime(oldest.SentAt, zone);
            var when = local.ToString("dd'/'MM'/'yyyy", System.Globalization.CultureInfo.InvariantCulture) + " à "
                + local.ToString("HH':'mm", System.Globalization.CultureInfo.InvariantCulture);
            first = new PendingOldest(oldest.Id, oldest.Label, oldest.Target.Name, oldest.Target.KindLabel, oldest.SentAt,
                (pending == 1 ? "À vérifier" : "Le plus ancien") + FrenchText.Colon + oldest.Label + " · " + oldest.Target.Name + ", envoyée le " + when + ".");
        }
        return new PendingPill(true, text, PillHelp, first);
    }

    /// <summary>The oldest receipt still to verify among <paramref name="rows"/> (first sent first), or null.</summary>
    public static ReceiptRow? Oldest(IEnumerable<ReceiptRow> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        return rows.Where(r => r.Pending).OrderBy(r => r.SentAt).ThenBy(r => r.Id, StringComparer.Ordinal).FirstOrDefault();
    }

    [GeneratedRegex(@"(?<!\d)(?:\d{6}-){7}\d{6}(?!\d)", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex RecoveryPassword();

    [GeneratedRegex(@"\b(Bearer|Basic)\s+[A-Za-z0-9_.~+/=-]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 1000)]
    private static partial Regex Authorization();

    [GeneratedRegex("(\"(?:password|passwd|pwd|pass|p|motdepasse|secret|token|api[_-]?key|apikey|client[_-]?secret)\"\\s*:\\s*)(\"(?:\\\\.|[^\"\\\\])*\"|[^,}\\s]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 1000)]
    private static partial Regex JsonMember();

    [GeneratedRegex("\\b(password|passwd|pwd|pass|motdepasse|mot\\s+de\\s+passe|secret|token|authorization|api[_-]?key|apikey|client[_-]?secret)(\\s*[=:]\\s*)(\"[^\"]*\"|'[^']*'|[^\\s;,]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 1000)]
    private static partial Regex KeyValue();

    [GeneratedRegex("(^|\\s)([-/](?:p|rp|pass|password|pwd))(?:\\s+|[:=])(\"[^\"]*\"|'[^']*'|\\S+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 1000)]
    private static partial Regex Switch();
}
