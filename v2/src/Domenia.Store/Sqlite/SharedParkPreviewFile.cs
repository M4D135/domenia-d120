using System.Collections.Immutable;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// What the caller binds to one staged preview, exactly as the qualified read produced it: the source epoch, the canonical TSV
/// path, the store and domain identities, the local revision AND the local header generation, whether the local survey exists and
/// whether the base is inherited, the exhaustive rows fingerprint and the local fingerprint, whether the shared TSV exists and the
/// SHA of its bytes. These fields describe a read; they never prove a database re-read or a CAS, and the caller must still re-read
/// and re-qualify everything before any publication. Nothing is read from configuration, from the base or from a share here.
/// </summary>
internal sealed record SharedParkPreviewContext(string BatchId, string SessionId, long Epoch, string Path, string StoreId, string DomainDn,
    long Revision, long Generation, bool LocalExists, bool Legacy, string RowsFingerprint, string LocalFingerprint,
    bool RemoteExists, string RemoteSha256);

/// <summary>
/// Immutable metadata of one staged spool: the bound context, the creation and expiration instants measured by the clock given to
/// the component, and the measures the component took itself (rows, exact proposed byte count, SHA of the proposed bytes). A lease
/// exposes nothing else: no local, remote or merged array is ever kept after <c>Stage</c>.
/// </summary>
internal sealed record SharedParkPreviewMetadata(string BatchId, string SessionId, long Epoch, string Path, string StoreId, string DomainDn,
    long Revision, long Generation, bool LocalExists, bool Legacy, string RowsFingerprint, string LocalFingerprint,
    bool RemoteExists, string RemoteSha256, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, int Rows, long PayloadBytes, string Sha256);

/// <summary>
/// The one private local file of one preview lot: a bounded compact header line (64 Kio au plus, scalars only — the three arrays
/// are never encoded as JSON) followed by the proposed TSV bytes exactly as <see cref="SharedParkFile.Encode"/> produced them.
/// The file is created once, with its private DACL already applied, and that very handle is kept without write or delete sharing
/// until <see cref="Dispose"/>; the DACL is read back from the handle, never from the name. Every read re-checks the size, the
/// header against the immutable metadata and the SHA of the bytes. An expired, abandoned or disposed lease is unusable and never
/// reopens the file by its name. This file is a temporary spool: it is not a durable write journal and never a receipt of success.
/// </summary>
internal sealed class SharedParkPreviewFile : IDisposable
{
    /// <summary>Hard bound of the header line, the payload itself staying bounded by the codec (16 Mio, 50 000 lignes).</summary>
    internal const int MaxHeaderBytes = 64 * 1024;

    /// <summary>Process-wide bounds, admitted atomically under one gate.</summary>
    internal const int MaxActiveLeases = 8;

    internal const long MaxReservedBytes = 128L * 1024 * 1024;
    internal const long MinFreeBytes = 32L * 1024 * 1024;
    internal static readonly TimeSpan MaxLifetime = TimeSpan.FromMinutes(15);
    private static readonly Lock Admission = new();
    private static readonly Dictionary<string, Reservation> Active = [];
    private static long reservedBytes;

    private readonly Lock gate = new();
    private readonly TimeProvider clock;
    private FileStream? stream;

    /// <summary>
    /// The reservation this lease owns, and this one only. Cleared by the first <see cref="Dispose"/> so a stale lease can never
    /// release a later reservation that happens to live at the same path.
    /// </summary>
    private Reservation? reservation;

    internal SharedParkPreviewMetadata Metadata { get; }

    internal string Path { get; }

    /// <summary>Measured size of the held file, header included.</summary>
    internal long Bytes { get; }

    internal int Rows => Metadata.Rows;

    internal long PayloadBytes => Metadata.PayloadBytes;

    internal string Sha256 => Metadata.Sha256;

    /// <summary>Reservation accounting, exposed only as a diagnostic so the tests can prove nothing leaks after a refusal.</summary>
    internal static long ReservedBytes
    {
        get
        {
            lock (Admission)
            {
                return reservedBytes;
            }
        }
    }

    internal static int ActiveLeases
    {
        get
        {
            lock (Admission)
            {
                return Active.Count;
            }
        }
    }

