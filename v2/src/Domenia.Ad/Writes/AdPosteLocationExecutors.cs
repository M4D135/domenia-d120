using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Ad;

/// <summary>Poste plans carry whole before/after DNs, unlike the parent-only move changes of Fiche.</summary>
public abstract class AdPosteLocationExecutor(AdDirectorySource source) : AdPosteDirectoryExecutor(source)
{
    private protected async Task<WritePlanDraft> BindParentAsync(WritePlanDraft draft, CancellationToken token)
    {
        var parentDn = DistinguishedName.Parent(draft.Changes[0].AfterValue!)!;
        var parent = await ReadAsync(parentDn, token).ConfigureAwait(false);
        if (parent.Kind is not (FicheKind.Ou or FicheKind.Container) || Kind == PosteDirectoryWrites.MoveKind && parent.Kind != FicheKind.Ou)
        { throw WriteErrors.Refusal(PosteErrors.Refused, "Destination non admise pour ce poste."); }
        var collision = await ReadExactAsync(draft.Changes[0].AfterValue!, token).ConfigureAwait(false);
        if (collision is not null) { throw WriteErrors.Refusal(PosteErrors.Refused, "Un objet porte déjà ce nom dans la destination."); }
        return draft with { Changes = [draft.Changes[0] with { ReferenceGuid = parent.ObjectGuid.ToString("D") }] };
    }

    private protected override async Task<bool> ReferencesAsync(WritePlan plan, CancellationToken token)
    {
        var parent = await ReadExactAsync(DistinguishedName.Parent(plan.Changes[0].AfterValue!)!, token).ConfigureAwait(false);
        return parent?.Guid("objectGUID")?.ToString("D") == plan.Changes[0].ReferenceGuid;
    }

    private protected override async Task<WritePrecheck> CheckRulesAsync(WritePlan plan, FicheEntry? current, CancellationToken token)
    {
        if (current is null) { return WritePrecheck.Stale("Le GUID du poste n’existe plus."); }
        if (!FicheValues.SameDn(current.Dn, plan.Target.Dn) && !FicheValues.SameDn(current.Dn, plan.Changes[0].AfterValue))
        { return WritePrecheck.Stale("Le poste a été renommé ou déplacé ailleurs depuis la préparation."); }
        if (!string.Equals(current.First("sAMAccountName"), plan.Target.SamAccountName, StringComparison.OrdinalIgnoreCase))
        { return WritePrecheck.Stale("Le nom de compte du poste a changé ; préparez un nouveau plan."); }
        var collision = await ReadExactAsync(plan.Changes[0].AfterValue!, token).ConfigureAwait(false);
        if (collision is not null && collision.Guid("objectGUID") != current.ObjectGuid)
        { return WritePrecheck.Stale("Un autre objet occupe le nom de destination ; rien n’a été envoyé."); }
        return WritePrecheck.Valid(AlreadyApplied(plan, current) ? "Le poste est déjà au nom et à l’emplacement confirmés." : "GUID, nom de compte et emplacement relus conformes au plan.");
    }

    private protected override bool AlreadyApplied(WritePlan plan, FicheEntry? current) => current is not null
        && FicheValues.SameDn(current.Dn, plan.Changes[0].AfterValue)
        && string.Equals(current.First("sAMAccountName"), plan.Target.SamAccountName, StringComparison.OrdinalIgnoreCase);

    private protected override async Task<WriteOutcome> SendAsync(WritePlan plan, FicheEntry current, CancellationToken cancellationToken)
    {
        var name = DistinguishedName.Parse(plan.Changes[0].AfterValue!)[0];
        await Source.Connection.RenameAsync(GuidDn(plan.Target.ObjectGuid), GuidDn(plan.Changes[0].ReferenceGuid!),
            DistinguishedName.Rdn(name.Type, name.Value), cancellationToken).ConfigureAwait(false);
        return new(WriteResult.Applied, "ModifyDN accepté ; relecture du nom, de l’emplacement et du compte ordinateur en cours.");
    }

