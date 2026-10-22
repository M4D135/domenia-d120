using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>A user or workstation of the directory as the relations need it (local index in directory mode).</summary>
public sealed record RelationObject(
    RelationSubjectKind Kind,
    Guid Guid,
    string Dn,
    string Name,
    string Login,
    string? Detail,
    bool Enabled,
    DateTimeOffset? LastLogon,
    DateTimeOffset Created,
    string? Sid,
    string? Upn);

/// <summary>Lookups of the directory used by the projection: by GUID first, by name for legacy rows.</summary>
public interface IRelationDirectoryLookup
{
    RelationObject? User(Guid? guid, string login);

    RelationObject? Computer(Guid? guid, string name);
}

/// <summary>
/// Projection of the stored associations into the views of the page (pure, shared by every source): rows with badge, rule,
/// identity and persistence; figures; the view of a subject with its statements, primary relation, recent logons and graph.
/// Identity rules of Domenia 1 point 9 apply everywhere: a link of another GUID is never given to an object by a reused name.
/// </summary>
public static class RelationProjection
{
    /// <summary>Most nodes of the second ring of the graph.</summary>
    public const int SecondRingLimit = 24;

    /// <summary>Most second-ring nodes around one first-ring node.</summary>
    public const int SecondRingPerNode = 5;

    /// <summary>Most recent logons shown for a subject.</summary>
    public const int LogonLimit = 30;

    private static string C => FrenchText.Colon;

    public static readonly ImmutableArray<RelationBadge> BadgeOrder =
        [RelationBadge.Declared, RelationBadge.Observed, RelationBadge.History, RelationBadge.Imported, RelationBadge.Hint, RelationBadge.Contradictory, RelationBadge.ToCheck];

    /// <summary>Keys of the relations involved in a contradiction (badge « Contradictoire »).</summary>
    public static ImmutableHashSet<string> ContradictedKeys(IEnumerable<StoredRelation> relations) =>
        RelationRules.Conflicts(relations).SelectMany(c => c.Keys).ToImmutableHashSet(StringComparer.Ordinal);

    /// <summary>Identity of a link with respect to the current objects of its names (worst of the two ends).</summary>
    public static (RelationIdentityMatch Match, string? Note) IdentityOf(StoredRelation relation, RelationObject? user, RelationObject? computer)
    {
        ArgumentNullException.ThrowIfNull(relation);
        var notes = new List<string>();
        var match = RelationIdentityMatch.Same;
        void Check(RelationObject? target, RelationSubjectKind kind, string missing)
        {
            if (target is null)
            {
                notes.Add(missing);
                if ((kind == RelationSubjectKind.User ? relation.UserGuid : relation.ComputerGuid) is null)
                {
                    match = Worst(match, RelationIdentityMatch.Unknown);
                }
                return;
            }
            var (result, reason) = RelationRules.Identity(relation, kind, target.Guid, target.Created);
            match = Worst(match, result);
            if (result != RelationIdentityMatch.Same)
            {
                notes.Add(reason);
            }
        }
        Check(computer, RelationSubjectKind.Computer, "Poste introuvable dans l’annuaire (supprimé ou renommé).");
        Check(user, RelationSubjectKind.User, "Compte introuvable dans l’annuaire (supprimé ou renommé).");
        return (match, notes.Count == 0 ? null : string.Join(" ", notes.Distinct(StringComparer.Ordinal)));
    }

    private static RelationIdentityMatch Worst(RelationIdentityMatch a, RelationIdentityMatch b) =>
        a == RelationIdentityMatch.Different || b == RelationIdentityMatch.Different ? RelationIdentityMatch.Different
        : a == RelationIdentityMatch.Unknown || b == RelationIdentityMatch.Unknown ? RelationIdentityMatch.Unknown
        : RelationIdentityMatch.Same;