    internal SharedParkPreviewFile(string path, FileStream stream, SharedParkPreviewMetadata metadata, long bytes, TimeProvider clock, Reservation reservation)
    {
        Path = path;
        this.stream = stream;
        Metadata = metadata;
        Bytes = bytes;
        this.clock = clock;
        this.reservation = reservation;
    }

    /// <summary>
    /// Atomic admission of one spool of <paramref name="bytes"/> bytes for the lot <paramref name="path"/>: the expired leases are
    /// closed and freed first, then the count and the byte caps are checked and the reservation taken in the same critical section.
    /// The returned token is the only way back to that reservation. No timer, no service, no startup scan, no automatic recovery.
    /// </summary>
    internal static Reservation Admit(string path, long bytes, DateTimeOffset expiresAt, TimeProvider clock)
    {
        CloseExpired();
        lock (Admission)
        {
            if (Active.ContainsKey(path)) { throw new InvalidDataException("Un seul fichier local privé par lot d’aperçu ; le spool de ce lot est déjà tenu."); }
            if (Active.Count >= MaxActiveLeases) { throw new InvalidDataException("Au plus " + MaxActiveLeases + " spools d’aperçu actifs par processus ; aucune admission partielle."); }
            if (reservedBytes > MaxReservedBytes - bytes) { throw new IOException("Au plus " + MaxReservedBytes + " octets de spools d’aperçu par processus ; rien n’est écrit à moitié."); }
            reservedBytes = checked(reservedBytes + bytes);
            var reservation = new Reservation(path, Guid.NewGuid(), bytes, expiresAt, clock, null);
            Active.Add(path, reservation);
            return reservation;
        }
    }

    /// <summary>Binds the admitted reservation to the lease that really owns the held handle, after checking the token.</summary>
    internal static void Attach(string path, Reservation reservation, SharedParkPreviewFile lease)
    {
        ArgumentNullException.ThrowIfNull(reservation);
        ArgumentNullException.ThrowIfNull(lease);
        lock (Admission)
        {
            if (!Active.TryGetValue(path, out var current) || current.Token != reservation.Token)
            { throw new IOException("Réservation du spool d’aperçu perdue ou reprise par un autre lot ; rien n’est remis."); }
            Active[path] = current with { Lease = lease };
        }
    }

    /// <summary>Releases a reservation this caller still owns: the token must still be the one registered at that path, so a stale
    /// lease or a stale staging can never free the reservation of a later one. Idempotent.</summary>
    internal static void Release(Reservation reservation)
    {
        ArgumentNullException.ThrowIfNull(reservation);
        lock (Admission)
        {
            if (Active.TryGetValue(reservation.Path, out var current) && current.Token == reservation.Token)
            {
                Active.Remove(reservation.Path);
                reservedBytes -= reservation.Bytes;
            }
        }
    }

    /// <summary>Closes and frees the leases whose horizon has passed, on the operation that notices it (Stage or Read). Each slot is
    /// judged with its own clock, never with the clock of whoever triggers the sweep. Under the admission gate the sweep only SELECTS
    /// the expired leases: it never removes a slot nor decrements the reserved bytes there, so a concurrent admission can never take
    /// the place or the bytes of a lease whose handle is still open. The physical close happens outside the gate, and each lease hands
    /// its own reservation back by token only after its file is really closed. A slot still owned by an in-flight staging (no lease
    /// yet) is left alone: its owner releases it. Never a timer, never a service, never a startup scan.</summary>
    internal static void CloseExpired()
    {
        List<SharedParkPreviewFile>? expired = null;
        lock (Admission)
        {
            foreach (var slot in Active.Values.ToArray())
            {
                var lease = slot.Lease;
                if (lease is null) { continue; }
                if (slot.ExpiresAt > slot.Clock.GetUtcNow()) { continue; }
                (expired ??= []).Add(lease);
            }
        }
        if (expired is null) { return; }
        foreach (var lease in expired) { lease.Dispose(); }
    }

