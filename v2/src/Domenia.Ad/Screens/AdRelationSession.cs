using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Shared, bounded observations from native readers that have already checked both AD identities. No account-name guessing here.</summary>
internal sealed class AdRelationSession
{
    private static readonly ConditionalWeakTable<AdDirectorySource, AdRelationSession> Sessions = new();
    private const int ObservationCapacity = 4096;
    private readonly AdDirectorySource source;
    private readonly Lock gate = new();
    private readonly SemaphoreSlim saving = new(1, 1);
    private readonly Dictionary<string, StoredRelation> observations = new(StringComparer.Ordinal);
    private long epoch;
    private AdRelationSession(AdDirectorySource source) { this.source = source; epoch = source.Epoch; }
    internal static AdRelationSession For(AdDirectorySource source) => Sessions.GetValue(source, static s => new(s));

    internal ImmutableArray<StoredRelation> Snapshot(long expectedEpoch)
    {
        lock (gate) { EnsureEpoch(expectedEpoch); return [.. observations.Values]; }
    }

    internal RelationObservationReceipt ObserveValidated(StoredRelation relation, long expectedEpoch)
    {
        lock (gate)
        {
            EnsureEpoch(expectedEpoch);
            if (ValidationError(relation) is { } invalid) { return new(false, null, invalid); }
            var key = RelationRules.Key(relation);
            if (observations.TryGetValue(key, out var previous) && previous.When is { } date && (relation.When is null || date > relation.When))
            { return new(false, key, "Observation plus ancienne que celle déjà reçue ; constat récent conservé."); }
            if (!observations.ContainsKey(key) && observations.Count >= ObservationCapacity)
            { return new(false, null, "Mémoire des observations pleine (4 096) ; aucun ancien constat évincé silencieusement."); }
            observations[key] = relation;
            return new(true, key, "Observation qualifiée conservée dans la session, en attente du stockage local.");
        }
    }

    internal string? ValidationError(StoredRelation relation)
    {
        if (relation.Kind is not (RelationKind.Console or RelationKind.RemoteSession or RelationKind.History or RelationKind.Hint)
            || relation.UserGuid is null || relation.ComputerGuid is null || relation.UserGuid == Guid.Empty || relation.ComputerGuid == Guid.Empty
            || !relation.VerifiedInAd || relation.UserDn is null || relation.ComputerDn is null
            || relation.UserLogin.Length is 0 or > 320 || relation.Computer.Length is 0 or > 255 || relation.Source.Length is 0 or > 512
            || relation.Details?.Length > 16_384 || relation.When == DateTimeOffset.MinValue || relation.When > source.Clock.GetUtcNow().AddMinutes(2)
            || relation.Kind is RelationKind.Console or RelationKind.RemoteSession && relation.When is null
            || relation.BatchId is not null || relation.Declarant is not null)
        { return "Observation non qualifiée ou hors contrat ; aucune association déduite."; }
        var domain = source.CurrentDirectory?.Domain;
        try
        {
            if (domain is null || !ScopeRules.Contains(new(domain.RootDn, "", true), relation.UserDn)
                || !ScopeRules.Contains(new(domain.RootDn, "", true), relation.ComputerDn))
            { return "Observation étrangère au domaine courant ; aucune association mémorisée."; }
        }
        catch (FormatException) { return "DN de l’observation invalide."; }
        return null;
    }

