using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Native secret handoff and exact vault targets; the simulation keeps its existing fictitious JSON input.</summary>
internal static class AccountsCredentialEntry
{
    internal static async Task<(CredentialWindowEntry? Entry, ImmutableArray<CredentialVaultTarget> Targets)> AskAsync(
        EngineContext context, IReadOnlyDictionary<string, JsonElement> values, string login, string usage, string? target, string title, CancellationToken token)
    {
        if (context.Mode == AppMode.Simulation) { return (new(AccountsArguments.GetPassword(values, "password"), false), []); }
        if (values.ContainsKey("password")) { throw BridgeArguments.Invalid("La saisie du mot de passe utilise la fenêtre native ; aucune valeur n’est acceptée dans le message de la page."); }
        var access = AccountAccess.From(context);
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        var contextCheck = CredentialRules.CheckContext(usage == "Secrets" ? CredentialRules.Laps : usage, login, target,
            new[] { session.Domain?.DnsName, session.Domain?.NetbiosName }.OfType<string>().ToArray());
        if (!contextCheck.Valid) { throw new DomeniaOperationException(AccountAccess.ContextRefused, contextCheck.Reason); }
        var targets = Targets(DomainRoot(session), usage, login, target);
        var canUse = await access.CanUseVaultAsync(login, target, token).ConfigureAwait(false);
        var request = new CredentialWindowRequest(title, login, usage == "Secrets" ? "Compte Secrets (LAPS et BitLocker)" : CredentialRules.ScopeLabel(usage),
            BridgeArguments.GetOptionalString(values, "theme") is "light" ? "light" : BridgeArguments.GetOptionalString(values, "theme") is "contrast" ? "contrast" : "dark",
            targets, canUse, !canUse ? "Ce compte a été refusé : saisissez le mot de passe corrigé. Le coffre ne sera pas réessayé automatiquement."
                : targets.IsEmpty ? "Coffre indisponible pour ce contexte de connexion." : null);
        var window = context.Readers.Require<IAccountsCredentialWindow>();
        return (await window.AskAsync(request, token).ConfigureAwait(false), targets);
    }

    internal static string? DomainRoot(SessionSnapshot session)
    {
        if (session.Domain?.RootDn is { } root) { return root; }
        var labels = session.Domain?.DnsName?.Split('.');
        return labels is { Length: > 1 } && labels.All(label => label.Length is > 0 and <= 63 && label.All(c => char.IsAsciiLetterOrDigit(c) || c == '-'))
            ? string.Join(',', labels.Select(label => "DC=" + label)) : null;
    }

    internal static ImmutableArray<CredentialVaultTarget> Targets(string? root, string usage, string login, string? target)
    {
        if (root is null || login.Trim().Length > 256) { return []; }
        string[] scopes = usage switch
        {
            "Secrets" => ["Laps", "BitLocker"],
            CredentialRules.Laps => ["Laps"],
            CredentialRules.BitLocker => ["BitLocker"],
            CredentialRules.Remote when CredentialRules.IsLocalAccount(login, target) => ["RemoteLocal:" + CredentialRules.MachineKey(target)],
            _ => [usage],
        };
        var result = scopes.Select(scope => new CredentialVaultTarget(root, scope, login)).ToImmutableArray();
        foreach (var item in result) { _ = item.Key; }
        return result;
    }

    internal static AccessValidation Cancelled(EngineContext context) => new(false, "cancelled", "Saisie annulée ; aucun essai envoyé.", "Le compte précédent est conservé.", null, null, Tone.Off, "Droits non testés.", context.Mode == AppMode.Simulation, context.Clock.GetUtcNow());

    internal static async Task<T> CompleteAsync<T>(EngineContext context, CredentialWindowEntry entry, ImmutableArray<CredentialVaultTarget> targets, T result, CancellationToken token)
    {
        var validation = result switch { AccessValidation value => value, AccessChange value => value.Result, AccessSwitch value => value.Result, _ => null };
        if (!entry.Remember || targets.IsEmpty || validation?.Success != true) { return result; }
        try
        {
            var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            if (DomainRoot(session) is not { } root || targets.Any(target => !DistinguishedName.AreEqual(target.DomainDn, root)))
            { throw new DomeniaOperationException(CredentialVaultRules.Failed, "Domaine authentifié différent du coffre demandé."); }
            var proofs = context.Shared(c => new CredentialVaultProofs(c.Clock));
            validation = validation with { VaultSaveTicket = proofs.Stage(targets, entry.Password, session.Epoch) };
        }
        catch (DomeniaOperationException error)
        { validation = validation with { Hint = validation.Hint + " Compte validé, mais mémorisation non préparée : " + error.Message, Tone = Tone.Warn }; }
        object updated = result switch
        {
            AccessValidation => validation,
            AccessChange change => change with { Result = validation },
            AccessSwitch change => change with { Result = validation },
            _ => result!,
        };
        return (T)updated;
    }
}