    /// <summary>One row of the page.</summary>
    public static RelationRow Row(StoredRelation relation, IRelationDirectoryLookup lookup, bool contradicted, RelationPersistence persistence, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(relation);
        ArgumentNullException.ThrowIfNull(lookup);
        ArgumentNullException.ThrowIfNull(zone);
        var user = lookup.User(relation.UserGuid, relation.UserLogin);
        var computer = lookup.Computer(relation.ComputerGuid, relation.Computer);
        var (identity, note) = IdentityOf(relation, user, computer);
        // A name met on another object never lends its directory data to the link.
        var sameUser = user is not null && (relation.UserGuid is null || relation.UserGuid == user.Guid);
        var sameComputer = computer is not null && (relation.ComputerGuid is null || relation.ComputerGuid == computer.Guid);
        // The badge keeps the nature of the proof; a contradiction is a mark beside it, never a replacement (« tout s’améliore »).
        var badge = RelationRules.BadgeOf(relation.Kind);
        var rule = badge.Rule;
        if (contradicted)
        {
            rule += " Contradiction" + C + RelationRules.BadgeOf(relation.Kind, true).Rule;
        }
        var provenance = relation.Source;
        var whenText = RelationRules.WhenText(relation.When, now, zone);
        if (whenText is not null)
        {
            provenance += " · " + whenText;
        }
        return new RelationRow(
            RelationRules.Key(relation),
            RelationRules.Fingerprint(relation),
            relation.UserLogin,
            sameUser ? user!.Name : null,
            relation.UserDn ?? (sameUser ? user!.Dn : null),
            relation.UserGuid?.ToString("D"),
            relation.Computer,
            relation.ComputerDn ?? (sameComputer ? computer!.Dn : null),
            relation.ComputerGuid?.ToString("D"),
            relation.Kind,
            badge.Badge,
            badge.Label,
            badge.Tone,
            rule + " Provenance" + C + provenance + ".",
            relation.Source,
            relation.When,
            whenText,
            relation.Details,
            persistence,
            persistence == RelationPersistence.Stored ? "Enregistrée" : "Session uniquement",
            identity,
            note,
            relation.VerifiedInAd,
            RelationRules.IsProtectedSource(relation.Source),
            relation.BatchId,
            contradicted,
            relation.Declarant);
    }

    /// <summary>
    /// Count per badge, in the fixed order of the facets (zero counts kept): the natures (their sum is the number of rows) and,
    /// apart, the rows in contradiction (« Contradictoire »), which keep their nature.
    /// </summary>
    public static ImmutableArray<RelationBadgeCount> Badges(IEnumerable<RelationRow> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var list = rows as IReadOnlyCollection<RelationRow> ?? [.. rows];
        var counts = list.GroupBy(r => r.Badge).ToDictionary(g => g.Key, g => g.Count());
        counts[RelationBadge.Contradictory] = list.Count(r => r.Contradicted);
        return [.. BadgeOrder.Select(b => new RelationBadgeCount(b, RelationRules.BadgeLabel(b), RelationRules.BadgeTone(b), counts.GetValueOrDefault(b)))];
    }

    /// <summary>
    /// The most recent import batch still present in the store (Domenia 1 Get-DomeniaImportBatches): identified by its token,
    /// never by a file name.
    /// </summary>
    public static RelationImportBatch? LastImport(IEnumerable<StoredRelation> relations, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(relations);
        var batches = relations
            .Select(r => (Relation: r, Batch: r.BatchId ?? RelationImport.BatchToken(r.Details)))
            .Where(x => x.Batch is not null && x.Relation.Kind == RelationKind.Imported)
            .GroupBy(x => x.Batch!, StringComparer.Ordinal)
            .OrderByDescending(g => g.Key, StringComparer.Ordinal)
            .FirstOrDefault();
        if (batches is null)
        {
            return null;
        }
        var first = batches.First().Relation;
        var file = FileOf(first.Details) ?? "fichier inconnu";
        var at = RelationImport.BatchInstant(batches.Key) ?? first.When ?? now;
        var count = batches.Count();
        var tip = "Retire les " + FrenchText.Count(count, "association importée", "associations importées") + " depuis " + file + " le "
            + (RelationRules.WhenText(at, now, zone) ?? "") + ", après confirmation. Chaque retrait est journalisé et restaurable ; Active Directory n’est pas modifié.";
        return new RelationImportBatch(batches.Key, file, first.Source, at, count, tip);
    }

    private static string? FileOf(string? details)
    {
        const string marker = "Importé depuis ";
        var text = details ?? "";
        var start = text.IndexOf(marker, StringComparison.Ordinal);
        if (start < 0)
        {
            return null;
        }
        start += marker.Length;
        var end = text.IndexOfAny([',', '.'], start);
        while (end > 0 && end + 1 < text.Length && text[end] == '.' && char.IsLetterOrDigit(text[end + 1]))
        {
            end = text.IndexOfAny([',', '.'], end + 1);
        }
        return end < 0 ? text[start..] : text[start..end];
    }