    internal async Task<RelationAutoSave> SaveAsync(long expectedEpoch, CancellationToken token)
    {
        var saved = 0; var batches = 0; string? stopped = null; var pending = Snapshot(expectedEpoch).Length;
        if (source.LocalStore is not IRelationLocalWriter writer)
        { return RelationChange.AutoSaved(0, 0, pending, "Le magasin local ne permet pas encore la mémorisation des associations."); }
        await saving.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var session = await source.GetSessionAsync(token).ConfigureAwait(false);
            EnsureEpochOutside(expectedEpoch);
            using var lease = source.AcquireWriteLease(session);
            for (var pass = 0; pass < RelationChange.MaxAutoSaveBatches; pass++)
            {
                token.ThrowIfCancellationRequested();
                var current = await writer.ReadRelationsAsync(token).ConfigureAwait(false);
                EnsureEpochOutside(expectedEpoch);
                if (current.Truncated || current.Rejected > 0)
                { stopped = "Associations locales partiellement lisibles ; lot automatique différé, observations conservées."; break; }
                var sessionRows = Snapshot(expectedEpoch);
                var ready = PrepareItems(current, sessionRows); pending = ready.Length;
                var waiting = ready.Select(i => RelationRules.Key(i.After!)).ToHashSet(StringComparer.Ordinal);
                lock (gate)
                {
                    EnsureEpoch(expectedEpoch);
                    foreach (var known in sessionRows.Where(r => !waiting.Contains(RelationRules.Key(r))))
                    {
                        var key = RelationRules.Key(known);
                        if (observations.TryGetValue(key, out var currentObservation) && SameObservation(known, currentObservation)) { observations.Remove(key); }
                    }
                }
                if (pending == 0) { break; }
                var items = ready.Take(WritePlans.MaxChanges).ToImmutableArray();
                var draft = RelationChange.Draft("Mémoriser les observations", "Mémorisation automatique", RelationChange.AutoSaveOrigin(batches + 1),
                    RelationChange.Changes(items.Length), false, items, [], RelationChange.AddReversibility(), source.Clock.GetUtcNow(), source.Zone);
                var plan = WritePlans.Seal(draft, WritePlans.NewId(), session.Account.Login, AppMode.Directory, source.Clock.GetUtcNow(), source.Zone);
                var keys = items.SelectMany(i => new[] { i.Before, i.After }).OfType<StoredRelation>().Select(RelationRules.Key).ToHashSet(StringComparer.Ordinal);
                var request = new RelationStoreWrite(current.StoreId, plan, [.. current.Rows.Where(r => keys.Contains(RelationRules.Key(r.Relation)))], items);
                var result = await writer.ApplyRelationsAsync(request, token).ConfigureAwait(false);
                EnsureEpochOutside(expectedEpoch);
                saved += result.Applied; batches++;
                // Keep only newer concurrent observations. The just-saved ones are now supplied by SQLite, not retained forever.
                lock (gate)
                {
                    EnsureEpoch(expectedEpoch);
                    foreach (var item in items)
                    {
                        var key = RelationRules.Key(item.After!);
                        if (observations.TryGetValue(key, out var observation) && SameObservation(observation, item.After!)) { observations.Remove(key); }
                    }
                }
                if (result.JournalPending != 0) { stopped = "Observations enregistrées dans SQLite ; copie du journal D1 en attente."; break; }
                if (result.Applied == 0) { break; }
            }
            var reread = await writer.ReadRelationsAsync(token).ConfigureAwait(false);
            pending = reread.Truncated || reread.Rejected > 0 ? Snapshot(expectedEpoch).Length : PrepareItems(reread, Snapshot(expectedEpoch)).Length;
        }
        catch (OperationCanceledException)
        { stopped = "Mémorisation interrompue ; les observations non acquittées restent dans la session pour une prochaine tentative."; pending = Snapshot(expectedEpoch).Length; }
        catch (Exception ex) when (ex is DomeniaOperationException or IOException or UnauthorizedAccessException or InvalidDataException)
        { stopped = "Le lot local n’a pas pu être confirmé ; observations conservées, aucun rejeu immédiat."; pending = Snapshot(expectedEpoch).Length; }
        finally { saving.Release(); }
        return RelationChange.AutoSaved(saved, batches, pending, stopped);
    }

    /// <summary>Only exact GUID keys may refresh an automatic observation; legacy names and declarations remain separate.</summary>
    internal static ImmutableArray<RelationChangeItem> PrepareItems(RelationCacheSnapshot current, IEnumerable<StoredRelation> session)
    {
        var groups = current.Rows.GroupBy(r => RelationRules.Key(r.Relation), StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.ToArray(), StringComparer.Ordinal);
        var result = ImmutableArray.CreateBuilder<RelationChangeItem>();
        foreach (var observation in session.OrderByDescending(r => r.When).ThenBy(RelationRules.Key, StringComparer.Ordinal))
        {
            var key = RelationRules.Key(observation);
            var matching = groups.GetValueOrDefault(key, []);
            if (matching.Length > 1) { throw WriteErrors.Refusal(WriteErrors.Stale, "Association ambiguë ; mémorisation automatique suspendue."); }
            var old = matching.SingleOrDefault()?.Relation;
            if (old is not null && (SameObservation(old, observation) || old.When is { } date && (observation.When is null || date > observation.When))) { continue; }
            var incoming = old is null ? observation : observation with { BatchId = old.BatchId, Declarant = old.Declarant };
            result.Add(new(old is null ? RelationChangeOperation.Add : RelationChangeOperation.Replace, old, incoming,
                "Observation native vérifiée ; aucune affectation déclarée remplacée.", null));
        }
        return result.ToImmutable();
    }

    private static bool SameObservation(StoredRelation a, StoredRelation b) => RelationRules.Fingerprint(a with { BatchId = null, Declarant = null })
        == RelationRules.Fingerprint(b with { BatchId = null, Declarant = null });
    private void EnsureEpochOutside(long expected) { lock (gate) { EnsureEpoch(expected); } }
    private void EnsureEpoch(long expected)
    {
        var active = source.Epoch;
        if (active != epoch) { observations.Clear(); epoch = active; }
        if (expected != active) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée ; observations anciennes écartées."); }
    }
}