    /// <summary>
    /// Explicit read of the proposed bytes only, from the handle already held: the expired leases (this one included) are closed
    /// first, the session and the epoch are compared to the immutable metadata, then size, header, bytes and SHA are re-read. The
    /// horizon is verified again once the lock is held and again before the bytes are returned. The bytes are built for the caller
    /// and never kept in a field of this lease.
    /// </summary>
    internal Task<byte[]> ReadProposedAsync(string expectedSessionId, long expectedEpoch, CancellationToken token)
        => Task.Run(() => Read(expectedSessionId, expectedEpoch, token), token);

    /// <summary>Same read on the calling thread, used by <c>Stage</c> to verify its own file before handing the lease out.</summary>
    internal byte[] ReadProposed(string expectedSessionId, long expectedEpoch, CancellationToken token) => Read(expectedSessionId, expectedEpoch, token);

    private byte[] Read(string expectedSessionId, long expectedEpoch, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(expectedSessionId);
        // The sweep closes the expired leases first, this one included. But an expiration can still appear after that sweep, while this
        // operation waits for the gate or during the physical reread: the two horizon checks below then refuse, and this operation must
        // close and free its OWN lease too, never hand back an expired byte, and never do it under the gate (Dispose takes that gate).
        CloseExpired();
        Require(string.Equals(expectedSessionId, Metadata.SessionId, StringComparison.Ordinal), "Spool d’aperçu demandé par une autre session que celle qui l’a créé ; rien n’est réutilisé.");
        Require(expectedEpoch == Metadata.Epoch, "Spool d’aperçu demandé sous une autre époque de source ; rien n’est réutilisé.");
        string? expiredCause = null;
        byte[]? payload = null;
        lock (gate)
        {
            token.ThrowIfCancellationRequested();
            if (clock.GetUtcNow() >= Metadata.ExpiresAt)
            {
                expiredCause = "Spool d’aperçu expiré ; la relecture physique de la base et du relevé partagé reste obligatoire avant toute publication.";
            }
            else
            {
                var file = stream ?? throw new InvalidDataException("Spool d’aperçu fermé ou abandonné ; il n’est jamais rouvert par son nom.");
                if (file.Length != Bytes) { throw new InvalidDataException("Taille du spool d’aperçu différente de son reçu ; aucun octet réutilisé."); }
                file.Position = 0;
                var line = ReadHeaderLine(file, token);
                Header? header;
                try { header = JsonSerializer.Deserialize<Header>(line); }
                catch (JsonException ex) { throw new InvalidDataException("En-tête du spool d’aperçu illisible ; aucun octet réutilisé.", ex); }
                RequireBound(header);
                file.Position = (long)line.Length + 1;
                var proposed = new byte[checked((int)Metadata.PayloadBytes)];
                file.ReadExactly(proposed);
                token.ThrowIfCancellationRequested();
                if (file.ReadByte() != -1) { throw new InvalidDataException("Spool d’aperçu agrandi après ses octets proposés ; rien n’est utilisé."); }
                if (Convert.ToHexStringLower(SHA256.HashData(proposed)) != Metadata.Sha256) { throw new InvalidDataException("Empreinte des octets proposés différente ; aucun octet réutilisé."); }
                if (clock.GetUtcNow() >= Metadata.ExpiresAt) { expiredCause = "Spool d’aperçu expiré pendant la relecture ; aucun octet proposé n’est remis."; }
                else { payload = proposed; }
            }
        }
        if (expiredCause is not null)
        {
            // Outside the gate, so Dispose can take it: the refusal of this very operation closes its own held file and hands its own
            // reservation back by token, exactly as the sweep would have, and no expired byte is ever returned.
            Dispose();
            throw new InvalidDataException(expiredCause);
        }
        token.ThrowIfCancellationRequested();
        return payload!;
    }

