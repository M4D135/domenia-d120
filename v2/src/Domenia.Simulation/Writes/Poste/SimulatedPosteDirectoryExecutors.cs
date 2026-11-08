using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Simulation.Poste;

namespace Domenia.Simulation;

/// <summary>
/// Shared steps of the directory writes of the workstation screen in simulation (docs/WRITES.md § 6): fresh read of the
/// computer as the session sees it, realistic delays of their own sub-sequences, writes to the in-memory overlay only.
/// </summary>
public abstract class SimulatedPosteDirectoryExecutor
{
    private protected SimulatedPosteDirectoryExecutor(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        Source = source;
    }

    private protected SimulatedDirectorySource Source { get; }

    private protected string? Controller => Source.World.Session.Controller?.DnsName;

    private protected DirectoryComputer Find(string dn)
    {
        try
        {
            return PosteSimulation.For(Source).Find(dn);
        }
        catch (DomeniaOperationException)
        {
            throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Ce nom distinctif ne désigne aucun compte ordinateur de l’annuaire fictif : aucune écriture préparée.");
        }
    }

    private protected DirectoryComputer? FindByGuid(string guid) => PosteSimulation.For(Source).FindByGuid(guid);

    private protected Task Wait(string step, int min, int max, CancellationToken cancellationToken) =>
        Source.SimulateScreenLatencyAsync("write/" + step, min, max, cancellationToken);

    private protected WriteOutcome Write(WritePlan plan, Func<DirectoryComputer, long, DirectoryComputer> apply, string detail)
    {
        if (!Guid.TryParseExact(plan.Target.ObjectGuid, "D", out var id))
        {
            throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Le compte ordinateur n’existe plus dans l’annuaire fictif : rien n’a été modifié.");
        }
        var wrote = false;
        var after = Source.UpdateComputer(id, (c, usn) =>
        {
            var next = apply(c, usn);
            if (next == c with { WhenChanged = next.WhenChanged, UsnChanged = next.UsnChanged })
            {
                return null;
            }
            wrote = true;
            return next;
        });
        if (after is null)
        {
            throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Le compte ordinateur n’existe plus dans l’annuaire fictif : rien n’a été modifié.");
        }
        return wrote
            ? new WriteOutcome(WriteResult.Applied, detail + " dans l’annuaire fictif (en mémoire, aucun effet réel)" + (Controller is null ? "." : ", comme le ferait " + Controller + "."))
            : new WriteOutcome(WriteResult.NoChange, "Déjà dans l’état demandé : aucune écriture.");
    }
}

/// <summary>Enable or disable a computer account in simulation (overlay only).</summary>
public sealed class SimulatedPosteAccountStateExecutor : SimulatedPosteDirectoryExecutor, IPosteAccountStateExecutor
{
    public SimulatedPosteAccountStateExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => PosteDirectoryWrites.AccountStateKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, bool enable, CancellationToken cancellationToken)
    {
        await Wait("plan", 90, 220, cancellationToken).ConfigureAwait(false);
        return PosteDirectoryWrites.AccountState(Find(dn), enable, Controller);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("check", 60, 140, cancellationToken).ConfigureAwait(false);
        return PosteDirectoryWrites.CheckAccountState(plan, FindByGuid(plan.Target.ObjectGuid));
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("execute", 280, 620, cancellationToken).ConfigureAwait(false);
        var now = Source.Clock.GetUtcNow();
        return Write(plan, (c, usn) => PosteDirectoryWrites.ApplyAccountState(c, plan, now, usn), "userAccountControl modifié");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("verify", 90, 200, cancellationToken).ConfigureAwait(false);
        return PosteDirectoryWrites.Verify(plan, FindByGuid(plan.Target.ObjectGuid), null);
    }
}

