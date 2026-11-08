using System.Diagnostics;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class StorageProcessTests
{
    internal const string FixtureArgument = "--storage-process-fixture";

    private static Process Start(string mode, string path)
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Processus de test absent.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(typeof(StorageProcessTests).Assembly.Location);
        start.ArgumentList.Add(FixtureArgument); start.ArgumentList.Add(mode); start.ArgumentList.Add(path);
        return Process.Start(start) ?? throw new InvalidOperationException("Processus de stockage non démarré.");
    }

    internal static async Task<int> RunFixtureAsync(string[] args)
    {
        if (args.Length != 3 || args[0] != FixtureArgument) return 2;
        void WaitForParent()
        {
            Console.WriteLine("storage:ready"); Console.Out.Flush();
            using var wait = new ManualResetEventSlim();
            if (!wait.Wait(TimeSpan.FromSeconds(30))) throw new TimeoutException("Parent de qualification absent.");
        }
        try
        {
            if (args[1] == "writer")
            {
                using var db = new SqliteDatabase(args[2], false);
                db.Begin(); db.Execute("UPDATE contention_proof SET value=99 WHERE id=1;");
                WaitForParent(); return 0;
            }
            if (args[1] == "migration")
            {
                var db = new DomeniaDatabase(args[2], Fixtures.Root, TestClock.Fixed()) { UpgradeCheckpoint = WaitForParent };
                await db.InitializeAsync(default); return 0;
            }
            return 2;
        }
        catch (Exception error) { Console.Error.WriteLine(error.GetType().Name + ": " + error.Message); return 1; }
    }

    private static async Task Kill(Process process)
    {
        if (!process.HasExited) process.Kill(entireProcessTree: true);
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Test]
    public static async Task Separate_process_writer_is_excluded_by_SQLite_and_interrupted_changes_are_not_committed()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("two-processes.db");
        using (var db = new SqliteDatabase(path, false)) db.Script("CREATE TABLE contention_proof(id INTEGER PRIMARY KEY,value INTEGER); INSERT INTO contention_proof VALUES(1,7);");
        using var child = Start("writer", path);
        var errors = child.StandardError.ReadToEndAsync();
        try
        {
            Check.Equal("storage:ready", await child.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)), "transaction du second processus réellement ouverte");
            using var competing = new SqliteDatabase(path, false, busyTimeoutMs: 100);
            var busy = Check.Throws<SqliteStoreException>(() => competing.Begin(), "écrivains inter-processus exclus par BEGIN IMMEDIATE");
            Check.True(busy.Busy, "contention identifiée, jamais un succès vide");
        }
        finally { await Kill(child); }
        Check.Equal("", await errors, "arrêt au point contrôlé, sans erreur de fixture");
        using var recovered = new SqliteDatabase(path, false);
        Check.Equal(7L, (long)recovered.Scalar("SELECT value FROM contention_proof WHERE id=1;")!, "rollback natif après disparition du propriétaire");
        recovered.Begin(); recovered.Execute("UPDATE contention_proof SET value=8 WHERE id=1;"); recovered.Commit();
        using var read = new SqliteDatabase(path, true);
        Check.Equal(8L, (long)read.Scalar("SELECT value FROM contention_proof WHERE id=1;")!, "verrou libéré et nouvelle transaction distincte validée");
    }

    [Test]
    public static async Task Process_death_during_upgrade_keeps_the_previous_schema_and_a_verified_backup()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("migration.db");
        var database = new DomeniaDatabase(path, Fixtures.Root, TestClock.Fixed()); await database.InitializeAsync(default);
        using (var legacy = new SqliteDatabase(path, false))
        {
            legacy.Script("DROP TABLE domenia_v2_objects; DROP TABLE domenia_v2_metadata; DROP TABLE domenia_v2_batches; DELETE FROM schema_info WHERE key='domenia_schema';");
            legacy.Execute("INSERT INTO park_state(computer_key,computer) VALUES(?1,?2);", "kept", "PC1");
        }
        using var child = Start("migration", path);
        var errors = child.StandardError.ReadToEndAsync();
        try { Check.Equal("storage:ready", await child.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(15)), "DDL exécuté mais transaction non validée"); }
        finally { await Kill(child); }
        Check.Equal("", await errors, "interruption au point contrôlé");
        // A writable native opener performs hot-journal recovery explicitly for this fixture.
        // Product read-only inspection must never pretend a failed opening was an empty database.
        using (var recovered = new SqliteDatabase(path, false))
        {
            Check.Null(recovered.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';"), "ancienne version retrouvée, aucun demi-schéma");
            Check.Equal(0L, (long)recovered.Scalar("SELECT count(*) FROM sqlite_master WHERE name='domenia_v2_objects';")!, "création additive annulée par rollback");
            Check.Equal("PC1", recovered.Scalar("SELECT computer FROM park_state WHERE computer_key='kept';") as string, "données d’origine intactes");
            Check.Equal("ok", recovered.Scalar("PRAGMA quick_check;") as string, "intégrité après récupération");
        }
        var backupPath = Directory.GetFiles(folder.File("Backups"), "*.db").Single();
        using (var backup = new SqliteDatabase(backupPath, true))
        {
            Check.Null(backup.Scalar("SELECT value FROM schema_info WHERE key='domenia_schema';"), "sauvegarde avant migration");
            Check.Equal("PC1", backup.Scalar("SELECT computer FROM park_state WHERE computer_key='kept';") as string, "sauvegarde complète et lisible indépendamment");
        }
        var retried = await new DomeniaDatabase(path, Fixtures.Root, TestClock.Fixed()).InitializeAsync(default);
        Check.Equal(1, retried.SchemaRevision, "réinitialisation explicite de la fixture après contrôle de récupération");
    }

    [Test]
    public static async Task Maintenance_fence_timeout_is_explicit_and_never_loses_the_existing_owner()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("fence.db");
        using (var held = StorageWriteFence.Exclusive(path, default))
        {
            var error = await Check.ThrowsAsync<StorageBusyException>(() => Task.Run(() => { using var denied = StorageWriteFence.Writer(path, default); }), "autre maintenance non contournée");
            Check.Contains("5 s", error.Message, "attente bornée annoncée");
            Check.False(File.Exists(path), "un refus de verrou ne crée pas de base");
        }
        using var admitted = StorageWriteFence.Writer(path, default);
    }
}