    /// <summary>Bounded single header line: never empty, never a carriage return, never beyond 64 Kio, never without its end.</summary>
    private static byte[] ReadHeaderLine(FileStream file, CancellationToken token)
    {
        var buffer = new byte[MaxHeaderBytes + 1];
        var read = 0;
        while (read < buffer.Length)
        {
            token.ThrowIfCancellationRequested();
            var got = file.Read(buffer.AsSpan(read));
            if (got == 0) { break; }
            read += got;
            var end = Array.IndexOf(buffer, (byte)'\n', 0, read);
            if (end < 0) { continue; }
            if (end == 0) { throw new InvalidDataException("En-tête du spool d’aperçu absent."); }
            if (buffer[end - 1] == (byte)'\r') { throw new InvalidDataException("Retour chariot dans l’en-tête du spool d’aperçu ; format ambigu refusé."); }
            if (end > MaxHeaderBytes) { throw new InvalidDataException("En-tête du spool d’aperçu au-delà de 64 Kio."); }
            return buffer[..end].ToArray();
        }
        throw new InvalidDataException("En-tête du spool d’aperçu sans fin de ligne ou au-delà de 64 Kio.");
    }

    /// <summary>Every persisted field is compared to the immutable metadata: nothing read from disk is ever taken as a summary.</summary>
    private void RequireBound(Header? header)
    {
        var m = Metadata;
        Require(header is not null, "En-tête du spool d’aperçu absent.");
        Require(header!.Version == 1, "Version d’en-tête du spool d’aperçu inconnue.");
        Require(header.BatchId == m.BatchId && header.SessionId == m.SessionId && header.Epoch == m.Epoch, "Identité de lot, de session ou époque de l’en-tête différente du contexte lié.");
        Require(header.Path == m.Path && header.StoreId == m.StoreId && header.DomainDn == m.DomainDn, "Chemin du relevé ou identité de base de l’en-tête différent du contexte lié.");
        Require(header.Revision == m.Revision && header.Generation == m.Generation && header.LocalExists == m.LocalExists && header.Legacy == m.Legacy,
            "Révision, génération, existence locale ou héritage de l’en-tête différents du contexte lié : un instantané absent n’est jamais confondu avec un instantané vide.");
        Require(header.RowsFingerprint == m.RowsFingerprint && header.LocalFingerprint == m.LocalFingerprint && header.RemoteExists == m.RemoteExists && header.RemoteSha256 == m.RemoteSha256,
            "Empreintes ou existence distante de l’en-tête différentes du contexte lié.");
        Require(header.CreatedAtMs == m.CreatedAt.ToUnixTimeMilliseconds() && header.ExpiresAtMs == m.ExpiresAt.ToUnixTimeMilliseconds(), "Instants de l’en-tête différents du contexte lié.");
        Require(header.Rows == m.Rows && header.PayloadBytes == m.PayloadBytes && header.Sha256 == m.Sha256, "Mesures de l’en-tête différentes des mesures prises à l’écriture.");
    }

    internal static Header HeaderOf(SharedParkPreviewMetadata m) => new(1, m.BatchId, m.SessionId, m.Epoch, m.Path, m.StoreId, m.DomainDn,
        m.Revision, m.Generation, m.LocalExists, m.Legacy, m.RowsFingerprint, m.LocalFingerprint, m.RemoteExists, m.RemoteSha256,
        m.CreatedAt.ToUnixTimeMilliseconds(), m.ExpiresAt.ToUnixTimeMilliseconds(), m.Rows, m.PayloadBytes, m.Sha256);

    private static void Require(bool condition, string cause)
    {
        if (!condition) { throw new InvalidDataException(cause); }
    }

    /// <summary>Idempotent: the held handle is closed once (its <see cref="FileOptions.DeleteOnClose"/> removes only that owned
    /// file), and the reservation is handed back once, by token. No foreign folder is ever cleaned, no file is ever deleted by name.</summary>
    public void Dispose()
    {
        lock (gate)
        {
            stream?.Dispose();
            stream = null;
        }
        var owned = Interlocked.Exchange(ref reservation, null);
        if (owned is not null) { Release(owned); }
    }

    /// <summary>One owned reservation: its token is the only proof of ownership, its own clock is the only one that can expire it.</summary>
    internal sealed record Reservation(string Path, Guid Token, long Bytes, DateTimeOffset ExpiresAt, TimeProvider Clock, SharedParkPreviewFile? Lease);

    internal sealed record Header(int Version, string BatchId, string SessionId, long Epoch, string Path, string StoreId, string DomainDn,
        long Revision, long Generation, bool LocalExists, bool Legacy, string RowsFingerprint, string LocalFingerprint,
        bool RemoteExists, string RemoteSha256, long CreatedAtMs, long ExpiresAtMs, int Rows, long PayloadBytes, string Sha256);
}

