using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Executor of the changes of the local association store (docs/ops/relations.md, docs/WRITES.md § 6), served by the source of
/// the mode: Domenia.Simulation changes the associations kept in memory, the local base of Domenia will be changed in wave 3.
/// Associations are local to Domenia: no plan of this executor ever writes Active Directory. Each plan read builds a draft from
/// a fresh read of the store and of the directory; the circuit seals it, the operator confirms it, write.execute runs it once
/// with its receipt and its re-read. The rules are pure and shared: <see cref="RelationChange"/>.
/// </summary>
public interface IRelationChangeExecutor : IWriteExecutor
{
    /// <summary>Declared association between the subject and a target of the opposite type, both read again (REL-002, REL-016, REL-026).</summary>
    Task<WritePlanDraft> PlanAssociationAsync(string subjectDn, string targetDn, CancellationToken cancellationToken);

    /// <summary>Removal of one stored association, named by its key and the fingerprint the page showed (REL-008, REL-012).</summary>
    Task<WritePlanDraft> PlanRemovalAsync(string key, string fingerprint, CancellationToken cancellationToken);

    /// <summary>Restoration of a local removal (the most recent one when <paramref name="entryId"/> is null, REL-009).</summary>
    Task<WritePlanDraft> PlanRestoreAsync(string? entryId, CancellationToken cancellationToken);

    /// <summary>The rows of an import preview marked « À importer », 64 at most (REL-035, REL-037).</summary>
    Task<WritePlanDraft> PlanImportAsync(string previewId, CancellationToken cancellationToken);

    /// <summary>Removal of the associations of an import batch (the most recent one when <paramref name="batchId"/> is null, REL-038).</summary>
    Task<WritePlanDraft> PlanImportUndoAsync(string? batchId, CancellationToken cancellationToken);

    /// <summary>Removal of the orphan links checked by the operator in an orphan check, 64 at most (REL-052).</summary>
    Task<WritePlanDraft> PlanOrphanCleanupAsync(string checkId, IReadOnlyList<string> keys, CancellationToken cancellationToken);

    /// <summary>
    /// Observations of a detection, a session read, a relevé or a harvest kept by the engine (the page names them, never sends
    /// them), 64 at most (REL-017, REL-018, REL-024, REL-030).
    /// </summary>
    Task<WritePlanDraft> PlanObservationsAsync(string resultId, IReadOnlyList<string> keys, CancellationToken cancellationToken);
}

/// <summary>Operation of one change of the store.</summary>
public enum RelationChangeOperation
{
    Add,
    Remove,
    Replace,
}

/// <summary>
/// One change of a plan: the association before (Remove, Replace) and after (Add, Replace), the note of the journal and, for a
/// restoration, the journal line of the removal it puts back.
/// </summary>
public sealed record RelationChangeItem(RelationChangeOperation Operation, StoredRelation? Before, StoredRelation? After, string? Note, string? RestoresEntry);

/// <summary>Result of applying a plan to the store: the store after, the journal lines, and whether anything changed.</summary>
public sealed record RelationChangeResult(ImmutableDictionary<string, StoredRelation> Store, ImmutableArray<RelationJournalRecord> Journal, int Applied, int AlreadyDone);

/// <summary>
/// Pure rules of the changes of the association store, for every source: drafting (plain words, raw values, risks,
/// reversibility), preconditions read again just before sending (optimistic control by fingerprint, Domenia 1 REL-012: an
/// association changed elsewhere is never overwritten), application (for the simulation and the local base), and the
/// postcondition read back. A raw value is « fingerprint|key »: the fingerprint protects the whole association, the full
/// record is kept by the executor and found again by its fingerprint.
/// </summary>
public static class RelationChange
{
    public const string Kind = "relations.change";

    /// <summary>
    /// Result identifier naming the observations of the session not saved yet (rows « Session uniquement »), for
    /// relations.observations.plan: 32 zeros, never issued for a real result.
    /// </summary>
    public const string SessionResultId = "00000000000000000000000000000000";

