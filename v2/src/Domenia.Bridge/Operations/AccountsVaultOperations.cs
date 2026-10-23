using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>All persistent vault mutations are separately classified LocalWrite, never hidden in a network-read operation.</summary>
public sealed class AccountsVaultOperations : IOperationModule
{
    public string Screen => "accounts";
    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context) =>
    [
        new("accounts.vault.save", OperationClass.LocalWrite, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["ticket"]);
            var ticket = BridgeArguments.GetString(values, "ticket");
            if (!Guid.TryParseExact(ticket, "N", out var parsedTicket) || parsedTicket == Guid.Empty) { throw BridgeArguments.Invalid("Confirmation de coffre invalide."); }
            var vault = context.Readers.Require<IAccountsCredentialVault>();
            if (!vault.Available) { throw new DomeniaOperationException(CredentialVaultRules.Unavailable, "Coffre indisponible dans ce mode."); }
            var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            using var proof = context.Shared(c => new CredentialVaultProofs(c.Clock)).Take(ticket, session.Epoch);
            var saved = 0;
            try
            {
                foreach (var target in proof.Targets)
                {
                    token.ThrowIfCancellationRequested();
                    vault.Write(target, proof.Password); saved++;
                }
            }
            catch (OperationCanceledException) when (saved > 0)
            { return new VaultReceipt(false, saved, proof.Targets.Length, "Mémorisation interrompue : " + saved + "/" + proof.Targets.Length + " usage(s) déjà enregistré(s)."); }
            catch (DomeniaOperationException error)
            {
                context.Journal.Add(new(context.Clock.GetUtcNow(), "Coffre Windows : " + saved + "/" + proof.Targets.Length + " usage(s) enregistré(s).", Tone.Warn));
                return new VaultReceipt(false, saved, proof.Targets.Length, "Compte disponible pour la session. Coffre : " + saved + "/" + proof.Targets.Length + " usage(s) enregistré(s). " + error.Message);
            }
            context.Journal.Add(new(context.Clock.GetUtcNow(), "Compte mémorisé dans le coffre Windows après validation explicite (" + saved + " usage(s)).", Tone.Info));
            return new VaultReceipt(true, saved, proof.Targets.Length, "Mot de passe mémorisé dans le coffre Windows de ce PC.");
        }, "Mémorise le seul compte validé et choisi explicitement, avec une confirmation en mémoire à usage unique."),
        new("accounts.vault.delete", OperationClass.LocalWrite, async (args, _, token) =>
        {
            var values = BridgeArguments.ReadObject(args, ["usage", "login", "target"]);
            var login = AccountsArguments.GetLogin(values, "login");
            var usage = BridgeArguments.GetString(values, "usage") switch
            { "directory" => CredentialRules.Directory, "remote" => CredentialRules.Remote, "secrets" => "Secrets", _ => throw BridgeArguments.Invalid("Usage du coffre inconnu.") };
            var target = BridgeArguments.GetOptionalString(values, "target");
            var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            var targets = AccountsCredentialEntry.Targets(AccountsCredentialEntry.DomainRoot(session), usage, login, target);
            if (targets.IsEmpty) { throw new DomeniaOperationException(CredentialVaultRules.Unavailable, "Domaine du coffre inconnu."); }
            var vault = context.Readers.Require<IAccountsCredentialVault>();
            if (!vault.Available) { throw new DomeniaOperationException(CredentialVaultRules.Unavailable, "Coffre indisponible dans ce mode."); }
            var removed = 0;
            try { foreach (var item in targets) { token.ThrowIfCancellationRequested(); if (vault.Delete(item)) { removed++; } } }
            catch (OperationCanceledException) when (removed > 0)
            { return new VaultReceipt(false, removed, targets.Length, "Suppression interrompue : " + removed + "/" + targets.Length + " entrée(s) déjà supprimée(s)."); }
            catch (DomeniaOperationException error) { return new VaultReceipt(false, removed, targets.Length, "Suppression partielle du coffre : " + removed + "/" + targets.Length + ". " + error.Message); }
            context.Journal.Add(new(context.Clock.GetUtcNow(), "Entrées du coffre oubliées explicitement ; compte de session conservé.", Tone.Info));
            return new VaultReceipt(true, removed, targets.Length, "Aucun mot de passe mémorisé pour ce compte et ces usages ; le compte en mémoire reste actif.");
        }, "Oublie seulement les entrées du compte et des usages choisis, sans fermer sa session ni modifier l’AD."),
    ];
}

public sealed record VaultReceipt(bool Complete, int Changed, int Requested, string Message);