    /// <summary>The removal « Restaurer » puts back, named on the button (Domenia 1 CO-28).</summary>
    public static RelationRestoreCandidate? Restore(RelationJournalRecord? entry, DateTimeOffset now, TimeZoneInfo zone)
    {
        if (entry is null)
        {
            return null;
        }
        var label = RelationRules.RestoreLabel(entry.Relation.UserLogin, entry.Relation.Computer);
        var tip = "Remet l’association " + entry.Relation.UserLogin + " → " + entry.Relation.Computer + " supprimée localement ("
            + (RelationRules.WhenText(entry.At, now, zone) ?? "") + "), depuis le journal ; une association par clic. Aucun objet Active Directory n’est lu ni modifié.";
        return new RelationRestoreCandidate(entry.Id, label, tip, entry.At, entry.Relation.UserLogin, entry.Relation.Computer);
    }

    /// <summary>Observations and history relevés per local day over the last <paramref name="days"/> days, oldest first.</summary>
    public static ImmutableArray<RelationDayCount> Activity(IEnumerable<StoredRelation> relations, DateTimeOffset now, TimeZoneInfo zone, int days = 14)
    {
        ArgumentNullException.ThrowIfNull(relations);
        var today = LocalDays.DateOf(now, zone);
        var observed = new int[days];
        var history = new int[days];
        foreach (var relation in relations)
        {
            if (relation.When is not DateTimeOffset when)
            {
                continue;
            }
            var day = LocalDays.DateOf(when, zone);
            var index = days - 1 - (today.DayNumber - day.DayNumber);
            if (index < 0 || index >= days)
            {
                continue;
            }
            if (relation.Kind is RelationKind.Console or RelationKind.RemoteSession)
            {
                observed[index]++;
            }
            else if (relation.Kind == RelationKind.History)
            {
                history[index]++;
            }
        }
        return
        [
            .. Enumerable.Range(0, days).Select(i =>
            {
                var date = today.AddDays(i - days + 1);
                return new RelationDayCount(date, FrenchText.DayAbbreviation(date.DayOfWeek) + " " + date.Day.ToString(System.Globalization.CultureInfo.InvariantCulture), observed[i], history[i]);
            }),
        ];
    }

    /// <summary>
    /// The relations of one subject (Domenia 1 Get-DomeniaRelationsSelectedLinks): links of its GUID, legacy links of its name
    /// unless they predate the object; a link carrying another GUID never joins by a reused name.
    /// </summary>
    public static ImmutableArray<StoredRelation> SubjectRelations(IEnumerable<StoredRelation> relations, RelationObject subject)
    {
        ArgumentNullException.ThrowIfNull(relations);
        ArgumentNullException.ThrowIfNull(subject);
        var key = subject.Kind == RelationSubjectKind.User ? RelationRules.LoginKey(subject.Login) : RelationRules.ComputerKey(subject.Name);
        return
        [
            .. relations.Where(r =>
            {
                var guid = subject.Kind == RelationSubjectKind.User ? r.UserGuid : r.ComputerGuid;
                if (guid is Guid known)
                {
                    return known == subject.Guid;
                }
                var name = subject.Kind == RelationSubjectKind.User ? RelationRules.LoginKey(r.UserLogin) : RelationRules.ComputerKey(r.Computer);
                return name == key && RelationRules.Identity(r, subject.Kind, subject.Guid, subject.Created).Match != RelationIdentityMatch.Different;
            }),
        ];
    }