    /// <summary>Attribute of every change: one association of the local store.</summary>
    public const string Attribute = "association";

    /// <summary>Identity of the local association store as the target of a plan (it is not a directory object).</summary>
    public static readonly Guid StoreGuid = new("6d1b0c2e-5a47-4f3b-9e21-8c0a7d4f2b19");

    private static string C => FrenchText.Colon;

    /// <summary>Target of a plan: the local store, named after what the plan changes (« j.martin → PC-PAR-0042 »).</summary>
    public static WriteTarget Target(string name, bool simulated) => new(
        "relations",
        "Associations locales",
        name,
        simulated ? "Mémoire de la simulation · associations utilisateurs-postes" : "Base locale de Domenia · associations utilisateurs-postes",
        StoreGuid.ToString("D"),
        null);

    /// <summary>Raw value of an association in a plan: its fingerprint, then its key.</summary>
    public static string Value(StoredRelation relation)
    {
        ArgumentNullException.ThrowIfNull(relation);
        return RelationRules.Fingerprint(relation) + "|" + RelationRules.Key(relation);
    }

    /// <summary>Fingerprint and key of a raw value; null when it is not one.</summary>
    public static (string Fingerprint, string Key)? Parse(string? value)
    {
        if (value is null || value.Length < 66 || value[64] != '|')
        {
            return null;
        }
        var fingerprint = value[..64];
        return fingerprint.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f')) ? (fingerprint, value[65..]) : null;
    }

    /// <summary>« j.martin → PC-PAR-0042 ».</summary>
    public static string Pair(StoredRelation relation)
    {
        ArgumentNullException.ThrowIfNull(relation);
        return relation.UserLogin + " → " + relation.Computer;
    }

    /// <summary>Plain words of an association in a plan: « Observé · Console CIM/DCOM · 08/10 09:15 ».</summary>
    public static string Describe(StoredRelation relation, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(relation);
        var text = RelationRules.BadgeOf(relation.Kind).Label + " · " + RelationRules.Flat(relation.Source, 40);
        var when = RelationRules.WhenText(relation.When, now, zone);
        return when is null ? text : text + " · " + when;
    }

