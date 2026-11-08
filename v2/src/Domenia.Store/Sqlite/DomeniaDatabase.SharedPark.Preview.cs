using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    /// <summary>The preview spool is held for ten minutes, inside the fifteen-minute bound the spool itself enforces.</summary>
    private static readonly TimeSpan PreviewLifetime = TimeSpan.FromMinutes(10);

    /// <summary>
    /// The one real preview operation that wires the qualified local read, the shared TSV read, the merge and the bounded spool, and
    /// hands back only a compact reference plus the held lease. The local spool is qualified before any SQLite or TSV access, so an
    /// invalid local spool cannot be discovered only after a remote read. It reads nothing from configuration, invents no identity,
    /// takes no share lock, initializes or migrates nothing and publishes nothing: the durable protocol stays in the next lot. The
    /// caller must still re-read the base and the shared survey and re-qualify every path before any publication, and the future AD
    /// caller must confirm its own epoch and session are still current before retaining this result — a number passed here proves
    /// nothing about that check. Everything runs off the UI thread and honours cancellation at each transition and before delivery.
    /// </summary>
    /// <param name="tsvPath">The shared survey path, lexically qualified against the real base path and the explicit protections.</param>
    /// <param name="configFiles">Protected configuration files the TSV may never target; never read here, only compared.</param>
    /// <param name="protectedDirectories">Protected directories (Backups among them); the spool directory is added to them, none removed.</param>
    /// <param name="spoolDirectory">Dedicated local directory the proposed spool is written under.</param>
    /// <param name="sessionId">Preview session identity, a WritePlans identifier, bound into the spool and required to re-read it.</param>
    /// <param name="epoch">Expected source epoch, bound into the spool and required to re-read it.</param>
    internal Task<SharedParkPreparedPreview> PreviewSharedParkAsync(string tsvPath, ImmutableArray<string> configFiles, ImmutableArray<string> protectedDirectories,
        string spoolDirectory, string sessionId, long epoch, CancellationToken cancellationToken, Action? validateSource = null) => Task.Run(async () =>
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(tsvPath)) { throw new InvalidDataException("Chemin du relevé partagé absent ; aucune lecture engagée."); }
        if (string.IsNullOrWhiteSpace(spoolDirectory)) { throw new InvalidDataException("Répertoire de spool d’aperçu absent ; aucune écriture temporaire n’est engagée."); }
        if (string.IsNullOrWhiteSpace(sessionId) || !WritePlans.IsPlanId(sessionId)) { throw new InvalidDataException("Identifiant de session d’aperçu hors des règles WritePlans ; rien n’est lié à une session libre."); }
        if (epoch < 0) { throw new InvalidDataException("Époque de source négative ; aucun aperçu n’est lié."); }
        if (configFiles.IsDefault) { throw new InvalidDataException("Liste de fichiers de configuration protégés absente ; les protections ne sont pas ignorées."); }
        if (protectedDirectories.IsDefault) { throw new InvalidDataException("Liste de répertoires protégés absente ; les protections ne sont pas ignorées."); }
        var batchId = WritePlans.NewId();
        // The spool is qualified as local storage before any base or TSV access. Its constructor only canonicalizes and rejects a
        // redirected/network/UNC root; it creates nothing. Its canonical root then joins the protected directories without dropping
        // any caller protection, so a TSV that would land inside the spool is refused lexically before a single byte is read.
        var spool = new SharedParkPreviewSpool(spoolDirectory, clock);
        var protections = protectedDirectories.Add(spool.Root);
        SharedParkRemoteReader.Validate(tsvPath, Path, configFiles, protections, cancellationToken);

        validateSource?.Invoke();
        var local = await ReadSharedParkLocalAsync(cancellationToken).ConfigureAwait(false);
        validateSource?.Invoke();
        cancellationToken.ThrowIfCancellationRequested();
        var now = clock.GetUtcNow();
        var remote = await SharedParkRemoteReader.ReadAsync(tsvPath, Path, configFiles, protections, now, cancellationToken).ConfigureAwait(false);
        validateSource?.Invoke();
        cancellationToken.ThrowIfCancellationRequested();
        var merge = SharedParkMerge.Preview(local, remote.Rows, now, cancellationToken);
        var presentation = DescribeSharedParkPreview(local, remote.Rows, now, cancellationToken);

        var context = new SharedParkPreviewContext(batchId, sessionId, epoch, remote.Path, local.StoreId, local.DomainDn, local.Revision, local.Generation,
            local.Exists, local.Legacy, local.RowsFingerprint, local.Fingerprint, remote.Exists, remote.Sha256);
        validateSource?.Invoke();
        var lease = await spool.StageAsync(context, merge, PreviewLifetime, cancellationToken).ConfigureAwait(false);
        try
        {
            // The compact reference is built only from what was read, from the measures the lease took itself and from the merge
            // counters — never from a caller-declared summary, and never carrying an array, a payload or the spool path.
            cancellationToken.ThrowIfCancellationRequested(); validateSource?.Invoke();
            var reference = new SharedParkBatch(batchId, sessionId, epoch, remote.Path, local.StoreId, local.DomainDn, local.Revision, local.Generation,
                local.Exists, local.Legacy, local.RowsFingerprint, local.Fingerprint, remote.Exists, remote.Sha256,
                lease.Metadata.CreatedAt, lease.Metadata.ExpiresAt, lease.Rows, lease.PayloadBytes, lease.Sha256, merge.Added, merge.Replaced);
            cancellationToken.ThrowIfCancellationRequested();
            return new SharedParkPreparedPreview(new SharedParkPreviewInfo(reference, remote.Rows.Length, presentation.Kept,
                presentation.Differences, presentation.Truncated), lease);
        }
        catch
        {
            // Between staging and delivery, an cancellation or a failure must not strand the reservation: close the lease we just took.
            lease.Dispose();
            throw;
        }
    }, cancellationToken);

    /// <summary>Read-only precheck. It re-derives the proposal and repeats the local observation across the TSV read; Apply still
    /// performs the locked double CAS and physical-copy checks. No precheck is a reservation of either source.</summary>
    internal Task<WritePrecheck> CheckSharedParkPreviewAsync(SharedParkPreparedPreview preview, ImmutableArray<string> configs,
        ImmutableArray<string> protectedDirectories, Action validateSource, CancellationToken token) => Task.Run(async () =>
    {
        var batch = preview.Reference; validateSource(); ValidateSharedParkBackupBatch(batch);
        var proposed = await preview.ReadProposedAsync(batch.SessionId, batch.Epoch, token).ConfigureAwait(false); validateSource();
        var local = await ReadSharedParkLocalAsync(token).ConfigureAwait(false); validateSource(); MatchSharedParkBackupLocal(batch, local);
        var remote = await SharedParkRemoteReader.ReadAsync(batch.Path, Path, configs, protectedDirectories, clock.GetUtcNow(), token).ConfigureAwait(false);
        validateSource(); MatchSharedParkBackupRemote(batch, remote);
        var merge = SharedParkMerge.Preview(local, remote.Rows, clock.GetUtcNow(), token);
        if (merge.Added != batch.Added || merge.Replaced != batch.Replaced || merge.Lines.Length != batch.MergedRows
            || proposed.LongLength != batch.PayloadBytes || SharedParkFile.Hash(proposed) != batch.ProposedSha256
            || !SharedParkFile.Encode(merge.Lines).AsSpan().SequenceEqual(proposed))
        { throw new InvalidDataException("Fusion ou spool différent de l’aperçu retenu."); }
        MatchSharedParkBackupLocal(batch, await ReadSharedParkLocalAsync(token).ConfigureAwait(false));
        validateSource(); token.ThrowIfCancellationRequested(); ValidateSharedParkBackupBatch(batch);
        return WritePrecheck.Valid("Sources et octets proposés relus ; l’exécution devra encore obtenir son verrou et revérifier les deux sources.");
    }, token);

    private static (int Kept, ImmutableArray<ParkMergeRow> Differences, bool Truncated) DescribeSharedParkPreview(
        SharedParkLocalRead local, ImmutableArray<SharedParkLine> remote, DateTimeOffset now, CancellationToken token)
    {
        // Use the merger's exact native/GUID/date/tie ordering, not a second interpretation of local names.
        var mine = SharedParkMerge.SelectLocalWinners(local, now.AddMinutes(2), token);
        var theirs = remote.ToDictionary(row => row.Computer, StringComparer.OrdinalIgnoreCase);
        var kept = 0; var count = 0; var rows = ImmutableArray.CreateBuilder<ParkMergeRow>(128);
        foreach (var name in mine.Keys.Concat(theirs.Keys).Distinct(StringComparer.OrdinalIgnoreCase)
            .Order(StringComparer.OrdinalIgnoreCase).ThenBy(name => name, StringComparer.Ordinal))
        {
            token.ThrowIfCancellationRequested(); mine.TryGetValue(name, out var localRow); theirs.TryGetValue(name, out var sharedRow);
            if (localRow is not null && (sharedRow is null || localRow.At!.Value > sharedRow.At)) { kept++; }
            if (localRow is not null && sharedRow is not null && localRow.At == sharedRow.At) { continue; }
            count++;
            if (rows.Count == 128) { continue; }
            var sharedWins = localRow is null || sharedRow is not null && sharedRow.At > localRow.At!.Value;
            var status = sharedWins ? sharedRow!.Status : localRow!.Status;
            var detail = localRow is null ? "Relevé d’une autre console" : sharedRow is null ? "Relevé local à ajouter au partage"
                : sharedWins ? "Le partage est plus récent" : "Cette console est plus récente";
            rows.Add(new(localRow?.Computer ?? sharedRow!.Computer, localRow?.At, sharedRow?.At, sharedWins ? "shared" : "local",
                detail + SyncText.C + SyncPark.StatusLabel(SharedParkIdentity.Status(status))));
        }
        token.ThrowIfCancellationRequested();
        return (kept, rows.ToImmutable(), count > rows.Count);
    }
}

