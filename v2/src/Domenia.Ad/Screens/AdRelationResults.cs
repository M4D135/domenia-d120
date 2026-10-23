using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Ad;

internal sealed record AdRelationImportPreview(RelationImportPreview Preview, ImmutableArray<StoredRelation> Importable, string StoreId);
internal sealed record AdRelationOrphanCheck(string Id, string StoreId, ImmutableDictionary<string, (string Fingerprint, string Reason)> Rows);
internal sealed record AdRelationObservationSet(string Id, string Origin, ImmutableDictionary<string, StoredRelation> Relations);
internal sealed record AdRelationProbePlan(RelationDetectionPlan Plan, string Mode, RelationObject? Subject, ImmutableArray<RelationCandidate> Candidates,
    ImmutableDictionary<Guid, RelationObject> Targets, ImmutableDictionary<Guid, string> Hosts, long AccessVersion, long MachineGeneration);

/// <summary>Bounded results held by the native engine. Browser identifiers never supply the records of a write.</summary>
internal sealed class AdRelationResults(AdDirectorySource source)
{
    private static readonly ConditionalWeakTable<AdDirectorySource, AdRelationResults> Instances = new();
    private readonly Lock gate = new();
    private readonly Dictionary<string, (DateTimeOffset Expires, object Value)> results = new(StringComparer.Ordinal);
    private long epoch = source.Epoch;
    private bool probing;
    internal static AdRelationResults For(AdDirectorySource source) => Instances.GetValue(source, static s => new(s));
    internal T Remember<T>(Func<string, T> create, long expectedEpoch) where T : class
    {
        lock (gate)
        {
            Purge(expectedEpoch);
            if (results.Count >= 16) { throw new DomeniaOperationException(RelationErrors.Expired, "Trop de résultats en attente ; attendez l’expiration des précédents avant un nouvel aperçu."); }
            var id = WritePlans.NewId(); var value = create(id);
            if (value is AdRelationObservationSet observations && (observations.Origin.Length is 0 or > 80 || observations.Relations.Count > 4096
                || observations.Relations.Sum(p => (long)p.Key.Length + p.Value.UserLogin.Length + p.Value.Computer.Length + p.Value.Source.Length
                    + (p.Value.UserDn?.Length ?? 0) + (p.Value.ComputerDn?.Length ?? 0) + (p.Value.Details?.Length ?? 0)) > 2 * 1024 * 1024))
            { throw new DomeniaOperationException(RelationErrors.TooMany, "Résultat d’observations trop volumineux pour être conservé ; réduisez le périmètre."); }
            results.Add(id, (source.Clock.GetUtcNow().AddMinutes(15), value)); return value;
        }
    }
    internal T Recall<T>(string id, long expectedEpoch) where T : class
    {
        lock (gate)
        {
            Purge(expectedEpoch);
            return results.TryGetValue(id, out var entry) && entry.Value is T value ? value
                : throw new DomeniaOperationException(RelationErrors.Expired, "Résultat absent, expiré ou d’une autre session ; relancez l’aperçu.");
        }
    }
    internal T Take<T>(string id, long expectedEpoch) where T : class
    {
        lock (gate)
        {
            var value = Recall<T>(id, expectedEpoch); results.Remove(id); return value;
        }
    }
    internal string RememberObservations(string origin, ImmutableDictionary<string, StoredRelation> observations, long expectedEpoch)
    {
        try { return Remember(id => new AdRelationObservationSet(id, origin, observations), expectedEpoch).Id; }
        catch (DomeniaOperationException ex) when (ex.Code == RelationErrors.Expired)
        {
            // A full preview pool must not hide a completed native read. The producer has already queued its evidence.
            return RelationChange.SessionResultId;
        }
    }
    internal bool BeginProbe(long expectedEpoch)
    {
        lock (gate) { Purge(expectedEpoch); if (probing) { return false; } probing = true; return true; }
    }
    internal void EndProbe() { lock (gate) { probing = false; } }
    internal ImmutableArray<(AdRelationObservationSet Set, DateTimeOffset Expires)> ObservationSets(long expectedEpoch)
    {
        lock (gate) { Purge(expectedEpoch); return [.. results.Values.Where(r => r.Value is AdRelationObservationSet).Select(r => ((AdRelationObservationSet)r.Value, r.Expires))]; }
    }
    internal void ForgetSavedObservations(RelationCacheSnapshot stored, long expectedEpoch)
    {
        if (stored.Truncated || stored.Rejected > 0) { return; }
        lock (gate)
        {
            Purge(expectedEpoch);
            foreach (var pair in results.Where(r => r.Value.Value is AdRelationObservationSet).ToArray())
            {
                try
                {
                    var set = (AdRelationObservationSet)pair.Value.Value;
                    if (AdRelationSession.PrepareItems(stored, set.Relations.Values).Length == 0) { results.Remove(pair.Key); }
                }
                catch (DomeniaOperationException) { /* Ambiguous storage is not an acknowledgement. */ }
            }
        }
    }
    private void Purge(long expectedEpoch)
    {
        if (epoch != source.Epoch) { results.Clear(); epoch = source.Epoch; }
        if (expectedEpoch != epoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée ; ancien résultat écarté."); }
        foreach (var id in results.Where(p => p.Value.Expires <= source.Clock.GetUtcNow()).Select(p => p.Key).ToArray()) { results.Remove(id); }
    }
}
