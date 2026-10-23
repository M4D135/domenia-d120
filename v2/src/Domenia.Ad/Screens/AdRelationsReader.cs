using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

// The screen contract will be exposed once its explicitly requested network gestures are also implemented.
public sealed partial class AdRelationsReader(AdDirectorySource source)
{
    private sealed record LocalRelations(DirectorySnapshot Directory, AdRelationLookup Lookup, RelationCacheSnapshot Stored, RelationJournalCache Journal,
        ImmutableArray<StoredRelation> Session, long Epoch)
    {
        internal string Notice => "Base et index locaux ; aucune lecture réseau. " + Stored.Notice
            + (Lookup.Rejected > 0 ? " " + FrenchText.Count(Lookup.Rejected, "identité locale ambiguë ou invalide exclue", "identités locales ambiguës ou invalides exclues") + "." : "")
            + (Stored.Rows.GroupBy(r => RelationRules.Key(r.Relation), StringComparer.Ordinal).Any(g => g.Count() > 1)
                ? " Plusieurs lignes de la base représentent une même association ; elles restent visibles, sans retrait arbitraire." : "");
    }

    private async Task<LocalRelations> LocalAsync(CancellationToken token, bool withJournal = true)
    {
        var epoch = source.Epoch;
        var local = await source.ReadLocalAsync(token).ConfigureAwait(false);
        if (source.LocalStore is not IRelationLocalCache cache)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Magasin local des associations indisponible ; aucun annuaire de remplacement utilisé."); }
        var stored = await cache.ReadRelationsAsync(token).ConfigureAwait(false);
        if (!DistinguishedName.AreEqual(stored.DomainDn, local.Directory.Domain.RootDn))
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "La base des relations appartient à un autre domaine."); }
        var journal = withJournal ? await cache.ReadRelationJournalAsync(token).ConfigureAwait(false) : new RelationJournalCache([], 0, 0, false, "Journal non demandé.");
        EnsureEpoch(epoch);
        return new(local.Directory, AdRelationLookup.For(local.Directory), stored, journal, AdRelationSession.For(source).Snapshot(epoch), epoch);
    }
    private void EnsureEpoch(long expected)
    { if (source.Epoch != expected) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée ; vue locale précédente écartée."); } }

    public async Task<RelationsOverview> OverviewAsync(CancellationToken cancellationToken)
    {
        var local = await LocalAsync(cancellationToken).ConfigureAwait(false); var rows = Rows(local); var stored = local.Stored.Rows.Select(r => r.Relation).ToArray();
        var users = rows.Select(r => r.UserGuid ?? "login:" + RelationRules.LoginKey(r.UserLogin)).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        var computers = rows.Select(r => r.ComputerGuid ?? "name:" + RelationRules.ComputerKey(r.Computer)).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        var conflicts = RelationRules.Conflicts(stored.Concat(local.Session)).Length;
        return new("Base locale Domenia", false, rows.Length, users, computers, RelationProjection.Badges(rows), conflicts,
            rows.Count(r => r.Identity == RelationIdentityMatch.Unknown), rows.Count(r => r.Persistence == RelationPersistence.Session),
            RelationProjection.LastImport(stored, source.Clock.GetUtcNow(), source.Zone), Restore(local),
            RelationProjection.Activity(stored.Concat(local.Session), source.Clock.GetUtcNow(), source.Zone), local.Journal.Entries.Length,
            FrenchText.Count(rows.Length, "association affichée", "associations affichées") + ". " + local.Notice, Pending(local));
    }

    public async Task<RelationList> ListAsync(CancellationToken cancellationToken)
    {
        var local = await LocalAsync(cancellationToken).ConfigureAwait(false); var rows = Rows(local).OrderByDescending(r => r.When)
            .ThenBy(r => r.Computer, StringComparer.OrdinalIgnoreCase).ThenBy(r => r.Key, StringComparer.Ordinal).ToImmutableArray();
        return new(rows.Length, RelationProjection.Badges(rows), rows, RelationProjection.LastImport(local.Stored.Rows.Select(r => r.Relation), source.Clock.GetUtcNow(), source.Zone), Restore(local))
        { Notice = local.Notice };
    }

    public async Task<RelationSubjectView> SubjectAsync(string reference, CancellationToken cancellationToken)
    {
        var local = await LocalAsync(cancellationToken).ConfigureAwait(false);
        var subject = local.Lookup.Find(reference) ?? throw new DomeniaOperationException(RelationErrors.Unknown, "Sujet absent ou ambigu dans l’index local ; actualisez sa fiche depuis Rechercher.");
        var stored = local.Stored.Rows.Select(r => r.Relation).ToArray();
        var restore = RelationRules.Restorable(local.Journal.Entries).FirstOrDefault(e => RelationProjection.SubjectRelations([e.Relation], subject).Length > 0);
        var view = RelationProjection.Subject(subject, RelationRules.Path(subject.Dn, local.Directory.Domain.DnsName), stored, local.Session, stored, local.Lookup, restore, source.Clock.GetUtcNow(), source.Zone);
        return view with { Associations = PhysicalRows(view.Associations, local), Context = view.Context + " " + local.Notice };
    }

    public async Task<RelationSubjectMatches> SubjectsAsync(string text, CancellationToken cancellationToken)
    {
        if (text.Length > 320 || text.Any(char.IsControl)) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Recherche locale trop longue ou invalide."); }
        var local = await LocalAsync(cancellationToken, withJournal: false).ConfigureAwait(false);
        var counts = local.Stored.Rows.SelectMany(r => new[] { r.Relation.UserGuid, r.Relation.ComputerGuid }).OfType<Guid>().GroupBy(g => g).ToDictionary(g => g.Key, g => g.Count());
        RelationSubjectMatch Match(RelationObject item, string? reason = null) => new(item.Kind, item.Dn, item.Guid.ToString("D"), item.Name, item.Login, item.Detail, counts.GetValueOrDefault(item.Guid), reason);
        var objects = local.Lookup.Users.Concat(local.Lookup.Computers);
        var folded = FrenchText.Fold(text.Trim());
        if (folded.Length == 0)
        {
            return new([], false, [.. objects.Where(o => counts.ContainsKey(o.Guid)).OrderByDescending(o => counts[o.Guid])
                .ThenBy(o => o.Name, StringComparer.OrdinalIgnoreCase).Take(7).Select(o => Match(o, "Associations présentes dans la base locale"))]);
        }
        var matches = objects.Select(o => (Item: o, Name: FrenchText.Fold(o.Name), Login: FrenchText.Fold(o.Login)))
            .Where(o => o.Name.Contains(folded, StringComparison.Ordinal) || o.Login.Contains(folded, StringComparison.Ordinal))
            .OrderBy(o => o.Name == folded || o.Login == folded ? 0 : o.Name.StartsWith(folded, StringComparison.Ordinal) || o.Login.StartsWith(folded, StringComparison.Ordinal) ? 1 : 2)
            .ThenByDescending(o => counts.GetValueOrDefault(o.Item.Guid)).ThenBy(o => o.Item.Name, StringComparer.OrdinalIgnoreCase).Take(31).ToArray();
        return new([.. matches.Take(30).Select(o => Match(o.Item))], matches.Length > 30, []);
    }

    public async Task<RelationJournal> JournalAsync(CancellationToken cancellationToken)
    {
        var local = await LocalAsync(cancellationToken).ConfigureAwait(false); var journal = local.Journal.Entries;
        var restorable = RelationRules.Restorable(journal); var ids = restorable.Select(e => e.Id).ToHashSet(StringComparer.Ordinal);
        var restoredBy = journal.Where(e => e.Action == RelationJournalAction.Restored && e.Note is not null)
            .GroupBy(e => e.Note!, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Last().Id, StringComparer.Ordinal);
        var rows = journal.Reverse().Select(e =>
        {
            var (label, tone) = RelationRules.JournalAction(e.Action);
            return new RelationJournalEntry(e.Id, e.Action, label, tone, e.At, e.Declarant,
                e.Action == RelationJournalAction.Restored ? "Remet en place la suppression du journal." : e.Note,
                e.Relation.UserLogin, e.Relation.Computer, e.Relation.Kind, RelationRules.BadgeOf(e.Relation.Kind).Label, e.Relation.Source, ids.Contains(e.Id), restoredBy.GetValueOrDefault(e.Id));
        }).ToImmutableArray();
        return new(rows.Length, rows, [.. restorable.Select(e => RelationProjection.Restore(e, source.Clock.GetUtcNow(), source.Zone)!)], local.Journal.Notice);
    }

    public async Task<RelationPendingObservations> PendingAsync(CancellationToken cancellationToken) =>
        Pending(await LocalAsync(cancellationToken, withJournal: false).ConfigureAwait(false));

    private RelationPendingObservations Pending(LocalRelations local)
    {
        StoredRelation[] pending; string? issue = null;
        try
        {
            if (local.Stored.Truncated || local.Stored.Rejected > 0)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Base partiellement lisible."); }
            pending = AdRelationSession.PrepareItems(local.Stored, local.Session).Select(i => i.After!).ToArray();
        }
        catch (DomeniaOperationException) { pending = local.Session.ToArray(); issue = "Association ambiguë ou base partiellement lisible ; mémorisation suspendue."; }
        var batches = (pending.Length + WritePlans.MaxChanges - 1) / WritePlans.MaxChanges;
        ImmutableArray<RelationPendingSet> sets = pending.Length == 0 ? [] : [new(RelationChange.SessionResultId, "Observations natives de la session", local.Session.Length, pending.Length, batches,
            [.. pending.GroupBy(r => r.Source, StringComparer.Ordinal).OrderBy(g => g.Key, StringComparer.Ordinal).Select(g => new RelationPendingSource(g.Key, g.Count()))], null)];
        var keys = pending.Select(RelationRules.Key).ToHashSet(StringComparer.Ordinal);
        foreach (var (set, expires) in AdRelationResults.For(source).ObservationSets(local.Epoch))
        {
            var remaining = set.Relations.Where(p => keys.Contains(p.Key)).Select(p => p.Value).ToArray();
            if (remaining.Length == 0) { continue; }
            sets = sets.Add(new(set.Id, set.Origin, set.Relations.Count, remaining.Length, (remaining.Length + WritePlans.MaxChanges - 1) / WritePlans.MaxChanges,
                [.. remaining.GroupBy(r => r.Source, StringComparer.Ordinal).OrderBy(g => g.Key, StringComparer.Ordinal).Select(g => new RelationPendingSource(g.Key, g.Count()))], expires));
        }
        return new(pending.Length, batches, sets, (pending.Length == 0 ? "Aucune observation native en attente."
            : FrenchText.Count(pending.Length, "observation native en attente", "observations natives en attente") + " de mémorisation locale, par lots de 64.")
            + (issue is null ? "" : " " + issue));
    }

    private RelationRestoreCandidate? Restore(LocalRelations local) => RelationProjection.Restore(RelationRules.Restorable(local.Journal.Entries).FirstOrDefault(), source.Clock.GetUtcNow(), source.Zone);

    private ImmutableArray<RelationRow> Rows(LocalRelations local)
    {
        var stored = local.Stored.Rows.Select(r => r.Relation).ToArray();
        var fingerprints = stored.Select(RelationRules.Fingerprint).ToHashSet(StringComparer.Ordinal);
        var session = local.Session.Where(r => !fingerprints.Contains(RelationRules.Fingerprint(r))).ToArray();
        var contradicted = RelationProjection.ContradictedKeys(stored.Concat(session));
        var rows = stored.Select(r => RelationProjection.Row(r, local.Lookup, contradicted.Contains(RelationRules.Key(r)), RelationPersistence.Stored, source.Clock.GetUtcNow(), source.Zone))
            .Concat(session.Select(r => RelationProjection.Row(r, local.Lookup, contradicted.Contains(RelationRules.Key(r)), RelationPersistence.Session, source.Clock.GetUtcNow(), source.Zone)));
        return PhysicalRows(rows, local);
    }

    private static ImmutableArray<RelationRow> PhysicalRows(IEnumerable<RelationRow> rows, LocalRelations local)
    {
        var ambiguous = local.Stored.Rows.GroupBy(r => RelationRules.Key(r.Relation), StringComparer.Ordinal).Where(g => g.Count() > 1).ToDictionary(g => g.Key, g => g.ToArray(), StringComparer.Ordinal);
        var positions = new Dictionary<string, int>(StringComparer.Ordinal);
        return [.. rows.Select(row =>
        {
            if (!ambiguous.TryGetValue(row.Key, out var matches)) { return row; }
            if (row.Persistence == RelationPersistence.Session) { return row with { Key = row.Key + "|session", StorageAmbiguous = true }; }
            var same = matches.Where(r => RelationRules.Fingerprint(r.Relation) == row.Fingerprint).ToArray();
            var index = positions.GetValueOrDefault(row.Fingerprint); positions[row.Fingerprint] = index + 1;
            return row with { Key = row.Key + "|row:" + same[index].StorageFingerprint, StorageAmbiguous = true };
        })];
    }
}
