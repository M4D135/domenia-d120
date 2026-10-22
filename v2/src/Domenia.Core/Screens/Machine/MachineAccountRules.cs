using System.Collections.Immutable;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>
/// Pure rules of the workstation account (Domenia 1 Domenia-Accounts.Model.ps1 and Domenia-Accounts.UI.ps1): the words of
/// the account in service, the form of a typed account, the verdict of an access trial and the cascade of the sources.
/// </summary>
public static partial class MachineAccountRules
{
    /// <summary>Longest account accepted from the page.</summary>
    public const int MaxAccountLength = 256;

    /// <summary>Longest password accepted from the page (never kept as text: SecureString at once).</summary>
    public const int MaxPasswordLength = 256;

    /// <summary>Trials of the session kept for the page.</summary>
    public const int MaxTrials = 8;

    private const string UserChars = "[^\\\\/\"\\[\\]:;|=,+*?<>@\\s][^\\\\/\"\\[\\]:;|=,+*?<>@]{0,103}";

    [GeneratedRegex("^(\\.|[A-Za-z0-9][A-Za-z0-9._-]{0,14})\\\\" + UserChars + "$", RegexOptions.CultureInvariant)]
    private static partial Regex DownLevelPattern();

    [GeneratedRegex("^" + UserChars + "@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", RegexOptions.CultureInvariant)]
    private static partial Regex UpnPattern();

    [GeneratedRegex("^[A-Za-z0-9][A-Za-z0-9-]{0,62}(\\.[A-Za-z0-9-]{1,63})*$", RegexOptions.CultureInvariant)]
    private static partial Regex HostPattern();

    [GeneratedRegex("(?i)RPC|0x800706BA|unavailable|indisponible|injoignable|not reachable|network path|chemin r[eé]seau", RegexOptions.CultureInvariant)]
    private static partial Regex UnreachablePattern();

    // ---------------------------------------------------------------- words

    /// <summary>Origin of a source, in the words of Domenia 1.</summary>
    public static string Origin(MachineAccountSource source) => source switch
    {
        MachineAccountSource.TemporaryLocal => "compte local temporaire de ce poste",
        MachineAccountSource.Temporary => "compte temporaire accepté après un refus",
        MachineAccountSource.Typed => "compte poste saisi, en mémoire seulement",
        MachineAccountSource.Remote => "compte Postes de la page Comptes",
        MachineAccountSource.Connection => "compte de connexion",
        _ => "session Windows",
    };

    /// <summary>
    /// Names the account the next workstation operation takes (Get-DomeniaMachineAccountLabel): Short for the pill, Long for the
    /// sentences, Pill for « Compte poste : … ▾ ». Names only.
    /// </summary>
    public static MachineAccountLabel Label(MachineAccountSource source, string? account)
    {
        var name = (account ?? "").Trim();
        var origin = Origin(source);
        var windows = source == MachineAccountSource.Windows;
        var shortText = windows ? "session Windows" : name.Length > 0 ? name : origin;
        var longText = name.Length > 0 ? name + " (" + origin + ")" : origin;
        if (windows && name.Length > 0)
        {
            longText = "session Windows (" + name + ")";
        }
        return new MachineAccountLabel(source, name, origin, shortText, longText, "Compte poste" + FrenchText.Colon + shortText + " ▾");
    }

    /// <summary>« Opérations poste : … . » (Get-DomeniaMachineOperationAccountText).</summary>
    public static string Sentence(MachineAccountLabel label)
    {
        ArgumentNullException.ThrowIfNull(label);
        return "Opérations poste" + FrenchText.Colon + label.Long + ".";
    }

    /// <summary>Tip of the pill (Update-DomeniaMachineAccountUi).</summary>
    public static string Tip(MachineAccountLabel label, MachineAccountPause? pause)
    {
        ArgumentNullException.ThrowIfNull(label);
        var tip = "Compte utilisé pour les opérations sur ce poste" + FrenchText.Colon + label.Long
            + ". Ouvre un panneau pour saisir un autre compte ou revenir au compte de connexion.";
        return pause is null ? tip : tip + " En pause après un refus" + FrenchText.Colon + pause.Reason;
    }

