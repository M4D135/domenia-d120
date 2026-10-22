using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Settings that decide the transports (Domenia 1 Remote.UseCim, Remote.UseWinRM, Remote.UsePsExecFallback, Remote.UseTaskFallback).</summary>
public sealed record TransportSettings(bool UseCim, bool UseWinRm, bool UsePsExecFallback, bool UseTaskFallback, string Source)
{
    /// <summary>Defaults of Domenia 1 (every transport allowed, the intrusive ones still need an explicit consent).</summary>
    public static TransportSettings Defaults { get; } = new(true, true, true, true, "Réglages par défaut de Domenia 1 (Remote.UseCim, Remote.UseWinRM, Remote.UsePsExecFallback, Remote.UseTaskFallback)");
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
    public static TransportTable Build(TransportSettings settings, bool consentActive, string? consentTarget)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var c = FrenchText.Colon;
        var consent = consentActive && consentTarget is not null ? "Autorisé pour " + consentTarget + " et la durée consentie" : "Inactif sans autorisation explicite";
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
            ? "Autorisation d’intervention en cours" + c + consentTarget + ", pour ce poste seulement et pour vos actions volontaires."
            : "Aucune autorisation d’intervention en cours" + c + "une autorisation couvre un seul poste pendant 5 minutes, sur geste explicite (Assistance poste, Intervenir).";
        return new TransportTable(rows, consentActive, consentText, settings.Source,
            "Un transport intrusif n’est jamais un repli silencieux d’une lecture ni d’une détection. Rien ici ne modifie un réglage de Windows.");
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