/// <summary>
/// Explicit staging of the proposed bytes outside the UI thread, off a dedicated local directory and controlled identifiers only:
/// no free path ever comes from a plan, no configuration, base or share is read, no SQLite file is initialized or migrated, and no
/// foreign directory ACL is touched. The rows, the exact size and the SHA are measured here from the codec itself, never declared
/// by the caller, and the whole request is refused beyond 50 000 rows or 16 Mio instead of being truncated.
/// </summary>
internal sealed class SharedParkPreviewSpool(string spoolRoot, TimeProvider clock)
{
    internal string Root { get; } = QualifiedRoot(spoolRoot);

    internal Task<SharedParkPreviewFile> StageAsync(SharedParkPreviewContext context, SharedParkMergePreview preview, TimeSpan lifetime, CancellationToken token)
        => Task.Run(() => Stage(context, preview, lifetime, token), token);

    internal SharedParkPreviewFile Stage(SharedParkPreviewContext context, SharedParkMergePreview preview, TimeSpan lifetime, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(preview);
        token.ThrowIfCancellationRequested();
        if (lifetime <= TimeSpan.Zero || lifetime > SharedParkPreviewFile.MaxLifetime)
        { throw new InvalidDataException("Durée de vie du spool d’aperçu hors de l’intervalle ouvert 0 – 15 minutes ; aucune écriture temporaire."); }
        var created = clock.GetUtcNow();
        if (created <= DateTimeOffset.UnixEpoch) { throw new InvalidDataException("Horloge du spool absente ou sentinelle ; aucune date d’expiration n’est fabriquée."); }
        var expires = created + lifetime;
        var bound = Bind(context, created, expires);
        if (preview.Lines.IsDefault || preview.RemoteWinners.IsDefault) { throw new InvalidDataException("Fusion absente ; aucun spool n’est bâti sur un tableau absent."); }
        if (preview.Added < 0 || preview.Replaced < 0 || preview.RemoteWinners.Length > preview.Lines.Length)
        { throw new InvalidDataException("Compteurs de fusion incohérents ; aucun spool n’est bâti sur une synthèse invérifiable."); }
        if (preview.Lines.Length > SharedParkFile.MaxRows) { throw new InvalidDataException("Fusion au-delà des 50 000 lignes que le codec admet ; aucune troncature."); }
        token.ThrowIfCancellationRequested();
        var payload = SharedParkFile.Encode(preview.Lines);
        if (payload.Length > SharedParkFile.MaxBytes) { throw new InvalidDataException("Octets proposés au-delà de 16 Mio ; aucune troncature."); }
        var sha = SharedParkFile.Hash(payload);
        token.ThrowIfCancellationRequested();
        var metadata = bound with { Rows = preview.Lines.Length, PayloadBytes = payload.Length, Sha256 = sha };
        var headerBytes = JsonSerializer.SerializeToUtf8Bytes(SharedParkPreviewFile.HeaderOf(metadata));
        if (headerBytes.Length is 0 or > SharedParkPreviewFile.MaxHeaderBytes) { throw new InvalidDataException("En-tête du spool hors de la borne de 64 Kio ; rien n’est écrit."); }
        var directory = System.IO.Path.Combine(Root, metadata.SessionId);
        var path = System.IO.Path.Combine(directory, metadata.BatchId + ".sharedpark");
        var spoolBytes = checked((long)headerBytes.Length + payload.Length + 1);
        EnsureSpace(path, spoolBytes);
        CompatibleDirectoryCache.ValidateLocalPath(path);
        var reservation = SharedParkPreviewFile.Admit(path, spoolBytes, expires, clock);
        FileStream? held = null;
        SharedParkPreviewFile? lease = null;
        try
        {
            token.ThrowIfCancellationRequested();
            Directory.CreateDirectory(directory);
            CompatibleDirectoryCache.ValidateLocalPath(path);
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("Répertoire du spool d’aperçu redirigé refusé."); }
            var (security, principals) = PrivateSecurity();
            // One single creation: the private DACL is applied by the create itself and the handle is never released, so there is no
            // replaceable window between a create and an open, and no ACL is ever set through a name.
            held = FileSystemAclExtensions.Create(new FileInfo(path), FileMode.CreateNew,
                FileSystemRights.Read | FileSystemRights.Write | FileSystemRights.Delete | FileSystemRights.Synchronize, FileShare.Read,
                64 * 1024, FileOptions.SequentialScan | FileOptions.DeleteOnClose, security);
            VerifyPrivateAcl(held, principals);
            token.ThrowIfCancellationRequested();
            held.Write(headerBytes);
            held.WriteByte((byte)'\n');
            held.Write(payload);
            held.Flush(flushToDisk: true);
            if (held.Length != spoolBytes) { throw new InvalidDataException("Taille écrite du spool différente de la réservation ; rien n’est remis."); }
            lease = new SharedParkPreviewFile(path, held, metadata, held.Length, clock, reservation);
            held = null;
            // The same held handle is re-read before any reference leaves this method.
            lease.ReadProposed(metadata.SessionId, metadata.Epoch, token);
            token.ThrowIfCancellationRequested();
            SharedParkPreviewFile.Attach(path, reservation, lease);
            return lease;
        }
        catch
        {
            lease?.Dispose();
            held?.Dispose();
            SharedParkPreviewFile.Release(reservation);
            throw;
        }
    }

    /// <summary>Every identity, fingerprint, counter and clock value is bounded and checked before anything is created.</summary>
    private static SharedParkPreviewMetadata Bind(SharedParkPreviewContext context, DateTimeOffset created, DateTimeOffset expires)
    {
        if (context.BatchId is null || context.SessionId is null || context.Path is null || context.StoreId is null || context.DomainDn is null
            || context.RowsFingerprint is null || context.LocalFingerprint is null || context.RemoteSha256 is null)
        { throw new InvalidDataException("Chaîne obligatoire du contexte d’aperçu absente ; aucune protection n’est ignorée en silence."); }
        if (!WritePlans.IsPlanId(context.BatchId)) { throw new InvalidDataException("Identifiant de lot d’aperçu hors des règles WritePlans ; aucun chemin n’est dérivé d’un identifiant libre."); }
        if (!WritePlans.IsPlanId(context.SessionId)) { throw new InvalidDataException("Identifiant de session d’aperçu hors des règles WritePlans ; aucun chemin n’est dérivé d’un identifiant libre."); }
        if (context.Epoch < 0) { throw new InvalidDataException("Époque de source négative ; aucune liaison n’est établie."); }
        if (context.Revision < 0) { throw new InvalidDataException("Révision locale négative ; aucun spool n’est lié."); }
        if (context.Generation < 0) { throw new InvalidDataException("Génération locale négative ; aucun spool n’est lié."); }
        if (expires <= created) { throw new InvalidDataException("Expiration du spool non postérieure à sa création."); }
        var canonical = SharedParkFile.PathValue(context.Path);
        if (context.StoreId.Length is 0 or > 512 || context.StoreId.Any(char.IsControl)) { throw new InvalidDataException("Identifiant de base absent, non borné ou contenant un caractère de contrôle."); }
        QualifiedDomain(context.DomainDn);
        if (!IsSha(context.RowsFingerprint) || !IsSha(context.LocalFingerprint) || !IsSha(context.RemoteSha256)) { throw new InvalidDataException("Empreinte d’un spool d’aperçu absente ou mal formée ; rien n’est lié à un résumé invérifiable."); }
        return new SharedParkPreviewMetadata(context.BatchId, context.SessionId, context.Epoch, canonical, context.StoreId, context.DomainDn,
            context.Revision, context.Generation, context.LocalExists, context.Legacy, context.RowsFingerprint, context.LocalFingerprint,
            context.RemoteExists, context.RemoteSha256, created, expires, 0, 0, string.Empty);
    }

    /// <summary>The domain must be a real, non-empty distinguished name for the existing parser: « =invalide » or « DC= » are refused
    /// as an invalid context, and the source string stays bound exactly as received — the parser is never used to normalize it.</summary>
    private static void QualifiedDomain(string domainDn)
    {
        if (domainDn.Length is 0 or > 1024 || domainDn.Any(char.IsControl)) { throw new InvalidDataException("Domaine absent, non borné ou contenant un caractère de contrôle."); }
        ImmutableArray<RelativeName> parts;
        try { parts = DistinguishedName.Parse(domainDn); }
        catch (FormatException ex) { throw new InvalidDataException("Domaine du spool d’aperçu illisible par le parseur de noms distinctifs : « " + domainDn + " ».", ex); }
        if (parts.IsDefaultOrEmpty) { throw new InvalidDataException("Domaine du spool d’aperçu sans aucun nom distinctif relatif."); }
        foreach (var part in parts)
        {
            if (part.Type.Length == 0 || part.Value.Length == 0) { throw new InvalidDataException("Domaine du spool d’aperçu portant un nom distinctif relatif vide : « " + domainDn + " »."); }
        }
    }

    private static bool IsSha(string? value) => value is { Length: 64 } && value.All(char.IsAsciiHexDigit);

    private static string QualifiedRoot(string root)
    {
        if (root is null || root.Length is 0 or > 1024 || root.Any(char.IsControl) || !System.IO.Path.IsPathFullyQualified(root))
        { throw new InvalidDataException("Répertoire de spool d’aperçu local absolu attendu (1 024 caractères au plus, sans caractère de contrôle) ; rien n’est complété en silence."); }
        var full = System.IO.Path.GetFullPath(root);
        CompatibleDirectoryCache.ValidateLocalPath(full);
        if (Directory.Exists(full) && (new DirectoryInfo(full).Attributes & FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("Répertoire de spool d’aperçu redirigé refusé."); }
        return full.TrimEnd('\\');
    }

    /// <summary>At least 32 Mio of margin must stay free besides the bytes about to be written; the request is refused, never reduced.</summary>
    private static void EnsureSpace(string path, long needed)
    {
        if (new DriveInfo(System.IO.Path.GetPathRoot(path)!).AvailableFreeSpace < SharedParkPreviewFile.MinFreeBytes + needed)
        { throw new IOException("Moins de 32 Mio de marge disque avant le spool d’aperçu ; rien n’est créé et la base est inchangée."); }
    }

    /// <summary>Private DACL of the owned file only, exactly like the protected receipts: three principals, nothing inherited.</summary>
    private static (FileSecurity Security, SecurityIdentifier[] Principals) PrivateSecurity()
    {
        SecurityIdentifier[] principals;
        using (var identity = WindowsIdentity.GetCurrent())
        {
            principals = [identity.User ?? throw new IOException("Identité Windows absente ; le spool d’aperçu ne peut pas être rendu privé."),
                new(WellKnownSidType.LocalSystemSid, null), new(WellKnownSidType.BuiltinAdministratorsSid, null)];
        }
        var security = new FileSecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var principal in principals) { security.AddAccessRule(new FileSystemAccessRule(principal, FileSystemRights.FullControl, AccessControlType.Allow)); }
        return (security, principals);
    }

    /// <summary>The DACL is read back from the handle that owns the file, never through the name of a replaceable object. No foreign
    /// directory ACL is ever changed.</summary>
    private static void VerifyPrivateAcl(FileStream held, SecurityIdentifier[] principals)
    {
        var allowed = principals.Select(p => p.Value).Distinct(StringComparer.Ordinal).ToHashSet(StringComparer.Ordinal);
        var read = held.GetAccessControl() ?? throw new IOException("DACL du spool d’aperçu illisible depuis le handle tenu ; aucun octet proposé n’est conservé.");
        var rules = read.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        if (!read.AreAccessRulesProtected || rules.Length != allowed.Count
            || rules.Any(r => r.IsInherited || r.AccessControlType != AccessControlType.Allow || r.FileSystemRights != FileSystemRights.FullControl
                || r.InheritanceFlags != InheritanceFlags.None || r.PropagationFlags != PropagationFlags.None || !allowed.Contains(r.IdentityReference.Value))
            || !allowed.SetEquals(rules.Select(r => r.IdentityReference.Value)))
        { throw new IOException("DACL privé du spool d’aperçu non confirmé à la relecture depuis le handle tenu ; aucun octet proposé n’est conservé."); }
    }
}
