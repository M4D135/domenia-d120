using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Simulation.Poste;

namespace Domenia.Simulation;

/// <summary>
/// Shared steps of the remote actions in simulation: the workstation is the fictitious one of the screen (memory only), its
/// reachability follows the stored observation and the pings of the session; nothing leaves the process.
/// </summary>
public abstract class SimulatedPosteRemoteExecutor
{
    private protected SimulatedPosteRemoteExecutor(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        Source = source;
    }

    private protected SimulatedDirectorySource Source { get; }

    private protected PosteSimulation Sim => PosteSimulation.For(Source);

    private protected Task Wait(string step, int min, int max, CancellationToken cancellationToken) =>
        Source.SimulateScreenLatencyAsync("write/" + step, min, max, cancellationToken);

    private protected async Task<(DirectoryComputer Computer, PosteMachine Machine, WorkstationObservation? Observation)> ResolveAsync(string dn, CancellationToken cancellationToken)
    {
        var state = await Source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        DirectoryComputer computer;
        try
        {
            computer = Sim.Find(dn);
        }
        catch (DomeniaOperationException)
        {
            throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Ce nom distinctif ne désigne aucun poste de l’annuaire fictif : aucune action préparée.");
        }
        return (computer, Sim.Machine(computer), state.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == computer.ObjectGuid));
    }

    private protected async Task<(DirectoryComputer? Computer, bool Reachable)> RereadAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        var state = await Source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var computer = Sim.FindByGuid(plan.Target.ObjectGuid);
        if (computer is null)
        {
            return (null, false);
        }
        var observation = state.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == computer.ObjectGuid);
        return (computer, Sim.Reachable(computer.ObjectGuid, observation));
    }

    private protected void RequireReach(DirectoryComputer c, WorkstationObservation? observation) => Sim.Unreachable(c, observation);

    private protected bool WinRm(PosteMachine machine) =>
        Sim.ServiceStates(machine.Computer.ObjectGuid).TryGetValue("WinRM", out var state) ? state == "Running" : machine.Services.Any(s => s.Name == "WinRM" && s.State == "Running");
}

