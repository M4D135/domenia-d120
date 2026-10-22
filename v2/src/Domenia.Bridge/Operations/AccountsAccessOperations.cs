using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// The accounts Domenia works with (docs/ops/comptes.md, Domenia 1 CPT-001 to CPT-021): connection card, accounts in service,
/// accounts kept in memory, secondary accounts (workstations, secrets), accesses to review after a refusal, trial of the
/// workstation account, rights required by each operation and transport policy. Validations are network reads (one bind,
/// after the operator's gesture, one at a time), served by the fictitious directory in simulation; the other operations act on
/// the memory of the session or on the local preferences (identifiers only, never a password).
/// </summary>
public sealed class AccountsAccessOperations : IOperationModule
{
    private static readonly string[] CredentialArguments = ["usage", "login", "password"];
    private static readonly string[] UsageArguments = ["usage"];
    private static readonly string[] RecoverArguments = ["id", "login", "password", "lease", "minutes", "target"];
    private static readonly string[] IdArguments = ["id"];
    private static readonly string[] KeyArguments = ["key"];
    private static readonly string[] ComputerArguments = ["computer"];
    private static readonly string[] PasswordArguments = ["password"];

    public string Screen => "accounts";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var access = AccountAccess.From(context);
        return
        [
            new OperationDefinition("accounts.access.state", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                return await access.OverviewAsync(cancellationToken).ConfigureAwait(false);
            }, "Comptes utilisés par Domenia\u00A0: connexion, en ce moment, en mémoire, comptes secondaires, accès à revoir\u00A0; aucun secret."),

            new OperationDefinition("accounts.access.test", OperationClass.NetworkRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, CredentialArguments);
                var usage = Usage(values);
                var login = AccountsArguments.GetLogin(values, "login");
                using var password = AccountsArguments.GetPassword(values, "password");
                return await access.TestAsync(usage, login, password, cancellationToken).ConfigureAwait(false);
            }, "Valide un compte secondaire sans l’activer (une seule validation à la fois, 12 s au plus).", ServedInSimulation: true),

            new OperationDefinition("accounts.access.activate", OperationClass.NetworkRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, CredentialArguments);
                var usage = Usage(values);
                var login = AccountsArguments.GetLogin(values, "login");
                using var password = AccountsArguments.GetPassword(values, "password");
                return await access.ActivateAsync(usage, login, password, cancellationToken).ConfigureAwait(false);
            }, "Valide puis active un compte Postes ou Secrets\u00A0; l’identifiant (jamais le mot de passe) est mémorisé.", ServedInSimulation: true),

            new OperationDefinition("accounts.access.clear", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, UsageArguments);
                return await access.ClearAsync(Usage(values), cancellationToken).ConfigureAwait(false);
            }, "Efface un compte secondaire\u00A0: retour au compte de connexion."),

            new OperationDefinition("accounts.access.recover", OperationClass.NetworkRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, RecoverArguments);
                var id = RequireId(values);
                var login = AccountsArguments.GetLogin(values, "login");
                if (!CredentialRules.TryParseLease(BridgeArguments.GetString(values, "lease"), out var lease))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("lease") + " doit valoir inactivity, session ou once.");
                }
                var minutes = AccountsArguments.GetOptionalInt(values, "minutes", CredentialRules.MinLeaseMinutes, CredentialRules.MaxLeaseMinutes) ?? CredentialRules.DefaultLeaseMinutes;
                var target = BridgeArguments.GetOptionalString(values, "target");
                if (target is not null && !CredentialRules.IsComputerName(target))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("target") + " doit être un nom de poste valide ou null.");
                }
                using var password = AccountsArguments.GetPassword(values, "password");
                return await access.RecoverAsync(id, login, password, lease, minutes, target, cancellationToken).ConfigureAwait(false);
            }, "Utilise un autre compte pour la ressource d’un accès refusé (contexte contrôlé, une validation, bail)\u00A0; rien n’est rejoué.", ServedInSimulation: true),

            new OperationDefinition("accounts.access.dismiss", OperationClass.Local, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, IdArguments);
                return await access.DismissAsync(RequireId(values), cancellationToken).ConfigureAwait(false);
            }, "Écarte un accès à revoir\u00A0: le compte actuel est conservé."),

            new OperationDefinition("accounts.access.forget", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, KeyArguments);
                var key = BridgeArguments.GetString(values, "key");
                if (key.Length is 0 or > 300 || key.Any(char.IsControl))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("key") + " doit désigner un compte en mémoire.");
                }
                return await access.ForgetAsync(key, cancellationToken).ConfigureAwait(false);
            }, "Oublie un compte gardé en mémoire\u00A0; une opération déjà partie garde sa copie."),

            new OperationDefinition("accounts.access.forgetAll", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                return await access.ForgetAllAsync(cancellationToken).ConfigureAwait(false);
            }, "Oublie tous les comptes temporaires en un geste."),

            new OperationDefinition("accounts.access.cancel", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(new ValidationCancel(access.CancelValidation()));
            }, "Annule la validation en cours (le compte précédent est conservé)."),

            new OperationDefinition("accounts.access.tryRemote", OperationClass.NetworkRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, ComputerArguments);
                var computer = BridgeArguments.GetString(values, "computer").Trim();
                if (!CredentialRules.IsComputerName(computer))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("computer") + " doit être un nom de poste valide.");
                }
                return await access.TryRemoteAsync(computer, cancellationToken).ConfigureAwait(false);
            }, "Essaie le compte poste sur un seul poste (une lecture CIM légère)\u00A0; ni balayage, ni ping, ni console.", ServedInSimulation: true),

            new OperationDefinition("accounts.connection.correct", OperationClass.NetworkRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, PasswordArguments);
                using var password = AccountsArguments.GetPassword(values, "password");
                return await access.CorrectConnectionAsync(password, cancellationToken).ConfigureAwait(false);
            }, "Corrige le mot de passe du compte de connexion sans reconnecter (même identité seulement).", ServedInSimulation: true),

            new OperationDefinition("accounts.remembered.forget", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, UsageArguments);
                return await access.ForgetRememberedAsync(Usage(values), cancellationToken).ConfigureAwait(false);
            }, "Oublie l’identifiant mémorisé d’un usage (nom seulement)."),

            new OperationDefinition("accounts.requirements", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(OperationRequirements.All());
            }, "Droits, comptes et accès réseau requis par chaque opération."),

            new OperationDefinition("accounts.transports", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(TransportPolicy.Build(TransportSettings.Defaults, false, null));
            }, "Politique de transport\u00A0: ce que Domenia utilise, ce qui reste coupé et pourquoi."),
        ];
    }

    private static AccessUsage Usage(IReadOnlyDictionary<string, JsonElement> values) =>
        CredentialRules.TryParseUsage(BridgeArguments.GetString(values, "usage"), out var usage)
            ? usage
            : throw BridgeArguments.Invalid(FrenchText.Quote("usage") + " doit valoir remote ou secrets.");

    private static string RequireId(IReadOnlyDictionary<string, JsonElement> values)
    {
        var id = BridgeArguments.GetString(values, "id");
        return id.Length is > 0 and <= 32 && id.All(char.IsAsciiLetterOrDigit)
            ? id
            : throw BridgeArguments.Invalid(FrenchText.Quote("id") + " doit être l’identifiant d’un accès à revoir.");
    }
}

/// <summary>Result of accounts.access.cancel.</summary>
public sealed record ValidationCancel(bool Cancelled);
