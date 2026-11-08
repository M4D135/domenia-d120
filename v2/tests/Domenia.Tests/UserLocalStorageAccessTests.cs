using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class UserLocalStorageAccessTests
{
    [Test]
    public static async Task Profile_creation_is_private_and_readonly_location_does_not_change_any_acl()
    {
        using var folder = new TemporaryFolder();
        var app = folder.File("wad"); Directory.CreateDirectory(app);
        File.WriteAllText(Path.Combine(app, "Domenia.config.json"), "{\"LocalStore\":{\"Mode\":\"UserLocal\"}}");
        var user = folder.File("profile"); var cache = new CompatibleDirectoryCache(app, user, "test.local", TestClock.Fixed());
        var parentAcl = Acl(folder.Path);
        var initial = await cache.LocationAsync(default);
        Check.Equal("À créer", initial.State, "absence qualifiée sans écriture");
        Check.False(Directory.Exists(user), "consulter ne crée même pas le profil");
        Check.Equal(parentAcl, Acl(folder.Path), "aucune modification du parent général");
        var database = await cache.DatabaseAsync(default); await database.InitializeAsync(default);
        var data = Path.Combine(user, "Data");
        var directoryAcl = new DirectoryInfo(data).GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner);
        Check.True(directoryAcl.AreAccessRulesProtected, "dossier neuf privé dès sa création");
        UserLocalStorageProtection.Verify(directoryAcl);
        var fileAcl = new FileInfo(database.Path).GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner);
        Check.True(fileAcl.AreAccessRulesProtected, "base créée avec DACL explicite");
        UserLocalStorageProtection.Verify(fileAcl);
        var before = Acl(data); var fileBefore = Acl(database.Path, true);
        Check.Equal("Lecture disponible", (await cache.LocationAsync(default)).State, "lecture réelle de la base");
        Check.Equal(before, Acl(data), "la consultation laisse les droits du dossier intacts");
        Check.Equal(fileBefore, Acl(database.Path, true), "la consultation laisse les droits de la base intacts");
        Check.Equal(parentAcl, Acl(folder.Path), "parent non possédé inchangé après création");

        // Change the real file ACL after initialization: the next writer must inspect it again.
        var broad = new FileInfo(database.Path).GetAccessControl(AccessControlSections.Access);
        broad.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.Read, AccessControlType.Allow));
        new FileInfo(database.Path).SetAccessControl(broad);
        var changed = Acl(database.Path, true); var bytes = File.ReadAllBytes(database.Path);
        Check.Throws<IOException>(() => { using var write = database.Open(false); }, "droits élargis refusés avant connexion d’écriture");
        Check.Equal(changed, Acl(database.Path, true), "aucun retrait automatique des droits d’un fichier existant");
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(database.Path)), "base conservée après refus");
        Check.Equal("Lecture disponible", (await cache.LocationAsync(default)).State, "lecture toujours possible, aucune permission corrigée en douce");
    }

    [Test]
    public static async Task Existing_broad_profile_is_not_repaired_and_portable_permissions_are_not_changed()
    {
        using var folder = new TemporaryFolder();
        foreach (var portable in new[] { false, true })
        {
            var prefix = portable ? "portable" : "user"; var app = folder.File(prefix + "/wad"); Directory.CreateDirectory(app);
            File.WriteAllText(Path.Combine(app, "Domenia.config.json"), "{\"LocalStore\":{\"Mode\":\"" + (portable ? "Portable" : "UserLocal") + "\"}}");
            var user = folder.File(prefix + "/profile"); var data = Path.Combine(portable ? app : user, portable ? "data" : "Data");
            Directory.CreateDirectory(data); var directory = new DirectoryInfo(data);
            var access = directory.GetAccessControl(AccessControlSections.Access);
            access.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.Read,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            directory.SetAccessControl(access); var before = Acl(data);
            var cache = new CompatibleDirectoryCache(app, user, "test.local", TestClock.Fixed());
            _ = await cache.LocationAsync(default); Check.Equal(before, Acl(data), "lecture sans retrait de droits");
            var database = await cache.DatabaseAsync(default);
            if (portable) { await database.InitializeAsync(default); Check.True(File.Exists(database.Path), "portable conserve son modèle d’accès"); }
            else { await Check.ThrowsAsync<IOException>(() => database.InitializeAsync(default), "ancien dossier utilisateur trop ouvert : refus explicite"); Check.False(File.Exists(database.Path), "aucune base créée dans un dossier non privé"); }
            Check.Equal(before, Acl(data), "dossier existant jamais reconfiguré");
        }
    }

    [Test]
    public static void Orphan_redirected_companion_is_refused_before_creating_the_database()
    {
        using var folder = new TemporaryFolder(); var root = folder.File("private"); var path = Path.Combine(root, "missing.db");
        var protection = new UserLocalStorageProtection(root); protection.PrepareDirectory(path, default);
        var target = folder.File("unrelated.txt"); File.WriteAllText(target, "conserver");
        File.CreateSymbolicLink(path + "-wal", target);
        try
        {
            Check.Throws<InvalidDataException>(() => protection.PrepareFile(path, default), "annexe orpheline redirigée refusée avant ouverture");
            Check.False(File.Exists(path), "même la base vide n’est pas créée");
            Check.Equal("conserver", File.ReadAllText(target), "cible de l’annexe intacte");
        }
        finally { File.Delete(path + "-wal"); }
    }

    [Test]
    public static async Task Preference_access_is_observed_without_a_probe_and_real_failed_writes_remain_pending()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("prefs/preferences.json");
        using var store = new FilePreferenceStore(path, new RecordingJournal());
        Check.Equal("À créer", (await store.InspectAccessAsync(default)).State, "absence, pas promesse writable");
        Check.False(Directory.Exists(Path.GetDirectoryName(path)), "aucun fichier de test ni dossier");
        await store.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(100), default);
        var original = File.ReadAllBytes(path);
        using (var locked = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            Check.Equal("Non lisible", (await store.InspectAccessAsync(default)).State, "vrai fichier occupé, pas absent");
            await Check.ThrowsAsync<IOException>(() => store.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(110), default), "échec réel sans écrasement illisible");
        }
        var refused = await store.InspectAccessAsync(default);
        Check.Equal("Dernier enregistrement refusé", refused.State, "refus mémorisé même après libération du fichier");
        Check.Equal(1, refused.PendingChanges, "choix conservé dans la session");
        Check.True(store.TryGet(PreferenceApproval.ZoomKey, out var pending) && pending.GetInt32() == 110, "préférence de session conservée");
        Check.True(original.SequenceEqual(File.ReadAllBytes(path)), "ancien document intact");
        File.SetAttributes(path, File.GetAttributes(path) | FileAttributes.ReadOnly);
        try
        {
            Check.Equal("Lecture seule", (await store.InspectAccessAsync(default)).State, "attribut observé sans écriture");
            await Check.ThrowsAsync<UnauthorizedAccessException>(() => store.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(120), default), "le remplacement réel du document readonly est refusé");
            Check.True(original.SequenceEqual(File.ReadAllBytes(path)), "document readonly conservé");
            Check.Equal(1, Directory.EnumerateFiles(Path.GetDirectoryName(path)!).Count(), "temporaire propre nettoyé après refus");
        }
        finally { File.SetAttributes(path, File.GetAttributes(path) & ~FileAttributes.ReadOnly); }
        await store.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(130), default);
        var success = await store.InspectAccessAsync(default);
        Check.Equal("Lecture disponible", success.State, "dernier refus effacé seulement après remplacement réussi");
        Check.Equal(0, success.PendingChanges, "choix réellement enregistrés");
        Check.Contains("prochain enregistrement", success.Reason, "aucune garantie de droit futur");
    }

    [Test]
    public static async Task Network_locations_are_rejected_before_io_and_legacy_is_reported_only_from_the_actual_inspection()
    {
        Check.Throws<InvalidDataException>(() => new FilePreferenceStore(@"\\unreachable\share\preferences.json", new RecordingJournal()), "préférences réseau refusées avant ouverture");
        Check.Throws<ArgumentException>(() => new DomeniaDatabase(@"\\unreachable\share\database.db", Fixtures.Root, TestClock.Fixed()), "base UNC refusée avant ouverture");
        Check.Throws<InvalidDataException>(() => CompatibleDirectoryCache.ValidateLocalPath(@"\\unreachable\share\database.db"), "admission UNC refuse tout accès implicite");
        using var folder = new TemporaryFolder(); var user = folder.File("profile");
        var cache = new CompatibleDirectoryCache(folder.File("wad"), user, "test.local", TestClock.Fixed());
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache);
        var reader = new AdSettingsReader(source);
        Check.Null((await reader.LocationAsync(default)).LegacyLocation, "aucun chemin historique présumé");
        var database = await cache.DatabaseAsync(default); await database.InitializeAsync(default);
        Directory.CreateDirectory(Path.Combine(user, "Index"));
        File.WriteAllText(Path.Combine(user, "Index", "recherches.tsv"), "alice\t2026-10-20T12:00:00Z\t1\t3\t2\t1\tPC1\n");
        var snapshot = await reader.LocalStoreAsync(default);
        Check.True(snapshot.Legacy.Found && snapshot.Legacy.ReadProblem is null, "vraies anciennes données consultées");
        var location = await reader.LocationAsync(default);
        Check.Equal(snapshot.Legacy.Location, location.LegacyLocation, "source réellement examinée, pas chemin calculé pour l’interface");
        var policy = DataPolicyRules.Build(StoragePolicyRules.Default, false, new(null, null, null, null, null, database.Path, null, false, false)
        { Legacy = location.LegacyLocation, PreferenceAccess = "Lecture seule · Enregistrement refusé" });
        Check.Equal(snapshot.Legacy.Location, policy.Rows.Single(r => r.Category == "legacy").Location, "raccord réel à la politique affichée");
        Check.Contains("Lecture seule", policy.Rows.Single(r => r.Category == "preference").Content, "accès réel visible");
        var unknown = DataPolicyRules.Build(StoragePolicyRules.Default, false, new(null, null, null, null, null, null, null, false, false));
        Check.Contains("non déterminé", unknown.Rows.Single(r => r.Category == "legacy").Location, "absence de consultation honnête");
        var configuration = ConfigurationRules.Read(Encoding.UTF8.GetBytes("{\"LocalStore\":{\"Mode\":\"UserLocal\",\"DatabaseFile\":\"production.db\"}}"), "Domenia.config.json");
        foreach (var key in new[] { "Mode", "DatabaseFile" }) Check.Equal("applied", configuration.Sections.Single(s => s.Id == "LocalStore").Entries.Single(e => e.Key == key).Use, "réglage réellement appliqué : " + key);
    }

    private static string Acl(string path, bool file = false) => (file
        ? (FileSystemSecurity)new FileInfo(path).GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner)
        : new DirectoryInfo(path).GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner))
        .GetSecurityDescriptorSddlForm(AccessControlSections.Access | AccessControlSections.Owner);
}
