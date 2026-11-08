using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdRelationsReader
{
    public async Task<RelationOrphanCheck> OrphansAsync(CancellationToken cancellationToken)
    {
        var local = await LocalAsync(cancellationToken, withJournal: false).ConfigureAwait(false);
        var groups = local.Stored.Rows.GroupBy(r => RelationRules.Key(r.Relation), StringComparer.Ordinal).ToArray();
        var records = groups.Where(g => g.Count() == 1).Select(g => g.Single().Relation).ToArray();
        var protectedCount = records.Count(Protected);
        var candidates = records.Where(r => !Protected(r)).OrderByDescending(r => r.When).ThenBy(RelationRules.Key, StringComparer.Ordinal).ToArray();
        var rows = ImmutableArray.CreateBuilder<RelationOrphan>(); var retained = ImmutableDictionary.CreateBuilder<string, (string Fingerprint, string Reason)>(StringComparer.Ordinal);
        var checkedCount = 0; var uncertain = 0; var timedOut = false; var resultLimited = false;
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(60), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        if (candidates.Length > 0)
        {
            using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, budget.Token).ConfigureAwait(false);
            foreach (var batch in candidates.Chunk(64))
            {
                AdRelationAbsence.Result read;
                try { read = await AdRelationAbsence.CheckAsync(access, local.Directory.Domain, batch, budget.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && elapsed.IsCancellationRequested) { timedOut = true; break; }
                catch (DomeniaOperationException ex) when (ex.Code == AdErrors.Timeout) { timedOut = true; break; }
                checkedCount += batch.Length; uncertain += read.Uncertain;
                foreach (var relation in batch)
                {
                    var key = RelationRules.Key(relation);
                    if (!read.Missing.TryGetValue(key, out var reason)) { continue; }
                    if (rows.Count == 512) { resultLimited = true; break; }
                    retained.Add(key, (RelationRules.Fingerprint(relation), reason));
                    rows.Add(new(key, relation.UserLogin, relation.Computer, relation.Source, reason, relation.When,
                        RelationRules.WhenText(relation.When, source.Clock.GetUtcNow(), source.Zone), false));
                }
                if (rows.Count >= 512) { break; }
            }
            access.EnsureCurrent();
        }
        EnsureEpoch(local.Epoch);
        var held = AdRelationResults.For(source).Remember(id => new AdRelationOrphanCheck(id, local.Stored.StoreId, retained.ToImmutable()), local.Epoch);
        var summary = FrenchText.Count(checkedCount, "association contrôlée", "associations contrôlées") + " ; " + FrenchText.Count(rows.Count, "association à examiner", "associations à examiner")
            + ". Aucun objet non retrouvé n’est déclaré supprimé. Cochez les lignes à retirer localement ; aucun retrait automatique.";
        if (protectedCount > 0) { summary += " " + FrenchText.Count(protectedCount, "affectation déclarée ou importée protégée", "affectations déclarées ou importées protégées") + "."; }
        if (uncertain > 0) { summary += " " + FrenchText.Count(uncertain, "lecture non concluante écartée", "lectures non concluantes écartées") + "."; }
        if (checkedCount < candidates.Length || resultLimited) { summary += " Contrôle partiel : " + (timedOut ? "délai atteint" : "limite des résultats atteinte") + ". Relancez le contrôle après traitement des lignes affichées."; }
        if (groups.Any(g => g.Count() > 1) || local.Stored.Truncated || local.Stored.Rejected > 0) { summary += " La base comporte des lignes ambiguës ou non lues ; elles ne sont pas proposées."; }
        if (local.Stored.Truncated || local.Stored.Rejected > 0) { summary += " Les retraits restent bloqués tant que la base n’est pas entièrement lisible."; }
        return new(held.Id, checkedCount, protectedCount, rows.ToImmutable(), summary);
    }

    internal static bool Protected(StoredRelation relation) => relation.Kind is RelationKind.Assignment or RelationKind.Imported || RelationRules.IsProtectedSource(relation.Source);
}
