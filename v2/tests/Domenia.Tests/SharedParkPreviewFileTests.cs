using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>
/// Bounded, expiring preview spool: a real private local file written off the UI thread behind one single owned handle, a compact
/// header that really binds the read it describes, and a reservation owned by a token so a stale lease can never free another lot.
/// Nothing here opens a share, reads a base, initializes SQLite or publishes anything; the durable publication protocol stays
/// entirely in the next lot.
/// </summary>
internal static class SharedParkPreviewFileTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly DateTimeOffset Now = TestClock.Reference;
    private static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(10);
    private static readonly string Store = new('0', 64);
    private static readonly string Domain = Fixtures.Root;
    private static readonly string RowsFingerprint = new('A', 64);
    private static readonly string LocalFingerprint = new('B', 64);
    private static readonly string RemoteSha = SharedParkFile.Hash([]);

    private static SharedParkLine Line(string computer, string? user = null, int attempts = 1, string? probedBy = null)
        => new(computer, Now.AddMinutes(-5), "CONFIRME", user, attempts, probedBy);

    private static SharedParkMergePreview Preview(params SharedParkLine[] lines) => new([.. lines], lines.Length, 0, []);

    private static SharedParkPreviewContext Context(string? batchId = null, string? sessionId = null, long epoch = 7, string path = @"C:\domenia-tests\parc.tsv",
        long revision = 3, long generation = 3, bool localExists = true, bool legacy = false, bool remoteExists = true, string? remoteSha = null,
        string? storeId = null, string? domainDn = null, string? rowsFingerprint = null, string? localFingerprint = null)
        => new(batchId ?? WritePlans.NewId(), sessionId ?? WritePlans.NewId(), epoch, path, storeId ?? Store, domainDn ?? Domain,
            revision, generation, localExists, legacy, rowsFingerprint ?? RowsFingerprint, localFingerprint ?? LocalFingerprint,
            remoteExists, remoteSha ?? RemoteSha);

    private static SharedParkPreviewSpool Spool(TemporaryFolder folder, FixedTimeProvider clock) => new(folder.File("spool"), clock);

    private static int HeaderLength(byte[] raw) => Array.IndexOf(raw, (byte)'\n');

    /// <summary>
    /// Bounded reader of a file still held by a lease, with the same compatible sharing the native spool test uses: the production
    /// handle keeps its protection (no write, no delete sharing) and the physical bytes are really read, never replaced by metadata.
    /// </summary>
    private static byte[] ReadHeld(string path, long announcedBytes)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        Check.Equal(announcedBytes, file.Length, "le fichier physique porte la taille annoncée par la lease");
        var bytes = new byte[checked((int)file.Length)];
        file.ReadExactly(bytes);
        return bytes;
    }

    [Test]
    public static async Task A_staged_preview_is_a_real_private_file_whose_reread_matches_the_measured_sha()
    {
        using var folder = new TemporaryFolder();
        var spool = Spool(folder, TestClock.Fixed());
        var lines = new[] { Line("PC2"), Line("PC1", "élodie.martin", 3, "dc-1") };
        var context = Context();
        var proposed = SharedParkFile.Encode([.. lines]);
        var lease = await spool.StageAsync(context, Preview(lines), Lifetime, None);
        try
        {
            Check.True(File.Exists(lease.Path), "un vrai fichier local est écrit");
            Check.True(lease.Path.StartsWith(folder.File("spool"), StringComparison.OrdinalIgnoreCase), "le chemin vient du seul répertoire dédié et des identifiants contrôlés");
            Check.True(lease.Path.EndsWith(".sharedpark", StringComparison.Ordinal), "le spool n’est pas un TSV nu ni un fichier de base");
            Check.Equal(2, lease.Rows, "le nombre de lignes est mesuré par le composant, jamais déclaré par l’appelant");
            Check.Equal(SharedParkFile.Hash(proposed), lease.Sha256, "l’empreinte est celle des octets proposés réellement encodés par le codec");
            var raw = ReadHeld(lease.Path, lease.Bytes);
            var header = HeaderLength(raw);
            Check.True(header > 0 && header <= SharedParkPreviewFile.MaxHeaderBytes, "un en-tête borné, puis les octets proposés");
            Check.Equal(lease.PayloadBytes + header + 1L, (long)raw.Length, "en-tête, sa fin de ligne et les octets proposés : rien d’autre");
            Check.Equal(SharedParkFile.Hash(raw[(header + 1)..]), lease.Sha256, "les octets physiquement présents portent bien l’empreinte annoncée");
            var reread = await lease.ReadProposedAsync(context.SessionId, context.Epoch, None);
            Check.True(reread.SequenceEqual(proposed), "la relecture rend exactement les octets du codec");
            Check.Equal(lease.Sha256, Convert.ToHexStringLower(SHA256.HashData(reread)), "l’empreinte est vérifiée sur les octets relus, pas sur un résumé");
            Check.Equal(0, Directory.EnumerateFiles(folder.Path, "*.sqlite", SearchOption.AllDirectories).Count(), "aucune base SQLite initialisée ni migrée");
            Check.Equal(0, Directory.EnumerateFiles(folder.Path, "*.db", SearchOption.AllDirectories).Count(), "aucun fichier de base créé");
        }
        finally
        {
            lease.Dispose();
        }
    }

    [Test]
    public static async Task The_compact_header_binds_exists_revision_generation_epoch_and_every_fingerprint()
    {
        using var folder = new TemporaryFolder();
        var spool = Spool(folder, TestClock.Fixed());
        var context = Context(epoch: 41, revision: 9, generation: 12, localExists: false, legacy: true, remoteExists: false, remoteSha: new string('e', 64));
        var lease = await spool.StageAsync(context, Preview(Line("PC1", "alice", 2)), Lifetime, None);
        try
        {
            var raw = ReadHeld(lease.Path, lease.Bytes);
            var end = HeaderLength(raw);
            Check.True(end > 0 && end <= SharedParkPreviewFile.MaxHeaderBytes, "un seul en-tête borné à 64 Kio");
            Check.Equal(-1, raw.AsSpan(0, end).IndexOf((byte)'\r'), "l’en-tête est une ligne unique, sans retour chariot ambigu");
            using var document = JsonDocument.Parse(raw.AsMemory(0, end));
            var root = document.RootElement;
            Check.Equal(1, root.GetProperty("Version").GetInt32(), "version d’en-tête");
            Check.Equal(context.BatchId, root.GetProperty("BatchId").GetString(), "le lot lié");
            Check.Equal(context.SessionId, root.GetProperty("SessionId").GetString(), "la session liée");
            Check.Equal(41L, root.GetProperty("Epoch").GetInt64(), "l’époque de source est liée");
            Check.Equal(9L, root.GetProperty("Revision").GetInt64(), "la révision locale est liée");
            Check.Equal(12L, root.GetProperty("Generation").GetInt64(), "la génération locale est liée en plus de la révision");
            Check.False(root.GetProperty("LocalExists").GetBoolean(), "Exists=false est conservé tel quel");
            Check.True(root.GetProperty("Legacy").GetBoolean(), "l’héritage de la base est conservé");
            Check.False(root.GetProperty("RemoteExists").GetBoolean(), "l’absence distante n’est pas perdue parce que des octets vides auraient le même SHA");
            Check.Equal(new string('e', 64), root.GetProperty("RemoteSha256").GetString(), "le SHA des octets distants est lié");
            Check.Equal(RowsFingerprint, root.GetProperty("RowsFingerprint").GetString(), "l’empreinte exhaustive des lignes est liée");
            Check.Equal(LocalFingerprint, root.GetProperty("LocalFingerprint").GetString(), "l’empreinte locale est liée");
            Check.Equal(@"C:\domenia-tests\parc.tsv", root.GetProperty("Path").GetString(), "le chemin TSV canonique est lié");
            Check.Equal(Store, root.GetProperty("StoreId").GetString(), "le store est lié");
            Check.Equal(Domain, root.GetProperty("DomainDn").GetString(), "le domaine est lié, conservé sans normalisation silencieuse");
            Check.Equal(lease.Sha256, root.GetProperty("Sha256").GetString(), "l’empreinte des octets proposés est liée");
            Check.Equal(1, root.GetProperty("Rows").GetInt32(), "le nombre de lignes mesuré est lié");
            Check.Equal(lease.PayloadBytes, root.GetProperty("PayloadBytes").GetInt64(), "la taille exacte mesurée est liée");
            Check.Equal(Now.ToUnixTimeMilliseconds(), root.GetProperty("CreatedAtMs").GetInt64(), "l’instant de création vient de l’horloge fournie");
            Check.Equal(Now.Add(Lifetime).ToUnixTimeMilliseconds(), root.GetProperty("ExpiresAtMs").GetInt64(), "l’expiration est bornée par cette même horloge");
        }
        finally
        {
            lease.Dispose();
        }
    }

    [Test]
    public static async Task An_empty_proposal_keeps_its_exists_flags_apart_from_an_absent_survey()
    {
        using var folder = new TemporaryFolder();
        var spool = Spool(folder, TestClock.Fixed());
        var context = Context(localExists: false, remoteExists: true, remoteSha: SharedParkFile.Hash([]));
        var lease = await spool.StageAsync(context, Preview(), Lifetime, None);
        try
        {
            Check.Equal(0, lease.Rows, "aucune ligne proposée");
            Check.Equal(0L, lease.PayloadBytes, "aucun octet proposé");
            Check.Equal(SharedParkFile.Hash([]), lease.Sha256, "la même empreinte du vide que le distant absent");
            Check.True(File.Exists(lease.Path), "une proposition vide est pourtant un vrai fichier tenu");
            Check.Equal(0, (await lease.ReadProposedAsync(context.SessionId, context.Epoch, None)).Length, "la relecture rend zéro octet proposé");
            var raw = ReadHeld(lease.Path, lease.Bytes);
            using var document = JsonDocument.Parse(raw.AsMemory(0, HeaderLength(raw)));
            Check.False(document.RootElement.GetProperty("LocalExists").GetBoolean(), "l’instantané local absent reste distinct d’un instantané présent vide");
            Check.True(document.RootElement.GetProperty("RemoteExists").GetBoolean(), "malgré des empreintes identiques, l’existence distante est conservée");
        }
        finally
        {
            lease.Dispose();
        }
    }

    [Test]
    public static async Task Another_session_another_epoch_or_an_advanced_clock_refuses_the_held_preview()
    {
        using var folder = new TemporaryFolder();
        var clock = TestClock.Fixed();
        var spool = Spool(folder, clock);
        var context = Context();
        var lease = await spool.StageAsync(context, Preview(Line("PC1")), Lifetime, None);
        try
        {
            await Check.ThrowsAsync<InvalidDataException>(() => lease.ReadProposedAsync(WritePlans.NewId(), context.Epoch, None), "une autre session que celle qui a créé le spool ne le lit pas");
            await Check.ThrowsAsync<InvalidDataException>(() => lease.ReadProposedAsync(context.SessionId, context.Epoch + 1, None), "une autre époque de source ne le lit pas");
            Check.True((await lease.ReadProposedAsync(context.SessionId, context.Epoch, None)).Length > 0, "le contexte attendu relit normalement");
            clock.Advance(TimeSpan.FromMinutes(11));
            var ex = await Check.ThrowsAsync<InvalidDataException>(() => lease.ReadProposedAsync(context.SessionId, context.Epoch, None), "l’horloge avancée au-delà de l’expiration refuse la relecture");
            Check.Contains("expiré", ex.Message, "le refus nomme l’expiration, jamais une absence");
        }
        finally
        {
            lease.Dispose();
        }
    }

    [Test]
    public static async Task An_expired_lease_is_refused_and_physically_closed_by_a_read_alone()
    {
        using var folder = new TemporaryFolder();
        var clock = TestClock.Fixed();
        var spool = Spool(folder, clock);
        var context = Context();
        var lease = await spool.StageAsync(context, Preview(Line("PC1")), TimeSpan.FromMinutes(5), None);
        var path = lease.Path;
        Check.Equal(1, SharedParkPreviewFile.ActiveLeases, "une lease active est comptée");
        Check.Equal(lease.Bytes, SharedParkPreviewFile.ReservedBytes, "et sa réservation est exactement la taille de son fichier");
        clock.Advance(TimeSpan.FromMinutes(6));
        var ex = await Check.ThrowsAsync<InvalidDataException>(() => lease.ReadProposedAsync(context.SessionId, context.Epoch, None),
            "une simple lecture, sans Stage ni Dispose préalable, refuse la lease expirée");
        Check.Contains("expiré", ex.Message, "le refus nomme l’expiration");
        Check.False(File.Exists(path), "la lecture qui a constaté l’expiration a aussi fermé et supprimé le fichier expiré");
        Check.Equal(0, SharedParkPreviewFile.ActiveLeases, "la place a été rendue");
        Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "les octets ont été rendus");
        lease.Dispose();
        Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "un Dispose sur une lease déjà fermée ne rend rien une deuxième fois");
    }

    [Test]
    public static async Task An_expiration_seen_at_the_gate_closes_the_lease_and_frees_its_own_reservation()
    {
        using var folder = new TemporaryFolder();
        var clock = TestClock.Fixed();
        var context = Context();
        var directory = Path.Combine(folder.File("spool"), context.SessionId);
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, context.BatchId + ".sharedpark");
        var created = TestClock.Reference;
        var expires = created + TimeSpan.FromMinutes(5);
        var lines = new[] { Line("PC1") };
        var proposed = SharedParkFile.Encode([.. lines]);
        var held = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.DeleteOnClose);
        SharedParkPreviewFile? lease = null;
        try
        {
            held.Write(proposed);
            held.Flush(flushToDisk: true);
            var bytes = held.Length;
            var metadata = new SharedParkPreviewMetadata(context.BatchId, context.SessionId, context.Epoch, context.Path, context.StoreId, context.DomainDn,
                context.Revision, context.Generation, context.LocalExists, context.Legacy, context.RowsFingerprint, context.LocalFingerprint,
                context.RemoteExists, context.RemoteSha256, created, expires, lines.Length, proposed.Length, SharedParkFile.Hash(proposed));
            // The reservation is admitted but never attached, exactly like an in-flight staging the sweep must leave alone (Lease is null):
            // the sweep therefore cannot close this spool, and only the refusal inside Read can close the held file and hand the
            // reservation back. Advancing the clock past the horizon reproduces, without any sleep, an expiration seen at the gate.
            var reservation = SharedParkPreviewFile.Admit(path, bytes, expires, clock);
            var active = new SharedParkPreviewFile(path, held, metadata, bytes, clock, reservation);
            lease = active;
            Check.True(File.Exists(path), "le spool est réellement tenu avant le refus");
            Check.Equal(1, SharedParkPreviewFile.ActiveLeases, "la réservation de ce spool est comptée");
            Check.Equal(bytes, SharedParkPreviewFile.ReservedBytes, "ses octets sont réservés");
            clock.Advance(TimeSpan.FromMinutes(6));
            var ex = await Check.ThrowsAsync<InvalidDataException>(() => active.ReadProposedAsync(context.SessionId, context.Epoch, None),
                "le balayage a laissé ce spool intacte (aucune lease attachée) et seule la relecture expirée peut le fermer");
            Check.Contains("expiré", ex.Message, "le refus nomme l’expiration");
            Check.False(File.Exists(path), "le refus d’expiration a lui-même fermé et supprimé le fichier tenu");
            Check.Equal(0, SharedParkPreviewFile.ActiveLeases, "le refus a rendu sa propre réservation, sans Stage ni Dispose préalable");
            Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "le refus a rendu ses propres octets");
        }
        finally
        {
            lease?.Dispose();
            held.Dispose();
        }
        Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "un second Dispose ne rend rien une deuxième fois");
    }

    [Test]
    public static async Task A_stale_lease_can_never_release_the_reservation_of_the_same_path()
    {
        using var folder = new TemporaryFolder();
        var spool = Spool(folder, TestClock.Fixed());
        var context = Context();
        var first = await spool.StageAsync(context, Preview(Line("PC1")), Lifetime, None);
        var path = first.Path;
        first.Dispose();
        var second = await spool.StageAsync(context, Preview(Line("PC2")), Lifetime, None);
        try
        {
            Check.Equal(path, second.Path, "le second lot reprend exactement le même chemin, avec une réservation distincte");
            first.Dispose();
            Check.Equal(1, SharedParkPreviewFile.ActiveLeases, "le second Dispose de la vieille lease n’a rien retiré : le lot en cours reste compté");
            Check.Equal(second.Bytes, SharedParkPreviewFile.ReservedBytes, "et sa réservation reste exactement celle de son fichier");
            var bytes = await second.ReadProposedAsync(context.SessionId, context.Epoch, None);
            Check.Equal(second.Sha256, SharedParkFile.Hash(bytes), "le lot en cours reste relisible");
            Check.True(File.Exists(second.Path), "et son fichier reste tenu");
        }
        finally
        {
            second.Dispose();
        }
        Check.Equal(0, SharedParkPreviewFile.ActiveLeases, "la vraie lease libère bien sa propre réservation");
        Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "rien ne reste réservé après la vraie libération");
    }

    [Test]
    public static async Task Two_components_with_their_own_clocks_never_expire_each_other()
    {
        using var folder = new TemporaryFolder();
        var slow = TestClock.Fixed();
        var fast = TestClock.Fixed();
        var first = new SharedParkPreviewSpool(folder.File("spool-a"), slow);
        var second = new SharedParkPreviewSpool(folder.File("spool-b"), fast);
        var kept = await first.StageAsync(Context(), Preview(Line("PC1")), TimeSpan.FromMinutes(5), None);
        try
        {
            fast.Advance(TimeSpan.FromMinutes(30));
            using var late = await second.StageAsync(Context(), Preview(Line("PC2")), TimeSpan.FromMinutes(5), None);
            Check.Equal(2, SharedParkPreviewFile.ActiveLeases, "l’horloge avancée d’un composant n’expire pas la lease de l’autre");
            Check.True(File.Exists(kept.Path), "le spool de l’autre composant reste tenu et présent");
            var bytes = await kept.ReadProposedAsync(kept.Metadata.SessionId, kept.Metadata.Epoch, None);
            Check.Equal(kept.Sha256, SharedParkFile.Hash(bytes), "et reste relisible par son propre contexte");
        }
        finally
        {
            kept.Dispose();
        }
        Check.Equal(0, SharedParkPreviewFile.ActiveLeases, "les deux leases ont été rendues par leurs propriétaires");
    }

    [Test]
    public static async Task A_preexisting_sentinel_at_the_spool_path_is_never_touched()
    {
        using var folder = new TemporaryFolder();
        var spool = Spool(folder, TestClock.Fixed());
        var context = Context();
        var directory = Path.Combine(spool.Root, context.SessionId);
        var sentinel = Path.Combine(directory, context.BatchId + ".sharedpark");
        Directory.CreateDirectory(directory);
        var original = new byte[] { (byte)'D', (byte)'o', (byte)'n', (byte)'e', 0x00, 0x21 };
        File.WriteAllBytes(sentinel, original);
        await Check.ThrowsAsync<IOException>(() => spool.StageAsync(context, Preview(Line("PC1")), Lifetime, None),
            "CreateNew refuse d’écraser un fichier préexistant : le spool n’est jamais ouvert en écriture d’avance");
        Check.True(original.SequenceEqual(File.ReadAllBytes(sentinel)), "la sentinelle préexistante est restée intacte, octets par octets");
        Check.Equal(0, SharedParkPreviewFile.ActiveLeases, "aucune lease n’a été admise sur un échec de création");
        Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "la réservation a été rendue après l’échec de création");
    }

    [Test]
    public static async Task A_disposed_lease_deletes_its_own_file_and_is_never_reusable()
    {
        using var folder = new TemporaryFolder();
        var spool = Spool(folder, TestClock.Fixed());
        var context = Context();
        var lease = await spool.StageAsync(context, Preview(Line("PC1")), Lifetime, None);
        var path = lease.Path;
        Check.True(File.Exists(path), "le fichier existe tant que la lease est tenue");
        lease.Dispose();
        Check.False(File.Exists(path), "seul le fichier possédé est fermé et supprimé");
        await Check.ThrowsAsync<InvalidDataException>(() => lease.ReadProposedAsync(context.SessionId, context.Epoch, None), "une lease fermée ne relit rien et ne rouvre jamais le fichier par son nom");
        lease.Dispose();
        Check.Equal(0, SharedParkPreviewFile.ActiveLeases, "un second Dispose ne retire rien une deuxième fois");
        Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "la réservation est rendue exactement une fois");
        Check.True(Directory.Exists(folder.File("spool")), "le dossier du lot n’est pas nettoyé récursivement par la lease");
    }

    [Test]
    public static async Task A_concurrent_write_or_delete_of_the_held_preview_is_refused()
    {
        using var folder = new TemporaryFolder();
        var spool = Spool(folder, TestClock.Fixed());
        var context = Context();
        var lease = await spool.StageAsync(context, Preview(Line("PC1"), Line("PC2")), Lifetime, None);
        try
        {
            Check.Throws<IOException>(() => File.WriteAllText(lease.Path, "corrompu"), "le fichier tenu n’est ouvert en écriture à personne");
            Check.Throws<IOException>(() => File.Delete(lease.Path), "le fichier tenu n’est ouvert en suppression à personne");
            Check.Throws<IOException>(() =>
            {
                using var truncate = new FileStream(lease.Path, FileMode.Truncate, FileAccess.Write, FileShare.None);
            }, "aucun ouverture en écriture avec un autre partage ne contourne le handle propriétaire");
            var bytes = await lease.ReadProposedAsync(context.SessionId, context.Epoch, None);
            Check.Equal(lease.Sha256, SharedParkFile.Hash(bytes), "la tentative de mutation n’a rien changé aux octets proposés");
            Check.Equal(lease.Bytes, ReadHeld(lease.Path, lease.Bytes).LongLength, "et n’a rien changé à la taille physique");
        }
        finally
        {
            lease.Dispose();
        }
    }

    [Test]
    public static async Task A_pre_cancelled_or_invalid_context_is_refused_before_anything_is_created()
    {
        using var folder = new TemporaryFolder();
        var spool = Spool(folder, TestClock.Fixed());
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => spool.StageAsync(Context(), Preview(Line("PC1")), Lifetime, cancelled.Token), "une annulation préalable n’écrit rien");
        var invalid = new[]
        {
            ("identifiant de lot hors règles", Context(batchId: "ZZ")),
            ("identifiant de session hors règles", Context(sessionId: "x")),
            ("époque négative", Context(epoch: -1)),
            ("révision négative", Context(revision: -1)),
            ("génération négative", Context(generation: -1)),
            ("chemin de base SQLite", Context(path: @"C:\domenia-tests\base.db")),
            ("chemin relatif", Context(path: "parc.tsv")),
            ("chemin vide", Context(path: string.Empty)),
            ("store absent", Context(storeId: string.Empty)),
            ("domaine sans forme de nom distinctif", Context(domainDn: "pas-un-domaine")),
            ("domaine commençant par un égal", Context(domainDn: "=invalide")),
            ("domaine avec un type d’attribut vide", Context(domainDn: "DC=test,=local")),
            ("domaine finissant sans valeur", Context(domainDn: "DC=test,DC=")),
            ("domaine à RDN multivalué", Context(domainDn: "DC=a+DC=b,DC=local")),
            ("empreinte de lignes trop courte", Context(rowsFingerprint: new string('a', 63))),
            ("empreinte locale non hexadécimale", Context(localFingerprint: new string('g', 64))),
            ("empreinte distante absente", Context(remoteSha: string.Empty)),
        };
        foreach (var (cause, context) in invalid)
        {
            await Check.ThrowsAsync<InvalidDataException>(() => spool.StageAsync(context, Preview(Line("PC1")), Lifetime, None), "contexte invalide : " + cause);
        }
        foreach (var lifetime in new[] { TimeSpan.Zero, TimeSpan.FromMinutes(-1), TimeSpan.FromMinutes(16) })
        {
            await Check.ThrowsAsync<InvalidDataException>(() => spool.StageAsync(Context(), Preview(Line("PC1")), lifetime, None), "durée hors de 0 – 15 minutes refusée");
        }
        await Check.ThrowsAsync<InvalidDataException>(() => Spool(folder, TestClock.Fixed(DateTimeOffset.UnixEpoch)).StageAsync(Context(), Preview(Line("PC1")), Lifetime, None), "horloge sentinelle refusée");
        Check.False(Directory.Exists(folder.File("spool")), "aucun refus n’a créé le répertoire dédié, encore moins un fichier");
        Check.Equal(0, SharedParkPreviewFile.ActiveLeases, "aucun refus n’a admis une lease");
        Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "aucun refus n’a réservé d’octets");
    }

    [Test]
    public static async Task A_missing_or_incoherent_merge_is_refused_before_any_creation()
    {
        using var folder = new TemporaryFolder();
        var spool = Spool(folder, TestClock.Fixed());
        await Check.ThrowsAsync<InvalidDataException>(() => spool.StageAsync(Context(), new SharedParkMergePreview(default, 0, 0, []), Lifetime, None), "lignes locales absentes : rien n’est spoolé");
        await Check.ThrowsAsync<InvalidDataException>(() => spool.StageAsync(Context(), new SharedParkMergePreview([], 0, 0, default), Lifetime, None), "gagnantes distantes absentes : rien n’est spoolé");
        await Check.ThrowsAsync<InvalidDataException>(() => spool.StageAsync(Context(), new SharedParkMergePreview([], -1, 0, []), Lifetime, None), "compteur négatif refusé");
        await Check.ThrowsAsync<InvalidDataException>(() => spool.StageAsync(Context(), new SharedParkMergePreview([Line("PC1")], 0, 0, [Line("PC1"), Line("PC2")]), Lifetime, None), "plus de gagnantes que de lignes fusionnées");
        await Check.ThrowsAsync<InvalidDataException>(() => spool.StageAsync(Context(), new SharedParkMergePreview([Line("PC1"), Line("pc1")], 0, 0, []), Lifetime, None), "deux postes homonymes refusés par le codec, sans écriture ambiguë");
        Check.False(Directory.Exists(folder.File("spool")), "rien n’est créé sur disque");
        Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "une fusion refusée ne réserve rien");
    }

    [Test]
    public static async Task Oversized_proposals_are_refused_as_a_whole_without_reserving_anything()
    {
        using var folder = new TemporaryFolder();
        var spool = Spool(folder, TestClock.Fixed());
        var tooMany = ImmutableArray.CreateRange(Enumerable.Range(0, SharedParkFile.MaxRows + 1).Select(i => Line("PC" + i.ToString("D6", CultureInfo.InvariantCulture))));
        await Check.ThrowsAsync<InvalidDataException>(() => spool.StageAsync(Context(), new SharedParkMergePreview(tooMany, 0, 0, []), Lifetime, None), "50 001 lignes refusées, aucune troncature");
        var user = new string('u', 320);
        var probedBy = new string('p', 320);
        var tooBig = ImmutableArray.CreateRange(Enumerable.Range(0, 26_000).Select(i => Line("PC" + i.ToString("D6", CultureInfo.InvariantCulture), user, 1, probedBy)));
        await Check.ThrowsAsync<InvalidDataException>(() => spool.StageAsync(Context(), new SharedParkMergePreview(tooBig, 0, 0, []), Lifetime, None), "plus de 16 Mio d’octets proposés refusés, aucune troncature");
        Check.False(Directory.Exists(folder.File("spool")), "aucune écriture partielle");
        Check.Equal(0, SharedParkPreviewFile.ActiveLeases, "aucune admission partielle");
        Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "la réservation n’est jamais prise avant l’encodement vérifié");
    }

    [Test]
    public static async Task Eight_active_leases_are_the_hard_limit_then_release_admits_again()
    {
        using var folder = new TemporaryFolder();
        var spool = Spool(folder, TestClock.Fixed());
        var leases = new List<SharedParkPreviewFile>();
        try
        {
            for (var i = 0; i < SharedParkPreviewFile.MaxActiveLeases; i++) { leases.Add(await spool.StageAsync(Context(), Preview(Line("PC" + i)), Lifetime, None)); }
            Check.Equal(SharedParkPreviewFile.MaxActiveLeases, SharedParkPreviewFile.ActiveLeases, "huit spools actifs au plus");
            var reserved = SharedParkPreviewFile.ReservedBytes;
            Check.True(reserved > 0, "la réservation compte les en-têtes et les octets proposés");
            await Check.ThrowsAsync<InvalidDataException>(() => spool.StageAsync(Context(), Preview(Line("PC9")), Lifetime, None), "le neuvième est refusé, aucun des huit n’est évincé");
            Check.Equal(SharedParkPreviewFile.MaxActiveLeases, SharedParkPreviewFile.ActiveLeases, "le refus n’a rien admis");
            Check.Equal(reserved, SharedParkPreviewFile.ReservedBytes, "le refus n’a rien réservé de plus");
            foreach (var lease in leases) { Check.True(File.Exists(lease.Path), "les huit spools restent tenus et intacts"); }
        }
        finally
        {
            foreach (var lease in leases) { lease.Dispose(); }
        }
        Check.Equal(0, SharedParkPreviewFile.ActiveLeases, "la libération rend les places");
        Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "la libération rend les octets réservés");
        var again = new List<SharedParkPreviewFile>();
        try
        {
            for (var i = 0; i < SharedParkPreviewFile.MaxActiveLeases; i++) { again.Add(await spool.StageAsync(Context(), Preview(Line("PC" + i)), Lifetime, None)); }
            Check.Equal(SharedParkPreviewFile.MaxActiveLeases, SharedParkPreviewFile.ActiveLeases, "mêmes places réadmises après libération : aucune réservation fantôme");
        }
        finally
        {
            foreach (var lease in again) { lease.Dispose(); }
        }
        Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "aucune fuite de réservation après échec, libération et réadmission");
    }

    [Test]
    public static async Task Expired_leases_are_closed_and_freed_on_the_next_stage()
    {
        using var folder = new TemporaryFolder();
        var clock = TestClock.Fixed();
        var spool = Spool(folder, clock);
        var leases = new List<SharedParkPreviewFile>();
        try
        {
            for (var i = 0; i < SharedParkPreviewFile.MaxActiveLeases; i++) { leases.Add(await spool.StageAsync(Context(), Preview(Line("PC" + i)), TimeSpan.FromMinutes(5), None)); }
            var ninth = Context();
            await Check.ThrowsAsync<InvalidDataException>(() => spool.StageAsync(ninth, Preview(Line("PC9")), TimeSpan.FromMinutes(5), None), "la limite est atteinte avant toute expiration");
            clock.Advance(TimeSpan.FromMinutes(6));
            using var late = await spool.StageAsync(ninth, Preview(Line("PC9")), TimeSpan.FromMinutes(5), None);
            Check.Equal(1, SharedParkPreviewFile.ActiveLeases, "les huit expirées ont été fermées : il ne reste que la nouvelle, sans service ni temporisation");
            Check.Equal(late.Bytes, SharedParkPreviewFile.ReservedBytes, "la réservation du processus est exactement celle du fichier late");
            Check.Equal(late.Bytes, new FileInfo(late.Path).Length, "et correspond au fichier réellement tenu");
            foreach (var lease in leases) { Check.False(File.Exists(lease.Path), "le spool expiré a été fermé et son propre fichier supprimé"); }
        }
        finally
        {
            foreach (var lease in leases) { lease.Dispose(); }
        }
    }

    [Test]
    public static async Task A_new_component_never_scans_nor_recovers_the_old_spools()
    {
        using var folder = new TemporaryFolder();
        var clock = TestClock.Fixed();
        var first = Spool(folder, clock);
        Check.False(Directory.Exists(first.Root), "la construction ne crée et ne balaie aucun répertoire");
        Check.Equal(0, SharedParkPreviewFile.ActiveLeases, "la construction n’admet rien");
        var lease = await first.StageAsync(Context(), Preview(Line("PC1")), Lifetime, None);
        var abandoned = lease.Path;
        lease.Dispose();
        var second = Spool(folder, clock);
        Check.Equal(0, SharedParkPreviewFile.ActiveLeases, "aucune récupération automatique des anciens spools");
        Check.False(File.Exists(abandoned), "le fichier du lot abandonné est resté supprimé");
        using var fresh = await second.StageAsync(Context(), Preview(Line("PC2")), Lifetime, None);
        Check.True(File.Exists(fresh.Path), "un lot explicitement redemandé écrit son propre fichier");
        Check.Equal(1, Directory.EnumerateFiles(folder.File("spool"), "*.sharedpark", SearchOption.AllDirectories).Count(), "un seul spool sur le disque : celui du lot en cours");
    }

    [Test]
    public static async Task Concurrent_admission_never_exceeds_the_process_bounds()
    {
        using var folder = new TemporaryFolder();
        var spool = Spool(folder, TestClock.Fixed());
        var requests = Enumerable.Range(0, 16).Select(i => (context: Context(), preview: Preview(Line("PC" + i)))).ToList();
        var leases = new List<SharedParkPreviewFile>();
        var refusals = 0;
        var tasks = requests.Select(async request =>
        {
            try
            {
                var lease = await spool.StageAsync(request.context, request.preview, Lifetime, None);
                lock (leases) { leases.Add(lease); }
            }
            catch (Exception ex) when (ex is InvalidDataException or IOException)
            {
                Interlocked.Increment(ref refusals);
            }
        }).ToArray();
        await Task.WhenAll(tasks);
        try
        {
            Check.Equal(SharedParkPreviewFile.MaxActiveLeases, leases.Count, "l’admission atomique n’admet jamais plus de huit spools sous concurrence");
            Check.Equal(requests.Count - SharedParkPreviewFile.MaxActiveLeases, refusals, "les demandes de trop sont refusées, aucune n’est écrite à moitié");
            Check.Equal(SharedParkPreviewFile.MaxActiveLeases, SharedParkPreviewFile.ActiveLeases, "le compteur du processus reste cohérent");
        }
        finally
        {
            foreach (var lease in leases) { lease.Dispose(); }
        }
        Check.Equal(0L, SharedParkPreviewFile.ReservedBytes, "la concurrence ne laisse aucune réservation derrière elle");
    }
}