    private protected override Task<WriteVerification> VerifyComputerAsync(WritePlan plan, FicheEntry? current, CancellationToken token)
    {
        var computer = current is null ? null : Computer(current);
        var read = PosteDirectoryWrites.Verify(plan, computer, null);
        return Task.FromResult(computer is not null && !string.Equals(computer.SamAccountName, plan.Target.SamAccountName, StringComparison.OrdinalIgnoreCase)
            ? new(VerificationState.Mismatch, "Le nom de compte a changé depuis le plan ; l’état relu n’est pas celui confirmé.") : read);
    }

    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        if (plan.Target.Kind != "computer" || plan.Changes.Length != 1 || plan.Changes[0] is not { Kind: WriteChangeKind.Move, AfterValue: not null, ReferenceGuid: not null }
            || !FicheValues.SameDn(plan.Target.Dn, plan.Changes[0].BeforeValue) || !plan.Confirmation.TypedNameRequired)
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Plan de renommage ou déplacement du poste non conforme."); }
        AdFicheObjects.ValidateDn(plan.Changes[0].AfterValue!);
        var before = DistinguishedName.Parse(plan.Target.Dn)[0]; var after = DistinguishedName.Parse(plan.Changes[0].AfterValue!)[0];
        if (!after.Type.Equals("CN", StringComparison.OrdinalIgnoreCase)
            || Kind == PosteDirectoryWrites.RenameKind && (plan.Changes[0].Attribute != "cn" || !FicheValues.SameDn(DistinguishedName.Parent(plan.Target.Dn), DistinguishedName.Parent(plan.Changes[0].AfterValue!)))
            || Kind == PosteDirectoryWrites.MoveKind && (plan.Changes[0].Attribute != "distinguishedName" || before != after))
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Le renommage ne change que le CN et le déplacement conserve ce CN."); }
    }

    private Task<AdEntry?> ReadExactAsync(string dn, CancellationToken token) => new AdFicheObjects(Source).ReadExactAsync(dn,
        ["objectGUID"], TimeSpan.FromSeconds(10), token);
}

public sealed class AdPosteMoveExecutor(AdDirectorySource source) : AdPosteLocationExecutor(source), IPosteMoveExecutor
{
    public override string Kind => PosteDirectoryWrites.MoveKind;
    public Task<WritePlanDraft> PlanAsync(string dn, string targetOuDn, CancellationToken cancellationToken) => PrepareComputerAsync(dn, async (computer, session) =>
    {
        var parent = await ReadAsync(targetOuDn, cancellationToken).ConfigureAwait(false);
        if (parent.Kind != FicheKind.Ou) { throw WriteErrors.Refusal(PosteErrors.Refused, "Une OU du domaine est requise."); }
        var ou = AdDirectoryMapper.Ou(NativeEntry(parent)) ?? throw AdAttributeRange.Incomplete();
        return await BindParentAsync(PosteDirectoryWrites.Move(computer, ou, session.Controller?.DnsName), cancellationToken).ConfigureAwait(false);
    }, cancellationToken);
}

public sealed class AdPosteRenameExecutor(AdDirectorySource source) : AdPosteLocationExecutor(source), IPosteRenameExecutor
{
    public override string Kind => PosteDirectoryWrites.RenameKind;
    public Task<WritePlanDraft> PlanAsync(string dn, string newName, CancellationToken cancellationToken) => PrepareComputerAsync(dn, async (computer, session) =>
    {
        var first = PosteDirectoryWrites.Rename(computer, newName, [], session.Controller?.DnsName);
        var name = first.Changes[0].After!;
        var domain = await Source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var rows = await Source.Connection.SearchAsync(new(domain.RootDn, "(&(objectClass=computer)(|(name=" + LdapFilterText.Escape(name)
            + ")(sAMAccountName=" + LdapFilterText.Escape(name + "$") + ")))", AdSearchScope.Subtree,
            ["objectGUID", "objectSid", "objectClass", "name", "sAMAccountName", "dNSHostName", "userAccountControl"])
        { SizeLimit = 101, PageSize = 100, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10) }, cancellationToken).ConfigureAwait(false);
        if (rows.Count > 100) { throw WriteErrors.Refusal(PosteErrors.Refused, "Plus de 100 homonymes : contrôlez les noms avant de préparer ce renommage."); }
        var peers = new List<DirectoryComputer>();
        foreach (var row in rows)
        {
            AdFicheObjects.EnsureDomain(row.DistinguishedName, domain.RootDn);
            if (!row.Strings("objectClass").Contains("computer", StringComparer.OrdinalIgnoreCase)) { throw AdAttributeRange.Incomplete(); }
            peers.Add(AdDirectoryMapper.Computer(row) ?? throw AdAttributeRange.Incomplete());
        }
        return await BindParentAsync(PosteDirectoryWrites.Rename(computer, name, peers, session.Controller?.DnsName), cancellationToken).ConfigureAwait(false);
    }, cancellationToken);
}
