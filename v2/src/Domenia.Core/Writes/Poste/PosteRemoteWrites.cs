using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Poste;

/// <summary>Restart of the workstation, delayed with a message (WinRM) or immediate and forced (Domenia 1 PST-013, PST-014).</summary>
public interface IPosteRestartExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, RestartRequest request, CancellationToken cancellationToken);
}

/// <summary>Cancellation of a delayed restart still pending (improvement of PST-013: shutdown /a).</summary>
public interface IPosteRestartCancelExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken);
}

/// <summary>Group policy refresh asked once by WinRM (Domenia 1 PST-015: gpupdate /force).</summary>
public interface IPosteGpUpdateExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken);
}

/// <summary>Start, restart or stop of one service by CIM; its start type is never changed (Domenia 1 PST-069).</summary>
public interface IPosteServiceExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, string service, string action, CancellationToken cancellationToken);
}

/// <summary>A program of the workstation run once by a single scheduled task, created then deleted (Domenia 1 PST-016).</summary>
public interface IPosteRunExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, RunRequest request, CancellationToken cancellationToken);
}

/// <summary>Wake-on-LAN of one workstation (Domenia 1 PST-019): a magic packet, never a claim that it is on.</summary>
public interface IPosteWakeExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken);
}

/// <summary>
/// Pure rules of the remote actions of the workstation screen: drafts with the raw command in the change (never a secret),
/// risks, typed confirmation for the dangerous ones, reversibility in plain words. The receipt then says what left and what
/// the re-read saw; an effect that cannot be read back stays « à vérifier ».
/// </summary>
public static class PosteRemoteWrites
{
    public const string RestartKind = "poste.restart";
    public const string RestartCancelKind = "poste.restartCancel";
    public const string GpUpdateKind = "poste.gpupdate";
    public const string ServiceKind = "poste.service";
    public const string RunKind = "poste.run";
    public const string WakeKind = "poste.wake";

    public static WriteTarget Target(DirectoryComputer c)
    {
        ArgumentNullException.ThrowIfNull(c);
        return new WriteTarget("computer", "Poste de travail", c.Name, c.DistinguishedName, c.ObjectGuid.ToString("D"), c.SamAccountName);
    }

    private static WriteConfirmation Typed(DirectoryComputer c, string reason) => new(true, PosteDirectoryWrites.TypedName(c), "Saisie du nom exigée" + FrenchText.Colon + reason);

    private static WriteConfirmation Simple(string reason) => new(false, null, "Confirmation simple" + FrenchText.Colon + reason);

    public static WritePlanDraft Restart(DirectoryComputer c, RestartRequest request, RestartSessions sessions, DateTimeOffset? lastBoot, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(sessions);
        ArgumentNullException.ThrowIfNull(zone);
        var risks = ImmutableArray.CreateBuilder<WriteRisk>();
        risks.Add(new WriteRisk(sessions.Known && sessions.Count == 0 ? Tone.Info : request.Now ? Tone.Alert : Tone.Warn, sessions.Text));
        foreach (var line in sessions.Lines.Take(5))
        {
            risks.Add(new WriteRisk(Tone.Info, "Session lue : " + line));
        }
        if (request.Now)
        {
            risks.Add(new WriteRisk(Tone.Alert, "Redémarrage immédiat et forcé : aucun message, le travail non enregistré est perdu."));
        }
        else
        {
            risks.Add(new WriteRisk(Tone.Info, "Le redémarrage différé passe par WinRM ; un arrêt déjà programmé (code 1190) est signalé, jamais remplacé."));
        }
        risks.Add(new WriteRisk(Tone.Info, "Un accès refusé (code 5) n’envoie rien ; la requête part une seule fois et n’est jamais rejouée."));
        var before = lastBoot is DateTimeOffset boot ? "En service depuis " + PosteText.Duration(now - boot) : "En service (démarrage non lu)";
        var raw = request.Now ? "shutdown /r /f /t 0" : "shutdown /r /t " + request.DelaySeconds.ToString(CultureInfo.InvariantCulture) + " /c \"" + request.Message + "\"";
        return new WritePlanDraft(RestartKind, request.Now ? "Redémarrer le poste maintenant" : "Redémarrer le poste", "Redémarrage du poste", request.Summary, Target(c),
            [new WriteChange("shutdown", "Redémarrage", WriteChangeKind.Reset, before, request.Now ? "Redémarrage immédiat" : "Redémarrage dans " + FrenchText.Integer(request.Minutes) + " min, avec message",
                lastBoot?.ToString("o", CultureInfo.InvariantCulture), raw)],
            risks.ToImmutable(),
            request.Now ? Typed(c, "redémarrage immédiat, sans message.") : Simple("redémarrage différé avec message à l’utilisateur."),
            request.Now
                ? new WriteReversibility(false, "Sans retour arrière", "Un redémarrage immédiat ne s’annule pas.")
                : new WriteReversibility(true, "Annulable avant l’échéance", "« Annuler le redémarrage programmé » (shutdown /a) prépare un nouveau plan tant que le délai court."),
            null);
    }

