using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Changes of the association store in simulation (docs/ops/relations.md, docs/WRITES.md § 6): every plan reads the store and
/// the fictitious directory as the session sees them, drafts its changes with the pure rules of <see cref="RelationChange"/>, and
/// keeps the drafted records so that write.execute finds them by fingerprint. The store lives in memory only
/// (<see cref="SimulatedRelationState"/>): no network, no disk, no real effect, and Active Directory is never involved, as in
/// Domenia 1 where associations are local. Each step waits a short realistic delay (« latency/screen/write/relations/… »).
/// </summary>
public sealed class SimulatedRelationChangeExecutor : IRelationChangeExecutor
{
    private readonly SimulatedDirectorySource source;

    /// <summary>Found by WriteExecutors.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedRelationChangeExecutor(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public string Kind => RelationChange.Kind;

    private SimulatedRelationState State => SimulatedRelationState.For(source);

    private string Operator => source.World.Session.Account.Login;

    private static string C => FrenchText.Colon;

    public async Task<WritePlanDraft> PlanAssociationAsync(string subjectDn, string targetDn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(subjectDn);
        ArgumentNullException.ThrowIfNull(targetDn);
        await WaitAsync("plan", 120, 260, cancellationToken).ConfigureAwait(false);
        var state = State;
        var lookup = state.Lookup();
        // Subject and target are read again: an object deleted, moved or recreated since the search is refused.
        var subject = lookup.Find(subjectDn) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Le sujet n’existe plus dans l’annuaire fictif" + C + "aucune écriture préparée.");
        var target = lookup.Find(targetDn) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "La cible n’existe plus dans l’annuaire fictif" + C + "aucune écriture préparée.");
        if (subject.Kind == target.Kind)
        {
            throw WriteErrors.Refusal(RelationErrors.SameKind, RelationErrors.SameKindMessage);
        }
        var user = subject.Kind == RelationSubjectKind.User ? subject : target;
        var computer = subject.Kind == RelationSubjectKind.Computer ? subject : target;
        var now = WritePlans.TruncateToSecond(state.Now);
        var incoming = new StoredRelation(user.Login, user.Guid, user.Dn, computer.Name, computer.Guid, computer.Dn, RelationKind.Assignment, RelationRules.ManualSource, now,
            "Association confirmée dans Relations depuis Recherche AD manuelle.", true, Operator, null);
        var store = state.Store;
        var (refresh, existing, _) = RelationRules.Upsert(store.Values, incoming);
        var items = new List<RelationChangeItem>
        {
            refresh
                ? new RelationChangeItem(RelationChangeOperation.Replace, existing, incoming, "Association déjà déclarée" + C + "date mise à jour.", null)
                : new RelationChangeItem(RelationChangeOperation.Add, null, incoming, "Association déclarée depuis Relations.", null),
        };
        state.Hold(incoming, items[0].Note);
        var risks = new List<WriteRisk>();
        var others = store.Values.Where(r => r.ComputerGuid == computer.Guid && r.Kind == RelationKind.Assignment && r.UserGuid != user.Guid).Select(r => r.UserLogin).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (others.Count > 0)
        {
            risks.Add(new WriteRisk(Tone.Warn, computer.Name + " est déjà affecté à " + string.Join(", ", others) + C + "les deux affectations seront conservées, aucune n’est remplacée."));
        }
        var observedOthers = store.Values.Where(r => r.ComputerGuid == computer.Guid && r.Kind is RelationKind.Console or RelationKind.RemoteSession && r.UserGuid != user.Guid)
            .Select(r => r.UserLogin).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (observedOthers.Count > 0)
        {
            risks.Add(new WriteRisk(Tone.Info, "Session observée de " + string.Join(", ", observedOthers) + " sur " + computer.Name + C + "le poste sera signalé « Contradictoire », les deux relations restent visibles."));
        }
        if (!user.Enabled || !computer.Enabled)
        {
            risks.Add(new WriteRisk(Tone.Warn, (!user.Enabled ? "Le compte " + user.Login + " est désactivé" : "Le compte ordinateur " + computer.Name + " est désactivé") + C + "vérifiez que l’association reste utile."));
        }
        var title = refresh ? "Mettre à jour l’affectation déclarée" : "Associer " + (subject.Kind == RelationSubjectKind.User ? "ce poste" : "cet utilisateur");
        var summary = refresh
            ? "L’affectation déclarée " + user.Login + " → " + computer.Name + " existe déjà" + C + "sa date et son déclarant sont mis à jour."
            : user.Login + " → " + computer.Name + " sera enregistrée comme affectation déclarée (« Saisie manuelle »), à côté des relations existantes.";
        return RelationChange.Draft(title, "Association déclarée", summary, user.Login + " → " + computer.Name, true, items, risks, RelationChange.AddReversibility(), now, state.Zone);
    }

    public async Task<WritePlanDraft> PlanRemovalAsync(string key, string fingerprint, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(key);
        ArgumentNullException.ThrowIfNull(fingerprint);
        await WaitAsync("plan", 80, 180, cancellationToken).ConfigureAwait(false);
        var state = State;
        if (!state.Store.TryGetValue(key, out var relation))
        {
            throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Association introuvable" + C + "déjà retirée ou rechargée. Aucune modification.");
        }
        if (!string.Equals(RelationRules.Fingerprint(relation), fingerprint, StringComparison.Ordinal))
        {
            throw WriteErrors.Refusal(WriteErrors.Stale, "Association modifiée ailleurs depuis son affichage" + C + "rechargez les associations. Aucune modification.");
        }
        state.HoldNote(relation, "Retirée du stockage local.");
        var risks = new List<WriteRisk>();
        if (relation.Kind == RelationKind.Assignment)
        {
            risks.Add(new WriteRisk(Tone.Warn, "Affectation déclarée par un opérateur" + C + "retirez-la seulement si elle est fausse ; « Restaurer » la remet."));
        }
        else if (relation.Kind == RelationKind.Imported)
        {
            risks.Add(new WriteRisk(Tone.Info, "Association importée (lot " + (relation.BatchId ?? "inconnu") + ")" + C + "« Annuler l’import » retire tout le lot si c’est le but."));
        }
        var now = state.Now;
        return RelationChange.Draft("Retirer l’association", "Retrait d’association", RelationChange.Pair(relation) + " sera retirée du stockage local. Aucun objet Active Directory n’est modifié ; "
            + "la suppression est journalisée et peut être restaurée.", RelationChange.Pair(relation), true,
            [new RelationChangeItem(RelationChangeOperation.Remove, relation, null, "Retirée du stockage local.", null)], risks, RelationChange.RemoveReversibility(), now, state.Zone);
    }

    public async Task<WritePlanDraft> PlanRestoreAsync(string? entryId, CancellationToken cancellationToken)
    {
        await WaitAsync("plan", 80, 180, cancellationToken).ConfigureAwait(false);
        var state = State;
        var restorable = RelationRules.Restorable(state.Journal);
        var entry = (entryId is null ? restorable.FirstOrDefault() : restorable.FirstOrDefault(e => e.Id == entryId))
            ?? throw WriteErrors.Refusal(RelationErrors.NothingToRestore, RelationErrors.NothingToRestoreMessage);
        if (state.Store.Values.Any(r => RelationRules.Same(r, entry.Relation)))
        {
            throw WriteErrors.Refusal(RelationErrors.AlreadyExists, RelationErrors.AlreadyExistsMessage);
        }
        state.Hold(entry.Relation, null, entry.Id);
        var now = state.Now;
        return RelationChange.Draft(RelationRules.RestoreLabel(entry.Relation.UserLogin, entry.Relation.Computer), "Restauration d’association",
            RelationChange.Pair(entry.Relation) + ", supprimée localement " + RelationRules.WhenPhrase(entry.At, now, state.Zone) + ", sera remise depuis le journal, avec sa date et sa source d’origine.",
            RelationChange.Pair(entry.Relation), true, [new RelationChangeItem(RelationChangeOperation.Add, null, entry.Relation, null, entry.Id)], [],
            RelationChange.AddReversibility(), now, state.Zone);
    }

    public async Task<WritePlanDraft> PlanImportAsync(string previewId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(previewId);
        await WaitAsync("plan", 120, 280, cancellationToken).ConfigureAwait(false);
        var state = State;
        var holder = state.Recall<SimulatedImportPreview>(previewId);
        var store = state.Store;
        // A workstation associated since the preview is never replaced (Domenia 1 Confirm-DomeniaLinkImport).
        var linked = store.Values.Select(r => r.ComputerGuid?.ToString("D") ?? "name:" + RelationRules.ComputerKey(r.Computer)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var rows = holder.Importable.Where(r => !linked.Contains(r.ComputerGuid?.ToString("D") ?? "name:" + RelationRules.ComputerKey(r.Computer))).ToList();
        var skipped = holder.Importable.Length - rows.Count;
        if (rows.Count == 0)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune ligne à importer" + C + "chaque poste est déjà associé ou aucune ligne n’est valide. Rien n’a été préparé.");
        }
        var preview = holder.Preview;
        var note = preview.Source + " " + preview.FileName + " (lot " + preview.BatchId + ").";
        foreach (var row in rows)
        {
            state.Hold(row, note);
        }
        var risks = new List<WriteRisk>
        {
            new(Tone.Info, "Source imposée par le format" + C + FrenchText.Quote(preview.Source) + " (Importé), jamais la colonne Source du fichier ; aucun score."),
        };
        if (skipped > 0)
        {
            risks.Add(new WriteRisk(Tone.Warn, FrenchText.Count(skipped, "poste associé depuis l’aperçu est laissé", "postes associés depuis l’aperçu sont laissés") + " de côté" + C + "aucune association remplacée."));
        }
        if (preview.Counts.Deferred > 0)
        {
            risks.Add(new WriteRisk(Tone.Info, FrenchText.Count(preview.Counts.Deferred, "ligne reportée", "lignes reportées") + " au-delà de " + FrenchText.Integer(RelationImport.BatchLimit)
                + C + "importez à nouveau le même fichier ensuite, les lignes déjà importées seront reconnues."));
        }
        var now = state.Now;
        return RelationChange.Draft("Importer " + RelationChange.Changes(rows.Count), "Import d’associations",
            FrenchText.Count(rows.Count, "association sera ajoutée", "associations seront ajoutées") + " depuis " + preview.FileName + " avec la source " + FrenchText.Quote(preview.Source)
            + ". Lot de retour arrière" + C + preview.BatchId + ".", preview.Source + " · " + preview.FileName, true,
            [.. rows.Select(r => new RelationChangeItem(RelationChangeOperation.Add, null, r, note, null))], risks, RelationChange.ImportReversibility(preview.BatchId), now, state.Zone);
    }

    public async Task<WritePlanDraft> PlanImportUndoAsync(string? batchId, CancellationToken cancellationToken)
    {
        await WaitAsync("plan", 100, 220, cancellationToken).ConfigureAwait(false);
        var state = State;
        var store = state.Store;
        var batch = batchId ?? RelationProjection.LastImport(store.Values, state.Now, state.Zone)?.BatchId
            ?? throw WriteErrors.Refusal(RelationErrors.NoBatch, RelationErrors.NoBatchMessage);
        var rows = store.Values.Where(r => r.Kind == RelationKind.Imported && string.Equals(r.BatchId ?? RelationImport.BatchToken(r.Details), batch, StringComparison.Ordinal))
            .OrderBy(r => r.Computer, StringComparer.Ordinal).ToList();
        if (rows.Count == 0)
        {
            throw WriteErrors.Refusal(RelationErrors.NoBatch, RelationErrors.NoBatchMessage);
        }
        var shown = rows.Take(WritePlans.MaxChanges).ToList();
        var note = "Import annulé (lot " + batch + ").";
        foreach (var row in shown)
        {
            state.HoldNote(row, note);
        }
        var risks = new List<WriteRisk>
        {
            new(Tone.Alert, FrenchText.Count(shown.Count, "association importée sera retirée", "associations importées seront retirées") + " en une fois" + C + "vérifiez le lot avant de confirmer."),
        };
        if (rows.Count > shown.Count)
        {
            risks.Add(new WriteRisk(Tone.Info, FrenchText.Integer(WritePlans.MaxChanges) + " au plus par retrait" + C + "annulez de nouveau l’import pour les " + FrenchText.Integer(rows.Count - shown.Count) + " suivantes."));
        }
        var now = state.Now;
        var file = RelationProjection.LastImport(rows, now, state.Zone)?.FileName ?? "fichier inconnu";
        return RelationChange.Draft("Annuler l’import", "Annulation d’import",
            "Retire les " + FrenchText.Count(shown.Count, "association ajoutée", "associations ajoutées") + " par l’import de " + file + " (lot " + batch + "). Chaque retrait est journalisé ; "
            + "« Restaurer » les remet une par une. Aucun objet Active Directory n’est modifié.", "Lot " + batch, true,
            [.. shown.Select(r => new RelationChangeItem(RelationChangeOperation.Remove, r, null, note, null))], risks, RelationChange.RemoveReversibility(), now, state.Zone);
    }

    public async Task<WritePlanDraft> PlanOrphanCleanupAsync(string checkId, IReadOnlyList<string> keys, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(checkId);
        ArgumentNullException.ThrowIfNull(keys);
        if (keys.Count > WritePlans.MaxChanges)
        {
            throw WriteErrors.Refusal(RelationErrors.TooMany, RelationErrors.TooManyMessage(keys.Count));
        }
        await WaitAsync("plan", 100, 220, cancellationToken).ConfigureAwait(false);
        var state = State;
        var check = state.Recall<SimulatedOrphanCheck>(checkId);
        var store = state.Store;
        var items = new List<RelationChangeItem>();
        var kept = 0;
        foreach (var key in keys.Distinct(StringComparer.Ordinal))
        {
            // Only the rows of the check, still present, still not declared nor imported (Domenia 1 Complete-DomeniaOrphanRemoval).
            if (!check.Rows.TryGetValue(key, out var row) || !store.TryGetValue(key, out var relation) || RelationRules.IsProtectedSource(relation.Source)
                || RelationRules.Fingerprint(relation) != row.Fingerprint)
            {
                kept++;
                continue;
            }
            var note = "Orpheline" + C + row.Reason;
            state.HoldNote(relation, note);
            items.Add(new RelationChangeItem(RelationChangeOperation.Remove, relation, null, note, null));
        }
        if (items.Count == 0)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucune association orpheline à retirer" + C + "cochez au moins une ligne, ou relancez le contrôle (lignes déjà retirées ou devenues déclarées ou importées).");
        }
        var risks = new List<WriteRisk> { new(Tone.Warn, "Contrôle par nom dans l’annuaire" + C + "un objet absent peut avoir été renommé ; la suppression n’est jamais prouvée.") };
        if (kept > 0)
        {
            risks.Add(new WriteRisk(Tone.Info, FrenchText.Count(kept, "ligne conservée", "lignes conservées") + C + "déjà retirée, modifiée ou devenue déclarée ou importée depuis le contrôle."));
        }
        var now = state.Now;
        return RelationChange.Draft("Retirer les associations orphelines", "Nettoyage des orphelines",
            FrenchText.Count(items.Count, "association orpheline sera retirée", "associations orphelines seront retirées") + " du stockage local. Chaque retrait est journalisé avec son motif et restaurable.",
            RelationChange.Changes(items.Count) + " orphelines", true, items, risks, RelationChange.RemoveReversibility(), now, state.Zone);
    }

    public async Task<WritePlanDraft> PlanObservationsAsync(string resultId, IReadOnlyList<string> keys, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(resultId);
        ArgumentNullException.ThrowIfNull(keys);
        if (keys.Count > WritePlans.MaxChanges)
        {
            throw WriteErrors.Refusal(RelationErrors.TooMany, RelationErrors.TooManyMessage(keys.Count));
        }
        await WaitAsync("plan", 100, 220, cancellationToken).ConfigureAwait(false);
        var state = State;
        var set = resultId == RelationChange.SessionResultId
            ? new SimulatedObservationSet { Origin = "Observations de la session", Relations = state.Session.ToImmutableDictionary(RelationRules.Key, StringComparer.Ordinal) }
            : state.Recall<SimulatedObservationSet>(resultId);
        var store = state.Store;
        var chosen = (keys.Count == 0 ? set.Relations.Keys.Take(WritePlans.MaxChanges) : keys.Distinct(StringComparer.Ordinal)).ToList();
        var items = new List<RelationChangeItem>();
        foreach (var key in chosen)
        {
            if (!set.Relations.TryGetValue(key, out var observation))
            {
                continue;
            }
            // An observation is added next to the existing relations: it never replaces a declared assignment (another nature),
            // and the same relation only has its date and detail refreshed (Domenia 1 Resolve-DomeniaRelationUpsert).
            var (refresh, existing, reason) = RelationRules.Upsert(store.Values, observation);
            if (refresh && existing is not null && RelationRules.Fingerprint(existing) == RelationRules.Fingerprint(observation))
            {
                continue;
            }
            var merged = refresh && existing is not null ? observation with { BatchId = existing.BatchId, Declarant = existing.Declarant } : observation;
            var note = set.Origin + C + reason;
            state.Hold(merged, note);
            items.Add(refresh && existing is not null
                ? new RelationChangeItem(RelationChangeOperation.Replace, existing, merged, note, null)
                : new RelationChangeItem(RelationChangeOperation.Add, null, merged, note, null));
        }
        if (items.Count == 0)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Ces observations sont déjà enregistrées" + C + "aucune écriture préparée.");
        }
        var protectedDeclared = items.Count(i => store.Values.Any(r => r.ComputerGuid == i.After!.ComputerGuid && r.Kind == RelationKind.Assignment && r.UserGuid != i.After.UserGuid));
        var risks = new List<WriteRisk>();
        if (protectedDeclared > 0)
        {
            risks.Add(new WriteRisk(Tone.Info, FrenchText.Count(protectedDeclared, "poste a", "postes ont") + " une affectation déclarée à un autre compte" + C
                + "elle reste enregistrée ; le poste sera signalé « Contradictoire »."));
        }
        var now = state.Now;
        var kind = items[0].After!.Kind;
        return RelationChange.Draft("Enregistrer " + FrenchText.Count(items.Count, "observation", "observations"), "Enregistrement d’observations",
            FrenchText.Count(items.Count, "relation " + (kind == RelationKind.History ? "historique" : "observée") + " sera ajoutée", "relations " + (kind == RelationKind.History ? "historiques" : "observées") + " seront ajoutées")
            + " à côté des associations existantes (" + set.Origin + ")" + C + "aucune n’est retirée, aucune affectation déclarée n’est remplacée.",
            items.Count == 1 ? RelationChange.Pair(items[0].After!) : set.Origin + " · " + RelationChange.Changes(items.Count), true, items, risks, RelationChange.AddReversibility(), now, state.Zone);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await WaitAsync("check", 60, 140, cancellationToken).ConfigureAwait(false);
        var state = State;
        return RelationChange.Check(plan, state.Store, state.HasRecord);
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await WaitAsync("execute", 160, 420, cancellationToken).ConfigureAwait(false);
        var result = State.Commit(plan);
        return result.Applied > 0
            ? new WriteOutcome(WriteResult.Applied, FrenchText.Count(result.Applied, "association modifiée", "associations modifiées") + " dans la mémoire de la simulation (aucun effet réel)"
                + (result.AlreadyDone > 0 ? ", " + FrenchText.Integer(result.AlreadyDone) + " déjà dans l’état demandé." : ".") + " Journal local mis à jour.")
            : new WriteOutcome(WriteResult.NoChange, "Associations déjà dans l’état demandé" + C + "aucune écriture.");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await WaitAsync("verify", 60, 160, cancellationToken).ConfigureAwait(false);
        return RelationChange.Verify(plan, State.Store);
    }

    private Task WaitAsync(string step, int min, int max, CancellationToken cancellationToken) =>
        source.SimulateScreenLatencyAsync("write/relations/" + step, min, max, cancellationToken);
}
