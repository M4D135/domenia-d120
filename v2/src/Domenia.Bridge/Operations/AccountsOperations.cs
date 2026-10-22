using System.Globalization;
using System.Security;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Comptes screen (docs/ops/comptes.md): the accounts of the section scope, the detail of one account, its lockout diagnosis,
/// the exact preview of a collective action and the plans of the account writes (enable, disable, password reset, forced
/// change, expiration; the unlock plan is <see cref="AccountUnlockOperations"/>). Every operation only reads: the writes go
/// through write.execute, once, with their receipt and their re-read (docs/WRITES.md). LocalRead in simulation (fictitious
/// directory in memory), NetworkRead in directory mode (bounded reads on the controller, after the operator's gesture).
/// </summary>
public sealed class AccountsOperations : IOperationModule
{
    /// <summary>Most DNs of one collective preview (the bridge message stays far below 1 MB).</summary>
    public const int MaxBatchDns = 5000;

    private static readonly string[] ScopeArguments = ["dn", "subtree"];
    private static readonly string[] DnArguments = ["dn"];
    private static readonly string[] LockoutArguments = ["dn", "hours"];
    private static readonly string[] BatchArguments = ["action", "dns", "date", "ticket"];
    private static readonly string[] BatchConfirmArguments = ["id", "typedCount"];
    private static readonly string[] BatchPlanArguments = ["id", "index"];
    private static readonly string[] TicketArguments = ["ticket"];
    private static readonly string[] ExpirationArguments = ["dn", "date"];
    private static readonly string[] PasswordArguments = ["dn", "password", "mustChange", "unlock"];

    public string Screen => "accounts";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var readers = context.Readers;
        var writers = context.Writers;
        var source = context.Directory;
        var circuit = WriteCircuit.From(context);
        var scope = AccountsSectionScope.From(context);
        var seals = AccountsBatchSeals.From(context);
        var access = AccountAccess.From(context);
        var readClass = context.Mode == AppMode.Simulation ? OperationClass.LocalRead : OperationClass.NetworkRead;
        return
        [
            new OperationDefinition("accounts.list", readClass, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                var reader = readers.Require<IAccountsReader>();
                var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                var current = await scope.CurrentAsync(session, cancellationToken).ConfigureAwait(false)
                    ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
                return await reader.ListAsync(current, cancellationToken).ConfigureAwait(false);
            }, "Comptes utilisateurs du périmètre de la section (jamais tout le domaine), avec leurs états, les compteurs et la stratégie."),

