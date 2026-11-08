using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdAuditReader
{
    private static AuditRelationKind RelationKindOf(RelationKind kind) => kind switch
    { RelationKind.Assignment => AuditRelationKind.Declared, RelationKind.Console => AuditRelationKind.Console, RelationKind.RemoteSession => AuditRelationKind.RemoteSession,
      RelationKind.History => AuditRelationKind.History, RelationKind.Imported => AuditRelationKind.Imported, _ => AuditRelationKind.Clue };
    private static bool Belongs(AuditTarget target, StoredRelation relation) => target.ObjectGuid is { } id
        && (target.Kind == AuditObjectKind.User ? relation.UserGuid == id : target.Kind == AuditObjectKind.Computer && relation.ComputerGuid == id);
    public async Task<ImmutableArray<RelationRecord>> RelationsAsync(AuditTarget target, CancellationToken cancellationToken)
    {
        var epoch = source.Epoch; var local = await Local(cancellationToken).ConfigureAwait(false);
        var current = Targets(local).SingleOrDefault(t => t.Kind == target.Kind && t.ObjectGuid == target.ObjectGuid && DistinguishedName.AreEqual(t.Dn, target.Dn));
        if (current is null || target.ObjectGuid is null) { throw Incomplete(); }
        var stored = source.LocalStore is IRelationLocalCache cache ? await cache.ReadRelationsAsync(cancellationToken).ConfigureAwait(false) : null;
        Current(epoch); var rows = (stored?.Rows.Select(r => r.Relation) ?? []).Concat(AdRelationSession.For(source).Snapshot(epoch)).Where(r => Belongs(target, r))
            .GroupBy(RelationRules.Key, StringComparer.Ordinal).Select(g => g.OrderByDescending(r => r.When).First()).Take(5000);
        return [.. rows.Select(r => new RelationRecord(RelationKindOf(r.Kind), r.UserLogin, r.UserGuid, r.Computer, r.ComputerGuid, r.Source, r.When))];
    }
    public async Task<RelationHistoryRead> RelationHistoryAsync(AuditTarget target, int limit, CancellationToken cancellationToken)
    {
        if (limit is < 1 or > 5000) { throw Invalid("Historique limité à 5 000 lignes."); }
        var epoch = source.Epoch;
        var current = await FindTargetAsync(target.Dn, cancellationToken).ConfigureAwait(false);
        if (target.ObjectGuid is null || current?.ObjectGuid != target.ObjectGuid || current.Kind != target.Kind) { throw Incomplete(); }
        if (source.LocalStore is not IRelationLocalCache cache) { return new(ReadState.NotRead, "Aucun magasin local d’associations.", -1, limit, []); }
        var history = await cache.ReadRelationJournalAsync(cancellationToken).ConfigureAwait(false); Current(epoch);
        var rows = history.Entries.Where(e => Belongs(target, e.Relation)).OrderByDescending(e => e.At).ToArray();
        return new(!history.LegacyReadable ? ReadState.Unavailable : rows.Length == 0 ? ReadState.Empty : ReadState.Read,
            history.Rejected > 0 || history.Truncated || !history.LegacyReadable ? history.Notice : null, rows.Length, limit,
            [.. rows.Take(limit).Select(e => new RelationHistoryRow(e.Relation.UserLogin, e.Relation.Computer, e.Relation.Source, RelationKindOf(e.Relation.Kind), e.Relation.VerifiedInAd, e.Relation.When ?? e.At, e.Note ?? e.Relation.Details))]);
    }
}