    // ---------------------------------------------------------------- form of an account

    /// <summary>
    /// The typed account, trimmed, when it has an accepted form: DOMAINE\nom, POSTE\nom, .\nom (local account of the workstation
    /// chosen) or nom@domaine; otherwise null.
    /// </summary>
    public static string? NormalizeAccount(string? account)
    {
        var text = (account ?? "").Trim();
        if (text.Length is 0 or > MaxAccountLength)
        {
            return null;
        }
        return DownLevelPattern().IsMatch(text) || UpnPattern().IsMatch(text) ? text : null;
    }

    /// <summary>Short upper-case name of a workstation (ConvertTo-DomeniaMachineKey): the part before the first dot.</summary>
    public static string? MachineKey(string? computer)
    {
        var text = (computer ?? "").Trim();
        if (text.Length is 0 or > 255 || !HostPattern().IsMatch(text))
        {
            return null;
        }
        var dot = text.IndexOf('.', StringComparison.Ordinal);
        return (dot < 0 ? text : text[..dot]).ToUpperInvariant();
    }

    /// <summary>« .\nom » completed with the name of the workstation (Domenia 1 CPT-018); other forms unchanged.</summary>
    public static string ForTarget(string account, string? computer)
    {
        ArgumentNullException.ThrowIfNull(account);
        var key = MachineKey(computer);
        return key is not null && account.StartsWith(".\\", StringComparison.Ordinal) ? key + account[1..] : account;
    }

    // ---------------------------------------------------------------- verdict of a trial

    /// <summary>
    /// What one light CIM read on one workstation proves about the account (Get-DomeniaRemoteAccessTrialVerdict). Only an
    /// explicit success says « Accès administrateur OK ».
    /// </summary>
    public static (MachineTrialVerdict Verdict, string Text, Tone Tone) Verdict(string? outcome, string? errorText, string? category, string? computer, string? account, string? caption)
    {
        var o = (outcome ?? "").Trim();
        var e = (errorText ?? "").Trim();
        var k = (category ?? "").Trim();
        var target = (computer ?? "").Trim();
        if (target.Length == 0)
        {
            target = "ce poste";
        }
        var who = (account ?? "").Trim();
        if (who.Length == 0)
        {
            who = "le compte utilisé pour les postes";
        }
        var verdict = MachineTrialVerdict.Unknown;
        if (o == "AuthRejected" || k == "CredentialsRejected")
        {
            verdict = MachineTrialVerdict.Rejected;
        }
        else if (k == "AccountState")
        {
            verdict = MachineTrialVerdict.AccountState;
        }
        else if (o == "Denied" || k is "AccessDenied" or "DecryptionDenied")
        {
            verdict = MachineTrialVerdict.Denied;
        }
        else if (o == "Timeout" || k is "Timeout" or "Network")
        {
            verdict = MachineTrialVerdict.Unreachable;
        }
        else if (UnreachablePattern().IsMatch(e))
        {
            verdict = MachineTrialVerdict.Unreachable;
        }
        else if (e.Length == 0 && o is "NotRequested" or "Observed" or "NoConsole")
        {
            verdict = MachineTrialVerdict.AdminOk;
        }
        var system = (caption ?? "").Trim();
        var text = verdict switch
        {
            MachineTrialVerdict.AdminOk => "Accès administrateur OK sur " + target + " avec " + who + "." + (system.Length > 0 ? " Système" + FrenchText.Colon + system + "." : ""),
            MachineTrialVerdict.Denied => "Accès refusé sur " + target + " avec " + who + FrenchText.Colon + "droit administrateur requis sur ce poste.",
            MachineTrialVerdict.Rejected => "Identifiants refusés par " + target + " pour " + who + FrenchText.Colon + "vérifiez le compte et son mot de passe.",
            MachineTrialVerdict.AccountState => "Compte verrouillé, expiré ou restreint (" + who + ")" + FrenchText.Colon + "vérifiez son état avant un nouvel essai.",
            MachineTrialVerdict.Unreachable => "Poste " + target + " injoignable (réseau, nom ou service WMI)" + FrenchText.Colon + "aucun droit n’a pu être vérifié.",
            _ => "Essai non concluant sur " + target + (e.Length > 0 ? FrenchText.Colon + (e.Length > 160 ? e[..160] + "…" : e) : "."),
        };
        var tone = verdict switch
        {
            MachineTrialVerdict.AdminOk => Tone.Ok,
            MachineTrialVerdict.Denied or MachineTrialVerdict.AccountState => Tone.Warn,
            MachineTrialVerdict.Rejected => Tone.Alert,
            MachineTrialVerdict.Unreachable => Tone.Info,
            _ => Tone.Off,
        };
        return (verdict, text, tone);
    }