    /// <summary>
    /// Draft of a plan over the store. Between 1 and 64 changes (<see cref="WritePlans.MaxChanges"/>); simple confirmation,
    /// because every change is local, journaled and reversible (Domenia 1: inline confirmation, « Danger » level for a batch).
    /// </summary>
    public static WritePlanDraft Draft(string title, string label, string summary, string targetName, bool simulated, IReadOnlyList<RelationChangeItem> items,
        IEnumerable<WriteRisk> risks, WriteReversibility reversibility, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(items);
        ArgumentNullException.ThrowIfNull(risks);
        ArgumentNullException.ThrowIfNull(zone);
        if (items.Count == 0)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune association à modifier" + C + "aucune écriture préparée.");
        }
        if (items.Count > WritePlans.MaxChanges)
        {
            throw WriteErrors.Refusal(RelationErrors.TooMany, RelationErrors.TooManyMessage(items.Count));
        }
        var changes = items.Select(item => item.Operation switch
        {
            RelationChangeOperation.Add => new WriteChange(Attribute, Pair(item.After!), WriteChangeKind.Add, null,
                item.RestoresEntry is null ? Describe(item.After!, now, zone) : "Restaurée · " + Describe(item.After!, now, zone), null, Value(item.After!)),
            RelationChangeOperation.Remove => new WriteChange(Attribute, Pair(item.Before!), WriteChangeKind.Remove, Describe(item.Before!, now, zone),
                "Retirée (journalisée, restaurable)", Value(item.Before!), null),
            _ => new WriteChange(Attribute, Pair(item.After!), WriteChangeKind.Replace, Describe(item.Before!, now, zone), Describe(item.After!, now, zone),
                Value(item.Before!), Value(item.After!)),
        }).ToImmutableArray();
        var allRisks = ImmutableArray.CreateBuilder<WriteRisk>();
        allRisks.Add(new WriteRisk(Tone.Info, "Associations locales à Domenia" + C + "aucun objet Active Directory n’est lu en écriture ni modifié."));
        allRisks.AddRange(risks);
        return new WritePlanDraft(
            Kind,
            title,
            label,
            summary,
            Target(targetName, simulated),
            changes,
            allRisks.ToImmutable(),
            new WriteConfirmation(false, null, "Confirmation simple" + C + "changement local, journalisé et réversible ; Active Directory n’est pas modifié."),
            reversibility,
            null);
    }

    /// <summary>
    /// Preconditions read again just before sending, all or nothing: an association to add is still absent (or already the
    /// same), an association to remove or replace still has the fingerprint shown in the plan (or is already in the state
    /// asked). An association changed elsewhere stops the whole plan: nothing is sent (Domenia 1 REL-012). A record the
    /// executor no longer holds (<paramref name="hasRecord"/>) stops it too.
    /// </summary>
    public static WritePrecheck Check(WritePlan plan, IReadOnlyDictionary<string, StoredRelation> store, Func<string, bool> hasRecord)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(hasRecord);
        var pending = 0;
        var done = 0;
        foreach (var change in plan.Changes)
        {
            var before = Parse(change.BeforeValue);
            var after = Parse(change.AfterValue);
            if (change.Attribute != Attribute || (before is null && after is null))
            {
                return WritePrecheck.Stale("Plan illisible pour le magasin des associations" + C + "rien n’a été envoyé.");
            }
            string? PrintOf(string key) => store.TryGetValue(key, out var current) ? RelationRules.Fingerprint(current) : null;
            var state = change.Kind switch
            {
                WriteChangeKind.Remove when before is { } removed => PrintOf(removed.Key) switch
                {
                    null => 1,
                    var print when print == removed.Fingerprint => 0,
                    _ => -1,
                },
                WriteChangeKind.Add when after is { } added => PrintOf(added.Key) switch
                {
                    null => 0,
                    var print when print == added.Fingerprint => 1,
                    _ => -1,
                },
                WriteChangeKind.Replace when before is { } old && after is { } fresh =>
                    PrintOf(fresh.Key) == fresh.Fingerprint ? 1
                    : PrintOf(old.Key) == old.Fingerprint && (old.Key == fresh.Key || PrintOf(fresh.Key) is null) ? 0
                    : -1,
                _ => -1,
            };
            if (state < 0)
            {
                return WritePrecheck.Stale("Association " + change.Label + " modifiée ailleurs depuis le plan" + C
                    + "rechargez les associations puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
            }
            if (state > 0)
            {
                done++;
                continue;
            }
            if (after is { } target && !hasRecord(target.Fingerprint))
            {
                return WritePrecheck.Stale("Association " + change.Label + " préparée lors d’une session précédente" + C + "préparez de nouveau l’écriture. Rien n’a été envoyé.");
            }
            pending++;
        }
        var text = FrenchText.Count(plan.Changes.Length, "association relue", "associations relues") + C
            + (pending == 0 ? "déjà dans l’état demandé, rien ne sera écrit." : FrenchText.Count(pending, "changement à appliquer", "changements à appliquer")
                + (done > 0 ? ", " + FrenchText.Integer(done) + " déjà dans l’état demandé." : "."));
        return WritePrecheck.Valid(text);
    }

    /// <summary>
    /// Applies a plan whose preconditions were just checked: adds, replaces and removes the associations, and writes one
    /// journal line per change (« Ajoutée », « Restaurée », « Mise à jour », « Retirée »).
    /// </summary>
    public static RelationChangeResult Apply(WritePlan plan, ImmutableDictionary<string, StoredRelation> store, Func<string, StoredRelation?> record,
        Func<string, (string? Note, string? RestoresEntry)> notes, DateTimeOffset now, Func<string> newId)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(record);
        ArgumentNullException.ThrowIfNull(notes);
        ArgumentNullException.ThrowIfNull(newId);
        var builder = store.ToBuilder();
        var journal = ImmutableArray.CreateBuilder<RelationJournalRecord>();
        var applied = 0;
        var already = 0;
        var at = WritePlans.TruncateToSecond(now);
        foreach (var change in plan.Changes)
        {
            var before = Parse(change.BeforeValue);
            var after = Parse(change.AfterValue);
            if (change.Kind == WriteChangeKind.Remove)
            {
                if (before is not { } removed || !builder.TryGetValue(removed.Key, out var current))
                {
                    already++;
                    continue;
                }
                builder.Remove(removed.Key);
                var (note, _) = notes(removed.Fingerprint);
                journal.Add(new RelationJournalRecord(newId(), RelationJournalAction.Removed, at, plan.Operator, note, removed.Key, current));
                applied++;
                continue;
            }
            if (after is not { } target)
            {
                continue;
            }
            if (builder.TryGetValue(target.Key, out var existing) && RelationRules.Fingerprint(existing) == target.Fingerprint)
            {
                already++;
                continue;
            }
            var relation = record(target.Fingerprint)
                ?? throw new DomeniaOperationException(WriteErrors.Stale, "Association " + change.Label + " introuvable au moment de l’écriture" + C + "rien n’a été modifié.");
            if (before is { } replaced && replaced.Key != target.Key)
            {
                builder.Remove(replaced.Key);
            }
            builder[target.Key] = relation;
            var (text, restores) = notes(target.Fingerprint);
            var action = restores is not null ? RelationJournalAction.Restored
                : change.Kind == WriteChangeKind.Replace ? RelationJournalAction.Refreshed
                : RelationJournalAction.Added;
            journal.Add(new RelationJournalRecord(newId(), action, at, plan.Operator, restores ?? text, target.Key, relation));
            applied++;
        }
        return new RelationChangeResult(builder.ToImmutable(), journal.ToImmutable(), applied, already);
    }

    /// <summary>Postcondition (OPE-009): every association added or replaced is present with its fingerprint, every one removed is absent.</summary>
    public static WriteVerification Verify(WritePlan plan, IReadOnlyDictionary<string, StoredRelation>? store)
    {
        ArgumentNullException.ThrowIfNull(plan);
        if (store is null)
        {
            return new WriteVerification(VerificationState.Unknown, "Magasin des associations illisible à la relecture" + C + "relisez ce reçu depuis Opérations.");
        }
        var wrong = new List<string>();
        foreach (var change in plan.Changes)
        {
            var before = Parse(change.BeforeValue);
            var after = Parse(change.AfterValue);
            if (change.Kind == WriteChangeKind.Remove)
            {
                if (before is { } removed && store.TryGetValue(removed.Key, out var still) && RelationRules.Fingerprint(still) == removed.Fingerprint)
                {
                    wrong.Add(change.Label);
                }
                continue;
            }
            if (after is not { } target || !store.TryGetValue(target.Key, out var present) || RelationRules.Fingerprint(present) != target.Fingerprint)
            {
                wrong.Add(change.Label);
            }
        }
        if (wrong.Count == 0)
        {
            return new WriteVerification(VerificationState.Verified, FrenchText.Count(plan.Changes.Length, "association relue", "associations relues")
                + " dans le magasin local" + C + "état attendu confirmé.");
        }
        return new WriteVerification(VerificationState.Mismatch, FrenchText.Count(wrong.Count, "association ne correspond pas", "associations ne correspondent pas")
            + " au plan à la relecture (" + string.Join(", ", wrong.Take(3)) + (wrong.Count > 3 ? "…" : "") + ")" + C + "une autre console a pu les modifier entre-temps.");
    }

    /// <summary>Reversibility of an addition: removing the association undoes it, and the removal is journaled.</summary>
    public static WriteReversibility AddReversibility() => new(true, "Réversible",
        "« Retirer l’association » la défait ; chaque retrait est journalisé et restaurable. Active Directory n’est pas concerné.");

    /// <summary>Reversibility of a removal: « Restaurer » puts the association back from the journal.</summary>
    public static WriteReversibility RemoveReversibility() => new(true, "Réversible",
        "Chaque retrait est journalisé ; « Restaurer » remet les associations une par une, même après un redémarrage.");

    /// <summary>Reversibility of an import: « Annuler l’import » removes its batch, even after a restart.</summary>
    public static WriteReversibility ImportReversibility(string batchId) => new(true, "Réversible",
        "« Annuler l’import » retire les associations du lot " + batchId + ", y compris après un redémarrage ; chaque retrait est journalisé.");

    /// <summary>Number of changes of a plan in words (journal and summaries).</summary>
    public static string Changes(int count) => FrenchText.Count(count, "association", "associations");
}

