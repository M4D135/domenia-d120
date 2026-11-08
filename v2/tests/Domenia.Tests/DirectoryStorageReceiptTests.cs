using System.Collections.Immutable;
using System.Globalization;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class DirectoryStorageReceiptTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    internal static readonly ScopeSelection Scope = new(Fixtures.Postes, "Postes", true);
    internal static readonly string StoreId = new('a', 64);
    internal static DirectoryStorageReceipt Proof(DirectorySnapshot snapshot) => new(StoreId, Fixtures.Root, Scope,
        snapshot.ReadAt, snapshot.Complete, "035646c0-294a-4823-af12-c9e5e70876ee", new('b', 64), 7, snapshot.ObjectCount, Fixtures.Now);

    [Test]
    public static async Task Sqlite_receipt_matches_the_actual_batch_table_after_reopening_the_cache()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed(Fixtures.Now.AddMilliseconds(750));
        var database = new DomeniaDatabase(folder.File("receipt.db"), Fixtures.Root, clock);
        var cache = new SqliteDirectoryCache(database);
        var snapshot = Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")], readAt: clock.GetUtcNow()) with { Coverage = Scope };
        var receipt = await cache.SaveWithReceiptAsync(snapshot, Scope, "DC1.test.local", None);
        var reopened = new SqliteDirectoryCache(new(database.Path, Fixtures.Root, clock));
        var restored = await reopened.ReadAsync(None);
        Check.NotNull(restored, "relecture SQLite réelle après nouveau cache");
        Check.Equal(snapshot.ReadAt, restored!.ReadAt, "date précise réellement conservée à la relecture");
        Check.True(receipt.Matches(database.StoreId, Fixtures.Root, Scope, snapshot, clock.GetUtcNow()), "horodatage SQL réel accepté pour le relevé soumis");
        Check.False(restored.Complete, "la réunion d’objets conservés n’est pas un nouveau recensement complet");
        Check.False(receipt.Matches(database.StoreId, Fixtures.Root, Scope, restored, clock.GetUtcNow()), "un redémarrage ne renouvelle pas la preuve de lecture complète");
        Check.Equal(snapshot.Computers.Single().ObjectGuid, restored!.Computers.Single().ObjectGuid, "objet réellement conservé");
        using var sql = new SqliteDatabase(database.Path, true);
        var row = sql.Query("SELECT sha256,revision,items,committed_at FROM domenia_v2_batches WHERE batch_id=?1;", receipt.BatchId).Single();
        Check.Equal(receipt.Sha256, (string)row["sha256"]!, "SHA du reçu effectivement inscrit en transaction");
        Check.Equal(receipt.Revision, (long)row["revision"]!, "révision réelle");
        Check.Equal((long)receipt.Items, (long)row["items"]!, "compte réel");
        Check.Equal(clock.GetUtcNow(), receipt.CommittedAt, "le fournisseur SQLite conserve ici la précision réelle de sa date");
        Check.Equal(receipt.CommittedAt, DateTimeOffset.Parse((string)row["committed_at"]!, CultureInfo.InvariantCulture), "date relue, pas l’heure du retour de méthode");
        Check.Equal(0, Directory.EnumerateFiles(folder.File("Staging"), "*.jsonl").Count(), "stage supprimé seulement après son reçu durable");
    }

    [Test]
    public static async Task Native_refresh_exposes_the_committed_sqlite_receipt_and_exact_session_generation()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var database = new DomeniaDatabase(folder.File("receipt.db"), Fixtures.Root, clock); await database.InitializeAsync(None);
        var cache = new SqliteDirectoryCache(database); var computer = Fixtures.Computer("PC1");
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        ldap.SearchAnswer = q => q.Filter == AdDirectoryMapper.ComputerFilter ? [AdPosteNetworkTests.Entry(computer)] : [];
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: ldap, localStore: cache);
        var state = await source.RefreshAsync(MeasureFamily.Directory, Scope, None);
        Check.Equal(1, state.Directory.Computers.Length, "relecture LDAP de fixture réellement atteinte");
        Check.True(ldap.Searches.Any(q => q.Filter == AdDirectoryMapper.ComputerFilter), "ce test ne valide pas seulement un état local initial");
        Check.NotNull(state.DirectoryCommit, "preuve remontée par le vrai AdDirectorySource");
        var commit = state.DirectoryCommit!;
        Check.Equal(source.Epoch, commit.SessionEpoch, "génération exacte après connexion");
        Check.True(commit.Receipt.Matches(database.StoreId, Fixtures.Root, Scope, state.Directory, clock.GetUtcNow()), "preuve liée au relevé envoyé");
        using var sql = new SqliteDatabase(database.Path, true);
        Check.Equal(commit.Receipt.Sha256, sql.Scalar("SELECT sha256 FROM domenia_v2_batches WHERE batch_id=?1;", commit.Receipt.BatchId) as string, "la source n’invente pas le reçu");
        using var cold = new AdDirectorySource("test.local", () => @"TEST\operator", clock,
            connection: new AdBoundaryTests.RecordingAdConnection(), localStore: new SqliteDirectoryCache(new(database.Path, Fixtures.Root, clock)));
        Check.Null((await cold.ReadLocalAsync(None)).DirectoryCommit, "un cache relu après redémarrage ne prétend pas être une nouvelle collecte de cette session");
    }

    [Test]
    public static async Task Session_reset_after_real_commit_prevents_publication_of_that_epochs_receipt()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed();
        var database = new DomeniaDatabase(folder.File("receipt.db"), Fixtures.Root, clock); await database.InitializeAsync(None);
        var cache = new ResetAfterSave(new SqliteDirectoryCache(database));
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        ldap.SearchAnswer = q => q.Filter == AdDirectoryMapper.ComputerFilter ? [AdPosteNetworkTests.Entry(Fixtures.Computer("PC1"))] : [];
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", clock, connection: ldap, localStore: cache);
        cache.AfterCommit = source.Reset;
        await Check.ThrowsAsync<DomeniaOperationException>(() => source.RefreshAsync(MeasureFamily.Directory, Scope, None), "époque changée après commit, publication refusée");
        Check.NotNull(cache.Receipt, "interleaving réellement atteint après reçu SQLite");
        Check.Null((await source.ReadLocalAsync(None)).DirectoryCommit, "aucun reçu attribué à la nouvelle session");
        using var sql = new SqliteDatabase(database.Path, true);
        Check.Equal(cache.Receipt!.Sha256, sql.Scalar("SELECT sha256 FROM domenia_v2_batches WHERE batch_id=?1;", cache.Receipt.BatchId) as string, "preuve réellement commise conservée malgré le refus tardif");
    }

    [Test]
    public static void Receipt_matching_refuses_wrong_identity_scope_read_and_impossible_metadata()
    {
        var snapshot = Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")], readAt: Fixtures.Now) with { Coverage = Scope };
        var valid = Proof(snapshot);
        Check.True(valid.Matches(StoreId, Fixtures.Root, Scope, snapshot, Fixtures.Now), "contrôle positif indispensable");
        foreach (var wrong in new[]
        {
            valid with { StoreId = "other" }, valid with { DomainDn = "DC=other,DC=local" },
            valid with { Scope = Scope with { Subtree = false } }, valid with { ReadAt = valid.ReadAt.AddSeconds(-1) },
            valid with { Complete = false }, valid with { Revision = 0 }, valid with { Items = 99 },
            valid with { BatchId = Guid.Empty.ToString("D") }, valid with { BatchId = "not-a-batch" },
            valid with { Sha256 = new('x', 64) }, valid with { Sha256 = null! },
            valid with { CommittedAt = DateTimeOffset.MinValue }, valid with { CommittedAt = Fixtures.Now.AddMinutes(3) },
            valid with { CommittedAt = Fixtures.Now.AddMinutes(-3) }, valid with { DomainDn = "not a DN" },
        }) { Check.False(wrong.Matches(StoreId, Fixtures.Root, Scope, snapshot, Fixtures.Now), "preuve altérée refusée : " + wrong); }
        Check.False(valid.Matches(StoreId, Fixtures.Root, Scope, snapshot with { Coverage = Scope with { Dn = Fixtures.People } }, Fixtures.Now), "couverture réellement lue liée à la preuve");
        Check.False(valid.Matches(StoreId, Fixtures.Root, Scope, snapshot with { Domain = Fixtures.Domain with { RootDn = "DC=other,DC=local" } }, Fixtures.Now), "domaine du snapshot lié au contexte attendu");
        var future = snapshot with { ReadAt = Fixtures.Now.AddMinutes(3) };
        Check.False(Proof(future).Matches(StoreId, Fixtures.Root, Scope, future, Fixtures.Now), "lecture future refusée malgré dates égales dans preuve/snapshot");
        var undated = snapshot with { ReadAt = DateTimeOffset.MinValue };
        Check.False(Proof(undated).Matches(StoreId, Fixtures.Root, Scope, undated, Fixtures.Now), "lecture non datée refusée");
    }

    [Test]
    public static void Coarse_timestamp_precision_and_bounded_clock_skew_are_not_treated_as_forgery()
    {
        var snapshot = Fixtures.Snapshot(readAt: Fixtures.Now.AddMilliseconds(875)) with { Coverage = Scope };
        Check.True(Proof(snapshot).Matches(StoreId, Fixtures.Root, Scope, snapshot, Fixtures.Now.AddSeconds(1)), "fournisseur à la seconde, lecture précise conservée");
        var skewed = snapshot with { ReadAt = Fixtures.Now.AddMinutes(2) };
        Check.True(Proof(skewed).Matches(StoreId, Fixtures.Root, Scope, skewed, Fixtures.Now), "tolérance de deux minutes identique à Store");
        Check.False(Proof(skewed with { ReadAt = skewed.ReadAt.AddSeconds(1) }).Matches(StoreId, Fixtures.Root, Scope,
            skewed with { ReadAt = skewed.ReadAt.AddSeconds(1) }, Fixtures.Now), "une seconde au-delà de la tolérance refusée");
    }

    private sealed class ResetAfterSave(SqliteDirectoryCache inner) : IReceiptedDirectoryCache, IPreparedDirectoryCache
    {
        internal Action? AfterCommit;
        internal DirectoryStorageReceipt? Receipt;
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken token) => inner.ReadAsync(token);
        public Task<DirectoryBackupReceipt> PrepareAsync(CancellationToken token) => inner.PrepareAsync(token);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) => throw new InvalidOperationException("Le contrat avec reçu doit être utilisé.");
        public async Task<DirectoryStorageReceipt> SaveWithReceiptAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token)
        { Receipt = await inner.SaveWithReceiptAsync(snapshot, scope, controller, token); AfterCommit?.Invoke(); return Receipt; }
    }
}
