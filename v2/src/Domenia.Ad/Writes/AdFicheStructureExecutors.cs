using Domenia.Core;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Ad;

public sealed class AdObjectMoveExecutor(AdDirectorySource source) : AdFicheWriteExecutor(source), IObjectMoveExecutor
{
    public override string Kind => ObjectWrites.MoveKind;
    public Task<WritePlanDraft> PlanAsync(string dn, string targetDn, Guid? expectedGuid, CancellationToken cancellationToken) => PrepareAsync(dn, async (entry, session) =>
    {
        if (expectedGuid is { } expected && expected != entry.ObjectGuid)
        { throw WriteErrors.Refusal(WriteErrors.Stale, "L’objet a été remplacé depuis le choix de l’OU ; relisez sa fiche."); }
        var destination = await ReadAsync(targetDn, cancellationToken).ConfigureAwait(false);
        var child = await ExistsAsync(DestinationDn(entry.Dn, destination.Dn), cancellationToken).ConfigureAwait(false);
        var draft = ObjectWrites.Move(entry, FicheSummary.From(destination, Source.Clock.GetUtcNow()),
            (await Source.DomainAsync(cancellationToken).ConfigureAwait(false)).RootDn, child is not null, session.Controller?.DnsName);
        return draft with { Changes = [draft.Changes[0] with { ReferenceGuid = destination.ObjectGuid.ToString("D") }] };
    }, cancellationToken);

    private protected override async Task<WritePrecheck> CheckRulesAsync(WritePlan plan, FicheEntry? current, CancellationToken token)
    {
        var change = plan.Changes[0];
        if (current is null) { return ObjectWrites.Check(plan, null, _ => false); }
        var expected = DestinationDn(plan.Target.Dn, change.AfterValue!);
        if (!FicheValues.SameDn(current.Dn, plan.Target.Dn) && !FicheValues.SameDn(current.Dn, expected))
        { return WritePrecheck.Stale("L’objet a changé de nom ou d’emplacement ; préparez un nouveau déplacement."); }
        var destination = await ReadAsync(change.AfterValue!, token).ConfigureAwait(false);
        if (destination.Kind is not (FicheKind.Ou or FicheKind.Container)) { return WritePrecheck.Stale("La destination n’est plus un conteneur."); }
        var child = await ExistsAsync(expected, token).ConfigureAwait(false);
        if (child is not null && child.Guid("objectGUID") != current.ObjectGuid)
        { return WritePrecheck.Stale("Un autre objet porte déjà ce nom dans la destination ; aucun déplacement envoyé."); }
        return ObjectWrites.Check(plan, current, dn => FicheValues.SameDn(dn, destination.Dn));
    }

    private protected override async Task<WriteOutcome> SendAsync(WritePlan plan, FicheEntry current, CancellationToken cancellationToken)
    {
        var name = DistinguishedName.Parse(plan.Target.Dn)[0];
        await Source.Connection.RenameAsync(GuidDn(plan.Target.ObjectGuid), GuidDn(plan.Changes[0].ReferenceGuid!),
            DistinguishedName.Rdn(name.Type, name.Value), cancellationToken).ConfigureAwait(false);
        return new(WriteResult.Applied, "Déplacement accepté par le contrôleur ; relecture du GUID, du nom et de l’emplacement en cours.");
    }

    private protected override Task<WriteVerification> VerifyCurrentAsync(WritePlan plan, FicheEntry? current, CancellationToken token) =>
        Task.FromResult(current is null ? new(VerificationState.Unknown, "Objet introuvable après le déplacement ; vérifiez l’annuaire.")
            : FicheValues.SameDn(current.Dn, DestinationDn(plan.Target.Dn, plan.Changes[0].AfterValue!))
                ? new WriteVerification(VerificationState.Verified, "Même GUID, même nom et emplacement confirmé relus après le déplacement.")
                : new(VerificationState.Mismatch, "Le nom ou l’emplacement relu diffère du déplacement confirmé."));

    private protected override void Protect(FicheEntry entry, SessionSnapshot session, WritePlan? plan)
    {
        base.Protect(entry, session, plan);
        if (entry.Kind is FicheKind.Ou or FicheKind.Container)
        { throw FicheErrors.Error(FicheErrors.Refused, "Cet éditeur ne déplace pas une branche d’annuaire."); }
    }

    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        if (plan.Changes.Length != 1 || plan.Changes[0] is not { Attribute: ObjectWrites.DnAttribute, Kind: WriteChangeKind.Move, ReferenceGuid: not null, AfterValue: not null }
            || !FicheValues.SameDn(plan.Changes[0].BeforeValue, DistinguishedName.Parent(plan.Target.Dn)))
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Plan de déplacement incomplet ou altéré."); }
        AdFicheObjects.ValidateDn(plan.Changes[0].AfterValue!);
    }

    private Task<AdEntry?> ExistsAsync(string dn, CancellationToken token) => new AdFicheObjects(Source).ReadExactAsync(dn, ["objectGUID"], TimeSpan.FromSeconds(10), token);
    internal static string DestinationDn(string originalDn, string parent)
    {
        var name = DistinguishedName.Parse(originalDn)[0];
        return DistinguishedName.Child(name.Type, name.Value, parent);
    }
}

