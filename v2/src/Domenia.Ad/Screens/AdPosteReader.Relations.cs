using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    private async Task<RelationCacheSnapshot?> StoredRelationsAsync(CancellationToken token) => source.LocalStore is IRelationLocalCache store
        ? await store.ReadRelationsAsync(token).ConfigureAwait(false) : null;

    private sealed class RelationLookup(RelationCacheSnapshot? stored)
    {
        private readonly Dictionary<Guid, ImmutableArray<StoredRelation>> known = (stored?.Rows ?? []).Select(r => r.Relation)
            .Where(r => r.ComputerGuid is not null).GroupBy(r => r.ComputerGuid!.Value).ToDictionary(g => g.Key, g => g.ToImmutableArray());
        private readonly Dictionary<string, ImmutableArray<StoredRelation>> legacy = (stored?.Rows ?? []).Select(r => r.Relation)
            .Where(r => r.ComputerGuid is null).GroupBy(r => RelationRules.ComputerKey(r.Computer), StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => g.ToImmutableArray(), StringComparer.Ordinal);

        public ImmutableArray<StoredRelation> For(DirectoryComputer computer) => [.. known.GetValueOrDefault(computer.ObjectGuid, []),
            .. legacy.GetValueOrDefault(RelationRules.ComputerKey(WorkstationIdentity.ExpectedName(computer) ?? computer.Name), [])
                .Where(r => !RelationRules.PredatesObject(r.When, computer.WhenCreated))];
    }

    private PosteAssociation? StoredAssociation(LocalPoste local, bool declared, ImmutableArray<AssociationEvent> history)
    {
        var candidates = local.Relations.Where(r => (r.Kind == RelationKind.Assignment) == declared).ToArray();
        if (candidates.Length == 0) { return null; }
        // A known GUID wins over a namesake legacy row, independently of its observation date.
        var relation = candidates.OrderByDescending(r => r.ComputerGuid == local.Computer.ObjectGuid)
            .ThenByDescending(r => r.When).ThenBy(r => RelationRules.Key(r), StringComparer.Ordinal).First();
        var users = relation.UserGuid is { } id ? local.Directory.Users.Where(u => u.ObjectGuid == id).Take(2).ToArray() : [];
        var user = users.Length == 1 && !RelationRules.PredatesObject(relation.When, users[0].WhenCreated) ? users[0] : null;
        var proven = relation.ComputerGuid == local.Computer.ObjectGuid && user is not null;
        var reference = user is null ? new UserRef(relation.UserLogin, relation.UserLogin, null, null)
            : new(user.DisplayName ?? user.Cn, user.SamAccountName, user.DistinguishedName, user.ObjectGuid);
        var badge = relation.Kind switch
        {
            RelationKind.Assignment => AssociationBadge.Declared,
            RelationKind.Console or RelationKind.RemoteSession => AssociationBadge.Observed,
            RelationKind.History => AssociationBadge.History,
            RelationKind.Imported => AssociationBadge.Imported,
            RelationKind.Hint => AssociationBadge.Hint,
            _ => AssociationBadge.ToCheck,
        };
        var events = local.Relations.Where(r => r.When is not null).OrderByDescending(r => r.When).Take(10)
            .Select(r => new AssociationEvent(r.When!.Value, r.UserLogin, r.Source, r.Details ?? RelationRules.BadgeOf(r.Kind).Rule));
        var rule = RelationRules.BadgeOf(relation.Kind).Rule + " "
            + (proven ? "Identités du poste et du compte conservées par GUID." : "Identité héritée non vérifiable ; aucun compte courant déduit du seul nom.");
        if (local.RelationNotice is { } notice) { rule += " " + notice; }
        return PosteHeaderRules.Association(reference, badge, relation.Source + " · base locale", relation.When, rule, proven,
            [.. history.Concat(events).OrderByDescending(e => e.At).Take(10)], source.Zone);
    }
}
