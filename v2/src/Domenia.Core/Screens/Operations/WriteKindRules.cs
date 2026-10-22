using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// The re-read that proves one kind of write (Domenia 1 Get-DomeniaPostconditionRule, OPE-009) and whether it can be compensated
/// (Domenia 1 Get-DomeniaCompensation, OPE-010). The return of the request is never the proof; the re-read is made on the
/// controller that received the write.
/// </summary>
/// <param name="Proof">Short name of the proof (« État », « Attribut », « Appartenance »…).</param>
/// <param name="Check">What the re-read must observe, in one sentence.</param>
/// <param name="Verifiable">False when no generic re-read proves the effect (remote script): a manual review is required.</param>
/// <param name="Partial">True when even a conforming re-read never proves the cause (wake on LAN): never more than « partiel ».</param>
/// <param name="Compensable">True for the kinds Domenia 1 compensates (fiche, groups, move, activation, expiration, options).</param>
/// <param name="Compensation">Why a compensation is or is not offered for this kind.</param>
public sealed record WriteKindRule(
    string Kind,
    string Label,
    string Proof,
    string Check,
    bool Verifiable,
    bool Partial,
    bool Compensable,
    string Compensation);

/// <summary>One change of a compensation: the plan's change read backwards (« après » becomes « avant »).</summary>
public sealed record CompensationChange(string Attribute, string Label, string? Before, string? After);

/// <summary>
/// Whether a compensation is offered for one receipt (Domenia 1 Get-DomeniaCompensation): always a NEW write with its own plan,
/// confirmation, receipt and re-read, prepared from the screen of the object; never automatic, one operation at a time.
/// </summary>
public sealed record CompensationAssessment(
    bool Offered,
    string Reason,
    ImmutableArray<CompensationChange> Changes,
    bool NewPlanRequired,
    bool Automatic,
    string NotCovered);

/// <summary>The kind rules shown by Opérations, with whether the executor of the kind is served in this mode.</summary>
public sealed record WriteKindRow(
    string Kind,
    string Label,
    string Proof,
    string Check,
    bool Verifiable,
    bool Partial,
    bool Compensable,
    string Compensation,
    bool Available);

/// <summary>Pure catalogue of the write kinds (Domenia 1 postconditions and compensations), by Domenia 2 kind name.</summary>
public static class WriteKindRules
{
    private const string NotCoveredText = "Ne concerne ni le code de Domenia ni ses données locales : seule la modification de l’annuaire est compensée.";
    private const string PasswordText = "Un mot de passe modifié n’est pas restaurable : l’ancien n’est ni connu ni conservé.";
    private const string RemoteText = "Action à distance déjà produite (redémarrage, stratégies, exécution, service ou réveil) : aucun inverse.";
    private const string CompensableText = "Compensation possible : nouvelle opération à confirmer, avec son plan, son reçu et sa relecture, seulement si l’objet est encore dans l’état écrit.";

    private static readonly WriteKindRule[] Rules =
    [
        new("account.unlock", "Déverrouillage du compte", "État", "Relire lockoutTime : compte déverrouillé attendu (valeur 0).", true, false, false, "Un déverrouillage ne se compense pas."),
        new("account.enabled", "Activation ou désactivation du compte", "État", "Relire userAccountControl : état activé ou désactivé attendu.", true, false, true, CompensableText),
        new("account.options", "Options du compte", "État", "Relire userAccountControl : options attendues.", true, false, true, CompensableText),
        new("account.expiration", "Expiration du compte", "Attribut", "Relire accountExpires sur le contrôleur initial.", true, false, true, CompensableText),
        new("password.expire", "Changement de mot de passe imposé", "Attribut", "Relire pwdLastSet : la valeur 0 impose le changement à la prochaine ouverture de session.", true, false, false, PasswordText),
        new("password.reset", "Réinitialisation du mot de passe", "Date", "Relire pwdLastSet : date postérieure à l’envoi. La valeur du mot de passe n’est jamais relue.", true, false, false, PasswordText),
        new("object.update", "Modification de la fiche", "Attribut", "Relire chaque attribut modifié sur le contrôleur initial et le comparer à la valeur envoyée.", true, false, true, CompensableText),
        new("attribute.raw", "Modification d’un attribut", "Attribut", "Relire l’attribut modifié sur le contrôleur initial et le comparer à la valeur envoyée.", true, false, true, CompensableText),
        new("group.member", "Membres du groupe", "Appartenance", "Relire l’attribut member du groupe sur le contrôleur qui a reçu l’écriture.", true, false, true, CompensableText),
        new("object.groups", "Appartenance aux groupes", "Appartenance", "Relire l’appartenance de l’objet à chaque groupe modifié, sur le contrôleur initial.", true, false, true, CompensableText),
        new("object.move", "Déplacement de l’objet", "Emplacement", "Relire l’objet par son GUID : il doit se trouver sous le conteneur choisi.", true, false, true, CompensableText + " Le conteneur d’origine doit encore exister."),
        new("computer.rename", "Renommage du poste", "Emplacement", "Relire l’objet par son GUID : son DN doit porter le nouveau nom.", true, false, false, "Le renommage touche aussi le poste et le DNS : pas de compensation proposée."),
        new("ou.create", "Création d’une OU", "Présence", "Relire l’OU créée sous son parent.", true, false, false, "Compenser une création reviendrait à supprimer : jamais proposé."),
        new("object.delete", "Suppression de l’objet", "Absence", "Relire l’objet par son GUID : une absence constatée est requise, un refus de lecture ne vaut pas absence.", true, false, false, "Une suppression ne se compense pas ici : la restauration relève de la corbeille AD ou d’une sauvegarde, avec ses propres contrôles."),
        new("computer.restart", "Redémarrage à distance", "Redémarrage", "Relire le dernier démarrage du poste : postérieur à l’envoi.", true, false, false, RemoteText),
        new("computer.gpupdate", "Actualisation des stratégies à distance", "Stratégies", "Relire la dernière application des stratégies : postérieure à l’envoi.", true, false, false, RemoteText),
        new("remote.run", "Exécution distante", "Aucune", "Aucune relecture générique : le résultat d’un script distant se vérifie sur le poste.", false, false, false, RemoteText),
        new("service.control", "Commande d’un service", "État", "Relire l’état du service sur le poste : état attendu après la commande.", true, false, false, RemoteText),
        new("wol.send", "Réveil réseau", "Présence", "Relire la présence du poste : réponse postérieure à la demande. Une réponse ne prouve pas que le réveil vient de cette demande.", true, true, false, RemoteText),
    ];

