using System.Collections.Immutable;
using System.Security.Cryptography;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeSyncSpoolTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Explicit_sync_read_uses_real_jsonl_and_never_initializes_a_cold_database()
    {
        using var setup = new Setup();
        var local = await setup.Cache.ReadSyncStateAsync(None);
        Check.False(Directory.Exists(setup.Profile), "lecture froide sans dossier");
        var batch = await setup.Batch([Row("PC1")]);
        await AdSyncState.For(setup.Source).HoldAsync(batch, None);
        var held = (SyncBatchFile)AdSyncState.For(setup.Source).Batches.Single().Value;
        Check.True(File.Exists(held.Path), "JSONL réel retenu");
        Check.True(held.Path.EndsWith(".jsonl", StringComparison.Ordinal), "format JSONL");
        Check.True(held.Bytes > 0, "taille mesurée");
        using (var file = new FileStream(held.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        { Check.Equal(held.Sha256, Convert.ToHexStringLower(SHA256.HashData(file)), "empreinte des octets réellement écrits"); }
        var reread = await held.ReadAsync(None);
        Check.Equal(batch.Rows.Single(), reread.Rows.Single(), "objet relu sans perte");
        Check.Equal(local.StoreId, reread.Header.StoreId, "base exacte");
        Check.False(File.Exists((await setup.Cache.DatabaseAsync(None)).Path), "spool sans création SQLite");
        Check.Equal(0, setup.Ldap.Calls, "aucun LDAP implicite");
        var discarded = new AdSyncReader(setup.Source).DiscardRead(batch.Id);
        Check.True(discarded.Discarded, "abandon explicite");
        Check.False(File.Exists(held.Path), "fichier fermé et supprimé");
        await Check.ThrowsAsync<InvalidDataException>(() => held.ReadAsync(None), "lot fermé non réutilisable");
    }

    [Test]
    public static async Task Held_sync_spool_rejects_concurrent_write_and_discard_invalidates_prepared_plan()
    {
        using var setup = new Setup();
        var batch = await setup.Batch([Row("PC1")]);
        await AdSyncState.For(setup.Source).HoldAsync(batch, None);
        var held = (SyncBatchFile)AdSyncState.For(setup.Source).Batches.Single().Value;
        Check.Throws<IOException>(() => File.WriteAllText(held.Path, "corrompu"), "fichier tenu sans partage en écriture");
        var executor = new AdSyncStoreExecutor(setup.Source);
        var draft = await executor.PlanBatchAsync(batch.Id, None);
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), "test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
        executor.Bind(draft, plan);
        new AdSyncReader(setup.Source).DiscardRead(batch.Id);
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, None), "pas d’envoi d’un lot abandonné après aperçu");
        Check.False(File.Exists((await setup.Cache.DatabaseAsync(None)).Path), "aucune base créée");
    }

    [Test]
    public static async Task Staged_sync_header_counts_identities_and_domain_are_checked_before_creation()
    {
        using var setup = new Setup();
        var batch = await setup.Batch([Row("PC1")]);
        var header = Header(batch);
        var spool = (ISyncBatchSpool)setup.Cache;
        await Check.ThrowsAsync<InvalidDataException>(() => spool.StageSyncBatchAsync(new(header with { Rows = 2 }, batch.Rows, [], []), None), "nombre annoncé exact");
        await Check.ThrowsAsync<InvalidDataException>(() => spool.StageSyncBatchAsync(new(header with { Rows = 2 }, [batch.Rows[0], batch.Rows[0]], [], []), None), "GUID dupliqué refusé");
        await Check.ThrowsAsync<InvalidDataException>(() => spool.StageSyncBatchAsync(new(header, [batch.Rows[0] with { Dn = "CN=PC1,DC=other,DC=local" }], [], []), None), "objet étranger refusé");
        await Check.ThrowsAsync<InvalidDataException>(() => spool.StageSyncBatchAsync(new(header with { StoreId = "other" }, batch.Rows, [], []), None), "base étrangère refusée");
        Check.False(Directory.Exists(setup.Profile), "refus avant toute création");
    }

    [Test]
    public static async Task Session_change_and_source_release_remove_only_their_own_spooled_batches()
    {
        using var setup = new Setup();
        var first = await setup.Batch([Row("PC1")]);
        await AdSyncState.For(setup.Source).HoldAsync(first, None);
        var held = (SyncBatchFile)AdSyncState.For(setup.Source).Batches.Single().Value;
        setup.Source.Reset();
        await Check.ThrowsAsync<DomeniaOperationException>(() => AdSyncState.For(setup.Source).ReadAsync(first.Id, None), "ancienne session refusée");
        Check.False(File.Exists(held.Path), "ancien spool purgé");
        var next = await setup.Batch([Row("PC2")]);
        await AdSyncState.For(setup.Source).HoldAsync(next, None);
        var path = ((SyncBatchFile)AdSyncState.For(setup.Source).Batches.Single().Value).Path;
        AdSyncState.Release(setup.Source);
        Check.False(File.Exists(path), "libération de source nettoie le spool");
        Check.Equal(0, AdSyncState.For(setup.Source).Batches.Count, "aucune récupération automatique de plan");
    }

    [Test]
    public static async Task Oversized_or_cancelled_spool_never_leaves_a_valid_partial_batch()
    {
        using var setup = new Setup();
        var batch = await setup.Batch([Row("PC1") with { Description = new string('x', 1_048_576) }]);
        await Check.ThrowsAsync<InvalidDataException>(() => AdSyncState.For(setup.Source).HoldAsync(batch, None), "ligne supérieure à 1 Mio refusée");
        Check.Equal(0, Directory.EnumerateFiles(setup.Profile, "*.jsonl", SearchOption.AllDirectories).Count(), "fichier partiel supprimé");
        Check.Equal(0, AdSyncState.For(setup.Source).Batches.Count, "aucun lot publié");
        using var stop = new CancellationTokenSource(); stop.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => AdSyncState.For(setup.Source).HoldAsync(batch, stop.Token), "annulation respectée");
    }

    [Test]
    public static async Task Confirmed_spooled_batch_is_deleted_only_after_a_durable_verified_commit()
    {
        using var setup = new Setup();
        var batch = await setup.Batch([Row("PC1")]);
        await AdSyncState.For(setup.Source).HoldAsync(batch, None);
        var path = ((SyncBatchFile)AdSyncState.For(setup.Source).Batches.Single().Value).Path;
        var executor = new AdSyncStoreExecutor(setup.Source);
        var draft = await executor.PlanBatchAsync(batch.Id, None);
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), "test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
        executor.Bind(draft, plan);
        Check.True(File.Exists(path), "aperçu conserve le fichier");
        Check.Equal(WriteResult.Applied, (await executor.ExecuteAsync(plan, None)).Result, "enregistrement local");
        Check.False(File.Exists(path), "fichier supprimé après réception du commit");
        Check.Equal(VerificationState.Verified, (await executor.VerifyAsync(plan, None)).State, "preuve relue sans spool");
        Check.Equal("PC1", (await setup.Cache.ReadSyncStateAsync(None)).Rows.Single().Name, "objet réellement relu");
    }

    private static SyncBatchHeader Header(AdSyncBatch batch) => new(batch.Id, batch.Label, WritePlans.NewId(), batch.Epoch, batch.At, batch.Expires,
        batch.StoreId, batch.DomainDn, batch.Revision, batch.BeforeSha256, batch.Coverage, batch.Rows.Length, batch.Absences.Length, batch.ResolvedGaps.Length);
    private static IndexRecord Row(string name) => new(Guid.NewGuid(), IndexObjectType.Computer, name, name + "$", name + ".test.local", null, null, "Windows", true,
        "CN=" + name + "," + Fixtures.Postes, Fixtures.Now, 12, null, LapsKind.None, null, Fixtures.Now);
    private sealed class Setup : IDisposable
    {
        private readonly TemporaryFolder folder = new();
        internal string Profile { get; }
        internal CompatibleDirectoryCache Cache { get; }
        internal AdBoundaryTests.RecordingAdConnection Ldap { get; } = new();
        internal AdDirectorySource Source { get; }
        internal Setup()
        {
            Profile = folder.File("profile"); Cache = new(folder.File("app"), Profile, "test.local", TestClock.Fixed());
            Source = new("test.local", () => "test", TestClock.Fixed(), connection: Ldap, localStore: Cache);
        }
        internal async Task<AdSyncBatch> Batch(ImmutableArray<IndexRecord> rows) => new AdSyncBatch(WritePlans.NewId(), "Lecture explicite", Source.Epoch,
            Fixtures.Now, Fixtures.Now.AddMinutes(15), rows, null, [], []).AtBase(await Cache.ReadSyncStateAsync(None));
        public void Dispose() { AdSyncState.Release(Source); Source.Dispose(); Ldap.Dispose(); folder.Dispose(); }
    }
}
