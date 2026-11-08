using System.Collections.Immutable;
using Domenia.Core.Poste;

namespace Domenia.Core;

/// <summary>Settings that decide the transports (Domenia 1 Remote.UseCim, Remote.UseWinRM, Remote.UsePsExecFallback, Remote.UseTaskFallback).</summary>
public sealed record TransportSettings(bool UseCim, bool UseWinRm, bool UsePsExecFallback, bool UseTaskFallback, string Source)
{
    /// <summary>Direct readings enabled; transient execution disabled until explicitly configured.</summary>
    public static TransportSettings Defaults { get; } = new(true, true, false, false, "Réglages de Domenia 2 : lectures directes actives, exécutions ponctuelles désactivées");
}

/// <summary>One transport, what it is used for, its ports, its state and its rule (CPT-020).</summary>
public sealed record TransportRow(string Id, string Transport, string Usage, string Ports, string State, Tone StateTone, string Rule, bool Intrusive);

/// <summary>Result of accounts.transports.</summary>
public sealed record TransportTable(ImmutableArray<TransportRow> Rows, bool ConsentActive, string ConsentText, string SettingsSource, string Note);

/// <summary>
/// What Domenia uses, what stays off and why (Domenia 1 Get-DomeniaTransportPolicy). Nothing here changes a Windows setting:
/// WinRM is never enabled, an intrusive transport never serves as a silent fallback of a read, and the intervention consent
/// covers one workstation for five minutes. Pure.
/// </summary>
public static class TransportPolicy
{
    public static TransportTable Build(TransportSettings settings, bool consentActive, string? consentTarget, DateTimeOffset? consentUntil = null)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var c = FrenchText.Colon;
        var consent = consentActive && consentTarget is not null ? "Autorisé pour " + consentTarget + " et la durée consentie" : "Inactif sans autorisation explicite";
        var until = consentUntil is DateTimeOffset end ? " jusqu’à " + end.ToLocalTime().ToString("HH':'mm", System.Globalization.CultureInfo.InvariantCulture) : "";
        var rows = ImmutableArray.Create(
            new TransportRow("ldap", "LDAP", "Lectures et écritures de l’annuaire", "389/TCP (signature et scellement Kerberos ou NTLM)", "Actif", Tone.Ok,
                "Authentification sécurisée Windows. Aucun certificat n’est accepté à l’aveugle.", false),
            new TransportRow("cimDcom", "CIM / DCOM", "Lectures sur les postes", "135/TCP puis ports RPC dynamiques",
                settings.UseCim ? "Actif" : "Désactivé par configuration", settings.UseCim ? Tone.Ok : Tone.Off,
                "Lecture seule par défaut. Aucun réglage du poste n’est modifié.", false),
            new TransportRow("cimWsman", "CIM / WSMan", "Repli des lectures CIM", "5985/TCP ou 5986/TCP",
                settings.UseWinRm ? "Autorisé s’il est déjà en service sur le poste" : "Désactivé par configuration", settings.UseWinRm ? Tone.Info : Tone.Off,
                "WinRM n’est jamais activé ni configuré par Domenia.", false),
            new TransportRow("wts", "WTS", "Lecture des sessions Windows", "RPC / 445/TCP", "À la demande", Tone.Info, "Consultation uniquement" + c + "aucune déconnexion.", false),
            new TransportRow("adminShare", "Partage ADMIN$", "Dépôt temporaire d’un script d’intervention", "445/TCP", consent, consentActive ? Tone.Warn : Tone.Off,
                "Jamais utilisé sans autorisation explicite d’intervention sur le poste. Une lecture exige une autorisation distincte, demandée pour cette lecture.", true),
            new TransportRow("scheduler", "Planificateur (COM)", "Exécution ponctuelle d’une intervention", "RPC",
                !settings.UseTaskFallback ? "Désactivé par configuration" : consent, !settings.UseTaskFallback ? Tone.Off : consentActive ? Tone.Warn : Tone.Off,
                "Aucun mot de passe en argument. Aucun repli silencieux.", true),
            new TransportRow("psexec", "PsExec", "Exécution ponctuelle d’une intervention", "445/TCP",
                !settings.UsePsExecFallback ? "Désactivé par configuration" : consentActive ? "Autorisé, contexte Windows intégré uniquement" : "Inactif sans autorisation explicite",
                !settings.UsePsExecFallback ? Tone.Off : consentActive ? Tone.Warn : Tone.Off,
                "Aucun compte explicite converti en argument.", true));
        var consentText = consentActive && consentTarget is not null
            ? "Autorisation d’intervention en cours" + c + consentTarget + until + ", pour ce poste seulement et pour vos actions volontaires."
            : "Aucune autorisation d’intervention en cours" + c + "une autorisation couvre un seul poste pendant 5 minutes, sur geste explicite (Assistance poste, Intervenir).";
        return new TransportTable(rows, consentActive, consentText, settings.Source,
            "Un transport intrusif n’est jamais un repli silencieux d’une lecture ni d’une détection. Rien ici ne modifie un réglage de Windows.");
    }

    /// <summary>Effective collection policy, including the locally saved selection. Display only; it grants no consent.</summary>
    public static TransportTable Build(PosteConfiguration settings, bool consentActive, string? consentTarget, DateTimeOffset? consentUntil = null)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var basis = Build(new TransportSettings(settings.UseCim, settings.Options.UseWinRm, settings.UsePsExecFallback,
            settings.UseTaskFallback, "Réglages de collecte effectifs : configuration et préférences locales"), consentActive, consentTarget, consentUntil);
        var selected = settings.SelectedCimTransport;
        var direct = settings.UseCim;
        var transient = settings.AllowsTransient;
        var mode = settings.TransientMode == "automatic"
            ? "Automatique après activation, au plus " + settings.AutomaticTargetLimit + " postes par campagne"
            : "Après accord explicite pour cette lecture";
        TransportRow Method(string id, string label, string ports, string choice, bool enabled, string rule)
        {
            var allowed = transient && enabled && (settings.TransientMethod == "auto" || settings.TransientMethod == choice);
            return new(id, label, "Collecte ponctuelle", ports, allowed ? mode : "Désactivé ou autre méthode sélectionnée",
                allowed ? Tone.Info : Tone.Off, rule, true);
        }
        var rows = basis.Rows.Select(row => row.Id switch
        {
            "cimDcom" => row with { State = direct && selected == InventoryTransport.Dcom ? "Sélectionné" : "Non sélectionné",
                StateTone = direct && selected == InventoryTransport.Dcom ? Tone.Ok : Tone.Off,
                Rule = "Lectures directes sans changement du poste. Les essais explicites de compte utilisent DCOM et sont bloqués en mode WinRM exclusif." },
            "cimWsman" => row with { Usage = "Lectures directes CIM", State = direct && selected == InventoryTransport.WinRm ? "Sélectionné" : "Non sélectionné",
                StateTone = direct && selected == InventoryTransport.WinRm ? Tone.Ok : Tone.Off },
            "adminShare" => row with { Usage = "Dépôt temporaire pour collecte ponctuelle ou intervention",
                State = transient ? mode : consentActive ? "Intervention consentie uniquement" : "Inactif sans autorisation explicite",
                StateTone = transient || consentActive ? Tone.Info : Tone.Off,
                Rule = "Collecte : activation dans les réglages, puis autorisation manuelle ou périmètre automatique borné. Intervention : accord distinct pour le poste." },
            "scheduler" => Method(row.Id, row.Transport, row.Ports, "task", settings.UseTaskFallback,
                "Tâche temporaire, programme figé, résultat et nettoyage suivis ; aucune relance après une issue incertaine."),
            "psexec" => Method(row.Id, row.Transport, row.Ports, "psexec", settings.UsePsExecFallback,
                "Binaire local approuvé et contexte Windows intégré uniquement. Aucun mot de passe en argument."),
            _ => row,
        }).ToImmutableArray();
        rows = rows.Add(new("remoteRegistry", "Registre distant", "Lectures de registre", "RPC / 445/TCP",
            settings.UseRemoteRegistry ? "Autorisé" : "Désactivé", settings.UseRemoteRegistry ? Tone.Info : Tone.Off,
            "Lecture seule ; le service distant n’est jamais activé par Domenia.", false));
        rows = rows.Add(Method("wmiProcess", "Processus WMI", "ADMIN$ / 445/TCP et DCOM / RPC", "wmi", settings.UseWmiProcess,
            "Compte administrateur choisi ; aucun processus arrêté sur la seule base de son PID. Issue incertaine conservée au journal."));
        rows = rows.Add(Method("winRmScript", "Script WinRM", "ADMIN$ / 445/TCP et 5985/5986/TCP", "winrm", settings.UseWinRmScript,
            "Compte administrateur choisi ; seul le shell créé par Domenia est fermé. WinRM doit déjà être configuré."));
        return basis with { Rows = rows, Note = "Aucune collecte ponctuelle sans activation explicite. Une seule méthode est choisie avant le lancement ; aucun autre compte ou lanceur après un refus ou une issue incertaine. Rien ici ne configure Windows." };
    }

    /// <summary>
    /// The real decision of a fallback (Domenia 1 Test-DomeniaTransportFallbackAllowed, SE-07): a read never uses an intrusive
    /// transport without a consent asked for that read alone; an action needs the intervention consent of the workstation.
    /// </summary>
    public static (bool Allowed, string Reason) FallbackAllowed(string transport, bool intrusive, bool consentGiven, bool isRead, bool readConsentGiven)
    {
        ArgumentNullException.ThrowIfNull(transport);
        if (!intrusive)
        {
            return (true, "");
        }
        if (isRead && !readConsentGiven)
        {
            return (false, transport + " n’est pas utilisé pour une lecture ou une détection.");
        }
        if (isRead)
        {
            return (true, "");
        }
        return consentGiven ? (true, "") : (false, transport + " exige une autorisation explicite pour ce poste.");
    }
}

