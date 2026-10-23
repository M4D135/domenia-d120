using System.Security;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Account of the workstation operations (docs/ops/schema.md « Comptes machine », Domenia 1 MAC-001 to MAC-003): the cascade
/// that picks the account of the next operation, the account typed for the session (memory only; password as a read-only
/// SecureString at once, never in a reply nor a journal), the return to the configured account, the light access trial on one
/// workstation (NetworkRead, served by the simulation) and the search of a workstation to try. No write anywhere: the accounts
/// live in the engine memory for the session only.
/// </summary>
public sealed class MachineOperations : IOperationModule
{
    private static readonly string[] TargetArguments = ["target"];
    private static readonly string[] UseArguments = ["account", "password", "target", "theme"];
    private static readonly string[] TrialArguments = ["target", "account", "password", "theme"];
    private static readonly string[] SearchArguments = ["text"];
    private static readonly string[] WatchArguments = ["since", "target"];

    /// <summary>Longest search text of a workstation.</summary>
    public const int MaxSearchLength = 64;

    /// <summary>Workstations returned by a search.</summary>
    public const int SearchLimit = 12;

    public string Screen => "machine";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var service = MachineAccountService.From(context);
        var simulation = context.Mode == AppMode.Simulation;
        async Task<SecureString> NativeSecretAsync(IReadOnlyDictionary<string, JsonElement> values, string account, string? target, string title, CancellationToken token)
        {
            var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            var check = CredentialRules.CheckContext(CredentialRules.Remote, account, target,
                new[] { session.Domain?.DnsName, session.Domain?.NetbiosName }.OfType<string>().ToArray());
            if (!check.Valid) { throw new DomeniaOperationException(AccountAccess.ContextRefused, check.Reason); }
            var theme = BridgeArguments.GetOptionalString(values, "theme") is "light" ? "light" : BridgeArguments.GetOptionalString(values, "theme") is "contrast" ? "contrast" : "dark";
            using var answer = await context.Readers.Require<IAccountsCredentialWindow>().AskAsync(new(title, account,
                target is null ? "Compte des opérations distantes, en mémoire pour cette session." : "Compte des opérations sur " + target + ".",
                theme, [], false, "Ce compte ponctuel reste en mémoire uniquement. Le chargement ne confirme pas ses droits."), token).ConfigureAwait(false)
                ?? throw new DomeniaOperationException("machine.cancelled", "Saisie annulée : aucun compte ni essai modifié.");
            token.ThrowIfCancellationRequested();
            if ((await context.Directory.GetSessionAsync(token).ConfigureAwait(false)).Epoch != session.Epoch)
            { throw new DomeniaOperationException(AccountAccess.EpochChanged, "La session a changé pendant la saisie ; aucun compte chargé."); }
            return answer.Password.Copy();
        }
        return
        [
            new OperationDefinition("machine.account.state", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                var target = OptionalTarget(args, TargetArguments);
                return await service.StateAsync(target, cancellationToken).ConfigureAwait(false);
            }, "Compte que prendra la prochaine opération sur un poste, règle de choix et compte des secrets ; noms seulement."),

