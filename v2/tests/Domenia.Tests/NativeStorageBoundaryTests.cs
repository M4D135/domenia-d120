using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeStorageBoundaryTests
{
    [Test]
    public static async Task Full_writer_queue_refuses_before_send_and_cancellation_releases_every_reservation()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("queue.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]), new(Fixtures.Postes, "Postes", true), "DC1", default);
        var patch = FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [Fixtures.Observe(Fixtures.Computer("PC1"), Fixtures.Presence(true, TimeSpan.Zero))]) };
        using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
        using var cancel = new CancellationTokenSource();
        database.FreeSpaceProbe = () => { entered.Set(); if (!release.Wait(TimeSpan.FromSeconds(15))) throw new TimeoutException("Écrivain de test non libéré."); return long.MaxValue; };
        var active = Task.Run(() => database.SaveFleetAsync(patch, default));
        var waiting = new List<Task>();
        try
        {
            Check.True(await Task.Run(() => entered.Wait(TimeSpan.FromSeconds(5))), "première écriture réellement active");
            for (var i = 1; i < DomeniaDatabase.MaxPendingWrites; i++) waiting.Add(database.SaveFleetAsync(patch, cancel.Token));
            var error = await Check.ThrowsAsync<IOException>(() => database.SaveFleetAsync(patch, default), "33e admission refusée sans masquer les précédentes");
            Check.Contains("32 lots", error.Message, "limite annoncée");
            cancel.Cancel();
            foreach (var task in waiting) await Check.ThrowsAsync<OperationCanceledException>(() => task, "attente annulée, pas de rejeu");
            waiting.Clear();
        }
        finally { cancel.Cancel(); release.Set(); await Task.WhenAll(waiting.Select(async task => { try { await task; } catch (OperationCanceledException) { } })); await active; }
        database.FreeSpaceProbe = () => long.MaxValue;
        var state = await database.CollectionStorageAsync(default);
        Check.Equal(0L, state.Space.QueuedBytes, "aucune réservation d’octets abandonnée");
        Check.Equal(0, state.Failures, "refus d’admission et annulations ne suspendent pas l’écrivain");
        await database.SaveFleetAsync(patch, default);
        Check.Equal(1, (await database.ReadFleetAsync(default)).Observations.Workstations.Length, "nouvelle admission et données initiales conservées");
    }

    [Test]
    public static void Streaming_digest_enforces_bytes_and_matches_the_full_document_without_retaining_it()
    {
        var options = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
        var payload = new { Text = "Éléonore", Values = Enumerable.Range(0, 300).ToArray() };
        var raw = JsonSerializer.SerializeToUtf8Bytes(payload, options);
        var result = StoragePayloadDigest.Of(payload, options, raw.Length, default);
        Check.Equal((long)raw.Length, result.Bytes, "taille UTF-8 exacte");
        Check.Equal(Convert.ToHexStringLower(SHA256.HashData(raw)), result.Sha256, "même empreinte canonique");
        Check.Throws<InvalidDataException>(() => StoragePayloadDigest.Of(payload, options, raw.Length - 1, default), "borne avant toute écriture disque");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Check.Throws<OperationCanceledException>(() => StoragePayloadDigest.Of(payload, options, raw.Length, cancelled.Token), "annulation pendant le hachage");
    }

    [Test]
    public static async Task Every_native_open_refuses_redirected_sidecars_even_readonly_and_before_creating_a_database()
    {
        using var folder = new TemporaryFolder();
        var target = folder.File("unrelated.txt"); await File.WriteAllTextAsync(target, "intact");
        foreach (var suffix in new[] { "-wal", "-shm", "-journal", ".domenia-write.lock", ".domenia-readonly" })
        {
            var path = folder.File("orphan.db"); var sidecar = path + suffix;
            File.CreateSymbolicLink(sidecar, target);
            try
            {
                foreach (var readOnly in new[] { true, false })
                    Check.Throws<InvalidDataException>(() => { using var _ = new SqliteDatabase(path, readOnly); }, "annexe redirigée refusée avant API native : " + suffix);
                Check.False(File.Exists(path), "aucun fichier principal créé");
                Check.Equal("intact", await File.ReadAllTextAsync(target), "cible du lien inchangée");
            }
            finally { File.Delete(sidecar); }
        }
        Check.Throws<InvalidDataException>(() => { using var _ = new SqliteDatabase(@"\\server\share\forbidden.db", false); }, "UNC refusé avant connexion au partage");
    }

    [Test]
    public static async Task Storage_identity_is_checked_before_any_upgrade_and_minimal_receipts_survive_reopening()
    {
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("identity.db"), Fixtures.Root, TestClock.Fixed());
        await database.InitializeAsync(default);
        using (var sql = new SqliteDatabase(database.Path, false)) sql.Execute("UPDATE domenia_store_state SET store_id=?1;", new string('a', 64));
        var bytes = await File.ReadAllBytesAsync(database.Path);
        await Check.ThrowsAsync<InvalidDataException>(() => new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed()).InitializeAsync(default), "identité d’un autre emplacement refusée");
        var afterRefusal = await File.ReadAllBytesAsync(database.Path);
        Check.True(bytes.SequenceEqual(afterRefusal), "pas de migration ni changement de l’identité étrangère");
        using (var sql = new SqliteDatabase(database.Path, false)) sql.Execute("UPDATE domenia_store_state SET store_id=?1;", database.StoreId);
        var snapshot = Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]); var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        var id = Guid.NewGuid().ToString("D"); var first = await database.SaveDirectoryAsync(id, snapshot, scope, "DC1", default);
        var reopened = new DomeniaDatabase(database.Path, Fixtures.Root, TestClock.Fixed(Fixtures.Now.AddDays(90))); await reopened.InitializeAsync(default);
        var repeat = await reopened.SaveDirectoryAsync(id, snapshot, scope, "DC1", default);
        Check.True(repeat.AlreadyCommitted, "identité du lot toujours reconnue après 90 jours et réouverture");
        Check.Equal(first.Revision, repeat.Revision, "aucune nouvelle révision ni mutation par rejeu");
        using var read = new SqliteDatabase(database.Path, true);
        Check.Equal(1L, (long)read.Scalar("SELECT count(*) FROM domenia_v2_batches;")!, "reçu minimal permanent, aucun doublon");
        foreach (var table in new[] { "domenia_v2_purge_receipts", "domenia_v2_writer_receipts", "domenia_v2_retention_receipts", "domenia_v2_legacy_receipts" })
            Check.Equal(1L, (long)read.Scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?1;", table)!, "reçus de maintenance initialisés avant la première opération");
    }

    [Test]
    public static void Receipt_read_transaction_does_not_consume_another_write_budget_or_replace_replay_proof()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("readback.db");
        using (var create = new SqliteDatabase(path, false)) create.Script("CREATE TABLE proof(value TEXT);");
        var budgets = 0; var checks = 0; var captures = 0;
        using var budget = StorageWriteBudgetScope.Enter(path, () => budgets++);
        using var replay = StorageReplayScope.Enter(path, _ => checks++, _ => "proof-" + ++captures);
        using (var write = new SqliteDatabase(path, false))
        { write.Begin(); write.Execute("INSERT INTO proof(value) VALUES('saved');"); write.Commit(); }
        Check.Equal(2, budgets, "budget de la transaction d’écriture au début et au commit");
        Check.Equal("proof-1", replay.AfterFingerprint, "preuve de l’écriture réelle");
        using (var read = new SqliteDatabase(path, true))
        { read.Begin(false); Check.Equal("saved", read.Scalar("SELECT value FROM proof;") as string, "reçu effectivement relu"); read.Commit(); }
        Check.Equal(2, budgets, "relecture ne demande pas un nouveau budget d’écriture");
        Check.Equal(1, checks, "aucun contrôle de rejeu sur transaction lisante");
        Check.Equal(1, captures, "aucune capture de la lecture au lieu du commit");
        Check.Equal("proof-1", replay.AfterFingerprint, "preuve du véritable commit conservée");
    }

    [Test]
    public static void Operator_plan_size_and_change_types_are_rejected_before_confirmation()
    {
        var draft = FakeWriteExecutor.Draft();
        var change = draft.Changes[0];
        Check.Throws<ArgumentException>(() => WritePlans.Seal(draft with { Changes = [change with { Kind = (WriteChangeKind)999 }] }, WritePlans.NewId(), "test", AppMode.Simulation, Fixtures.Now, TimeZoneInfo.Utc), "nature inconnue");
        Check.Throws<ArgumentException>(() => WritePlans.Seal(draft with { Changes = [change with { After = new string('x', WritePlans.MaxBytes) }] }, WritePlans.NewId(), "test", AppMode.Simulation, Fixtures.Now, TimeZoneInfo.Utc), "budget de plan indépendant du nombre de changements");
        foreach (var state in new[] { new CollectionStorageState(new(long.MaxValue, Fixtures.Now, 0), true, false, 0, null), new(new(long.MaxValue, Fixtures.Now, 0), false, false, 3, null) })
            Check.Equal(CollectionStorageRules.Unavailable, Check.Throws<DomeniaOperationException>(() => CollectionStorageRules.Ensure(state, Fixtures.Now, TimeZoneInfo.Utc), "maintenance ou erreurs même avec espace disponible").Code, "admission fermée");
    }
}