    public static WritePlanDraft RestartCancel(DirectoryComputer c, DateTimeOffset scheduledAt, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(zone);
        return new WritePlanDraft(RestartCancelKind, "Annuler le redémarrage programmé", "Annulation du redémarrage programmé",
            "Le redémarrage prévu à " + PosteText.LocalTime(scheduledAt, zone) + " sur " + c.Name + " est annulé (shutdown /a).", Target(c),
            [new WriteChange("shutdown", "Redémarrage programmé", WriteChangeKind.Clear, "Prévu à " + PosteText.LocalTime(scheduledAt, zone), "Aucun redémarrage programmé",
                scheduledAt.ToString("o", CultureInfo.InvariantCulture), "shutdown /a")],
            [new WriteRisk(Tone.Info, "Le message déjà affiché à l’utilisateur disparaît ; prévenez-le si besoin.")],
            Simple("annulation d’un redémarrage différé."),
            new WriteReversibility(true, "Réversible par un nouveau plan", "Un nouveau redémarrage se prépare depuis la vue Intervenir."),
            null);
    }

    public static WritePlanDraft GpUpdate(DirectoryComputer c)
    {
        ArgumentNullException.ThrowIfNull(c);
        return new WritePlanDraft(GpUpdateKind, "Actualiser les stratégies", "Actualisation des stratégies",
            "gpupdate /force demandé une seule fois sur " + c.Name + " par WinRM ; ni redémarrage, ni fermeture de session.", Target(c),
            [new WriteChange("gpupdate", "Stratégies de groupe", WriteChangeKind.Reset, "Appliquées à leur dernier rafraîchissement", "Actualisation forcée demandée", null, "gpupdate /force")],
            [
                new WriteRisk(Tone.Info, "Un seul transport (WinRM), sans repli ; la demande n’est jamais rejouée."),
                new WriteRisk(Tone.Warn, "Effet à vérifier : une extension peut demander une fermeture de session ou un redémarrage pour s’appliquer."),
            ],
            Simple("rafraîchissement des stratégies, sans redémarrage."),
            new WriteReversibility(false, "Sans retour arrière", "Une actualisation des stratégies ne se défait pas ; elle applique ce que l’annuaire publie déjà."),
            null);
    }

