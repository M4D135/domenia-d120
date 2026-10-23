using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdRelationChangeExecutor
{
    public async Task<WritePlanDraft> PlanAssociationAsync(string subjectDn, Guid subjectGuid, string targetDn, Guid targetGuid, CancellationToken cancellationToken)
    {
        if (subjectGuid == Guid.Empty || targetGuid == Guid.Empty)
        { throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Identités GUID obligatoires pour confirmer une association."); }
        var local = await ReadAsync(cancellationToken).ConfigureAwait(false); var domain = source.CurrentDirectory!.Domain;
        AdRelationDirectory.ValidateDn(subjectDn, domain); AdRelationDirectory.ValidateDn(targetDn, domain);
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(30), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, budget.Token).ConfigureAwait(false);
        var first = await AdRelationDirectory.ExactAsync(access, domain, subjectDn, subjectGuid, true, budget.Token).ConfigureAwait(false);
        var second = await AdRelationDirectory.ExactAsync(access, domain, targetDn, targetGuid, true, budget.Token).ConfigureAwait(false);
        if (first.Object.Kind == second.Object.Kind) { throw WriteErrors.Refusal(RelationErrors.SameKind, RelationErrors.SameKindMessage); }
        var user = first.Object.Kind == RelationSubjectKind.User ? first : second;
        var computer = first.Object.Kind == RelationSubjectKind.Computer ? first : second;
        access.EnsureCurrent();
        await source.RememberObjectsAsync(new(domain, source.Clock.GetUtcNow(), false, [], [AdDirectoryMapper.User(user.Entry)!], [AdDirectoryMapper.Computer(computer.Entry)!], []),
            local.Session.Epoch, budget.Token).ConfigureAwait(false);
        var incoming = new StoredRelation(user.Object.Login, user.Object.Guid, user.Object.Dn, computer.Object.Name, computer.Object.Guid, computer.Object.Dn, RelationKind.Assignment,
            RelationRules.ManualSource, WritePlans.TruncateToSecond(source.Clock.GetUtcNow()), "Affectation déclarée après relecture LDAP des deux identités GUID.", true, local.Session.Account.Login, null);
        var existing = local.Stored.Rows.Where(r => RelationRules.Key(r.Relation) == RelationRules.Key(incoming)).ToArray();
        if (existing.Length > 1) { throw WriteErrors.Refusal(WriteErrors.Stale, "Affectation ambiguë dans la base ; aucune ligne choisie arbitrairement."); }
        var before = existing.SingleOrDefault()?.Relation;
        var item = new RelationChangeItem(before is null ? RelationChangeOperation.Add : RelationChangeOperation.Replace, before, incoming,
            before is null ? "Affectation déclarée depuis Relations." : "Date et déclarant de l’affectation mis à jour.", null);
        var risks = new List<WriteRisk>();
        var others = local.Stored.Rows.Where(r => r.Relation.ComputerGuid == computer.Object.Guid && r.Relation.UserGuid != user.Object.Guid).Select(r => r.Relation).ToArray();
        if (others.Any(r => r.Kind == RelationKind.Assignment)) { risks.Add(new(Tone.Warn, "Ce poste porte déjà une autre affectation déclarée ; les deux sont conservées.")); }
        if (others.Any(r => r.Kind is RelationKind.Console or RelationKind.RemoteSession)) { risks.Add(new(Tone.Info, "Une session d’un autre compte a été observée ; les deux relations restent visibles et peuvent être contradictoires.")); }
        if (!user.Object.Enabled || !computer.Object.Enabled) { risks.Add(new(Tone.Warn, "Le compte utilisateur ou le compte du poste est désactivé ; vérifiez l’utilité de cette affectation.")); }
        access.EnsureCurrent();
        return Hold(local, before is null ? "Déclarer l’affectation" : "Actualiser l’affectation déclarée", "Affectation déclarée",
            RelationChange.Pair(incoming) + " sera enregistrée dans la base locale, à côté des relations existantes.", RelationChange.Pair(incoming), [item], risks, RelationChange.AddReversibility());
    }
}