    // ---------------------------------------------------------------- cascades

    /// <summary>Accounts known at each level for one operation (names only; a pause is looked up by name).</summary>
    public sealed record CascadeInput(
        string? TemporaryLocal,
        string? Temporary,
        string? Typed,
        string? Remote,
        string? Connection,
        string Windows,
        bool TargetChosen,
        bool Simulation,
        IReadOnlyDictionary<string, MachineAccountPause> Pauses);

    private static readonly (MachineAccountSource Source, string Title, string Detail)[] Levels =
    [
        (MachineAccountSource.TemporaryLocal, "Compte local accepté pour ce poste", "Accepté après un refus d’accès sur ce poste, pour lui seul ; gardé en mémoire avec son bail."),
        (MachineAccountSource.Temporary, "Compte temporaire Postes", "Accepté après un refus sur un poste ; vaut pour tous les postes tant que son bail est valide."),
        (MachineAccountSource.Typed, "Compte poste saisi", "Saisi dans le panneau " + FrenchText.Quote("Compte poste") + " ; en mémoire seulement, jamais enregistré."),
        (MachineAccountSource.Remote, "Compte Postes", "Compte administrateur des postes configuré dans la page Comptes."),
        (MachineAccountSource.Connection, "Compte de connexion", "Compte saisi à la connexion à l’annuaire (identifiants explicites)."),
        (MachineAccountSource.Windows, "Session Windows", "Compte de la session Windows qui a lancé Domenia ; toujours disponible."),
    ];

    /// <summary>
    /// The six levels in the order of the worker context, the first configured one active (Get-DomeniaMachineAccountInUse),
    /// with the account in service and its pause.
    /// </summary>
    public static (ImmutableArray<MachineAccountLevel> Levels, MachineAccountInUse InUse) Cascade(CascadeInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        var accounts = new[] { input.TemporaryLocal, input.Temporary, input.Typed, input.Remote, input.Connection, input.Windows };
        var active = Array.FindIndex(accounts, a => !string.IsNullOrWhiteSpace(a));
        var levels = ImmutableArray.CreateBuilder<MachineAccountLevel>(Levels.Length);
        for (var i = 0; i < Levels.Length; i++)
        {
            var (source, title, detail) = Levels[i];
            var account = string.IsNullOrWhiteSpace(accounts[i]) ? null : accounts[i]!.Trim();
            var pause = account is null ? null : input.Pauses.GetValueOrDefault(account);
            MachineLevelState state;
            if (i == active)
            {
                state = MachineLevelState.Active;
            }
            else if (account is not null)
            {
                state = MachineLevelState.Available;
            }
            else if (source == MachineAccountSource.TemporaryLocal && !input.TargetChosen)
            {
                state = MachineLevelState.NotApplicable;
            }
            else
            {
                state = MachineLevelState.Empty;
            }
            var levelDetail = source == MachineAccountSource.Connection && input.Simulation && account is null
                ? "Simulation : aucune connexion par identifiants ; l’annuaire fictif n’en demande pas."
                : detail;
            levels.Add(new MachineAccountLevel(
                i + 1, Camel(source.ToString()), title, Origin(source), account, state, StateLabel(state, pause is not null),
                pause is not null ? Tone.Warn : StateTone(state), levelDetail, pause is not null, pause?.Reason));
        }
        var chosen = Levels[active < 0 ? Levels.Length - 1 : active].Source;
        var label = Label(chosen, accounts[active < 0 ? Levels.Length - 1 : active]);
        var paused = label.Account.Length > 0 ? input.Pauses.GetValueOrDefault(label.Account) : null;
        var inUse = new MachineAccountInUse(
            label.Source, label.Account, label.Origin, label.Short, label.Long, label.Pill, Tip(label, paused), (active < 0 ? Levels.Length - 1 : active) + 1,
            paused is not null, paused?.Reason, paused is not null ? Tone.Warn : Tone.Ok);
        return (levels.ToImmutable(), inUse);
    }

