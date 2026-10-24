using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// Bounded, immutable result of a preview merge: the merged lines sorted OrdinalIgnoreCase (ordinal for a stable tie-break), the
/// number of names added and replaced against the local preview, and the winning remote lines (added or strictly newer). Those
/// references only prepare a future write of <c>shared:&lt;poste&gt;</c> lines; no identity, association or session is written or
/// inferred here, and the GUIDs, DNs and fingerprints of the local rows stay intact in the original snapshot.
/// </summary>
internal sealed record SharedParkMergePreview(ImmutableArray<SharedParkLine> Lines, int Added, int Replaced, ImmutableArray<SharedParkLine> RemoteWinners);

/// <summary>
/// Pure merge of one already qualified <see cref="DomeniaDatabase.SharedParkLocalRead"/> with the lines of the shared TSV: no file,
/// no SQLite, no configuration, no share, no lock, no mutation of the provided snapshot, no clock but the explicit one. The physical
/// re-read, the Exists/store/domain/revision/generation/SHA binding and the epoch control belong to the next step, before any write:
/// a summary fingerprint carried by the snapshot is never taken as proof of a database re-read or of a CAS.
/// </summary>
internal static class SharedParkMerge
{
    /// <summary>Same horizon the shared reader accepts: a line more than two minutes ahead of the explicit clock is refused.</summary>
    private static readonly TimeSpan FutureHorizon = TimeSpan.FromMinutes(2);

    /// <summary>
    /// Selects one local line per name (most recent date, then a non-empty GUID, then the ordinal storage key, whatever the entry
    /// order), then merges with the remote lines like <see cref="SyncPark.Merge"/>: an unknown name is added, a strictly newer remote
    /// date replaces the preview result, an equal date keeps the local result. The fields of the winning line are kept as they are:
    /// no invented attempt, no substituted date or status, no <c>ProbedBy</c> the local reader never exposes. This choice never
    /// certifies a remote line and never modifies a source line.
    /// </summary>
    internal static SharedParkMergePreview Preview(DomeniaDatabase.SharedParkLocalRead local, ImmutableArray<SharedParkLine> remote, DateTimeOffset now, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(local);
        token.ThrowIfCancellationRequested();
        if (remote.IsDefault) { throw new InvalidDataException("Lignes distantes non fournies ; aucune fusion n’est tentée avec un tableau absent."); }
        if (now <= DateTimeOffset.UnixEpoch) { throw new InvalidDataException("Horloge de fusion absente ou sentinelle ; aucune date n’est comparée à un zéro."); }
        if (remote.Length > SharedParkFile.MaxRows) { throw new InvalidDataException("Relevé distant au-delà des 50 000 lignes que le codec admet ; aucune fusion engagée."); }
        var horizon = now.Add(FutureHorizon);
        var localWinners = SelectLocalWinners(local, horizon, token);
        var incoming = IndexRemoteLines(remote, horizon, token);
        var lines = ImmutableArray.CreateBuilder<SharedParkLine>();
        var remoteWinners = ImmutableArray.CreateBuilder<SharedParkLine>();
        var added = 0;
        var replaced = 0;
        foreach (var (name, row) in localWinners)
        {
            token.ThrowIfCancellationRequested();
            var mine = new SharedParkLine(row.Computer, row.At!.Value, row.Status, row.UserLogin, row.Attempts, null);
            if (incoming.TryGetValue(name, out var theirs))
            {
                if (theirs.At > mine.At)
                {
                    lines.Add(theirs);
                    replaced++;
                    remoteWinners.Add(theirs);
                    continue;
                }
            }
            lines.Add(mine);
        }
        foreach (var (name, theirs) in incoming)
        {
            token.ThrowIfCancellationRequested();
            if (localWinners.ContainsKey(name)) { continue; }
            lines.Add(theirs);
            added++;
            remoteWinners.Add(theirs);
        }
        // Sorting and encoding can still take time after the walks: the token is verified before this phase, then again
        // immediately before the return, so an already granted cancellation never yields a success.
        token.ThrowIfCancellationRequested();
        ImmutableArray<SharedParkLine> ordered = [.. lines.OrderBy(line => line.Computer, StringComparer.OrdinalIgnoreCase).ThenBy(line => line.Computer, StringComparer.Ordinal)];
        ImmutableArray<SharedParkLine> orderedRemote = [.. remoteWinners.OrderBy(line => line.Computer, StringComparer.OrdinalIgnoreCase).ThenBy(line => line.Computer, StringComparer.Ordinal)];
        // The real encoded size is measured by the codec itself, never estimated: beyond 50 000 names or 16 Mio UTF-8 the whole
        // merge is refused, never truncated. The bytes are dropped on the spot: no duplicated payload travels in a plan.
        _ = SharedParkFile.Encode(ordered);
        token.ThrowIfCancellationRequested();
        return new SharedParkMergePreview(ordered, added, replaced, orderedRemote);
    }

