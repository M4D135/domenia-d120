using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Ad;

/// <summary>The plan targets a computer; LDAP modifies one member value on the sealed group.</summary>
public sealed class AdPosteGroupExecutor(AdDirectorySource source) : AdPosteDirectoryExecutor(source), IPosteGroupExecutor
{
    private const string Membership = "__posteGroupMember";
    public override string Kind => PosteDirectoryWrites.GroupKind;
    private protected override bool ScalarChanges => false;
    private protected override bool StoreReadBack => false;

    public Task<WritePlanDraft> PlanAsync(string dn, string groupDn, bool add, CancellationToken cancellationToken) =>
        PrepareComputerAsync(dn, async (computer, session) =>
        {
            var group = await ReadAsync(groupDn, cancellationToken).ConfigureAwait(false);
            var typed = Group(group);
            var present = await ContainsAsync(group, computer.DistinguishedName, cancellationToken).ConfigureAwait(false);
            // The targeted query is authoritative even when memberOf or member was ranged/truncated.
            var memberships = computer.MemberOf.Where(g => !FicheValues.SameDn(g, group.Dn)).ToImmutableArray();
            if (present) { memberships = memberships.Add(group.Dn); }
            var draft = PosteDirectoryWrites.Group(computer with { MemberOf = memberships }, typed, add, session.Controller?.DnsName);
            return draft with { Changes = [draft.Changes[0] with { ReferenceGuid = group.ObjectGuid.ToString("D") }] };
        }, cancellationToken);

    private protected override async Task<FicheEntry?> ReadTargetAsync(WritePlan plan, CancellationToken token)
    {
        var computer = await base.ReadTargetAsync(plan, token).ConfigureAwait(false);
        if (computer is null) { return null; }
        var group = await ReadGroupAsync(plan, token).ConfigureAwait(false);
        var state = group is null ? "UNKNOWN" : await ContainsAsync(group, computer.Dn, token).ConfigureAwait(false) ? "TRUE" : "FALSE";
        return computer.With(new Dictionary<string, ImmutableArray<string>> { [Membership] = [state] });
    }

    private protected override async Task<bool> ReferencesAsync(WritePlan plan, CancellationToken token)
    {
        var group = await ReadGroupAsync(plan, token).ConfigureAwait(false);
        if (group is null) { return false; }
        _ = Group(group);
        return group.Int32("adminCount") != 1 || plan.Confirmation.TypedNameRequired
            && plan.Confirmation.TypedName == plan.Target.SamAccountName?.TrimEnd('$');
    }

    private protected override Task<WritePrecheck> CheckRulesAsync(WritePlan plan, FicheEntry? current, CancellationToken token)
    {
        var check = PosteDirectoryWrites.CheckIdentity(plan, current is null ? null : Computer(current));
        if (check.Current && (current?.First(Membership) is not ("TRUE" or "FALSE")
            || !string.Equals(current.First("sAMAccountName"), plan.Target.SamAccountName, StringComparison.OrdinalIgnoreCase)))
        { check = WritePrecheck.Stale("Appartenance illisible ou nom de compte modifié ; préparez un nouveau plan."); }
        return Task.FromResult(check);
    }

    private protected override bool AlreadyApplied(WritePlan plan, FicheEntry? current) => current?.First(Membership) is "TRUE" or "FALSE"
        && (current.First(Membership) == "TRUE") == (plan.Changes[0].Kind == WriteChangeKind.Add);

    private protected override async Task<WriteOutcome> SendAsync(WritePlan plan, FicheEntry current, CancellationToken cancellationToken)
    {
        await Source.Connection.ModifyAsync(GuidDn(plan.Changes[0].ReferenceGuid!),
            [new("member", plan.Changes[0].Kind == WriteChangeKind.Add ? AdModificationKind.Add : AdModificationKind.Delete,
                [GuidDn(plan.Target.ObjectGuid)])], cancellationToken).ConfigureAwait(false);
        return new(WriteResult.Applied, "Une seule appartenance acceptée par le contrôleur ; relecture en cours.");
    }