/// <summary>Description, location and managedBy of a computer in simulation (overlay only).</summary>
public sealed class SimulatedPosteProfileExecutor : SimulatedPosteDirectoryExecutor, IPosteProfileExecutor
{
    public SimulatedPosteProfileExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => PosteDirectoryWrites.ProfileKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, string? description, string? location, string? managedByDn, CancellationToken cancellationToken)
    {
        await Wait("plan", 90, 220, cancellationToken).ConfigureAwait(false);
        var computer = Find(dn);
        string? managerName = null;
        if (!string.IsNullOrWhiteSpace(managedByDn))
        {
            var directory = Source.CurrentDirectory;
            var user = directory.Users.FirstOrDefault(u => PosteDirectoryWrites.SameDn(u.DistinguishedName, managedByDn));
            var group = user is null ? directory.Groups.FirstOrDefault(g => PosteDirectoryWrites.SameDn(g.DistinguishedName, managedByDn)) : null;
            if (user is null && group is null)
            {
                throw WriteErrors.Refusal(PosteErrors.Refused, "« Géré par » ne désigne aucun utilisateur ni groupe de l’annuaire fictif : aucune écriture préparée.");
            }
            managerName = user?.DisplayName ?? user?.Cn ?? group!.Name;
            managedByDn = user?.DistinguishedName ?? group!.DistinguishedName;
        }
        return PosteDirectoryWrites.Profile(computer, description, location, managedByDn, managerName, Controller);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("check", 60, 140, cancellationToken).ConfigureAwait(false);
        return PosteDirectoryWrites.CheckProfile(plan, FindByGuid(plan.Target.ObjectGuid));
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("execute", 280, 620, cancellationToken).ConfigureAwait(false);
        var now = Source.Clock.GetUtcNow();
        return Write(plan, (c, usn) => PosteDirectoryWrites.ApplyProfile(c, plan, now, usn), "Fiche du poste enregistrée");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("verify", 90, 200, cancellationToken).ConfigureAwait(false);
        return PosteDirectoryWrites.Verify(plan, FindByGuid(plan.Target.ObjectGuid), null);
    }
}

/// <summary>Rename of a computer object in simulation (overlay only; the Windows name is not changed).</summary>
public sealed class SimulatedPosteRenameExecutor : SimulatedPosteDirectoryExecutor, IPosteRenameExecutor
{
    public SimulatedPosteRenameExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => PosteDirectoryWrites.RenameKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, string newName, CancellationToken cancellationToken)
    {
        await Wait("plan", 90, 220, cancellationToken).ConfigureAwait(false);
        return PosteDirectoryWrites.Rename(Find(dn), newName, Source.CurrentDirectory.Computers, Controller);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("check", 60, 140, cancellationToken).ConfigureAwait(false);
        var check = PosteDirectoryWrites.CheckRename(plan, FindByGuid(plan.Target.ObjectGuid));
        if (check.Current && Source.CurrentDirectory.Computers.Any(c => PosteDirectoryWrites.SameDn(c.DistinguishedName, plan.Changes[0].AfterValue ?? "") && !string.Equals(c.ObjectGuid.ToString("D"), plan.Target.ObjectGuid, StringComparison.OrdinalIgnoreCase)))
        {
            return WritePrecheck.Stale("Le nom est maintenant pris par un autre objet de la même OU : rien n’a été envoyé.");
        }
        return check;
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("execute", 280, 620, cancellationToken).ConfigureAwait(false);
        var now = Source.Clock.GetUtcNow();
        return Write(plan, (c, usn) => PosteDirectoryWrites.ApplyRename(c, plan, now, usn), "Objet renommé");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("verify", 90, 200, cancellationToken).ConfigureAwait(false);
        return PosteDirectoryWrites.Verify(plan, FindByGuid(plan.Target.ObjectGuid), null);
    }
}

/// <summary>Group membership of a computer in simulation: member of the group and memberOf of the computer, both in memory.</summary>
public sealed class SimulatedPosteGroupExecutor : SimulatedPosteDirectoryExecutor, IPosteGroupExecutor
{
    public SimulatedPosteGroupExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => PosteDirectoryWrites.GroupKind;

    private DirectoryGroup? Group(string dn) => Source.CurrentDirectory.Groups.FirstOrDefault(g => PosteDirectoryWrites.SameDn(g.DistinguishedName, dn));