    /// <summary>
    /// One line per name, deterministic whatever the entry order; every row is re-validated against the codec and the explicit
    /// clock, never corrected. The snapshot is validated as data: the header generation is compared to the carried survey as a
    /// data consistency check, never as a physical CAS, and the bound summary fingerprint it carries is not consulted here,
    /// because only the physical re-read of the next step can prove it.
    /// </summary>
    private static Dictionary<string, RelationSweepRecord> SelectLocalWinners(DomeniaDatabase.SharedParkLocalRead local, DateTimeOffset horizon, CancellationToken token)
    {
        var sweeps = local.Sweeps;
        ArgumentNullException.ThrowIfNull(sweeps);
        if (sweeps.Rows.IsDefault) { throw new InvalidDataException("Lignes locales non fournies ; aucune fusion n’est tentée avec un tableau absent."); }
        if (string.IsNullOrEmpty(local.StoreId) || string.IsNullOrEmpty(local.DomainDn)) { throw new InvalidDataException("Identité locale absente ; aucune fusion engagée."); }
        if (!string.Equals(local.StoreId, sweeps.StoreId, StringComparison.Ordinal)) { throw new InvalidDataException("Relevé local rattaché à un autre store que celui annoncé ; aucune fusion engagée."); }
        if (!string.Equals(local.DomainDn, sweeps.DomainDn, StringComparison.OrdinalIgnoreCase)) { throw new InvalidDataException("Relevé local rattaché à un autre domaine que celui annoncé ; aucune fusion engagée."); }
        if (local.Revision < 0) { throw new InvalidDataException("Révision locale négative ; aucune fusion engagée."); }
        if (local.Generation < 0) { throw new InvalidDataException("Génération d’en-tête négative ; aucune fusion engagée."); }
        if (sweeps.Generation < 0) { throw new InvalidDataException("Génération des relevés négative ; aucune fusion engagée."); }
        if (local.Generation != sweeps.Generation) { throw new InvalidDataException("Génération d’en-tête différente de celle du relevé porté ; aucune fusion engagée."); }
        if (sweeps.Truncated) { throw new InvalidDataException("Relevé local lu partiellement ; aucune fusion partielle n’est envisagée."); }
        if (sweeps.Rejected > 0) { throw new InvalidDataException("Relevé local contenant des lignes illisibles ; rien n’est fusionné sans une base entièrement relisible."); }
        if (sweeps.UncertainDates > 0) { throw new InvalidDataException("Relevé local contenant des dates non qualifiées ; aucune date de substitution n’est fabriquée."); }
        if (sweeps.Total < 0 || sweeps.Total != sweeps.Rows.Length || sweeps.Rows.Length > SharedParkFile.MaxRows)
        { throw new InvalidDataException("Nombre de lignes du relevé local incohérent ou hors limites ; aucune fusion engagée."); }
        if (!local.Exists && sweeps.Rows.Length > 0) { throw new InvalidDataException("Résultat absent portant des lignes ; aucune fusion n’est bâtie sur un instantané incohérent."); }
        if (!string.Equals(local.RowsFingerprint, sweeps.Fingerprint, StringComparison.Ordinal))
        { throw new InvalidDataException("Empreinte des lignes ne correspondant pas au relevé porté ; l’aperçu n’est pas bâti sur une synthèse que la relecture physique devra revalider de toute façon."); }
        var winners = new Dictionary<string, RelationSweepRecord>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in sweeps.Rows)
        {
            token.ThrowIfCancellationRequested();
            if (row.At is not { } at || at <= DateTimeOffset.UnixEpoch || at > horizon)
            { throw new InvalidDataException("Relevé local sans date réelle ou hors horizon pour « " + row.StorageKey + " » ; DateTimeOffset.MinValue n’est jamais substitué."); }
            SharedParkFile.Validate(new SharedParkLine(row.Computer, at, row.Status, row.UserLogin, row.Attempts, null));
            if (!winners.TryGetValue(row.Computer, out var incumbent) || PreferredOver(row, at, incumbent)) { winners[row.Computer] = row; }
        }
        return winners;
    }

    /// <summary>Most recent date wins; at equal dates a non-empty GUID wins, then the smaller ordinal storage key decides.</summary>
    private static bool PreferredOver(RelationSweepRecord candidate, DateTimeOffset candidateAt, RelationSweepRecord incumbent)
    {
        var incumbentAt = incumbent.At!.Value;
        if (candidateAt != incumbentAt) { return candidateAt > incumbentAt; }
        var candidateGuided = HasGuid(candidate);
        if (candidateGuided != HasGuid(incumbent)) { return candidateGuided; }
        return string.CompareOrdinal(candidate.StorageKey, incumbent.StorageKey) < 0;
    }

    private static bool HasGuid(RelationSweepRecord row) => row.ComputerGuid is { } guid && guid != Guid.Empty;

    /// <summary>Every remote line is validated by the codec and dated within the horizon; a case-insensitive duplicate refuses the whole merge.</summary>
    private static Dictionary<string, SharedParkLine> IndexRemoteLines(ImmutableArray<SharedParkLine> remote, DateTimeOffset horizon, CancellationToken token)
    {
        var incoming = new Dictionary<string, SharedParkLine>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in remote)
        {
            token.ThrowIfCancellationRequested();
            ArgumentNullException.ThrowIfNull(line);
            SharedParkFile.Validate(line);
            if (line.At <= DateTimeOffset.UnixEpoch || line.At > horizon)
            { throw new InvalidDataException("Date du relevé distant absente, sentinelle ou au-delà de deux minutes devant l’horloge ; aucune ligne n’est retenue."); }
            if (!incoming.TryAdd(line.Computer, line))
            { throw new InvalidDataException("Poste dupliqué sans distinction de casse dans le relevé distant ; le TSV ambigu n’est pas corrigé silencieusement."); }
        }
        return incoming;
    }
}