            // LocalRead: the remembered choice is checked in the local OU index, never by the network.
            new OperationDefinition("accounts.scope.get", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                return await scope.CurrentAsync(session, cancellationToken).ConfigureAwait(false);
            }, "Périmètre des comptes\u00A0: choix de la section, sinon OU de travail\u00A0; aucune lecture de l’annuaire."),

            new OperationDefinition("accounts.scope.set", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, ScopeArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var subtree = BridgeArguments.GetBoolean(values, "subtree");
                var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                return await scope.SetAsync(session, dn, subtree, cancellationToken).ConfigureAwait(false);
            }, "Choisit le périmètre des comptes (une OU, jamais la racine), vérifié dans l’index local et mémorisé par domaine."),

            new OperationDefinition("accounts.scope.reset", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                return await scope.ResetAsync(session, cancellationToken).ConfigureAwait(false);
            }, "Revient à l’OU de travail pour la section Comptes."),

            new OperationDefinition("accounts.detail", readClass, async (args, _, cancellationToken) =>
            {
                var dn = RequireDn(args);
                var reader = readers.Require<IAccountsReader>();
                var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                var detail = await reader.DetailAsync(dn, session.Account.Dn, cancellationToken).ConfigureAwait(false);
                var settings = await access.ConfigurationAsync(cancellationToken).ConfigureAwait(false);
                return detail with
                {
                    ResetDefaults = new PasswordResetDefaults(settings.ForcePasswordChangeOnReset,
                        settings.State == ConfigurationFileState.Read ? "Security.ForcePasswordChangeOnReset (Domenia.config.json)" : "Défaut de Domenia 1 (Security.ForcePasswordChangeOnReset)",
                        AccountsConfiguration.RevealSeconds),
                };
            }, "Détail d’un compte\u00A0: identité, état calculé, mot de passe, bandeau support, actions possibles et réglages du formulaire de réinitialisation."),

            // NetworkRead in both modes: the security log of the PDC emulator, read on an explicit gesture only.
            new OperationDefinition("accounts.lockouts", OperationClass.NetworkRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, LockoutArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var hours = AccountsArguments.GetOptionalInt(values, "hours", AccountsLockouts.MinHours, AccountsLockouts.MaxHours) ?? AccountsLockouts.DefaultHours;
                var reader = readers.Require<IAccountsReader>();
                var (user, domain, read) = await reader.LockoutEventsAsync(dn, hours, cancellationToken).ConfigureAwait(false);
                var (now, zone, simulated) = reader.Clock;
                var keys = new[]
                {
                    CredentialRules.AccountKey(domain.NetbiosName + "\\" + user.SamAccountName, domain.DnsName, domain.NetbiosName, null),
                    CredentialRules.AccountKey(user.SamAccountName + "@" + domain.DnsName, domain.DnsName, domain.NetbiosName, null),
                };
                return AccountsLockouts.Report(user, domain, read, AccountAccess.From(context).Refusals(), keys, hours, now, zone, simulated);
            }, "Verrouillages du compte (événements 4740 de l’émulateur PDC, filtrés sur son SID), postes à l’origine et refus de Domenia juste avant.", ServedInSimulation: true),

            new OperationDefinition("accounts.batch.preview", readClass, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, BatchArguments);
                if (!AccountsBatch.TryParse(BridgeArguments.GetString(values, "action"), out var action))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("action") + " doit valoir unlock, enable, disable, mustChange ou expiration.");
                }
                var dns = AccountsArguments.GetDnList(values, "dns", MaxBatchDns);
                var ticket = AccountsArguments.GetTicket(values, "ticket");
                var reader = readers.Require<IAccountsReader>();
                var (now, zone, simulated) = reader.Clock;
                DateOnly? date = null;
                if (action == AccountsBatchAction.Expiration)
                {
                    date = AccountsArguments.GetExpirationDate(values, "date", now, zone);
                }
                else if (values.TryGetValue("date", out var unused) && unused.ValueKind != JsonValueKind.Null)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("date") + " n’est admise que pour l’expiration.");
                }
                var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                // The read of the candidates can be stopped by the page (panel closed: accounts.batch.cancel with its ticket).
                using var tracked = ticket is null ? null : seals.Track(ticket);
                using var linked = tracked is null ? null : CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, tracked.Token);
                try
                {
                    var candidates = await reader.CandidatesAsync(dns, linked?.Token ?? cancellationToken).ConfigureAwait(false);
                    var preview = AccountsBatch.Preview(action, candidates, session.Account.Dn, date, now, zone, simulated);
                    return seals.Seal(preview, session.Account.Dn);
                }
                finally
                {
                    if (ticket is not null && tracked is not null)
                    {
                        seals.Untrack(ticket, tracked);
                    }
                }
            }, "Aperçu exact d’une action par lot, scellé par le moteur\u00A0: cibles, exclusions motivées, impact et nombre de comptes à saisir\u00A0; rien n’est écrit."),

            new OperationDefinition("accounts.batch.cancel", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, TicketArguments);
                var ticket = AccountsArguments.GetTicket(values, "ticket") ?? throw BridgeArguments.Invalid(FrenchText.Quote("ticket") + " est obligatoire.");
                return Task.FromResult<object?>(new BatchCancel(seals.Cancel(ticket)));
            }, "Arrête la lecture d’un aperçu collectif (panneau fermé)\u00A0; rien n’a été préparé."),

            new OperationDefinition("accounts.batch.confirm", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, BatchConfirmArguments);
                var id = AccountsArguments.GetBatchId(values, "id");
                var typed = BridgeArguments.GetOptionalString(values, "typedCount");
                if (typed is { Length: > 12 })
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("typedCount") + " doit être un nombre de comptes.");
                }
                return Task.FromResult<object?>(seals.Confirm(id, typed));
            }, "Confirme un aperçu collectif scellé\u00A0: le nombre saisi est revérifié par le moteur\u00A0; rien n’est écrit."),

            new OperationDefinition("accounts.batch.plan", readClass, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, BatchPlanArguments);
                var id = AccountsArguments.GetBatchId(values, "id");
                var index = AccountsArguments.GetOptionalInt(values, "index", 0, AccountsBatch.Limit) ?? throw BridgeArguments.Invalid(FrenchText.Quote("index") + " est obligatoire.");
                var (action, date, dn, guid, operatorDn) = seals.Issue(id, index);
                var draft = action switch
                {
                    AccountsBatchAction.Unlock => await writers.Require<IAccountUnlockExecutor>().PlanAsync(dn, cancellationToken).ConfigureAwait(false),
                    AccountsBatchAction.Enable => await writers.Require<IAccountEnableExecutor>().PlanAsync(dn, cancellationToken).ConfigureAwait(false),
                    AccountsBatchAction.Disable => await writers.Require<IAccountDisableExecutor>().PlanAsync(dn, operatorDn, cancellationToken).ConfigureAwait(false),
                    AccountsBatchAction.MustChange => await writers.Require<IAccountMustChangePasswordExecutor>().PlanAsync(dn, cancellationToken).ConfigureAwait(false),
                    _ => await writers.Require<IAccountExpirationExecutor>().PlanAsync(dn, date, cancellationToken).ConfigureAwait(false),
                };
                if (!string.Equals(draft.Target.ObjectGuid, guid, StringComparison.OrdinalIgnoreCase))
                {
                    throw new DomeniaOperationException(AccountsBatchSeals.TargetChanged, "Ce nom distinctif désigne un autre compte que dans l’aperçu scellé" + FrenchText.Colon + "aucune écriture préparée.");
                }
                if (draft.Confirmation.TypedNameRequired)
                {
                    throw new DomeniaOperationException(AccountsBatchSeals.TypedNameRequired, "Ce compte exige la saisie de son nom" + FrenchText.Colon + "à traiter seul, aucune écriture préparée dans le lot.");
                }
                return await circuit.PlanAsync(draft, cancellationToken).ConfigureAwait(false);
            }, "Plan d’un compte d’un lot confirmé (une fois par compte, GUID scellé revérifié)\u00A0; l’exécution reste write.execute."),

            new OperationDefinition("accounts.enable.plan", readClass, async (args, _, cancellationToken) =>
            {
                var dn = RequireDn(args);
                var draft = await writers.Require<IAccountEnableExecutor>().PlanAsync(dn, cancellationToken).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, cancellationToken).ConfigureAwait(false);
            }, "Plan de l’activation d’un compte\u00A0: relecture, changement, risques et jeton de confirmation\u00A0; rien n’est écrit."),

            new OperationDefinition("accounts.disable.plan", readClass, async (args, _, cancellationToken) =>
            {
                var dn = RequireDn(args);
                var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                var draft = await writers.Require<IAccountDisableExecutor>().PlanAsync(dn, session.Account.Dn, cancellationToken).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, cancellationToken).ConfigureAwait(false);
            }, "Plan de la désactivation d’un compte (jamais le compte de session)\u00A0: relecture, risques et jeton\u00A0; rien n’est écrit."),

            new OperationDefinition("accounts.mustChange.plan", readClass, async (args, _, cancellationToken) =>
            {
                var dn = RequireDn(args);
                var draft = await writers.Require<IAccountMustChangePasswordExecutor>().PlanAsync(dn, cancellationToken).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, cancellationToken).ConfigureAwait(false);
            }, "Plan du changement de mot de passe imposé (pwdLastSet = 0)\u00A0; rien n’est écrit."),

            new OperationDefinition("accounts.expiration.plan", readClass, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, ExpirationArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var executor = writers.Require<IAccountExpirationExecutor>();
                var now = context.Clock.GetUtcNow();
                var zone = context.Clock.LocalTimeZone;
                if (readers.Find<IAccountsReader>() is IAccountsReader reader)
                {
                    var clock = reader.Clock;
                    now = clock.Now;
                    zone = clock.Zone;
                }
                var date = AccountsArguments.GetExpirationDate(values, "date", now, zone);
                var draft = await executor.PlanAsync(dn, date, cancellationToken).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, cancellationToken).ConfigureAwait(false);
            }, "Plan de l’expiration d’un compte (date locale à 0 h, ou jamais)\u00A0; rien n’est écrit."),

            new OperationDefinition("accounts.password.plan", readClass, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, PasswordArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var options = new PasswordResetOptions(BridgeArguments.GetBoolean(values, "mustChange"), BridgeArguments.GetBoolean(values, "unlock"));
                var executor = writers.Require<IAccountPasswordResetExecutor>();
                using var password = AccountsArguments.GetPassword(values, "password");
                var draft = await executor.PlanAsync(dn, options, password, cancellationToken).ConfigureAwait(false);
                var planned = await circuit.PlanAsync(draft, cancellationToken).ConfigureAwait(false);
                // The executor keeps its own read-only copy for this plan only; ours is disposed here.
                executor.Hold(planned.Plan.Id, planned.Plan.ExpiresAt, password);
                return planned;
            }, "Plan de la réinitialisation d’un mot de passe\u00A0: la valeur saisie reste en mémoire protégée pour ce plan seulement, jamais dans le plan, le reçu ni le journal."),
        ];
    }

    private static string RequireDn(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, DnArguments);
        return BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
    }
}