/// <summary>Restart of a fictitious workstation: delayed with a message, or immediate (memory only).</summary>
public sealed class SimulatedPosteRestartExecutor : SimulatedPosteRemoteExecutor, IPosteRestartExecutor
{
    public SimulatedPosteRestartExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => PosteRemoteWrites.RestartKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, RestartRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        RequireReach(c, observation);
        await Wait("plan", 140, 320, cancellationToken).ConfigureAwait(false);
        var now = Sim.Now;
        if (Sim.ScheduledRestart(c.ObjectGuid, now) is { } scheduled)
        {
            throw WriteErrors.Refusal(PosteErrors.Refused, "Un redémarrage est déjà programmé à " + PosteText.LocalTime(scheduled.At, Sim.Zone) + " (code 1190) : annulez-le d’abord, rien n’est remplacé.");
        }
        // The sessions are read just before the plan (Domenia 1 PST-014): the plan shows them.
        var user = Sim.Detected(c.ObjectGuid)?.User ?? machine.User;
        var open = Sim.Answers(c.ObjectGuid, observation) == true && user is not null;
        var sessions = PosteSessions.View(c.Name, SourceStatus.Ok,
            open ? [new LocalSession("1", "Console", user!.Login, SimulationProfile.NetbiosName, "Active", "Console", now.AddHours(-2), TimeSpan.FromMinutes(4), null)] : [],
            now, Sim.Reader, Sim.Zone);
        return PosteRemoteWrites.Restart(c, request, PosteSessions.ForRestart(sessions, null), Sim.Boot(c.ObjectGuid) ?? machine.LastBoot, now, Sim.Zone);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("check", 60, 140, cancellationToken).ConfigureAwait(false);
        var (c, reachable) = await RereadAsync(plan, cancellationToken).ConfigureAwait(false);
        var check = PosteRemoteWrites.Check(plan, c, reachable, true);
        if (check.Current && c is not null && Sim.ScheduledRestart(c.ObjectGuid, Sim.Now) is not null)
        {
            return WritePrecheck.Stale("Un arrêt est déjà programmé sur le poste (code 1190) : rien n’a été envoyé.");
        }
        return check;
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("execute", 280, 620, cancellationToken).ConfigureAwait(false);
        var c = Sim.FindByGuid(plan.Target.ObjectGuid) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Le poste n’existe plus dans l’annuaire fictif : rien n’a été envoyé.");
        var machine = Sim.Machine(c);
        var raw = plan.Changes[0].AfterValue ?? "";
        var now = Sim.Now;
        if (raw.StartsWith("shutdown /r /f", StringComparison.Ordinal))
        {
            Sim.RecordRestart(c.ObjectGuid, now, "", true);
            return new WriteOutcome(WriteResult.Applied, "Redémarrage immédiat demandé (simulation : aucun poste réel redémarré).");
        }
        if (!WinRm(machine))
        {
            throw WriteErrors.Refusal(PosteErrors.Refused, "Non envoyé : WinRM ne répond pas sur le poste (service arrêté). Le redémarrage différé passe par WinRM, sans repli.");
        }
        var delay = int.TryParse(raw.Split(' ').ElementAtOrDefault(3), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var seconds) ? seconds : 300;
        var message = raw.Contains("/c \"", StringComparison.Ordinal) ? raw[(raw.IndexOf("/c \"", StringComparison.Ordinal) + 4)..].TrimEnd('"') : "";
        Sim.RecordRestart(c.ObjectGuid, now.AddSeconds(delay), message, false);
        return new WriteOutcome(WriteResult.Applied, "shutdown /r /t " + delay.ToString(System.Globalization.CultureInfo.InvariantCulture) + " accepté par le poste (simulation : aucun poste réel).");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("verify", 90, 200, cancellationToken).ConfigureAwait(false);
        var c = Sim.FindByGuid(plan.Target.ObjectGuid);
        if (c is null)
        {
            return new WriteVerification(VerificationState.Unknown, "Poste introuvable à la relecture.");
        }
        var now = Sim.Now;
        if (Sim.ScheduledRestart(c.ObjectGuid, now) is { } scheduled)
        {
            return new WriteVerification(VerificationState.Verified, "Arrêt programmé relu sur le poste : redémarrage à " + PosteText.LocalTime(scheduled.At, Sim.Zone) + ".");
        }
        return Sim.Boot(c.ObjectGuid) is DateTimeOffset boot && boot >= plan.CreatedAt
            ? new WriteVerification(VerificationState.Verified, "Dernier démarrage relu : " + PosteText.LocalDateTime(boot, Sim.Zone) + ".")
            : new WriteVerification(VerificationState.Unknown, "Redémarrage non confirmé à la relecture : relisez l’état du poste dans quelques minutes.");
    }
}

/// <summary>Cancellation of a delayed restart of a fictitious workstation (shutdown /a).</summary>
public sealed class SimulatedPosteRestartCancelExecutor : SimulatedPosteRemoteExecutor, IPosteRestartCancelExecutor
{
    public SimulatedPosteRestartCancelExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => PosteRemoteWrites.RestartCancelKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken)
    {
        var (c, _, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        RequireReach(c, observation);
        await Wait("plan", 90, 220, cancellationToken).ConfigureAwait(false);
        var scheduled = Sim.ScheduledRestart(c.ObjectGuid, Sim.Now) ?? throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucun redémarrage programmé sur ce poste : rien à annuler.");
        return PosteRemoteWrites.RestartCancel(c, scheduled.At, Sim.Zone);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("check", 60, 140, cancellationToken).ConfigureAwait(false);
        var (c, reachable) = await RereadAsync(plan, cancellationToken).ConfigureAwait(false);
        return PosteRemoteWrites.Check(plan, c, reachable, true);
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("execute", 200, 420, cancellationToken).ConfigureAwait(false);
        var c = Sim.FindByGuid(plan.Target.ObjectGuid) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Le poste n’existe plus : rien n’a été envoyé.");
        return Sim.CancelRestart(c.ObjectGuid)
            ? new WriteOutcome(WriteResult.Applied, "shutdown /a accepté : redémarrage annulé (simulation).")
            : new WriteOutcome(WriteResult.NoChange, "Aucun arrêt n’était encore programmé (code 1116) : rien à annuler.");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("verify", 90, 200, cancellationToken).ConfigureAwait(false);
        var c = Sim.FindByGuid(plan.Target.ObjectGuid);
        return c is not null && Sim.ScheduledRestart(c.ObjectGuid, Sim.Now) is null
            ? new WriteVerification(VerificationState.Verified, "Aucun arrêt programmé à la relecture.")
            : new WriteVerification(VerificationState.Mismatch, "Un arrêt est encore programmé à la relecture.");
    }
}

