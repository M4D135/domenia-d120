using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeBackupBoundaryTests
{
    [Test]
    public static async Task Configured_deadline_cleans_its_partial_releases_the_writer_and_never_replays_the_plan()
    {
        using var folder = new TemporaryFolder(); var clock = new DeadlineClock();
        var cache = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", clock);
        cache.ConfigureBackupTimeout(5);
        var database = await cache.DatabaseAsync(default); await database.InitializeAsync(default);
        var before = File.ReadAllBytes(database.Path);
        var plan = Seal(await database.PrepareStorageBackupAsync(StoragePolicyRules.Default, "{}", "manual", null, default), clock);
        database.BackupStageReached = stage => { if (stage == "copyChunk") clock.Advance(TimeSpan.FromSeconds(6)); };
        var timeout = await Check.ThrowsAsync<IOException>(() => database.ApplyStorageBackupAsync(plan, default), "budget réellement déclenché après un pas de copie SQLite");
        Check.Contains("Budget de sauvegarde dépassé (5 s)", timeout.Message, "configuration du délai appliquée");
        Check.True(before.SequenceEqual(File.ReadAllBytes(database.Path)), "source intacte après expiration");
        var snapshot = await database.InspectLocalStoreAsync(false, false, default);
        Check.False(snapshot.Writer.Active, "la réservation physique est libérée après la fin réelle du travail");
        Check.Equal(0, snapshot.Backups.Length, "aucun succès sans copie contrôlée");
        AssertNoTemporary(folder.Path);
        Check.True(File.Exists(Path.Combine(Path.GetDirectoryName(database.Path)!, "Backups", ".receipts", plan.Id + ".json.intent")), "intention conservée pour interdire le rejeu ambigu");
        database.BackupStageReached = null;
        await Check.ThrowsAsync<IOException>(() => database.ApplyStorageBackupAsync(plan, default), "aucune reprise implicite du même plan");
        var next = Seal(await database.PrepareStorageBackupAsync(StoragePolicyRules.Default, "{}", "manual", null, default), clock);
        Check.Equal(WriteResult.Applied, (await database.ApplyStorageBackupAsync(next, default)).Result, "une nouvelle confirmation peut encore sauvegarder");
        Check.Equal(VerificationState.Verified, (await database.VerifyStorageBackupAsync(next, default)).State, "nouvelle copie relue sur disque");
        AssertNoTemporary(folder.Path);
    }

    [Test]
    public static async Task Interrupted_export_keeps_its_verified_local_copy_and_preserves_the_existing_destination()
    {
        foreach (var stage in new[] { "localVerified", "publication" })
        {
            using var folder = new TemporaryFolder(); var clock = new DeadlineClock();
            var database = new DomeniaDatabase(folder.File("source.db"), Fixtures.Root, clock);
            await database.InitializeAsync(default); var source = File.ReadAllBytes(database.Path);
            var destination = folder.File("export.db"); File.WriteAllText(destination, "document antérieur");
            var plan = Seal(await database.PrepareStorageBackupAsync(StoragePolicyRules.Default, "{}", "manual", destination, default), clock);
            using var cancel = new CancellationTokenSource();
            database.BackupStageReached = reached => { if (reached == stage) cancel.Cancel(); };
            await Check.ThrowsAsync<OperationCanceledException>(() => database.ApplyStorageBackupAsync(plan, cancel.Token), "interruption à une vraie frontière d’export");
            Check.Equal("document antérieur", File.ReadAllText(destination), "destination initiale conservée");
            Check.True(source.SequenceEqual(File.ReadAllBytes(database.Path)), "base active intacte");
            var snapshot = await database.InspectLocalStoreAsync(false, false, default);
            var backup = snapshot.Backups.Single();
            Check.True(BackupPreferencesRules.IsBound(backup), "copie locale et annexe réellement enregistrées");
            using (var copy = new SqliteDatabase(Path.Combine(folder.Path, "Backups", backup.FileName), true))
                Check.Equal("ok", copy.Scalar("PRAGMA quick_check;") as string, "copie locale récupérable");
            var receipt = await database.VerifyStorageBackupAsync(plan, default);
            Check.Equal(VerificationState.Mismatch, receipt.State, "l’export interrompu n’est jamais certifié");
            Check.Contains("Copie locale vérifiée ; publication interrompue", receipt.Detail, "résultat distingue la copie locale de la publication");
            database.BackupStageReached = null;
            Check.Equal(WriteResult.NoChange, (await database.ApplyStorageBackupAsync(plan, default)).Result, "aucune seconde publication du même plan");
            AssertNoTemporary(folder.Path);
        }
    }

    [Test]
    public static async Task Destination_changed_during_backup_or_missing_directory_is_refused_without_losing_the_local_copy()
    {
        using var folder = new TemporaryFolder(); var clock = new DeadlineClock();
        var database = new DomeniaDatabase(folder.File("source.db"), Fixtures.Root, clock); await database.InitializeAsync(default);
        var absent = folder.File("absent/export.db");
        await Check.ThrowsAsync<DirectoryNotFoundException>(() => database.PrepareStorageBackupAsync(StoragePolicyRules.Default, "{}", "manual", absent, default), "véritable dossier absent refusé");
        Check.False(Directory.Exists(Path.GetDirectoryName(absent)), "aucun dossier créé à la préparation");
        var target = folder.File("export.db"); File.WriteAllText(target, "premier contenu");
        var plan = Seal(await database.PrepareStorageBackupAsync(StoragePolicyRules.Default, "{}", "manual", target, default), clock);
        database.BackupStageReached = stage => { if (stage == "localVerified") File.WriteAllText(target, "modification pendant la copie"); };
        var failure = await Check.ThrowsAsync<IOException>(() => database.ApplyStorageBackupAsync(plan, default), "course atteinte après copie SQLite réelle");
        Check.Contains("destination a changé pendant la copie", failure.Message, "cause explicite");
        Check.Equal("modification pendant la copie", File.ReadAllText(target), "fichier concurrent intact");
        Check.Equal(1, (await database.InspectLocalStoreAsync(false, false, default)).Backups.Length, "copie locale demeure disponible");
        Check.Equal(VerificationState.Mismatch, (await database.VerifyStorageBackupAsync(plan, default)).State, "publication refusée visible à la relecture");
        AssertNoTemporary(folder.Path);
    }

    [Test]
    public static async Task Native_destination_validation_rejects_a_real_directory_junction()
    {
        using var folder = new TemporaryFolder(); var clock = new DeadlineClock();
        var database = new DomeniaDatabase(folder.File("source.db"), Fixtures.Root, clock); await database.InitializeAsync(default);
        var real = folder.File("real"); var junction = folder.File("redirected"); Directory.CreateDirectory(real);
        var start = new System.Diagnostics.ProcessStartInfo("cmd.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add("/d"); start.ArgumentList.Add("/c"); start.ArgumentList.Add("mklink"); start.ArgumentList.Add("/J"); start.ArgumentList.Add(junction); start.ArgumentList.Add(real);
        using var command = System.Diagnostics.Process.Start(start) ?? throw new TestFailureException("Création de la jonction de test non lancée.");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        try { await command.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException) { command.Kill(entireProcessTree: true); throw; }
        Check.Equal(0, command.ExitCode, "la fixture exige une vraie jonction NTFS : " + await command.StandardError.ReadToEndAsync());
        try
        {
            Check.True((File.GetAttributes(junction) & FileAttributes.ReparsePoint) != 0, "jonction réellement présente");
            await Check.ThrowsAsync<InvalidDataException>(() => database.PrepareStorageBackupAsync(StoragePolicyRules.Default, "{}", "manual", Path.Combine(junction, "export.db"), default), "publication à travers une jonction refusée par le stockage natif");
            Check.False(File.Exists(Path.Combine(real, "export.db")), "aucun fichier dans la destination redirigée");
        }
        finally { Directory.Delete(junction); }
    }

    [Test]
    public static async Task A_preexisting_partial_is_neither_overwritten_nor_deleted_by_cleanup()
    {
        using var folder = new TemporaryFolder(); var clock = new DeadlineClock();
        var database = new DomeniaDatabase(folder.File("source.db"), Fixtures.Root, clock); await database.InitializeAsync(default);
        var plan = Seal(await database.PrepareStorageBackupAsync(StoragePolicyRules.Default, "{}", "manual", null, default), clock);
        var backup = Path.Combine(folder.Path, "Backups"); Directory.CreateDirectory(backup);
        var partial = Path.Combine(backup, plan.Changes.Single(c => c.Attribute == "backup.file").AfterValue!) + ".partial-" + plan.Id;
        File.WriteAllText(partial, "fichier préexistant");
        await Check.ThrowsAsync<IOException>(() => database.ApplyStorageBackupAsync(plan, default), "collision refuse la création");
        Check.Equal("fichier préexistant", File.ReadAllText(partial), "nettoyage limité aux fichiers créés par cette exécution");
    }

    [Test]
    public static async Task A_preexisting_partial_connection_barrier_is_not_owned_or_removed_by_backup_cleanup()
    {
        using var folder = new TemporaryFolder(); var clock = new DeadlineClock();
        var database = new DomeniaDatabase(folder.File("source.db"), Fixtures.Root, clock); await database.InitializeAsync(default);
        var plan = Seal(await database.PrepareStorageBackupAsync(StoragePolicyRules.Default, "{}", "manual", null, default), clock);
        var backups = Path.Combine(folder.Path, "Backups"); Directory.CreateDirectory(backups);
        var partial = Path.Combine(backups, plan.Changes.Single(c => c.Attribute == "backup.file").AfterValue!) + ".partial-" + plan.Id;
        var barrier = partial + ".domenia-write.lock"; File.WriteAllText(barrier, "barrière préexistante");
        await Check.ThrowsAsync<IOException>(() => database.ApplyStorageBackupAsync(plan, default), "un compagnon préexistant refuse la copie");
        Check.Equal("barrière préexistante", File.ReadAllText(barrier), "barrière étrangère ni remplacée ni supprimée");
        Check.False(File.Exists(partial), "seul le fichier de travail créé ici est nettoyé");
    }

    [Test]
    public static async Task Internal_migration_copy_is_registered_at_cold_start_with_preferences_and_outside_scheduled_rotation()
    {
        using var folder = new TemporaryFolder(); var clock = new DeadlineClock();
        var database = new DomeniaDatabase(folder.File("source.db"), Fixtures.Root, clock);
        await database.InitializeAsync(default);
        var preferences = new MemoryPreferenceStore();
        await preferences.SetAsync(PreferenceApproval.ZoomKey, System.Text.Json.JsonSerializer.SerializeToElement(120), default);
        database.ConfigureBackupPreferences(preferences);
        using (var old = new SqliteDatabase(database.Path, false)) old.Execute("DROP INDEX ix_links_computer_guid;");
        await database.InitializeAsync(default);
        var cold = new DomeniaDatabase(database.Path, Fixtures.Root, clock);
        var saved = (await cold.InspectLocalStoreAsync(false, false, default)).Backups.Single(b => b.Kind == "migration");
        Check.True(BackupPreferencesRules.IsBound(saved), "annexe réelle liée à la copie avant migration");
        Check.Equal(1, saved.PreferenceKeys, "préférence approuvée conservée");
        var copy = Path.Combine(folder.Path, "Backups", saved.FileName);
        using (var old = new SqliteDatabase(copy, true))
            Check.Equal(0L, (long)old.Scalar("SELECT count(*) FROM sqlite_master WHERE type='index' AND name='ix_links_computer_guid';")!, "copie de l’ancien schéma, avant ajout");
        Check.True(File.Exists(copy), "copie de migration autonome et visible au redémarrage");
        var restore = await cold.InspectRegisteredSwitchSourceAsync(saved.Id, default);
        Check.Equal(saved.Sha256, restore.Backup!.Sha256, "copie restaurable depuis le registre");
        for (var n = 0; n < 3; n++)
        {
            var plan = Seal(await database.PrepareStorageBackupAsync(StoragePolicyRules.Default with { BackupKeep = 2 }, "{}", "scheduled", null, default), clock);
            await database.ApplyStorageBackupAsync(plan, default);
            clock.Advance(TimeSpan.FromHours(1));
        }
        Check.Equal(2, (await cold.InspectLocalStoreAsync(false, false, default)).Backups.Count(b => b.Kind == "scheduled"), "rotation planifiée réellement exécutée");
        Check.True(File.Exists(copy), "série migration hors de la rotation planifiée");
        Check.Equal(saved.Sha256, (await cold.InspectRegisteredSwitchSourceAsync(saved.Id, default)).Backup!.Sha256, "preuve autonome toujours valide");
    }

    [Test]
    public static async Task Internal_migration_copy_obeys_the_same_deadline_and_cleans_only_its_temporary_files()
    {
        using var folder = new TemporaryFolder(); var clock = new DeadlineClock();
        var database = new DomeniaDatabase(folder.File("source.db"), Fixtures.Root, clock); await database.InitializeAsync(default);
        using (var old = new SqliteDatabase(database.Path, false)) old.Execute("DROP INDEX ix_links_computer_guid;");
        var before = File.ReadAllBytes(database.Path);
        database.ConfigureBackupTimeout(5);
        database.BackupStageReached = stage => { if (stage == "internal.copy") clock.Advance(TimeSpan.FromSeconds(6)); };
        await Check.ThrowsAsync<IOException>(() => database.InitializeAsync(default), "copie interrompue avant modification du schéma");
        Check.True(before.SequenceEqual(File.ReadAllBytes(database.Path)), "original inchangé");
        AssertNoTemporary(folder.Path);
        Check.Equal(0, (await database.InspectLocalStoreAsync(false, false, default)).Backups.Length, "aucune fausse réussite publiée");
        database.BackupStageReached = null;
        await database.InitializeAsync(default);
        Check.Equal(1, (await database.InspectLocalStoreAsync(false, false, default)).Backups.Count(b => b.Kind == "migration"), "nouvelle demande explicite possible");
    }

    private static WritePlan Seal(WritePlanDraft draft, TimeProvider clock) => WritePlans.Seal(draft, WritePlans.NewId(), "test", AppMode.Directory, clock.GetUtcNow(), TimeZoneInfo.Utc);
    private static void AssertNoTemporary(string folder)
    {
        var remaining = Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories).Select(p => Path.GetRelativePath(folder, p))
            .Where(p => p.Contains(".partial", StringComparison.Ordinal) || p.Contains(".tmp-", StringComparison.Ordinal)).ToArray();
        Check.Equal(0, remaining.Length, "aucun provisoire possédé n’est laissé après retour : " + string.Join(", ", remaining));
    }

    private sealed class DeadlineClock : TimeProvider
    {
        private DateTimeOffset now = Fixtures.Now;
        private readonly List<DeadlineTimer> timers = [];
        public override DateTimeOffset GetUtcNow() => now;
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new DeadlineTimer(callback, state, now + dueTime); timers.Add(timer); return timer;
        }
        internal void Advance(TimeSpan by) { now += by; foreach (var timer in timers.ToArray()) timer.Fire(now); }
        private sealed class DeadlineTimer(TimerCallback callback, object? state, DateTimeOffset due) : ITimer
        {
            private bool done;
            internal void Fire(DateTimeOffset now) { if (!done && now >= due) { done = true; callback(state); } }
            public bool Change(TimeSpan dueTime, TimeSpan period) => throw new NotSupportedException("Budget à échéance fixe uniquement.");
            public void Dispose() => done = true;
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
}