public sealed class AdGroupMemberExecutor(AdDirectorySource source) : AdFicheWriteExecutor(source), IGroupMemberExecutor
{
    public override string Kind => ObjectWrites.MemberKind;
    private protected override bool ScalarChanges => false;
    // Membership checks project only the selected edge; never save that projection as the whole raw fiche.
    private protected override bool StoreReadBack => false;
    public Task<WritePlanDraft> PlanAsync(string groupDn, string memberDn, bool add, CancellationToken cancellationToken) => PrepareAsync(groupDn, async (group, session) =>
    {
        var member = await ReadAsync(memberDn, cancellationToken).ConfigureAwait(false);
        if (member.Kind is FicheKind.Ou or FicheKind.Container)
        { throw FicheErrors.Error(FicheErrors.NotApplicable, "Une OU ou un conteneur ne peut pas devenir membre de ce groupe."); }
        group = await ReadMembershipAsync(group, member.Dn, cancellationToken).ConfigureAwait(false);
        var draft = ObjectWrites.Member(group, FicheSummary.From(member, Source.Clock.GetUtcNow()), add,
            (await Source.DomainAsync(cancellationToken).ConfigureAwait(false)).RootDn, session.Controller?.DnsName);
        return draft with { Changes = [draft.Changes[0] with { ReferenceGuid = member.ObjectGuid.ToString("D") }] };
    }, cancellationToken);

    private protected override async Task<FicheEntry?> ReadTargetAsync(WritePlan plan, CancellationToken token)
    {
        var group = await base.ReadTargetAsync(plan, token).ConfigureAwait(false);
        return group is null ? null : await ReadMembershipAsync(group, MemberDn(plan), token).ConfigureAwait(false);
    }

    private async Task<FicheEntry> ReadMembershipAsync(FicheEntry group, string memberDn, CancellationToken token)
    {
        var rows = await Source.Connection.SearchAsync(new(group.Dn, "(&" + AdObjectAccess.GuidFilter(group.ObjectGuid)
            + "(member=" + LdapFilterText.Escape(memberDn) + "))", AdSearchScope.Base, ["objectGUID"])
        { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10) }, token).ConfigureAwait(false);
        if (rows.Count > 1 || rows.Any(r => !FicheValues.SameDn(r.DistinguishedName, group.Dn) || r.Guid("objectGUID") != group.ObjectGuid))
        { throw AdAttributeRange.Incomplete(); }
        return group.With(new Dictionary<string, System.Collections.Immutable.ImmutableArray<string>> { ["member"] = rows.Count == 1 ? [memberDn] : [] });
    }

    private protected override Task<IReadOnlyList<AdModification>> ModificationsAsync(WritePlan plan, FicheEntry current, CancellationToken token) =>
        Task.FromResult<IReadOnlyList<AdModification>>([new("member", plan.Changes[0].Kind == WriteChangeKind.Add ? AdModificationKind.Add : AdModificationKind.Delete,
            [GuidDn(plan.Changes[0].ReferenceGuid!)])]);

    private protected override void Protect(FicheEntry entry, SessionSnapshot session, WritePlan? plan)
    {
        base.Protect(entry, session, plan);
        if (plan is not null && plan.Confirmation.TypedNameRequired && plan.Confirmation.TypedName != ObjectWrites.TypedName(entry))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Le nom de confirmation du groupe a changé."); }
        if (entry.Kind != FicheKind.Group || entry.Int32("groupType") is null
            || FicheMemberships.IsPrivileged(entry.Name, entry.First("objectSid"), entry.Int32("adminCount")))
        { throw FicheErrors.Error(FicheErrors.Protected, "Groupe protégé ou type illisible ; aucune appartenance modifiée."); }
    }

    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        if (plan.Changes.Length != 1 || plan.Changes[0].Attribute != "member" || plan.Changes[0].ReferenceGuid is null
            || plan.Changes[0].Kind is not (WriteChangeKind.Add or WriteChangeKind.Remove)
            || plan.Changes[0].Kind == WriteChangeKind.Add && (plan.Changes[0].BeforeValue is not null || plan.Changes[0].AfterValue is null)
            || plan.Changes[0].Kind == WriteChangeKind.Remove && (plan.Changes[0].AfterValue is not null || plan.Changes[0].BeforeValue is null || !plan.Confirmation.TypedNameRequired))
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Le plan doit désigner exactement un ajout ou retrait de membre."); }
        AdFicheObjects.ValidateDn(MemberDn(plan));
    }
    private static string MemberDn(WritePlan plan) => plan.Changes[0].AfterValue ?? plan.Changes[0].BeforeValue!;
}
