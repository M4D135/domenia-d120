using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Creates one OU; an unknown Add response is never resolved by a same-name object alone.</summary>
public sealed class AdOuCreateExecutor(AdDirectorySource source) : AdFicheWriteExecutor(source), IOuCreateExecutor, IWriteOutcomeVerifier
{
    public override string Kind => ObjectWrites.CreateOuKind;
    private protected override bool StoreReadBack => false;
    // The parent's own ou attribute is unrelated to the creation change's child DN.
    private protected override bool ScalarChanges => false;

    public Task<WritePlanDraft> PlanAsync(string parentDn, string name, CancellationToken cancellationToken) => PrepareAsync(parentDn, async (parent, session) =>
    {
        var draft = ObjectWrites.CreateOu(parent, name, false, session.Controller?.DnsName);
        var child = await ReadChildAsync(draft.Changes[0].AfterValue!, cancellationToken).ConfigureAwait(false);
        if (child is not null) { return ObjectWrites.CreateOu(parent, name, true, session.Controller?.DnsName); }
        return draft;
    }, cancellationToken);

    private protected override async Task<WritePrecheck> CheckRulesAsync(WritePlan plan, FicheEntry? current, CancellationToken token)
    {
        var child = await ReadChildAsync(plan.Changes[0].AfterValue!, token).ConfigureAwait(false);
        return ObjectWrites.Check(plan, current, _ => child is not null);
    }

    private protected override async Task<WriteOutcome> SendAsync(WritePlan plan, FicheEntry current, CancellationToken cancellationToken)
    {
        var dn = plan.Changes[0].AfterValue!;
        var name = DistinguishedName.Parse(dn)[0].Value;
        await Source.Connection.AddAsync(dn, new Dictionary<string, IReadOnlyList<object>>(StringComparer.OrdinalIgnoreCase)
        { ["objectClass"] = ["top", "organizationalUnit"], ["ou"] = [name] }, cancellationToken).ConfigureAwait(false);
        return new(WriteResult.Applied, "Création acceptée par le contrôleur ; relecture de l’OU et de son parent en cours.");
    }

    public override Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken) =>
        VerifyOutcomeAsync(plan, WriteResult.Unknown, cancellationToken);

    public async Task<WriteVerification> VerifyOutcomeAsync(WritePlan plan, WriteResult outcome, CancellationToken cancellationToken)
    {
        var read = await base.VerifyAsync(plan, cancellationToken).ConfigureAwait(false);
        if (outcome is WriteResult.Unknown or WriteResult.Sent)
        {
            return new(VerificationState.Unknown, "Réponse de création inconnue. " + read.Detail
                + " Une OU homonyme ne prouve pas l’origine de la création ; revue manuelle requise, sans réessai.");
        }
        return outcome == WriteResult.Applied ? read : read with { State = VerificationState.Mismatch, Detail = "Création non acceptée par le contrôleur. " + read.Detail };
    }

    private protected override async Task<WriteVerification> VerifyCurrentAsync(WritePlan plan, FicheEntry? current, CancellationToken token)
    {
        if (current is null || !FicheValues.SameDn(current.Dn, plan.Target.Dn))
        { return new(VerificationState.Mismatch, "Le parent d’origine est absent ou déplacé ; l’emplacement de création n’est pas confirmé."); }
        var child = await ReadChildAsync(plan.Changes[0].AfterValue!, token).ConfigureAwait(false);
        return child is not null && child.Strings("objectClass").Contains("organizationalUnit", StringComparer.OrdinalIgnoreCase)
            ? new(VerificationState.Verified, "OU relue au nom demandé sous le même parent (GUID du parent inchangé).")
            : new(VerificationState.Mismatch, "L’OU demandée n’est pas présente à l’emplacement confirmé.");
    }

    private protected override void Protect(FicheEntry entry, SessionSnapshot session, WritePlan? plan)
    {
        // A root/domain or system container can legitimately be a parent: no property of it is changed here.
        if (entry.Kind is not (FicheKind.Ou or FicheKind.Container) || entry.Dn.StartsWith("CN=Builtin,", StringComparison.OrdinalIgnoreCase))
        { throw FicheErrors.Error(FicheErrors.NotApplicable, "Parent non admis pour une nouvelle OU."); }
    }

    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        if (plan.Changes.Length != 1 || plan.Changes[0] is not { Attribute: "ou", Kind: WriteChangeKind.Add, BeforeValue: null, AfterValue: not null, ReferenceGuid: null })
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Plan de création d’OU incomplet ou altéré."); }
        var dn = plan.Changes[0].AfterValue!;
        AdFicheObjects.ValidateDn(dn);
        var rdn = DistinguishedName.Parse(dn)[0];
        if (!rdn.Type.Equals("OU", StringComparison.OrdinalIgnoreCase) || rdn.Value.Length is 0 or > 64
            || rdn.Value.Any(char.IsControl) || rdn.Value.StartsWith('#') || rdn.Value != rdn.Value.Trim()
            || !FicheValues.SameDn(DistinguishedName.Parent(dn), plan.Target.Dn))
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Nom ou parent de l’OU non conforme au plan."); }
    }

    private Task<AdEntry?> ReadChildAsync(string dn, CancellationToken token) => new AdFicheObjects(Source).ReadExactAsync(dn,
        ["objectGUID", "objectClass"], TimeSpan.FromSeconds(10), token);
}