    /// <summary>The view of one subject.</summary>
    public static RelationSubjectView Subject(RelationObject subject, string path, IReadOnlyCollection<StoredRelation> stored, IReadOnlyCollection<StoredRelation> session,
        IReadOnlyCollection<StoredRelation> all, IRelationDirectoryLookup lookup, RelationJournalRecord? restore, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(subject);
        ArgumentNullException.ThrowIfNull(stored);
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(all);
        ArgumentNullException.ThrowIfNull(lookup);
        ArgumentNullException.ThrowIfNull(zone);
        var mine = SubjectRelations(stored, subject);
        var mineSession = SubjectRelations(session, subject).Where(s => !mine.Any(m => RelationRules.Same(m, s))).ToImmutableArray();
        var every = mine.Concat(mineSession).ToList();
        // A conflict is decided on the whole workstation: its other relations count, not only the subject's ones.
        var computers = every.Select(r => r.ComputerGuid?.ToString("D") ?? RelationRules.ComputerKey(r.Computer)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var neighbourhood = all.Concat(session).Where(r => computers.Contains(r.ComputerGuid?.ToString("D") ?? RelationRules.ComputerKey(r.Computer))).ToList();
        var contradicted = ContradictedKeys(neighbourhood);
        var rows = mine.Select(r => Row(r, lookup, contradicted.Contains(RelationRules.Key(r)), RelationPersistence.Stored, now, zone))
            .Concat(mineSession.Select(r => Row(r, lookup, contradicted.Contains(RelationRules.Key(r)), RelationPersistence.Session, now, zone)))
            .OrderByDescending(r => RelationRules.Strength(r.Badge)).ThenByDescending(r => r.When)
            .ToImmutableArray();
        var overview = RelationRules.Overview(every, subject.Kind, now, zone);
        var primaryRelation = RelationRules.Primary(every);
        RelationPrimary? primary = null;
        if (primaryRelation is not null)
        {
            var otherIsComputer = subject.Kind == RelationSubjectKind.User;
            var other = otherIsComputer ? lookup.Computer(primaryRelation.ComputerGuid, primaryRelation.Computer) : lookup.User(primaryRelation.UserGuid, primaryRelation.UserLogin);
            var badge = RelationRules.BadgeOf(primaryRelation.Kind);
            var reason = primaryRelation.Kind == RelationKind.Assignment
                ? "Affectation déclarée" + C + "elle passe avant toute observation."
                : "Aucune affectation déclarée" + C + "relation la plus récente (" + RelationRules.Phrase(primaryRelation.Kind) + ").";
            if (contradicted.Contains(RelationRules.Key(primaryRelation)))
            {
                reason += " Une session observée d’un autre compte la contredit" + C + "les deux restent visibles.";
            }
            primary = new RelationPrimary(
                otherIsComputer ? primaryRelation.Computer : other?.Name ?? primaryRelation.UserLogin,
                otherIsComputer ? primaryRelation.Computer : primaryRelation.UserLogin,
                other?.Dn ?? (otherIsComputer ? primaryRelation.ComputerDn : primaryRelation.UserDn),
                other?.Guid.ToString("D"),
                badge.Badge,
                badge.Label,
                badge.Tone,
                primaryRelation.When,
                RelationRules.WhenText(primaryRelation.When, now, zone),
                reason);
        }
        var counts = new RelationCounts(
            rows.Length,
            rows.Count(r => r.Badge == RelationBadge.Declared),
            rows.Count(r => r.Badge == RelationBadge.Observed),
            rows.Count(r => r.Badge == RelationBadge.History),
            rows.Count(r => r.Badge == RelationBadge.Imported),
            rows.Count(r => r.Badge == RelationBadge.Hint),
            rows.Count(r => r.Contradicted),
            rows.Count(r => r.Identity == RelationIdentityMatch.Unknown),
            rows.Count(r => r.Persistence == RelationPersistence.Session));
        var title = subject.Kind == RelationSubjectKind.User ? "Utilisateur" + C + subject.Login : "Poste" + C + subject.Name;
        var context = title + " · " + FrenchText.Count(counts.Total, "association mémorisée", "associations mémorisées") + ".";
        if (counts.SessionOnly > 0)
        {
            context += " " + FrenchText.Count(counts.SessionOnly, "observation visible", "observations visibles") + " pour cette session seulement" + C + "enregistrez-les pour les garder.";
        }
        if (counts.Contradicted > 0)
        {
            context += " " + FrenchText.Count(counts.Contradicted, "qualification contradictoire", "qualifications contradictoires") + C + "sources différentes conservées, sans fusion.";
        }
        var subjectView = new RelationSubject(subject.Kind, subject.Dn, subject.Guid.ToString("D"), subject.Name, subject.Login, subject.Detail, path, subject.Enabled, subject.LastLogon, subject.Created);
        return new RelationSubjectView(
            subjectView,
            RelationRules.Direction(subject.Kind),
            overview,
            primary,
            rows,
            Logons(subject, every, lookup, now, zone),
            Graph(subject, every, all, lookup, contradicted, primaryRelation, now, zone),
            counts,
            context,
            Restore(restore, now, zone));
    }

    /// <summary>
    /// Recent logons of a subject (« Dernières ouvertures de session »): observed and remote sessions, history relevés, and the
    /// last authentication stamp of the directory, which replicates with up to 14 days of delay.
    /// </summary>
    public static ImmutableArray<RelationLogon> Logons(RelationObject subject, IEnumerable<StoredRelation> relations, IRelationDirectoryLookup lookup, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(subject);
        ArgumentNullException.ThrowIfNull(relations);
        ArgumentNullException.ThrowIfNull(lookup);
        var list = new List<RelationLogon>();
        foreach (var relation in relations.Where(r => r.When is not null && r.Kind is RelationKind.Console or RelationKind.RemoteSession or RelationKind.History))
        {
            var otherIsComputer = subject.Kind == RelationSubjectKind.User;
            var other = otherIsComputer ? relation.Computer : relation.UserLogin;
            var otherObject = otherIsComputer ? lookup.Computer(relation.ComputerGuid, relation.Computer) : lookup.User(relation.UserGuid, relation.UserLogin);
            var badge = RelationRules.BadgeOf(relation.Kind);
            var text = relation.Kind switch
            {
                RelationKind.Console => "Console observée sur " + other,
                RelationKind.RemoteSession => "Session à distance sur " + other,
                _ => "Session relevée sur " + other,
            };
            if (subject.Kind == RelationSubjectKind.Computer)
            {
                text = relation.Kind switch
                {
                    RelationKind.Console => "Session console de " + (otherObject?.Name ?? other),
                    RelationKind.RemoteSession => "Session à distance de " + (otherObject?.Name ?? other),
                    _ => "Ouverture de session de " + (otherObject?.Name ?? other),
                };
            }
            list.Add(new RelationLogon(relation.When!.Value, RelationRules.WhenText(relation.When, now, zone)!, other, otherObject?.Dn, relation.Source, relation.Kind,
                badge.Badge, badge.Label, badge.Tone, text));
        }
        if (subject.LastLogon is DateTimeOffset stamp)
        {
            list.Add(new RelationLogon(stamp, RelationRules.WhenText(stamp, now, zone)!, subject.Kind == RelationSubjectKind.User ? "domaine" : subject.Name, null,
                "lastLogonTimestamp, jusqu’à 14 jours de retard", RelationKind.Hint, RelationBadge.Hint, "Annuaire", Tone.Off,
                "Dernière authentification (annuaire)"));
        }
        return [.. list.OrderByDescending(l => l.When).Take(LogonLimit)];
    }

    /// <summary>
    /// Graph of a subject: the subject at the centre, the objects of its relations around it (strongest badge per edge), and a
    /// second ring with the other relations of those objects, bounded.
    /// </summary>
    public static RelationGraph Graph(RelationObject subject, IReadOnlyCollection<StoredRelation> mine, IReadOnlyCollection<StoredRelation> all, IRelationDirectoryLookup lookup,
        ImmutableHashSet<string> contradicted, StoredRelation? primary, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(subject);
        ArgumentNullException.ThrowIfNull(mine);
        ArgumentNullException.ThrowIfNull(all);
        ArgumentNullException.ThrowIfNull(lookup);
        ArgumentNullException.ThrowIfNull(contradicted);
        var nodes = new Dictionary<string, RelationGraphNode>(StringComparer.Ordinal);
        var edges = new List<RelationGraphEdge>();
        var centre = "n:" + subject.Guid.ToString("D");
        nodes[centre] = new RelationGraphNode(centre, subject.Kind, subject.Name, subject.Kind == RelationSubjectKind.User ? subject.Login : subject.Detail, subject.Dn, 0, false, true, Tone.Info, mine.Count);
        var otherKind = subject.Kind == RelationSubjectKind.User ? RelationSubjectKind.Computer : RelationSubjectKind.User;
        string OtherId(StoredRelation r, RelationSubjectKind kind) =>
            kind == RelationSubjectKind.Computer
                ? "n:" + (r.ComputerGuid?.ToString("D") ?? "name:" + RelationRules.ComputerKey(r.Computer))
                : "n:" + (r.UserGuid?.ToString("D") ?? "login:" + RelationRules.LoginKey(r.UserLogin));
        RelationGraphNode NodeOf(StoredRelation r, RelationSubjectKind kind, int depth, bool isPrimary, int links)
        {
            if (kind == RelationSubjectKind.Computer)
            {
                var c = lookup.Computer(r.ComputerGuid, r.Computer);
                var exists = c is not null && (r.ComputerGuid is null || r.ComputerGuid == c.Guid);
                return new RelationGraphNode(OtherId(r, kind), kind, r.Computer, exists ? c!.Detail : "Absent de l’annuaire", exists ? c!.Dn : r.ComputerDn, depth, isPrimary, exists, exists ? Tone.Info : Tone.Off, links);
            }
            var u = lookup.User(r.UserGuid, r.UserLogin);
            var found = u is not null && (r.UserGuid is null || r.UserGuid == u.Guid);
            return new RelationGraphNode(OtherId(r, kind), kind, found ? u!.Name : r.UserLogin, r.UserLogin, found ? u!.Dn : r.UserDn, depth, isPrimary, found, found ? Tone.Info : Tone.Off, links);
        }
        RelationGraphEdge EdgeOf(string from, string to, IReadOnlyList<StoredRelation> group)
        {
            var best = group.OrderByDescending(r => RelationRules.Strength(RelationRules.BadgeOf(r.Kind).Badge)).ThenByDescending(r => r.When).First();
            var isContradicted = group.Any(r => contradicted.Contains(RelationRules.Key(r)));
            var badge = RelationRules.BadgeOf(best.Kind);
            var last = group.Max(r => r.When);
            var label = string.Join(" · ", group.Select(r => RelationRules.BadgeOf(r.Kind).Label).Distinct(StringComparer.Ordinal));
            return new RelationGraphEdge(from, to, badge.Badge, badge.Label, badge.Tone, group.Count, last, RelationRules.WhenText(last, now, zone), isContradicted, label);
        }
        var firstRing = mine.GroupBy(r => OtherId(r, otherKind), StringComparer.Ordinal).ToList();
        foreach (var group in firstRing.OrderByDescending(g => g.Max(r => RelationRules.Strength(RelationRules.BadgeOf(r.Kind).Badge))).ThenBy(g => g.Key, StringComparer.Ordinal))
        {
            var list = group.ToList();
            var isPrimary = primary is not null && list.Contains(primary);
            nodes[group.Key] = NodeOf(list[0], otherKind, 1, isPrimary, list.Count);
            edges.Add(EdgeOf(centre, group.Key, list));
        }
        // Second ring: the other relations of the first-ring objects (other users of a workstation, other workstations of a user).
        var truncated = false;
        var second = 0;
        var subjectKey = subject.Guid;
        foreach (var group in firstRing)
        {
            var related = all.Where(r => OtherId(r, otherKind) == group.Key)
                .Where(r => (subject.Kind == RelationSubjectKind.User ? r.UserGuid : r.ComputerGuid) != subjectKey)
                .Where(r => subject.Kind == RelationSubjectKind.User
                    ? !(r.UserGuid is null && RelationRules.LoginKey(r.UserLogin) == RelationRules.LoginKey(subject.Login))
                    : !(r.ComputerGuid is null && RelationRules.ComputerKey(r.Computer) == RelationRules.ComputerKey(subject.Name)))
                .GroupBy(r => OtherId(r, subject.Kind), StringComparer.Ordinal)
                .OrderByDescending(g => g.Max(r => r.When))
                .ToList();
            if (related.Count > SecondRingPerNode)
            {
                truncated = true;
            }
            foreach (var other in related.Take(SecondRingPerNode))
            {
                if (second >= SecondRingLimit)
                {
                    truncated = true;
                    break;
                }
                var items = other.ToList();
                if (!nodes.ContainsKey(other.Key))
                {
                    nodes[other.Key] = NodeOf(items[0], subject.Kind, 2, false, items.Count);
                    second++;
                }
                edges.Add(EdgeOf(group.Key, other.Key, items));
            }
        }
        return new RelationGraph([.. nodes.Values], [.. edges], truncated);
    }
}