    public async Task<WritePlanDraft> PlanAsync(string dn, string groupDn, bool add, CancellationToken cancellationToken)
    {
        await Wait("plan", 90, 220, cancellationToken).ConfigureAwait(false);
        var group = Group(groupDn) ?? throw WriteErrors.Refusal(PosteErrors.Refused, "Ce nom distinctif ne désigne aucun groupe de l’annuaire fictif : aucune écriture préparée.");
        return PosteDirectoryWrites.Group(Find(dn), group, add, Controller);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("check", 60, 140, cancellationToken).ConfigureAwait(false);
        return PosteDirectoryWrites.CheckGroup(plan, FindByGuid(plan.Target.ObjectGuid), Group(plan.Changes[0].BeforeValue ?? ""));
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("execute", 280, 620, cancellationToken).ConfigureAwait(false);
        var now = Source.Clock.GetUtcNow();
        var add = plan.Changes[0].Kind == WriteChangeKind.Add;
        var groupDn = plan.Changes[0].BeforeValue ?? "";
        var group = Group(groupDn) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Le groupe n’existe plus dans l’annuaire fictif : rien n’a été modifié.");
        var computer = FindByGuid(plan.Target.ObjectGuid) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Le compte ordinateur n’existe plus : rien n’a été modifié.");
        var already = group.Members.Any(m => PosteDirectoryWrites.SameDn(m, computer.DistinguishedName)) == add;
        if (already)
        {
            return new WriteOutcome(WriteResult.NoChange, "Appartenance déjà dans l’état demandé : aucune écriture.");
        }
        Source.UpdateGroup(group.ObjectGuid, (g, usn) => g with
        {
            Members = add ? g.Members.Add(computer.DistinguishedName) : [.. g.Members.Where(m => !PosteDirectoryWrites.SameDn(m, computer.DistinguishedName))],
            WhenChanged = now,
            UsnChanged = usn,
        });
        Source.UpdateComputer(computer.ObjectGuid, (c, usn) => c with
        {
            MemberOf = add ? c.MemberOf.Add(group.DistinguishedName) : [.. c.MemberOf.Where(m => !PosteDirectoryWrites.SameDn(m, group.DistinguishedName))],
            WhenChanged = now,
            UsnChanged = usn,
        });
        return new WriteOutcome(WriteResult.Applied, (add ? "Poste ajouté à " : "Poste retiré de ") + group.Name + " dans l’annuaire fictif (en mémoire, aucun effet réel).");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("verify", 90, 200, cancellationToken).ConfigureAwait(false);
        return PosteDirectoryWrites.Verify(plan, FindByGuid(plan.Target.ObjectGuid), Group(plan.Changes[0].BeforeValue ?? ""));
    }
}

/// <summary>Move of a computer to another OU of the fictitious domain (overlay only).</summary>
public sealed class SimulatedPosteMoveExecutor : SimulatedPosteDirectoryExecutor, IPosteMoveExecutor
{
    public SimulatedPosteMoveExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => PosteDirectoryWrites.MoveKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, string targetOuDn, CancellationToken cancellationToken)
    {
        await Wait("plan", 90, 220, cancellationToken).ConfigureAwait(false);
        var target = Source.CurrentDirectory.OrganizationalUnits.FirstOrDefault(o => PosteDirectoryWrites.SameDn(o.DistinguishedName, targetOuDn))
            ?? throw WriteErrors.Refusal(PosteErrors.Refused, "Cette OU n’existe pas dans le domaine fictif : aucune écriture préparée.");
        return PosteDirectoryWrites.Move(Find(dn), target, Controller);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("check", 60, 140, cancellationToken).ConfigureAwait(false);
        return PosteDirectoryWrites.CheckMove(plan, FindByGuid(plan.Target.ObjectGuid));
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("execute", 280, 620, cancellationToken).ConfigureAwait(false);
        var now = Source.Clock.GetUtcNow();
        return Write(plan, (c, usn) => PosteDirectoryWrites.ApplyMove(c, plan, now, usn), "Poste déplacé");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Wait("verify", 90, 200, cancellationToken).ConfigureAwait(false);
        return PosteDirectoryWrites.Verify(plan, FindByGuid(plan.Target.ObjectGuid), null);
    }
}