    public static WritePlanDraft Service(DirectoryComputer c, ServiceRow row, string action)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(row);
        ArgumentNullException.ThrowIfNull(action);
        if (!PosteServices.IsValidName(row.Name))
        {
            throw WriteErrors.Refusal(PosteErrors.Refused, "Nom de service non reconnu : aucune commande ne part.");
        }
        var display = FrenchText.Quote(row.DisplayName);
        var risks = ImmutableArray.CreateBuilder<WriteRisk>();
        string title, label, summary, after, afterValue;
        WriteConfirmation confirmation;
        switch (action)
        {
            case "start":
                if (row.StartMode == "Disabled")
                {
                    throw WriteErrors.Refusal(PosteErrors.Refused, display + " est désactivé : Domenia ne change pas le type de démarrage d’un service.");
                }
                if (row.State != "Stopped")
                {
                    throw WriteErrors.Refusal(WriteErrors.NothingToDo, display + " n’est pas arrêté (" + row.StateLabel + ") : aucune écriture à préparer.");
                }
                title = "Démarrer le service";
                label = "Démarrage d’un service";
                summary = "Demande au poste de démarrer le service " + row.Name + ", puis relit son état. Aucun autre service n’est modifié.";
                after = "En cours";
                afterValue = "Running";
                confirmation = Simple("démarrage d’un service arrêté.");
                break;
            case "restart":
                if (row.State != "Running")
                {
                    throw WriteErrors.Refusal(PosteErrors.Refused, display + " n’est pas en cours (" + row.StateLabel + ") : utilisez Démarrer.");
                }
                title = "Redémarrer le service";
                label = "Redémarrage d’un service";
                summary = "Arrête puis redémarre le service " + row.Name + " ; ce qu’il sert est interrompu pendant l’opération.";
                after = "En cours (redémarré)";
                afterValue = "Running";
                confirmation = Typed(c, "service interrompu pendant l’opération.");
                risks.Add(new WriteRisk(Tone.Warn, "Ce que sert le service est interrompu pendant l’opération."));
                break;
            case "stop":
                if (row.State != "Running")
                {
                    throw WriteErrors.Refusal(WriteErrors.NothingToDo, display + " n’est pas en cours (" + row.StateLabel + ") : aucune écriture à préparer.");
                }
                title = "Arrêter le service";
                label = "Arrêt d’un service";
                summary = "Arrête le service " + row.Name + " sans changer son type de démarrage : " + (row.StartMode == "Auto" ? "il redémarrera au prochain démarrage du poste." : "il reste arrêté jusqu’à sa prochaine demande.");
                after = "Arrêté";
                afterValue = "Stopped";
                confirmation = Typed(c, "arrêt d’un service en cours.");
                risks.Add(new WriteRisk(Tone.Alert, "Arrêter un service peut couper une fonction du poste à l’utilisateur."));
                if (row.InProfile)
                {
                    risks.Add(new WriteRisk(Tone.Alert, "Service du profil attendu d’un poste du domaine (" + row.ProfileReason + ")."));
                }
                break;
            default:
                throw WriteErrors.Refusal(PosteErrors.Refused, "Action de service inconnue : aucune écriture préparée.");
        }
        if (!row.Dependents.IsEmpty && action != "start")
        {
            risks.Add(new WriteRisk(Tone.Alert, "Services dépendants : " + string.Join(", ", row.Dependents.Take(5)) + (row.Dependents.Length > 5 ? "…" : "") + ". Windows refuse l’arrêt d’un service dont d’autres dépendent, sans rien arrêter."));
        }
        risks.Add(new WriteRisk(Tone.Info, "Le type de démarrage (" + row.StartLabel + ") n’est jamais modifié ; la requête part une seule fois."));
        return new WritePlanDraft(ServiceKind, title, label, summary, Target(c),
            [new WriteChange("service:" + row.Name, "Service " + row.DisplayName, WriteChangeKind.Replace, row.StateLabel, after, row.State, afterValue)],
            risks.ToImmutable(), confirmation,
            new WriteReversibility(true, "Réversible par un nouveau plan", action == "stop" ? "Le démarrer de nouveau est une nouvelle écriture." : "L’arrêter est une nouvelle écriture, jamais automatique."),
            null);
    }

    public static WritePlanDraft Run(DirectoryComputer c, RunRequest request, DateTimeOffset consentUntil, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(zone);
        var line = request.Command + (request.Arguments.Length > 0 ? " " + request.Arguments : "");
        var mode = request.Interactive ? "Session de " + request.RunUser : "Compte système (arrière-plan)";
        return new WritePlanDraft(RunKind, "Exécuter un programme", "Exécution d’un programme", request.Summary, Target(c),
            [new WriteChange("scheduledTask", "Tâche planifiée unique", WriteChangeKind.Add, "Aucune tâche Domenia", mode + (request.Elevated ? ", niveau le plus élevé" : "") + FrenchText.Colon + line,
                null, (request.Interactive ? "interactive|" + request.RunUser : "system") + "|" + (request.Elevated ? "elevated" : "limited") + "|" + line)],
            [
                new WriteRisk(Tone.Alert, "L’exécution réelle du programme n’est pas vérifiée : seule la création puis la suppression de la tâche le sont."),
                new WriteRisk(Tone.Warn, "Autorisation d’intervention valable jusqu’à " + PosteText.LocalTime(consentUntil, zone) + " pour ce poste seulement ; revérifiée juste avant l’envoi."),
                new WriteRisk(Tone.Info, "Aucun secret en argument : la commande est gardée dans le reçu telle que saisie ; la tâche est supprimée dans tous les cas."),
            ],
            Typed(c, "programme lancé à distance."),
            new WriteReversibility(false, "Sans retour arrière", "Ce que fait le programme sur le poste ne se défait pas depuis Domenia."),
            null);
    }

    public static WritePlanDraft Wake(DirectoryComputer c, WakeDecision decision, PresenceReading? presence, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(decision);
        ArgumentNullException.ThrowIfNull(zone);
        var before = presence?.Answered switch
        {
            true => "Répond au ping" + (presence.CheckedAt is DateTimeOffset at ? " (" + PosteText.LocalTime(at, zone) + ")" : ""),
            false => "Ne répond pas au ping" + (presence.CheckedAt is DateTimeOffset at2 ? " (" + PosteText.LocalTime(at2, zone) + ")" : ""),
            _ => "Présence non vérifiée",
        };
        return new WritePlanDraft(WakeKind, "Réveiller le poste", "Réveil du poste (Wake-on-LAN)",
            "Un paquet magique (102 octets, port 9) part vers " + decision.Broadcast + " pour la carte " + decision.MacAddress + ".", Target(c),
            [new WriteChange("wakeOnLan", "Réveil", WriteChangeKind.Replace, before, "Paquet magique envoyé", null, decision.MacAddress + "|" + decision.Broadcast + "|" + decision.Port.ToString(CultureInfo.InvariantCulture))],
            [
                new WriteRisk(Tone.Info, "Un paquet magique ne prouve rien : le poste peut être débranché, en veille prolongée ou sans réveil réseau."),
                new WriteRisk(Tone.Info, "Un ping de vérification est proposé une minute après l’envoi."),
            ],
            Simple("réveil d’un seul poste, sur un sous-réseau autorisé."),
            new WriteReversibility(false, "Sans retour arrière", "Un réveil ne s’annule pas ; il est sans effet sur un poste déjà allumé."),
            null);
    }

    /// <summary>Same workstation as in the plan (GUID and DN), reachable for an action that needs it.</summary>
    public static WritePrecheck Check(WritePlan plan, DirectoryComputer? c, bool reachable, bool needsReach)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var identity = PosteDirectoryWrites.CheckIdentity(plan, c);
        if (!identity.Current)
        {
            return identity;
        }
        if (needsReach && !reachable)
        {
            return WritePrecheck.Stale("Le poste ne répond plus : rien n’a été envoyé. Vérifiez sa présence puis préparez de nouveau l’action.");
        }
        return WritePrecheck.Valid("Poste relu juste avant l’envoi : même objet (GUID, DN), joignable.");
    }
}