    /// <summary>Every kind known by the catalogue, in display order.</summary>
    public static ImmutableArray<WriteKindRule> All => [.. Rules];

    /// <summary>
    /// The rule of a kind; an unknown kind keeps a cautious rule: verification by its executor if it has one, otherwise manual, and
    /// no compensation (a guessed inverse would hide what was really sent).
    /// </summary>
    public static WriteKindRule Of(string kind, string? label = null)
    {
        ArgumentNullException.ThrowIfNull(kind);
        return Rules.FirstOrDefault(r => string.Equals(r.Kind, kind, StringComparison.Ordinal))
            ?? new WriteKindRule(kind, label ?? kind, "Exécuteur",
                "Aucune règle de vérification connue pour cette opération : la relecture de son exécuteur fait foi, sinon à vérifier manuellement.",
                true, false, false, "Aucune compensation définie pour cette opération.");
    }

    /// <summary>The catalogue rows with the availability of each kind in this mode (its executor is served by the source).</summary>
    public static ImmutableArray<WriteKindRow> Rows(IReadOnlyCollection<string> available)
    {
        ArgumentNullException.ThrowIfNull(available);
        var known = Rules.Select(r => r.Kind).ToHashSet(StringComparer.Ordinal);
        var extra = available.Where(k => !known.Contains(k)).Order(StringComparer.Ordinal).Select(k => Of(k));
        return [.. Rules.Concat(extra).Select(r => new WriteKindRow(r.Kind, r.Label, r.Proof, r.Check, r.Verifiable, r.Partial, r.Compensable, r.Compensation, available.Contains(r.Kind)))];
    }

    /// <summary>
    /// Whether a compensation is offered for a receipt (Domenia 1 Get-DomeniaCompensation, without its own re-read: the new plan
    /// reads the object again on the controller, so its preconditions are checked there). Offered only for a compensable kind,
    /// once the write was applied and verified by a re-read; every change is shown backwards.
    /// </summary>
    public static CompensationAssessment Assess(ReceiptView receipt)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        var plan = receipt.Plan;
        var rule = Of(plan.Kind, plan.Label);
        CompensationAssessment Refuse(string why) => new(false, why, [], true, false, NotCoveredText);
        if (!rule.Compensable)
        {
            return Refuse(rule.Compensation);
        }
        if (plan.Changes.Any(c => c.Kind == WriteChangeKind.Reset || IsSecretAttribute(c.Attribute)))
        {
            return Refuse(PasswordText);
        }
        if (plan.Changes.IsDefaultOrEmpty)
        {
            return Refuse("Plan sans valeurs avant et après : la compensation ne peut pas être établie.");
        }
        if (receipt.Pending || receipt.Verification == VerificationState.Unknown)
        {
            return Refuse("Issue d’origine non vérifiée : relisez le reçu avant toute compensation.");
        }
        if (receipt.Verification == VerificationState.Reviewed)
        {
            return Refuse("Issue établie par une revue manuelle : relisez l’objet avant toute compensation, pour que ses valeurs actuelles soient connues.");
        }
        if (receipt.Result is WriteResult.NoChange or WriteResult.NotApplied)
        {
            return Refuse("Rien à compenser : aucune modification de l’opération n’a été appliquée.");
        }
        if (receipt.Verification == VerificationState.Mismatch)
        {
            return Refuse("Valeur relue différente de l’opération : la compensation écraserait un autre changement, elle n’est pas proposée.");
        }
        ImmutableArray<CompensationChange> inverse = [.. plan.Changes.Reverse().Select(c => new CompensationChange(c.Attribute, c.Label, c.After, c.Before))];
        return new CompensationAssessment(true,
            "Compensation possible : préparez-la depuis la fiche de l’objet, comme une nouvelle écriture (plan relu sur le contrôleur, confirmation, reçu et relecture). Jamais automatique.",
            inverse, true, false, NotCoveredText);
    }

    private static readonly HashSet<string> SecretAttributes = new(StringComparer.OrdinalIgnoreCase)
    {
        "unicodePwd", "userPassword", "dBCSPwd", "lmPwdHistory", "ntPwdHistory", "supplementalCredentials", "ms-Mcs-AdmPwd",
        "msLAPS-Password", "msLAPS-EncryptedPassword", "msLAPS-EncryptedPasswordHistory", "msLAPS-EncryptedDSRMPassword",
        "msLAPS-EncryptedDSRMPasswordHistory", "msFVE-RecoveryPassword", "msFVE-KeyPackage",
    };

    /// <summary>Attributes that carry a secret: never compensated, never shown (Domenia 1 Test-DomeniaSecretAttribute). Dates are not secrets.</summary>
    public static bool IsSecretAttribute(string? attribute) => attribute is not null && SecretAttributes.Contains(attribute);
}
