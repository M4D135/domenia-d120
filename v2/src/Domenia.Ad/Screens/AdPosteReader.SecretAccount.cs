using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    public async Task<OtherAccountResult> UseOtherAccountAsync(string dn, string resource, CancellationToken cancellationToken, string theme = "dark", bool retryRead = false)
    {
        if (resource is not ("laps" or "bitlocker") || theme is not ("dark" or "light" or "contrast"))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Ressource ou thème de saisie inconnu."); }
        var context = source.AccountContext ?? throw new DomeniaOperationException(PosteErrors.HostUnavailable, "Fenêtre native indisponible ; aucun compte demandé.");
        var window = context.Readers.Require<IAccountsCredentialWindow>();
        var local = await LocalAsync(dn, cancellationToken).ConfigureAwait(false);
        var access = AccountAccess.From(context);
        var scope = resource == "laps" ? CredentialRules.Laps : CredentialRules.BitLocker;
        var key = CredentialRules.SecretTargetKey(scope, dn);
        var overview = await access.OverviewAsync(cancellationToken).ConfigureAwait(false);
        var request = overview.Pending.FirstOrDefault(p => p.Scope == scope && CredentialRules.SecretTargetKey(scope, p.Target) == key);
        if (request is null)
        {
            // An invisible confidential attribute/child may be an ACL restriction, not a definitive access-denied response.
            access.RequestAccess(scope, "Autre compte demandé pour " + local.Computer.Name, dn);
            request = (await access.OverviewAsync(cancellationToken).ConfigureAwait(false)).Pending.First(p => p.Scope == scope && CredentialRules.SecretTargetKey(scope, p.Target) == key);
        }
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var generation = access.SelectionVersion;
        var label = resource == "laps" ? "LAPS" : "BitLocker";
        var appearance = LoginPresentation.Appearance(context, theme);
        using var entry = await window.AskAsync(new("Autre compte " + label, request.Remembered ?? session.Account.Login,
            "Lecture " + label + " de " + local.Computer.Name + " seulement. Compte temporaire pendant 30 minutes d’inactivité. "
                + (retryRead ? "Après validation, relire les métadonnées une seule fois ; aucune révélation." : "Aucune lecture ni révélation automatique."),
            appearance.Theme, [], false, "Ce compte reste en mémoire pour ce poste et cette ressource. Vous pouvez l’oublier dans Comptes.") { CanEditLogin = true, Appearance = appearance, LoginDomain = session.Domain }, cancellationToken).ConfigureAwait(false);
        EnsureEpoch(local.Epoch);
        if (access.SelectionVersion != generation) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Compte modifié pendant la saisie ; aucune nouvelle identité activée."); }
        if (entry is null) { return new(local.Computer.Name, resource, false, session.Account.Login, "Saisie annulée ; compte précédent conservé.", false); }
        var login = DirectoryLogin.Resolve(entry.Login, session.Domain)
            ?? throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, DirectoryLogin.Hint(entry.Login, session.Domain) + " Aucun essai envoyé.");
        var result = await LoginPresentation.RunAsync(context, appearance.Theme, ct => access.RecoverAsync(request.Id, login, entry.Password, LeaseMode.Inactivity, CredentialRules.DefaultLeaseMinutes, dn, ct, targetOnly: true), cancellationToken).ConfigureAwait(false);
        EnsureEpoch(local.Epoch);
        var answer = new OtherAccountResult(local.Computer.Name, resource, result.Result.Success, result.Result.Identity ?? entry.Login!,
            result.Result.Success ? "Compte validé pour " + label + " de " + local.Computer.Name + " ; relancez la lecture voulue. Les droits sur la valeur ne sont pas encore vérifiés."
                : "Compte non activé. " + result.Result.Message, false);
        if (!retryRead || !result.Result.Success) return answer;
        var selected = result.InstalledSelectionVersion
            ?? throw new DomeniaOperationException(AccountAccess.EpochChanged, "Compte validé sans preuve d’installation ; aucune lecture relancée.");
        cancellationToken.ThrowIfCancellationRequested(); EnsureEpoch(local.Epoch);
        // The explicit gesture admits exactly one metadata read, using the existing bounded reader. No reveal delegate exists here.
        var laps = resource == "laps" ? await LapsCoreAsync(dn, cancellationToken, selected).ConfigureAwait(false) : null;
        var bitLocker = resource == "bitlocker" ? await BitLockerListCoreAsync(dn, cancellationToken, selected).ConfigureAwait(false) : null;
        EnsureEpoch(local.Epoch);
        if (selected != access.SelectionVersion) throw new DomeniaOperationException(AccountAccess.EpochChanged, "Compte modifié pendant la relecture ; résultat écarté.");
        return answer with { ReadRetried = true, Laps = laps, BitLocker = bitLocker,
            Text = "Compte validé ; métadonnées " + label + " relues une fois. Aucune valeur secrète révélée." };
    }
}