/// <summary>Group policy refresh of a fictitious workstation (gpupdate /force by WinRM, effect to check).</summary>
public sealed class SimulatedPosteGpUpdateExecutor : SimulatedPosteRemoteExecutor, IPosteGpUpdateExecutor
{
    public SimulatedPosteGpUpdateExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => PosteRemoteWrites.GpUpdateKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken)
    {
        var (c, _, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        RequireReach(c, observation);
        await Wait("plan", 90, 220, cancellationToken).ConfigureAwait(false);
        return PosteRemoteWrites.GpUpdate(c);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("check", 60, 140, cancellationToken).ConfigureAwait(false);
        var (c, reachable) = await RereadAsync(plan, cancellationToken).ConfigureAwait(false);
        return PosteRemoteWrites.Check(plan, c, reachable, true);
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("execute", 600, 1400, cancellationToken).ConfigureAwait(false);
        var c = Sim.FindByGuid(plan.Target.ObjectGuid) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Le poste n’existe plus : rien n’a été envoyé.");
        if (!WinRm(Sim.Machine(c)))
        {
            throw WriteErrors.Refusal(PosteErrors.Refused, "Non envoyé : WinRM ne répond pas sur le poste (service arrêté). Un seul transport, sans repli.");
        }
        return new WriteOutcome(WriteResult.Applied, "gpupdate /force : « La mise à jour de la stratégie d’ordinateur s’est terminée sans erreur » (simulation).");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("verify", 90, 200, cancellationToken).ConfigureAwait(false);
        return new WriteVerification(VerificationState.Unknown, "Effet à vérifier : relisez les stratégies appliquées (RSoP) ou les événements « Stratégie de groupe » du poste.");
    }
}

/// <summary>Start, restart or stop of a service of a fictitious workstation; the start type is never changed.</summary>
public sealed class SimulatedPosteServiceExecutor : SimulatedPosteRemoteExecutor, IPosteServiceExecutor
{
    public SimulatedPosteServiceExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => PosteRemoteWrites.ServiceKind;

    private ImmutableArray<ServiceRow> Rows(PosteMachine machine)
    {
        var states = Sim.ServiceStates(machine.Computer.ObjectGuid);
        return PosteServices.Rows(machine.Services.Select(s => states.TryGetValue(s.Name, out var st) ? s with { State = st } : s));
    }

