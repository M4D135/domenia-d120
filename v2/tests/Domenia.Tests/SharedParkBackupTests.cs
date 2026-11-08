using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>Windows-only local fixtures; no AD, SMB, publication or journal. Written for final VM execution, not run here.</summary>
internal static class SharedParkBackupTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly FileSystemRights ReadRights = FileSystemRights.Read | FileSystemRights.Synchronize;

    private static SecurityIdentifier[] Principals()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new[] { identity.User!, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) }.DistinctBy(s => s.Value).ToArray();
    }

    private static string PrivateDirectory(TemporaryFolder folder, string name = "backups")
    {
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var principal in Principals()) { security.AddAccessRule(new FileSystemAccessRule(principal, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow)); }
        var path = folder.File(name);
        new DirectoryInfo(path).Create(security);
        return path;
    }

    private static void SetFileRights(string path, FileSystemRights rights)
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var principal in Principals()) { security.AddAccessRule(new FileSystemAccessRule(principal, rights, AccessControlType.Allow)); }
        new FileInfo(path).SetAccessControl(security);
    }

    private static async Task<DomeniaDatabase> Database(TemporaryFolder folder, bool present = true)
    {
        var db = new DomeniaDatabase(folder.File("source.db"), Fixtures.Root, TestClock.Fixed());
        if (present) { await db.InitializeAsync(None); }
        return db;
    }

    private static byte[] Tsv(string computer = "PC1")
        => Encoding.UTF8.GetBytes(computer + "\t2026-10-20T10:00:00Z\tCONFIRME\talice\t2\r\n");

    private static async Task<SharedParkBatch> Batch(DomeniaDatabase db, TemporaryFolder folder, string tsv)
    {
        using var preview = await db.PreviewSharedParkAsync(tsv, [], [], folder.File("preview"), WritePlans.NewId(), 1, None);
        return preview.Reference;
    }

    private static string Hash(string path) => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
    private static void VerifyBytes(SharedParkBackupReference reference)
    {
        Check.True(File.Exists(reference.Path), "la référence désigne une copie réelle");
        Check.Equal(new FileInfo(reference.Path).Length, reference.Length, "taille réellement relue");
        Check.Equal(Hash(reference.Path), reference.Sha256, "SHA réellement relu");
        var acl = new FileInfo(reference.Path).GetAccessControl();
        Check.True(acl.AreAccessRulesProtected, "aucune permission héritée sur la copie");
        var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        Check.True(Principals().Select(s => s.Value).ToHashSet().SetEquals(rules.Select(r => r.IdentityReference.Value)), "trois identités privées uniquement");
        Check.True(rules.All(r => !r.IsInherited && r.AccessControlType == AccessControlType.Allow && r.FileSystemRights == ReadRights), "copie scellée en lecture seule");
    }

    [Test]
    public static async Task Real_copies_are_reread_and_preserve_original_TSV_BOM_order_and_dates()
    {
        using var folder = new TemporaryFolder();
        var db = await Database(folder);
        var tsv = folder.File("source.tsv");
        byte[] original = [0xef, 0xbb, 0xbf, .. Tsv("PC2"), .. Tsv("PC1")];
        File.WriteAllBytes(tsv, original);
        var batch = await Batch(db, folder, tsv);
        var before = Hash(db.Path);
        var result = await db.CreateSharedParkBackupsAsync(batch, PrivateDirectory(folder), [], [], None);
        Check.NotNull(result.SqliteBackup, "base présente sauvegardée");
        Check.NotNull(result.TsvBackup, "TSV présent sauvegardé");
        VerifyBytes(result.SqliteBackup!); VerifyBytes(result.TsvBackup!);
        Check.True(original.SequenceEqual(File.ReadAllBytes(result.TsvBackup!.Path)), "aucun réencodage du BOM, des dates ni de l’ordre");
        Check.Equal(before, Hash(db.Path), "base active inchangée");
        Check.Equal(batch.RemoteSha256, Hash(tsv), "TSV actif inchangé");
        using var copy = new SqliteDatabase(result.SqliteBackup!.Path, true);
        Check.Equal("ok", (string)copy.Scalar("PRAGMA quick_check;")!, "copie SQLite réellement relisible");
        Check.Equal(StorageWriteSnapshot.Read(copy, None), result.SqliteLogicalFingerprint!, "empreinte logique relue dans la copie");
        var planId = WritePlans.NewId(); var planSha = new string('a', 64);
        var intent = new SharedParkIntent(1, planId, planSha, batch, SharedParkIdentity.Fingerprint(batch), TestClock.Reference,
            result.SqliteBackup, result.TsvBackup);
        var encoded = SharedParkIntentDocument.Encode(intent, db.StoreId, db.DomainDn, planId, planSha, TestClock.Reference, None);
        Check.Equal(intent, SharedParkIntentDocument.Decode(encoded, db.StoreId, db.DomainDn, planId, planSha, TestClock.Reference, None),
            "les références physiques produites respectent aussi le codec d’intention");
    }

    [Test]
    public static async Task A_committed_WAL_row_is_present_in_the_backup()
    {
        using var folder = new TemporaryFolder();
        var db = await Database(folder);
        using var writer = new SqliteDatabase(db.Path, false);
        writer.Script("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;");
        writer.Execute("INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts) VALUES('PC1','PC1','2026-10-20T10:00:00Z','SESSION','alice',2);");
        Check.True(new FileInfo(db.Path + "-wal").Length > 0, "la fixture contient un WAL réel encore ouvert");
        var batch = await Batch(db, folder, folder.File("absent.tsv"));
        var result = await db.CreateSharedParkBackupsAsync(batch, PrivateDirectory(folder), [], [], None);
        using var copy = new SqliteDatabase(result.SqliteBackup!.Path, true);
        Check.Equal(1L, (long)copy.Scalar("SELECT count(*) FROM park_state WHERE computer='PC1';")!, "la transaction WAL est incluse dans la copie SQLite");
        Check.Equal("delete", (string)copy.Scalar("PRAGMA journal_mode;")!, "copie autonome sans dépendance au WAL source");
        Check.Null(result.TsvBackup, "absence TSV sans faux fichier");
    }

    [Test]
    public static async Task Two_absent_sources_return_null_without_inventing_empty_copies()
    {
        using var folder = new TemporaryFolder();
        var db = await Database(folder, present: false);
        var tsv = folder.File("absent.tsv");
        var batch = await Batch(db, folder, tsv);
        var root = PrivateDirectory(folder);
        var result = await db.CreateSharedParkBackupsAsync(batch, root, [], [], None);
        Check.Null(result.SqliteBackup, "absence SQLite explicite"); Check.Null(result.TsvBackup, "absence TSV explicite");
        Check.Null(result.SqliteLogicalFingerprint, "aucune empreinte logique SQLite inventée");
        Check.False(File.Exists(db.Path) || File.Exists(tsv), "aucune source créée");
        Check.Equal(0, Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).Count(), "aucun fichier de preuve fictif");
    }

    [Test]
    public static async Task An_empty_present_TSV_gets_a_real_zero_length_backup()
    {
        using var folder = new TemporaryFolder();
        var db = await Database(folder, present: false);
        var tsv = folder.File("empty.tsv"); File.WriteAllBytes(tsv, []);
        var result = await db.CreateSharedParkBackupsAsync(await Batch(db, folder, tsv), PrivateDirectory(folder), [], [], None);
        Check.NotNull(result.TsvBackup, "présent vide reste distinct d’absent");
        Check.Equal(0L, result.TsvBackup!.Length, "taille zéro mesurée"); VerifyBytes(result.TsvBackup);
    }

    [Test]
    public static async Task Foreign_identity_revision_generation_and_fingerprints_are_refused_before_copying()
    {
        using var folder = new TemporaryFolder();
        var db = await Database(folder);
        var tsv = folder.File("source.tsv"); File.WriteAllBytes(tsv, Tsv());
        var batch = await Batch(db, folder, tsv); var root = PrivateDirectory(folder);
        SharedParkBatch[] invalid = [batch with { StoreId = new string('0', 64) }, batch with { DomainDn = "DC=foreign,DC=local" },
            batch with { Revision = 1 }, batch with { Generation = 1 }, batch with { Legacy = true }, batch with { LocalExists = false },
            batch with { RowsFingerprint = new string('0', 64) }, batch with { LocalFingerprint = new string('0', 64) },
            batch with { RemoteSha256 = new string('0', 64) }, batch with { RemoteExists = false }, batch with { ExpiresAt = batch.CreatedAt }];
        foreach (var altered in invalid)
        { await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(altered, root, [], [], None), "qualification complète avant copie"); }
        Check.Equal(0, Directory.EnumerateFileSystemEntries(root).Count(), "aucune preuve créée pour un lot différent");
    }

    [Test]
    public static async Task A_D1_change_without_revision_increment_invalidates_the_preview()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder);
        var batch = await Batch(db, folder, folder.File("absent.tsv")); var root = PrivateDirectory(folder);
        using (var change = new SqliteDatabase(db.Path, false))
        { change.Execute("INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts) VALUES('PC1','PC1','2026-10-20T10:00:00Z','SESSION','alice',2);"); }
        await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None), "empreinte des lignes comparée même à révision inchangée");
        Check.Equal(0, Directory.EnumerateFileSystemEntries(root).Count(), "aucune copie certifiée");
    }

    [Test]
    public static async Task A_concurrent_SQLite_change_outside_park_is_refused_and_keeps_the_copy()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder);
        var batch = await Batch(db, folder, folder.File("absent.tsv")); var root = PrivateDirectory(folder);
        await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None, () =>
        {
            using var change = new SqliteDatabase(db.Path, false);
            change.Execute("INSERT INTO schema_info(key,value) VALUES('concurrent-proof','changed');");
        }), "la sauvegarde ne prétend pas être actuelle après un commit concurrent");
        var preserved = System.IO.Path.Combine(root, batch.Id, "initial.db");
        Check.True(File.Exists(preserved), "preuve créée conservée après conflit");
        using var copy = new SqliteDatabase(preserved, true);
        Check.Equal(0L, (long)copy.Scalar("SELECT count(*) FROM schema_info WHERE key='concurrent-proof';")!, "la copie reste la transaction initiale cohérente");
    }

    [Test]
    public static async Task A_concurrent_TSV_replacement_is_refused_and_initial_bytes_remain()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var tsv = folder.File("source.tsv"); var original = Tsv(); File.WriteAllBytes(tsv, original);
        var batch = await Batch(db, folder, tsv); var root = PrivateDirectory(folder);
        await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None,
            () => File.WriteAllBytes(tsv, Tsv("PC2"))), "changement TSV détecté à la relecture finale");
        Check.True(original.SequenceEqual(File.ReadAllBytes(System.IO.Path.Combine(root, batch.Id, "initial.tsv"))), "les octets initiaux restent conservés");
    }

    [Test]
    public static async Task Appearance_of_a_previously_absent_source_is_not_certified()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var tsv = folder.File("absent.tsv"); var batch = await Batch(db, folder, tsv);
        var hookRan = false;
        var error = await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, PrivateDirectory(folder), [], [], None,
            () => { hookRan = true; File.WriteAllBytes(tsv, []); }), "absent et présent vide ne sont pas confondus");
        Check.True(hookRan && File.Exists(tsv), "l’apparition a réellement eu lieu après capture");
        Check.Contains("TSV modifié", error.Message, "la présence finale déclenche le refus");
    }

    [Test]
    public static async Task Same_length_corruption_after_capture_is_detected_by_the_final_SHA_read()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var tsv = folder.File("source.tsv"); File.WriteAllBytes(tsv, Tsv());
        var batch = await Batch(db, folder, tsv); var root = PrivateDirectory(folder);
        var hookRan = false;
        var error = await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None, () =>
        {
            var copy = System.IO.Path.Combine(root, batch.Id, "initial.tsv");
            // The owning user can deliberately reopen permissions; this is corruption, not a proof of cryptographic authenticity.
            SetFileRights(copy, FileSystemRights.FullControl);
            File.WriteAllBytes(copy, Tsv("PC2"));
            SetFileRights(copy, ReadRights);
            hookRan = true;
        }), "même longueur et DACL conforme ne remplacent jamais le SHA des octets relus");
        var altered = File.ReadAllBytes(System.IO.Path.Combine(root, batch.Id, "initial.tsv"));
        Check.True(hookRan && altered.SequenceEqual(Tsv("PC2")), "corruption réellement injectée et conservée");
        Check.Equal(Tsv().Length, altered.Length, "corruption à longueur strictement identique");
        Check.Contains("altérée après création", error.Message, "refus par comparaison SHA finale");
    }

    [Test]
    public static async Task Cancellation_after_capture_keeps_both_created_copies()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder);
        var tsv = folder.File("source.tsv"); File.WriteAllBytes(tsv, Tsv());
        var batch = await Batch(db, folder, tsv); var root = PrivateDirectory(folder);
        using var cancel = new CancellationTokenSource();
        await Check.ThrowsAsync<OperationCanceledException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], cancel.Token, cancel.Cancel), "annulation remontée sans résultat certifié");
        Check.True(File.Exists(System.IO.Path.Combine(root, batch.Id, "initial.db")), "copie SQLite conservée");
        Check.True(File.Exists(System.IO.Path.Combine(root, batch.Id, "initial.tsv")), "copie TSV conservée");
    }

    [Test]
    public static async Task A_duplicate_batch_never_truncates_or_overwrites_its_copies()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder);
        var tsv = folder.File("source.tsv"); File.WriteAllBytes(tsv, Tsv());
        var batch = await Batch(db, folder, tsv); var root = PrivateDirectory(folder);
        var first = await db.CreateSharedParkBackupsAsync(batch, root, [], [], None);
        await Check.ThrowsAsync<IOException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None), "identifiant déjà créé refusé sans réemploi");
        VerifyBytes(first.SqliteBackup!); VerifyBytes(first.TsvBackup!);
        Check.Equal(1, Directory.EnumerateDirectories(root).Count(), "aucune alternative silencieuse à l’ID demandé");
    }

    [Test]
    public static async Task An_incompatible_existing_directory_ACL_is_never_repaired()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var batch = await Batch(db, folder, folder.File("absent.tsv")); var root = PrivateDirectory(folder);
        var security = new DirectoryInfo(root).GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.Read, AccessControlType.Allow));
        new DirectoryInfo(root).SetAccessControl(security);
        var before = new DirectoryInfo(root).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.Access);
        await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None), "dossier trop permissif refusé");
        Check.Equal(before, new DirectoryInfo(root).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.Access), "DACL préexistante laissée intacte");
        Check.Equal(0, Directory.EnumerateFileSystemEntries(root).Count(), "aucune création dans un dossier non privé");
    }

    [Test]
    public static async Task Dev_protected_source_and_configuration_destinations_are_refused()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var tsv = folder.File("absent.tsv"); var batch = await Batch(db, folder, tsv); var root = PrivateDirectory(folder);
        await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, folder.File("dev"), [], [], None), "dev jamais destination");
        await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [root], None), "dossier protégé jamais destination");
        await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, folder.Path, [], [], None), "dossier des sources jamais destination privée");
        await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, root, [System.IO.Path.Combine(root, "settings.json")], [], None), "dossier contenant une configuration refusé");
        Check.Equal(0, Directory.EnumerateFileSystemEntries(root).Count(), "aucune copie avant qualification");
    }

    [Test]
    public static async Task A_reparse_directory_is_refused_without_writing_through_it()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var batch = await Batch(db, folder, folder.File("absent.tsv")); var root = PrivateDirectory(folder);
        var link = folder.File("linked-backups"); Directory.CreateSymbolicLink(link, root);
        await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, link, [], [], None), "répertoire redirigé refusé");
        Check.Equal(0, Directory.EnumerateFileSystemEntries(root).Count(), "aucune écriture vers la cible du lien");
    }

    [Test]
    public static async Task The_TSV_size_bound_is_checked_before_any_copy()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var tsv = folder.File("source.tsv"); File.WriteAllBytes(tsv, Tsv());
        var batch = await Batch(db, folder, tsv); var root = PrivateDirectory(folder);
        using (var file = new FileStream(tsv, FileMode.Open, FileAccess.Write)) { file.SetLength(SharedParkFile.MaxBytes + 1L); }
        var error = await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None), "16 Mio maximum avant allocation/copie");
        Check.Contains("16 Mio", error.Message, "refus de taille avant décodage TSV");
        Check.Equal(0, Directory.EnumerateFileSystemEntries(root).Count(), "aucune preuve partielle présentée");
    }

    [Test]
    public static async Task The_SQLite_physical_size_bound_is_checked_before_native_backup()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder);
        var batch = await Batch(db, folder, folder.File("absent.tsv")); var root = PrivateDirectory(folder);
        using (var file = new FileStream(db.Path, FileMode.Open, FileAccess.Write)) { file.SetLength(SharedParkBackupFiles.MaxSqliteBytes + 1); }
        var error = await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None), "base trop grande refusée avant appel BackupTo");
        Check.Contains("256 Mio", error.Message, "refus par borne physique avant SQLite");
        Check.Equal(0, Directory.EnumerateFileSystemEntries(root).Count(), "aucune copie créée au-delà de la borne SQLite");
    }

    [Test]
    public static async Task Retained_batch_quota_refuses_without_deleting_evidence()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var batch = await Batch(db, folder, folder.File("absent.tsv")); var root = PrivateDirectory(folder);
        for (var i = 0; i < SharedParkBackupFiles.MaxBatches; i++) { Directory.CreateDirectory(System.IO.Path.Combine(root, WritePlans.NewId())); }
        var error = await Check.ThrowsAsync<IOException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None), "quota refuse sans rotation implicite");
        Check.Contains("Quota de 32", error.Message, "refus par nombre de lots");
        Check.Equal(SharedParkBackupFiles.MaxBatches, Directory.EnumerateDirectories(root).Count(), "tous les lots antérieurs conservés");
    }

    [Test]
    public static async Task A_precancelled_request_creates_no_directory_or_copy()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var batch = await Batch(db, folder, folder.File("absent.tsv")); var root = PrivateDirectory(folder);
        using var cancel = new CancellationTokenSource(); cancel.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], cancel.Token), "annulation initiale respectée");
        Check.Equal(0, Directory.EnumerateFileSystemEntries(root).Count(), "rien créé");
    }

    [Test]
    public static async Task A_preexisting_admission_lock_is_never_adopted_or_deleted()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var batch = await Batch(db, folder, folder.File("absent.tsv")); var root = PrivateDirectory(folder);
        var path = System.IO.Path.Combine(root, ".capture.lock"); File.WriteAllText(path, "preuve-d-un-autre-appel");
        await Check.ThrowsAsync<IOException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None), "verrou existant non adopté");
        Check.Equal("preuve-d-un-autre-appel", File.ReadAllText(path), "verrou existant jamais supprimé ni tronqué");
        Check.Equal(0, Directory.EnumerateDirectories(root).Count(), "aucun lot créé derrière un verrou étranger");
    }

    [Test]
    public static async Task A_root_file_cannot_be_ignored_by_quota_admission()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var batch = await Batch(db, folder, folder.File("absent.tsv")); var root = PrivateDirectory(folder);
        var path = System.IO.Path.Combine(root, "unexpected.dat"); File.WriteAllText(path, "preserved");
        var error = await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None), "fichier inattendu refusé");
        Check.Contains("Entrée de sauvegarde", error.Message, "quota inspecte toute entrée racine");
        Check.Equal("preserved", File.ReadAllText(path), "preuve étrangère intacte");
        Check.False(File.Exists(System.IO.Path.Combine(root, ".capture.lock")), "seul notre verrou est libéré");
    }

    [Test]
    public static async Task A_sealed_copy_replaced_with_a_symbolic_link_is_refused()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var tsv = folder.File("source.tsv"); File.WriteAllBytes(tsv, Tsv());
        var batch = await Batch(db, folder, tsv); var root = PrivateDirectory(folder); var hookRan = false;
        var error = await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None, () =>
        {
            var copy = System.IO.Path.Combine(root, batch.Id, "initial.tsv");
            File.Delete(copy); File.CreateSymbolicLink(copy, tsv); hookRan = true;
        }), "une référence n’est jamais certifiée à travers un lien");
        Check.True(hookRan, "remplacement réellement injecté après scellement");
        Check.Contains("redirigée", error.Message, "attributs du handle terminal inspectés");
        Check.Equal(batch.RemoteSha256, Hash(tsv), "source TSV inchangée");
    }

    [Test]
    public static async Task A_directory_ACL_changed_during_capture_is_refused_without_repair()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var batch = await Batch(db, folder, folder.File("absent.tsv")); var root = PrivateDirectory(folder); var hookRan = false;
        var error = await Check.ThrowsAsync<InvalidDataException>(() => db.CreateSharedParkBackupsAsync(batch, root, [], [], None, () =>
        {
            var security = new DirectoryInfo(root).GetAccessControl();
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.Read, AccessControlType.Allow));
            new DirectoryInfo(root).SetAccessControl(security); hookRan = true;
        }), "protection finale relue même lorsque les deux sources sont absentes");
        Check.True(hookRan, "ACL réellement changée après admission");
        Check.Contains("DACL privée", error.Message, "refus de protection finale");
        Check.True(new DirectoryInfo(root).GetAccessControl().GetAccessRules(true, true, typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>().Any(r => r.IdentityReference.Value == "S-1-1-0"), "ACL étrangère non réparée implicitement");
    }

    [Test]
    public static async Task Admission_stays_exclusive_until_the_first_capture_finishes()
    {
        using var folder = new TemporaryFolder(); var db = await Database(folder, present: false);
        var batch = await Batch(db, folder, folder.File("absent.tsv")); var root = PrivateDirectory(folder);
        for (var i = 0; i < SharedParkBackupFiles.MaxBatches - 1; i++) { Directory.CreateDirectory(System.IO.Path.Combine(root, WritePlans.NewId())); }
        using var release = new ManualResetEventSlim();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var first = db.CreateSharedParkBackupsAsync(batch, root, [], [], None, () =>
        {
            entered.SetResult();
            if (!release.Wait(TimeSpan.FromSeconds(15))) { throw new TimeoutException("Rendez-vous de test non libéré."); }
        });
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(15));
            await Check.ThrowsAsync<IOException>(() => db.CreateSharedParkBackupsAsync(batch with { Id = WritePlans.NewId() }, root, [], [], None), "admission occupée refusée");
            Check.Equal(SharedParkBackupFiles.MaxBatches, Directory.EnumerateDirectories(root).Count(), "aucun trente-troisième lot");
            Check.True(File.Exists(System.IO.Path.Combine(root, ".capture.lock")), "verrou du premier appel toujours présent");
        }
        finally { release.Set(); }
        await first;
        Check.False(File.Exists(System.IO.Path.Combine(root, ".capture.lock")), "le premier propriétaire libère son seul verrou");
        var error = await Check.ThrowsAsync<IOException>(() => db.CreateSharedParkBackupsAsync(batch with { Id = WritePlans.NewId() }, root, [], [], None), "quota final refuse après libération");
        Check.Contains("Quota de 32", error.Message, "réservation devenue preuve retenue");
    }
}