/// <summary>Argument checks of the Comptes operations (arguments.invalid with a fixed precision, never the page input).</summary>
internal static class AccountsArguments
{
    /// <summary>Optional whole number within [min, max]: absent or null gives null.</summary>
    public static int? GetOptionalInt(IReadOnlyDictionary<string, JsonElement> values, string name, int min, int max)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) && number >= min && number <= max)
        {
            return number;
        }
        throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un entier de " + FrenchText.Integer(min) + " à " + FrenchText.Integer(max) + ".");
    }

    /// <summary>A non-empty array of well-formed DNs, at most <paramref name="max"/>.</summary>
    public static IReadOnlyList<string> GetDnList(IReadOnlyDictionary<string, JsonElement> values, string name, int max)
    {
        var precision = FrenchText.Quote(name) + " doit être une liste de 1 à " + FrenchText.Integer(max) + " noms distinctifs valides.";
        if (!values.TryGetValue(name, out var value) || value.ValueKind != JsonValueKind.Array)
        {
            throw BridgeArguments.Invalid(precision);
        }
        var length = value.GetArrayLength();
        if (length is 0 || length > max)
        {
            throw BridgeArguments.Invalid(precision);
        }
        var list = new List<string>(length);
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String)
            {
                throw BridgeArguments.Invalid(precision);
            }
            var dn = item.GetString()!;
            try
            {
                list.Add(BridgeArguments.RequireDistinguishedName(dn, name));
            }
            catch (BridgeOperationException)
            {
                throw BridgeArguments.Invalid(precision);
            }
        }
        return list;
    }

    /// <summary>
    /// Expiration date: required key, « AAAA-MM-JJ » (local day, at most 50 years ahead) or null for « never ».
    /// </summary>
    public static DateOnly? GetExpirationDate(IReadOnlyDictionary<string, JsonElement> values, string name, DateTimeOffset now, TimeZoneInfo zone)
    {
        var precision = FrenchText.Quote(name) + " doit être une date AAAA-MM-JJ (au plus dans " + FrenchText.Integer(AccountExpiration.MaxYearsAhead) + " ans) ou null.";
        if (!values.TryGetValue(name, out var value))
        {
            throw BridgeArguments.Invalid(precision);
        }
        if (value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind != JsonValueKind.String
            || !DateOnly.TryParseExact(value.GetString(), "yyyy'-'MM'-'dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
        {
            throw BridgeArguments.Invalid(precision);
        }
        var today = LocalDays.DateOf(now, zone);
        if (date.Year < 1700 || date > today.AddYears(AccountExpiration.MaxYearsAhead))
        {
            throw BridgeArguments.Invalid(precision);
        }
        return date;
    }

    /// <summary>
    /// The password typed in the page, as a read-only <see cref="SecureString"/> (1 to 256 characters, no control character).
    /// The JSON text of the message stays in managed memory until the garbage collector reclaims it: it is never logged, never
    /// copied anywhere else, and our reference to its value is dropped at once.
    /// </summary>
    public static SecureString GetPassword(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var precision = FrenchText.Quote(name) + " doit être un texte de 1 à " + FrenchText.Integer(CredentialRules.MaxPasswordLength) + " caractères.";
        if (!values.TryGetValue(name, out var value) || value.ValueKind != JsonValueKind.String)
        {
            throw BridgeArguments.Invalid(precision);
        }
        var text = value.GetString()!;
        if (text.Length is 0 or > CredentialRules.MaxPasswordLength || text.Any(char.IsControl))
        {
            throw BridgeArguments.Invalid(precision);
        }
        return PasswordSecrets.FromText(text);
    }

    /// <summary>Optional ticket of a preview read (8 to 40 letters, digits or dashes), or null.</summary>
    public static string? GetTicket(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var ticket = BridgeArguments.GetOptionalString(values, name);
        return ticket is null || (ticket.Length is >= 8 and <= 40 && ticket.All(ch => char.IsAsciiLetterOrDigit(ch) || ch == '-'))
            ? ticket
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un identifiant de lecture (8 à 40 lettres, chiffres ou tirets).");
    }

    /// <summary>Identifier of a sealed collective plan (32 hexadecimal characters).</summary>
    public static string GetBatchId(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var id = BridgeArguments.GetString(values, name);
        return id.Length == 32 && id.All(char.IsAsciiHexDigitLower)
            ? id
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être l’identifiant d’un aperçu collectif (32 caractères hexadécimaux).");
    }

    /// <summary>An account name in one of the admitted forms (DOMAINE\compte, compte@domaine, POSTE\compte, .\compte).</summary>
    public static string GetLogin(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var login = BridgeArguments.GetString(values, name);
        return CredentialRules.IsWellFormed(login)
            ? login.Trim()
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un compte DOMAINE\\compte, compte@domaine, POSTE\\compte ou .\\compte.");
    }
}

/// <summary>Result of accounts.batch.cancel.</summary>
public sealed record BatchCancel(bool Cancelled);