            new OperationDefinition("machine.account.use", OperationClass.Local, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, UseArguments);
                var account = Account(BridgeArguments.GetString(values, "account"));
                var target = Target(values);
                var password = BridgeArguments.GetOptionalString(values, "password");
                if (!simulation && values.ContainsKey("password")) { throw BridgeArguments.Invalid("Le mot de passe du compte poste utilise la fenêtre native."); }
                var secure = simulation ? Secret(password, true) : await NativeSecretAsync(values, account, target, "Charger le compte poste", cancellationToken).ConfigureAwait(false);
                try
                {
                    service.UseTyped(account, secure);
                    secure = null;
                }
                finally
                {
                    secure?.Dispose();
                }
                context.Log.Info("Compte poste saisi pour la session (nom et mot de passe jamais journalisés).");
                return await service.StateAsync(target, cancellationToken).ConfigureAwait(false);
            }, "Utilise un compte poste pour la session, en mémoire seulement ; le mot de passe devient aussitôt une SecureString."),

            new OperationDefinition("machine.account.forget", OperationClass.Local, async (args, _, cancellationToken) =>
            {
                var target = OptionalTarget(args, TargetArguments);
                service.ForgetTyped();
                return await service.StateAsync(target, cancellationToken).ConfigureAwait(false);
            }, "Oublie le compte poste saisi : le compte configuré reprend sa place."),

            new OperationDefinition("machine.account.trial", OperationClass.NetworkRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, TrialArguments);
                var target = Target(values) ?? throw new DomeniaOperationException(MachineErrors.TargetMissing, MachineErrors.TargetMissingMessage);
                var candidateText = BridgeArguments.GetOptionalString(values, "account");
                var candidate = candidateText is null ? null : Account(candidateText);
                var password = BridgeArguments.GetOptionalString(values, "password");
                if (!simulation && values.ContainsKey("password")) { throw BridgeArguments.Invalid("Le mot de passe du compte poste utilise la fenêtre native."); }
                if (candidate is null && password is not null)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("password") + " accompagne seulement un compte à valider.");
                }
                var reader = context.Readers.Require<IMachineAccountReader>();
                var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                MachineAccountSource source;
                string account;
                SecureString? secret;
                // The place of the account in service: its verdict pauses or validates that place only. A candidate has none.
                string? place = null;
                if (candidate is not null)
                {
                    source = MachineAccountSource.Typed;
                    account = candidate;
                    secret = simulation ? Secret(password, true) : await NativeSecretAsync(values, candidate, target, "Valider le compte sur ce poste", cancellationToken).ConfigureAwait(false);
                }
                else
                {
                    // The trial is how a paused account is validated: it may leave with it.
                    var credential = service.CredentialFor(session, target, forTrial: true);
                    (source, account, secret, place) = (credential.Source, credential.Account, credential.Password, credential.Place);
                }
                MachineTrialObservation observation;
                try
                {
                    observation = await reader.ProbeAccessAsync(new MachineProbeRequest(target, source, MachineAccountRules.ForTarget(account, target), secret), cancellationToken)
                        .ConfigureAwait(false);
                }
                finally
                {
                    secret?.Dispose();
                }
                if (observation.Workstation is null)
                {
                    throw new DomeniaOperationException(MachineErrors.TargetUnknown, MachineErrors.TargetUnknownMessage);
                }
                var label = MachineAccountRules.Label(source, account);
                var origin = candidate is not null ? "compte à valider, pas encore en service" : label.Origin;
                var who = candidate is not null ? account + " (" + origin + ")" : label.Long;
                var computer = observation.Workstation.Name;
                var (verdict, text, tone) = MachineAccountRules.Verdict(observation.Outcome, observation.ErrorText, observation.Category, computer, who, observation.Caption);
                var result = new MachineTrialResult(
                    verdict, verdict == MachineTrialVerdict.AdminOk, text, tone, computer, label.Source == MachineAccountSource.Windows ? label.Long : account,
                    origin, observation.Caption, candidate is not null, simulation, context.Clock.GetUtcNow());
                service.RecordTrial(result, place, label.Account);
                context.Journal.Add(new JournalEntry(result.At, "Essai du compte poste sur " + computer + FrenchText.Colon + VerdictWords(verdict) + (simulation ? " (simulation)" : ""), tone));
                context.Log.Info("Essai du compte poste : verdict " + verdict + ".");
                return new MachineTrialOutcome(result, service.Build(session, target, observation.Workstation));
            }, "Essai d’accès sur un seul poste avec le compte des opérations (ou un compte à valider) : une lecture légère du système, sur clic.", ServedInSimulation: true),

            new OperationDefinition("machine.account.watch", OperationClass.Local, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, WatchArguments);
                var since = OptionalVersion(values);
                var target = Target(values);
                var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                await service.WaitForChangeAsync(since, session, MachineAccountService.WatchTimeout, cancellationToken).ConfigureAwait(false);
                var state = service.Build(session, target, null);
                return new MachineAccountWatch(state.Version, since is null || state.Version != since.Value, state.InUse, state.Sentence, state.Generation);
            }, "Attend un changement du compte des opérations poste (25 s au plus) : pastille et phrase à jour sur tout écran, mémoire seulement."),

            new OperationDefinition("machine.workstations.search", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, SearchArguments);
                var text = BridgeArguments.GetString(values, "text");
                if (text.Length > MaxSearchLength)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus " + FrenchText.Integer(MaxSearchLength) + " caractères.");
                }
                var reader = context.Readers.Require<IMachineAccountReader>();
                return await reader.SearchWorkstationsAsync(text, SearchLimit, cancellationToken).ConfigureAwait(false);
            }, "Postes dont le nom contient le texte (douze au plus), pour choisir le poste d’un essai."),
        ];
    }

    private static string VerdictWords(MachineTrialVerdict verdict) => verdict switch
    {
        MachineTrialVerdict.AdminOk => "accès administrateur OK",
        MachineTrialVerdict.Denied => "accès refusé",
        MachineTrialVerdict.Rejected => "identifiants refusés",
        MachineTrialVerdict.AccountState => "compte restreint",
        MachineTrialVerdict.Unreachable => "poste injoignable",
        _ => "essai non concluant",
    };

    /// <summary>The typed account, trimmed, in an accepted form; otherwise machine.accountEmpty or machine.accountInvalid.</summary>
    private static string Account(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new DomeniaOperationException(MachineErrors.AccountEmpty, MachineErrors.AccountEmptyMessage);
        }
        return MachineAccountRules.NormalizeAccount(value)
            ?? throw new DomeniaOperationException(MachineErrors.AccountInvalid, MachineErrors.AccountInvalidMessage);
    }

    /// <summary>
    /// The password as a read-only SecureString (directory mode, required); in simulation none is admitted. The text received from
    /// the page is never kept, logged nor sent back.
    /// </summary>
    private static SecureString? Secret(string? password, bool simulation)
    {
        if (simulation)
        {
            return string.IsNullOrEmpty(password)
                ? null
                : throw new DomeniaOperationException(MachineErrors.PasswordRefused, MachineErrors.PasswordRefusedMessage);
        }
        if (string.IsNullOrEmpty(password))
        {
            throw new DomeniaOperationException(MachineErrors.PasswordMissing, MachineErrors.PasswordMissingMessage);
        }
        if (password.Length > MachineAccountRules.MaxPasswordLength)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("password") + " doit faire au plus " + FrenchText.Integer(MachineAccountRules.MaxPasswordLength) + " caractères.");
        }
        var secure = new SecureString();
        foreach (var c in password)
        {
            secure.AppendChar(c);
        }
        secure.MakeReadOnly();
        return secure;
    }

    /// <summary>« since »: the change counter the page knows (an integer from 0), or null to get the words at once.</summary>
    private static long? OptionalVersion(IReadOnlyDictionary<string, JsonElement> values)
    {
        if (!values.TryGetValue("since", out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number) && number >= 0
            ? number
            : throw BridgeArguments.Invalid(FrenchText.Quote("since") + " doit être un entier positif ou null.");
    }

    private static string? OptionalTarget(JsonElement args, IReadOnlyCollection<string> allowed)
    {
        if (args.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
        {
            return null;
        }
        return Target(BridgeArguments.ReadObject(args, allowed));
    }

    /// <summary>Optional workstation: null when absent or empty; a name that is not a host name is refused.</summary>
    private static string? Target(IReadOnlyDictionary<string, JsonElement> values)
    {
        var target = BridgeArguments.GetOptionalString(values, "target");
        if (string.IsNullOrWhiteSpace(target))
        {
            return null;
        }
        return MachineAccountRules.MachineKey(target) is null
            ? throw BridgeArguments.Invalid(FrenchText.Quote("target") + " doit être un nom de poste.")
            : target.Trim();
    }
}