    private protected override Task<WriteVerification> VerifyComputerAsync(WritePlan plan, FicheEntry? current, CancellationToken token)
    {
        if (current is null || current.First(Membership) is not ("TRUE" or "FALSE"))
        { return Task.FromResult(new WriteVerification(VerificationState.Unknown, "Poste ou appartenance illisible à la relecture.")); }
        var ok = FicheValues.SameDn(current.Dn, plan.Target.Dn)
            && string.Equals(current.First("sAMAccountName"), plan.Target.SamAccountName, StringComparison.OrdinalIgnoreCase)
            && AlreadyApplied(plan, current);
        return Task.FromResult(new WriteVerification(ok ? VerificationState.Verified : VerificationState.Mismatch,
            ok ? "Appartenance exacte relue conforme au plan, sur le même poste et le même groupe."
                : "Écart à la relecture de l’appartenance ou de l’identité du poste ; aucun nouvel envoi automatique."));
    }

    private async Task<FicheEntry?> ReadGroupAsync(WritePlan plan, CancellationToken token)
    {
        var dn = plan.Changes[0].BeforeValue!;
        var identity = await new AdFicheObjects(Source).ReadExactAsync(dn, ["objectGUID"], TimeSpan.FromSeconds(10), token).ConfigureAwait(false);
        if (identity?.Guid("objectGUID")?.ToString("D") != plan.Changes[0].ReferenceGuid) { return null; }
        var group = await ReadAsync(dn, token).ConfigureAwait(false);
        return group.ObjectGuid.ToString("D") == plan.Changes[0].ReferenceGuid ? group : null;
    }

    private async Task<bool> ContainsAsync(FicheEntry group, string memberDn, CancellationToken token)
    {
        var rows = await Source.Connection.SearchAsync(new(group.Dn, "(&" + AdObjectAccess.GuidFilter(group.ObjectGuid)
            + "(member=" + LdapFilterText.Escape(memberDn) + "))", AdSearchScope.Base, ["objectGUID"])
        { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10) }, token).ConfigureAwait(false);
        if (rows.Count > 1 || rows.Any(r => !FicheValues.SameDn(r.DistinguishedName, group.Dn) || r.Guid("objectGUID") != group.ObjectGuid))
        { throw AdAttributeRange.Incomplete(); }
        return rows.Count == 1;
    }

    private static DirectoryGroup Group(FicheEntry entry)
    {
        if (entry.Kind != FicheKind.Group || entry.Int32("groupType") is null || entry.First("objectSid") is null
            || string.IsNullOrWhiteSpace(entry.First("sAMAccountName")))
        { throw WriteErrors.Refusal(PosteErrors.Refused, "Identité ou type du groupe illisible ; aucune appartenance modifiée."); }
        if (string.Equals(entry.First("isCriticalSystemObject"), "TRUE", StringComparison.OrdinalIgnoreCase))
        { throw FicheErrors.Error(FicheErrors.Protected, "Groupe système protégé ; aucune appartenance modifiée."); }
        return AdDirectoryMapper.Group(NativeEntry(entry)) ?? throw AdAttributeRange.Incomplete();
    }

    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        if (plan.Target.Kind != "computer" || plan.Changes.Length != 1
            || plan.Changes[0] is not { Attribute: "member", Kind: WriteChangeKind.Add or WriteChangeKind.Remove, BeforeValue: not null, AfterValue: not null, ReferenceGuid: not null }
            || !FicheValues.SameDn(plan.Changes[0].AfterValue, plan.Target.Dn))
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Le plan doit désigner une seule appartenance de ce poste à un groupe identifié."); }
        AdFicheObjects.ValidateDn(plan.Changes[0].BeforeValue!);
    }
}