/// <summary>
/// The owner handed back by a preview: compact reference, at most 128 presentation differences and the one held lease. It keeps no SQLite survey, no remote bytes,
/// no merged array and no remote winners in any field. An explicit proposed read delegates to the held handle with the expected
/// session and epoch, so the proposed bytes are re-read from disk and re-verified every time; <see cref="Dispose"/> closes that lease
/// and hands its reservation back. A read after disposal is refused by the spool’s own guards, never by reopening the file by name.
/// </summary>
internal sealed class SharedParkPreparedPreview : IDisposable
{
    private readonly SharedParkPreviewFile lease;
    private int disposed;

    internal SharedParkPreviewInfo Info { get; }
    internal SharedParkBatch Reference => Info.Batch;

    internal SharedParkPreparedPreview(SharedParkPreviewInfo info, SharedParkPreviewFile lease)
    {
        ArgumentNullException.ThrowIfNull(info);
        ArgumentNullException.ThrowIfNull(lease);
        Info = info;
        this.lease = lease;
    }

    /// <summary>Delegates the proposed-bytes read to the held handle, which re-checks the session, the epoch, the size, the header and
    /// the SHA, and refuses an expired or closed lease. Nothing is cached here.</summary>
    internal Task<byte[]> ReadProposedAsync(string expectedSessionId, long expectedEpoch, CancellationToken cancellationToken)
        => lease.ReadProposedAsync(expectedSessionId, expectedEpoch, cancellationToken);

    /// <summary>Idempotent: closes the one lease this owner holds, which deletes only its own spool file and frees its own reservation.</summary>
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) == 0) { lease.Dispose(); }
    }
}