/// <summary>Error codes of the relations screen (docs/ops/relations.md).</summary>
public static class RelationErrors
{
    public const string Unknown = "relation.unknown";
    public const string UnknownMessage = "Utilisateur ou poste introuvable dans l’index local : rien n’a été lu.";

    public const string NotRelationObject = "relation.subjectKind";
    public const string NotRelationObjectMessage = "Seuls un utilisateur ou un poste portent des relations : rien n’a été lu.";

    public const string SameKind = "relation.sameKind";
    public const string SameKindMessage = "Types opposés exigés : un utilisateur s’associe à un poste, un poste à un utilisateur. Aucune écriture préparée.";

    public const string TooMany = "relation.tooMany";

    public static string TooManyMessage(int count) =>
        FrenchText.Count(count, "association à modifier", "associations à modifier") + ", " + FrenchText.Integer(WritePlans.MaxChanges)
        + " au plus par enregistrement : rien n’a été préparé. Décochez des lignes ou procédez en plusieurs fois.";

    public const string Expired = "relation.expired";
    public const string ExpiredMessage = "Résultat expiré ou inconnu (session changée, plus de 15 minutes ou autre fenêtre) : relancez la lecture. Rien n’a été préparé.";

    public const string PlanExpired = "relation.planExpired";
    public const string PlanExpiredMessage = "Périmètre de détection expiré ou inconnu : relisez l’annuaire pour préparer un nouveau périmètre. Aucun poste contacté.";

