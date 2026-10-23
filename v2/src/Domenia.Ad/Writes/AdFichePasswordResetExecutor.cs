using System.Security;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Fiche confirmation and secret origin, with the same secure transport/policy/receipt rules as Accounts.</summary>
public sealed class AdFichePasswordResetExecutor(AdDirectorySource source) : AdPasswordResetWriteExecutor(source), IPasswordResetExecutor
{
    public override string Kind => ObjectWrites.ResetPasswordKind;

    public Task<WritePlanDraft> PlanAsync(string dn, bool mustChange, bool unlock, bool generated, int length, FicheSecurityPolicy policy, CancellationToken cancellationToken) =>
        PrepareFicheAsync(dn, mustChange, unlock, generated, length, policy, null, cancellationToken);

    public Task<WritePlanDraft> PlanAsync(string dn, bool mustChange, bool unlock, bool generated, SecureString password, FicheSecurityPolicy policy, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(password);
        return PrepareFicheAsync(dn, mustChange, unlock, generated, password.Length, policy, password, cancellationToken);
    }

    private Task<WritePlanDraft> PrepareFicheAsync(string dn, bool mustChange, bool unlock, bool generated, int length, FicheSecurityPolicy policy,
        SecureString? password, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(policy);
        if (length is < 1 or > AccountPasswordReset.MaxLength || generated && (length is < 14 or > 64))
        { throw FicheErrors.Error(FicheErrors.Invalid, "Longueur du mot de passe non admise ; aucune écriture préparée."); }
        return PrepareResetAsync(dn, new(mustChange, unlock), password, (user, domain, draft) =>
        {
            if (length < domain.PasswordPolicy.MinPasswordLength)
            { throw WriteErrors.Refusal(AccountPasswordReset.PolicyRefused, "Longueur inférieure à la stratégie effective du compte ; aucun plan préparé."); }
            var origin = generated ? "Mot de passe généré dans la fenêtre sécurisée, lu une fois" : "Mot de passe saisi deux fois dans la fenêtre sécurisée";
            var change = draft.Changes[0] with { After = origin + " (" + FrenchText.Count(length, "caractère", "caractères") + "), jamais inscrit dans le plan ni le journal" };
            return draft with
            {
                Changes = [change, .. draft.Changes.Skip(1)],
                Confirmation = new(true, user.SamAccountName, "Saisie du nom exigée : réinitialisation du mot de passe depuis la Fiche."),
            };
        }, token);
    }

    private protected override WritePrecheck CheckUser(WritePlan plan, DirectoryUser? user)
    {
        if (user is not null && plan.Confirmation.TypedName != user.SamAccountName)
        { return WritePrecheck.Stale("Le nom de confirmation a changé ; aucun mot de passe envoyé."); }
        return base.CheckUser(plan, user);
    }

    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        if (!plan.Confirmation.TypedNameRequired || string.IsNullOrWhiteSpace(plan.Confirmation.TypedName))
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Une réinitialisation de Fiche exige la confirmation du nom du compte."); }
    }
}