    /// <summary>The account of the secrets reads: temporary, Secrets account, otherwise the directory account.</summary>
    public static SecretsAccountState SecretsCascade(string? temporary, string? secrets, string directory, IReadOnlyDictionary<string, MachineAccountPause> pauses)
    {
        ArgumentNullException.ThrowIfNull(pauses);
        (SecretsAccountSource Source, string Title, string Origin, string Detail, string? Account)[] rows =
        [
            (SecretsAccountSource.Temporary, "Compte temporaire Secrets", "compte temporaire accepté après un refus", "Accepté après un refus de lecture LAPS ou BitLocker ; bail en mémoire.", Clean(temporary)),
            (SecretsAccountSource.Secrets, "Compte Secrets", "compte Secrets de la page Comptes", "Autorisé à lire LAPS et BitLocker ; configuré dans la page Comptes.", Clean(secrets)),
            (SecretsAccountSource.Directory, "Compte de l’annuaire", "compte de l’annuaire", "Compte de connexion, sinon session Windows ; toujours disponible.", Clean(directory)),
        ];
        var active = Array.FindIndex(rows, r => r.Account is not null);
        if (active < 0)
        {
            active = rows.Length - 1;
        }
        var levels = rows.Select((r, i) =>
        {
            var state = i == active ? MachineLevelState.Active : r.Account is not null ? MachineLevelState.Available : MachineLevelState.Empty;
            var pause = r.Account is null ? null : pauses.GetValueOrDefault(r.Account);
            return new MachineAccountLevel(i + 1, Camel(r.Source.ToString()), r.Title, r.Origin, r.Account, state, StateLabel(state, pause is not null),
                pause is not null ? Tone.Warn : StateTone(state), r.Detail, pause is not null, pause?.Reason);
        }).ToImmutableArray();
        var chosen = rows[active];
        var account = chosen.Account ?? "";
        var longText = account.Length > 0 ? account + " (" + chosen.Origin + ")" : chosen.Origin;
        return new SecretsAccountState(account, chosen.Origin, longText, levels);
    }

    private static string? Clean(string? account) => string.IsNullOrWhiteSpace(account) ? null : account.Trim();

    private static string StateLabel(MachineLevelState state, bool paused) => paused
        ? "En pause après un refus"
        : state switch
        {
            MachineLevelState.Active => "En service",
            MachineLevelState.Available => "Disponible, non utilisé",
            MachineLevelState.NotApplicable => "Propre au poste choisi",
            _ => "Non configuré",
        };

    private static Tone StateTone(MachineLevelState state) => state switch
    {
        MachineLevelState.Active => Tone.Ok,
        MachineLevelState.Available => Tone.Info,
        _ => Tone.Off,
    };

    private static string Camel(string name) => char.ToLowerInvariant(name[0]) + name[1..];
}