    public const string PlanRefused = "relation.planRefused";

    public const string ProbeBusy = "relation.probeBusy";
    public const string ProbeBusyMessage = "Une détection est déjà en cours : attendez son résultat ou arrêtez-la. Aucun poste contacté en plus.";

    public const string ImportTooLarge = "relation.importTooLarge";

    public const string ImportIncomplete = "relation.importIncomplete";
    public const string ImportIncompleteMessage = "Fichier incomplet : toutes ses parties ne sont pas arrivées. Choisissez de nouveau le fichier ; rien n’a été lu.";

    public const string ImportEmpty = "relation.importEmpty";
    public const string ImportEmptyMessage = "Fichier vide ou illisible pour ce format : aucune association à prévisualiser.";

    public const string NothingToRestore = "relation.nothingToRestore";
    public const string NothingToRestoreMessage = "Aucune suppression locale à restaurer.";

    public const string AlreadyExists = "relation.alreadyExists";
    public const string AlreadyExistsMessage = "Restauration non préparée : cette association existe déjà.";

    public const string NoBatch = "relation.noBatch";
    public const string NoBatchMessage = "Aucun lot d’import présent dans les associations : rien à annuler.";

    public const string Protected = "relation.protected";
    public const string ProtectedMessage = "Association déclarée ou importée : un nettoyage automatique ne la retire jamais. Retirez-la explicitement depuis la liste si elle est fausse.";

    public const string CompareUnresolved = "relation.compareUnresolved";

    public const string NotAUser = "relation.notAUser";
    public const string NotAUserMessage = "La comparaison porte sur deux comptes utilisateurs : rien n’a été lu.";
}