/// <summary>
/// The intervention consent in force (Domenia 1: one workstation, five minutes, granted by an explicit gesture of Assistance poste,
/// « Intervenir »). The screen that grants it publishes it here; the transport policy of the Comptes screen reads it. Names and
/// dates only. Thread safe; shared by the modules of the context.
/// </summary>
public sealed class InterventionConsentBoard
{
    private readonly Lock gate = new();
    private readonly TimeProvider clock;
    private (string Computer, DateTimeOffset Until)? current;

    public InterventionConsentBoard(TimeProvider clock)
    {
        ArgumentNullException.ThrowIfNull(clock);
        this.clock = clock;
    }

    /// <summary>The board shared by the modules of the context.</summary>
    public static InterventionConsentBoard From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new InterventionConsentBoard(c.Clock));
    }

    /// <summary>A consent granted for <paramref name="computer"/> until <paramref name="until"/> (replaces any other: one workstation at a time).</summary>
    public void Publish(string computer, DateTimeOffset until)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(computer);
        lock (gate)
        {
            current = (computer.Trim(), until);
        }
    }

    /// <summary>The consent of <paramref name="computer"/> withdrawn (or expired).</summary>
    public void Withdraw(string computer)
    {
        ArgumentNullException.ThrowIfNull(computer);
        lock (gate)
        {
            if (current is { } c && string.Equals(c.Computer, computer.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                current = null;
            }
        }
    }

    /// <summary>The consent in force now, or none (an expired one is forgotten).</summary>
    public (bool Active, string? Computer, DateTimeOffset? Until) Current()
    {
        lock (gate)
        {
            if (current is { } c && c.Until > clock.GetUtcNow())
            {
                return (true, c.Computer, c.Until);
            }
            current = null;
            return (false, null, null);
        }
    }
}