    public async Task<WritePlanDraft> PlanAsync(string dn, string service, string action, CancellationToken cancellationToken)
    {
        var (c, machine, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        RequireReach(c, observation);
        await Wait("plan", 120, 260, cancellationToken).ConfigureAwait(false);
        var row = Rows(machine).FirstOrDefault(r => string.Equals(r.Name, service, StringComparison.OrdinalIgnoreCase))
            ?? throw WriteErrors.Refusal(PosteErrors.Refused, "Service introuvable sur ce poste : relisez les services. Aucune écriture préparée.");
        return PosteRemoteWrites.Service(c, row, action);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("check", 60, 140, cancellationToken).ConfigureAwait(false);
        var (c, reachable) = await RereadAsync(plan, cancellationToken).ConfigureAwait(false);
        var check = PosteRemoteWrites.Check(plan, c, reachable, true);
        if (!check.Current || c is null)
        {
            return check;
        }
        var change = plan.Changes[0];
        var name = change.Attribute["service:".Length..];
        var row = Rows(Sim.Machine(c)).FirstOrDefault(r => string.Equals(r.Name, name, StringComparison.OrdinalIgnoreCase));
        if (row is null)
        {
            return WritePrecheck.Stale("Le service n’existe plus sur le poste : rien n’a été envoyé.");
        }
        if (!string.Equals(row.State, change.BeforeValue, StringComparison.Ordinal))
        {
            return WritePrecheck.Stale("L’état du service a changé depuis le plan (" + row.StateLabel + ") : relisez les services. Rien n’a été envoyé.");
        }
        return WritePrecheck.Valid("Service relu juste avant l’envoi : " + row.StateLabel.ToLowerInvariant() + ", type de démarrage " + row.StartLabel.ToLowerInvariant() + ".");
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("execute", 400, 900, cancellationToken).ConfigureAwait(false);
        var c = Sim.FindByGuid(plan.Target.ObjectGuid) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Le poste n’existe plus : rien n’a été envoyé.");
        var change = plan.Changes[0];
        var name = change.Attribute["service:".Length..];
        var row = Rows(Sim.Machine(c)).First(r => string.Equals(r.Name, name, StringComparison.OrdinalIgnoreCase));
        var target = change.AfterValue ?? "Running";
        var stopping = target == "Stopped" || plan.Title.StartsWith("Redémarrer", StringComparison.Ordinal);
        var running = Rows(Sim.Machine(c)).Where(r => r.State == "Running").Select(r => r.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (stopping && row.Dependents.Any(d => Rows(Sim.Machine(c)).Any(r => r.DisplayName == d && running.Contains(r.Name))))
        {
            throw WriteErrors.Refusal(PosteErrors.Refused, "Windows refuse l’arrêt : des services dépendants sont en cours (code 2051). Rien n’a été arrêté.");
        }
        Sim.RecordServiceState(c.ObjectGuid, row.Name, target);
        return new WriteOutcome(WriteResult.Applied, (target == "Stopped" ? "Service arrêté" : plan.Title.StartsWith("Redémarrer", StringComparison.Ordinal) ? "Service arrêté puis redémarré" : "Service démarré") + " (code 0, simulation).");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("verify", 90, 200, cancellationToken).ConfigureAwait(false);
        var c = Sim.FindByGuid(plan.Target.ObjectGuid);
        if (c is null)
        {
            return new WriteVerification(VerificationState.Unknown, "Poste introuvable à la relecture.");
        }
        var change = plan.Changes[0];
        var name = change.Attribute["service:".Length..];
        var row = Rows(Sim.Machine(c)).FirstOrDefault(r => string.Equals(r.Name, name, StringComparison.OrdinalIgnoreCase));
        return row is not null && string.Equals(row.State, change.AfterValue, StringComparison.Ordinal)
            ? new WriteVerification(VerificationState.Verified, "État relu : " + row.StateLabel.ToLowerInvariant() + ".")
            : new WriteVerification(VerificationState.Mismatch, "État relu différent de l’état attendu" + (row is null ? "" : " (" + row.StateLabel + ")") + " : un reçu « à vérifier » reste ouvert.");
    }
}

/// <summary>A program run once on a fictitious workstation by a single scheduled task (requires the intervention authorization).</summary>
public sealed class SimulatedPosteRunExecutor : SimulatedPosteRemoteExecutor, IPosteRunExecutor
{
    public SimulatedPosteRunExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => PosteRemoteWrites.RunKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, RunRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var (c, _, observation) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        var session = PosteSession.For(Source);
        var now = Sim.Now;
        if (!session.Covers(ConsentKind.Intervention, c.DistinguishedName, now))
        {
            throw WriteErrors.Refusal(PosteErrors.ConsentRequired, PosteErrors.ConsentRequiredMessage);
        }
        RequireReach(c, observation);
        await Wait("plan", 90, 220, cancellationToken).ConfigureAwait(false);
        var until = session.State(c.DistinguishedName, now).Intervention.Until ?? now;
        var draft = PosteRemoteWrites.Run(c, request, until, Sim.Zone);
        var digest = PosteRemote.ArgumentsDigest(request.Arguments);
        if (digest.Length > 0)
        {
            // Kept in memory only, under their fingerprint, for the life of the plan (never in the plan nor in the receipt).
            session.KeepRunArguments(digest, request.Arguments, now + WritePlans.Lifetime, now);
        }
        return draft;
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("check", 60, 140, cancellationToken).ConfigureAwait(false);
        var (c, reachable) = await RereadAsync(plan, cancellationToken).ConfigureAwait(false);
        var check = PosteRemoteWrites.Check(plan, c, reachable, true);
        if (check.Current && c is not null && !PosteSession.For(Source).Covers(ConsentKind.Intervention, c.DistinguishedName, Sim.Now))
        {
            return WritePrecheck.Stale("L’autorisation d’intervention a expiré ou a été retirée : rien n’a été envoyé. Accordez-la de nouveau puis préparez l’action.");
        }
        var digest = PosteRemoteWrites.RunDigest(plan);
        if (check.Current && digest.Length > 0 && !PosteSession.For(Source).HasRunArguments(digest, Sim.Now))
        {
            return WritePrecheck.Stale("Les arguments du programme ne sont plus en mémoire (plan expiré ou session changée) : rien n’a été envoyé. Préparez de nouveau l’exécution.");
        }
        return check;
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var digest = PosteRemoteWrites.RunDigest(plan);
        // The arguments are taken (and forgotten) from the memory of the session: the receipt only ever had their fingerprint.
        var arguments = digest.Length == 0 ? "" : PosteSession.For(Source).TakeRunArguments(digest, Sim.Now);
        if (arguments is null)
        {
            throw WriteErrors.Refusal(PosteErrors.Refused, "Arguments du programme introuvables en mémoire : rien n’a été envoyé. Préparez de nouveau l’exécution.");
        }
        await Wait("execute", 500, 1100, cancellationToken).ConfigureAwait(false);
        return new WriteOutcome(WriteResult.Applied, "Tâche planifiée unique créée, lancée puis supprimée (simulation : aucun programme réel lancé ; " + PosteRemote.ArgumentsText(arguments) + ").");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("verify", 90, 200, cancellationToken).ConfigureAwait(false);
        return new WriteVerification(VerificationState.Unknown, "Exécution du programme non vérifiée : seule la tâche (créée puis supprimée) l’est. Demandez à l’utilisateur ce qu’il voit.");
    }
}

/// <summary>Wake-on-LAN of a fictitious workstation: a magic packet that is never sent for real, never a claim that it is on.</summary>
public sealed class SimulatedPosteWakeExecutor : SimulatedPosteRemoteExecutor, IPosteWakeExecutor
{
    public SimulatedPosteWakeExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => PosteRemoteWrites.WakeKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken)
    {
        var (c, machine, _) = await ResolveAsync(dn, cancellationToken).ConfigureAwait(false);
        await Wait("plan", 90, 220, cancellationToken).ConfigureAwait(false);
        var options = new SimulatedPosteReader(Source).Options;
        var decision = PosteRemote.Wake(options.WakeOnLan, options.WakeNetworks, machine.Mac, machine.Ip, machine.Prefix);
        if (!decision.Allowed)
        {
            throw WriteErrors.Refusal(PosteErrors.Refused, decision.Reason + " Aucune demande préparée.");
        }
        return PosteRemoteWrites.Wake(c, decision, Sim.LastPing(c.ObjectGuid), Sim.Zone);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("check", 40, 100, cancellationToken).ConfigureAwait(false);
        var (c, reachable) = await RereadAsync(plan, cancellationToken).ConfigureAwait(false);
        return PosteRemoteWrites.Check(plan, c, reachable, false);
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("execute", 120, 300, cancellationToken).ConfigureAwait(false);
        if (Guid.TryParseExact(plan.Target.ObjectGuid, "D", out var id))
        {
            Sim.RecordWake(id, Sim.Now);
        }
        return new WriteOutcome(WriteResult.Applied, "Paquet magique de 102 octets envoyé au port 9 (simulation : aucun paquet réel).");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("verify", 40, 100, cancellationToken).ConfigureAwait(false);
        return new WriteVerification(VerificationState.Unknown, "Demande envoyée. État du poste non vérifié : relancez « Tester la réponse » dans une minute.");
    }
}
