using Domenia.Core;

namespace Domenia.Ad;

/// <summary>A local generation captured before a native gesture; a completed passage is never replayed after failure.</summary>
internal sealed class AdRelationPassMemory(AdDirectorySource source, long epoch, RelationSweepCacheSnapshot? snapshot, string? issue)
{
    internal static async Task<AdRelationPassMemory> BeginAsync(AdDirectorySource source, string domainDn, long epoch, CancellationToken token)
    {
        RelationSweepCacheSnapshot? snapshot = null; string? issue = null;
        try
        {
            if (source.LocalStore is IRelationSweepWriter writer) { snapshot = await writer.ReadRelationSweepsAsync(token).ConfigureAwait(false); }
            else { issue = "Stockage des passages indisponible ; cette lecture ne mettra pas à jour la file du parc."; }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
        { issue = "Mémoire des passages illisible ; cette lecture ne mettra pas à jour la file du parc."; }
        if (snapshot is not null && !DistinguishedName.AreEqual(snapshot.DomainDn, domainDn))
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Mémoire des passages d’un autre domaine ; aucune lecture distante."); }
        EnsureCurrent(source, epoch); token.ThrowIfCancellationRequested();
        return new(source, epoch, snapshot, issue);
    }

    internal async Task<string> CompleteAsync(RelationSweepUpdate passage, CancellationToken token)
    {
        EnsureCurrent(source, epoch); token.ThrowIfCancellationRequested();
        if (snapshot is null || source.LocalStore is not IRelationSweepWriter writer) { return issue ?? "Mémoire des passages indisponible."; }
        try
        {
            var session = await source.GetSessionAsync(token).ConfigureAwait(false); EnsureCurrent(source, epoch);
            using var lease = source.AcquireWriteLease(session);
            var result = await writer.ApplyRelationSweepsAsync(new(snapshot.StoreId, WritePlans.NewId(), snapshot.Generation, [passage]), token).ConfigureAwait(false);
            EnsureCurrent(source, epoch); return result.Detail;
        }
        catch (Exception ex) when (ex is DomeniaOperationException or IOException or UnauthorizedAccessException or InvalidDataException)
        {
            EnsureCurrent(source, epoch);
            return "Passage non confirmé dans la mémoire du parc (écriture refusée ou relevés effacés entre-temps) ; aucun rejeu. Les relations qualifiées restent indépendantes.";
        }
    }

    internal static string Status(string status, bool confirmed) => confirmed ? "CONFIRME" : status switch
    {
        "VIDE" => "LU", "REFUSE" => "REFUSE", "AUTH_REJETEE" => "AUTH_REJETEE", "ARRETE" => "DELAI", _ => "ERREUR",
    };

    private static void EnsureCurrent(AdDirectorySource source, long epoch)
    {
        if (source.Epoch != epoch) { throw WriteErrors.Refusal(WriteErrors.Stale, "Session modifiée pendant la lecture ; aucun ancien passage réintroduit."); }
    }
}
