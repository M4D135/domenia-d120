using System.Security.Cryptography;
using System.Text.Json;
using Domenia.App;
using Domenia.Core;

namespace Domenia.Tests;

internal static partial class PackageLifecycleTests
{
    private static readonly string[] Components = ["Domenia.exe", "Domenia.dll", "Domenia.deps.json", "Domenia.runtimeconfig.json",
        "Domenia.Core.dll", "Domenia.Ad.dll", "Domenia.Store.dll", "Domenia.Inventory.dll", "Domenia.Engine.dll",
        "Domenia.Bridge.dll", "Domenia.Simulation.dll", "web/index.html", "runtime/webview2/msedgewebview2.exe", "web/js/main.js"];
    private static PackageNativeSignature UnsignedFixture(FileStream _) => new(PackagePublisherTrust.NoSignature, null, null);
    private static readonly CancellationToken None = CancellationToken.None;

    private sealed class Fixture : IDisposable
    {
        private readonly TemporaryFolder folder = new();
        internal string Root => folder.Path;
        internal string Source => Path.Combine(Root, "source");
        internal string Target => Path.Combine(Root, "target");
        internal string Storage => Path.Combine(Root, ".target.domenia-lifecycle");
        internal Fixture(bool fresh = false, PackageRelease? old = null, PackageRelease? next = null)
        {
            Directory.CreateDirectory(Source); Directory.CreateDirectory(Target);
            Pack(Source, "new", next); if (!fresh) { Pack(Target, "old", old); }
        }
        internal PackageLifecycle Delivery(Action<string>? hook = null) => new(Source, TestClock.Fixed()) { Checkpoint = hook, SignatureVerifier = UnsignedFixture, PublisherPolicy = PackagePublisherPolicy.Unconfigured };
        internal string Transaction => Directory.GetDirectories(Storage).Select(Path.GetFileName).Single()!;
        internal string Backup => Path.Combine(Storage, Transaction, "old");
        public void Dispose() => folder.Dispose();
    }

    private static void Pack(string root, string label, PackageRelease? release = null)
    {
        foreach (var name in Components)
        {
            var path = Path.Combine(root, name); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, label + ":" + name);
        }
        File.WriteAllBytes(Path.Combine(root, ".lifecycle.lock"), []);
        var names = Components.AsEnumerable();
        if (release is not null)
        {
            File.WriteAllText(Path.Combine(root, "package-release.json"), JsonSerializer.Serialize(release, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
            names = names.Append("package-release.json");
        }
        Manifest(root, names);
    }
    private static void Manifest(string root, IEnumerable<string> names)
    {
        var files = names.Select(name => new { path = name, length = new FileInfo(Path.Combine(root, name)).Length, sha256 = Hash(Path.Combine(root, name)) });
        File.WriteAllText(Path.Combine(root, PackageIntegrity.ManifestName), JsonSerializer.Serialize(new { format = 1, files }));
    }
    private static string Hash(string file) => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(file)));
    private static PackageRelease Release(char identity, int revision = 1) => new("2.0.0-dev", "2.0.0-dev+" + new string(identity, 64), 11, revision);
    private static void Interrupt(Fixture fixture, string point)
    {
        var reached = false;
        var delivery = fixture.Delivery(stage => { if (!reached && stage == point) { reached = true; throw new IOException("Injected delivery interruption"); } });
        var plan = delivery.PreviewUpdate(fixture.Target, None);
        var error = Check.Throws<IOException>(() => delivery.Update(fixture.Target, plan.Confirmation, None), "interruption injectée");
        Check.Equal("Injected delivery interruption", error.Message, "preuve du chemin précis atteint"); Check.True(reached, "barrière atteinte");
        Check.True(File.Exists(Path.Combine(fixture.Target, ".update.pending")), "marqueur conservé");
        Check.Contains("interrompue", Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(fixture.Target, true).Dispose(), "lancement bloqué").Message, "garde pending avant lecture du code");
    }

    [Test]
    public static void Delivery_preview_is_read_only_and_rejects_wrong_confirmation_before_mutation()
    {
        using var fixture = new Fixture(); var delivery = fixture.Delivery();
        var before = Hash(Path.Combine(fixture.Target, PackageIntegrity.ManifestName));
        var preview = delivery.PreviewUpdate(fixture.Target, None);
        Check.Equal(Components.Length, preview.Replaced.Count, "vraie liste de code à installer");
        Check.True(preview.Advice.Any(a => a.Contains("inconnu", StringComparison.Ordinal)), "ancien schéma absent reste inconnu");
        Check.False(Directory.Exists(fixture.Storage), "aucune préparation sur aperçu");
        Check.Throws<InvalidDataException>(() => delivery.Update(fixture.Target, "wrong", None), "confirmation exacte requise");
        Check.False(Directory.Exists(fixture.Storage), "aucune sauvegarde sur mauvais consentement");
        Check.Equal(before, Hash(Path.Combine(fixture.Target, PackageIntegrity.ManifestName)), "code inchangé");
    }

    [Test]
    public static void First_delivery_and_update_activate_only_after_manifest_last_and_whole_pack_verification()
    {
        foreach (var fresh in new[] { true, false })
        {
            using var fixture = new Fixture(fresh); var beforeManifest = !fresh ? Hash(Path.Combine(fixture.Target, PackageIntegrity.ManifestName)) : null;
            var beforeSeen = false; var verifiedSeen = false;
            var delivery = fixture.Delivery(point =>
            {
                if (point == "before-manifest")
                {
                    beforeSeen = true;
                    Check.Equal("new:Domenia.exe", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "code déjà copié avant manifeste");
                    if (!fresh) { Check.Equal(beforeManifest, Hash(Path.Combine(fixture.Target, PackageIntegrity.ManifestName)), "ancien manifeste encore présent"); }
                    else { Check.False(File.Exists(Path.Combine(fixture.Target, PackageIntegrity.ManifestName)), "aucun manifeste prématuré"); }
                }
                if (point == "verified-before-activation")
                {
                    verifiedSeen = true;
                    Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(fixture.Target, true).Dispose(), "pending bloque même après vérification finale");
                }
            });
            var plan = delivery.PreviewUpdate(fixture.Target, None); var result = delivery.Update(fixture.Target, plan.Confirmation, None);
            Check.True(beforeSeen && verifiedSeen, "ordre observable réellement atteint");
            using var pack = PackageIntegrity.Open(fixture.Target, true);
            Check.Equal(plan.SourceIdentity, pack.ManifestHash, "paquet actif physiquement relu");
            Check.Equal(pack.ManifestHash, result.ActiveIdentity, "résultat lié aux octets observés");
            Check.False(File.Exists(Path.Combine(fixture.Target, ".update.pending")), "seul point d’activation franchi");
            if (!fresh) { using var backup = PackageIntegrity.Open(fixture.Backup, true); Check.Equal(beforeManifest, backup.ManifestHash, "sauvegarde complète conservée"); }
        }
    }

    [Test]
    public static void Running_target_keeps_its_code_and_refuses_delivery_before_any_backup()
    {
        using var fixture = new Fixture(); var delivery = fixture.Delivery(); var plan = delivery.PreviewUpdate(fixture.Target, None);
        using var running = PackageIntegrity.Open(fixture.Target, true);
        Check.Throws<IOException>(() => delivery.Update(fixture.Target, plan.Confirmation, None), "verrou du lanceur respecté");
        Check.False(Directory.Exists(fixture.Storage), "aucune sauvegarde ni écriture préparée sous instance active");
        Check.Equal("old:Domenia.exe", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "code actif conservé");
    }

    [Test]
    public static void Interrupted_delivery_resumes_explicitly_at_every_mutating_phase()
    {
        foreach (var phase in new[] { "pending-written", "component-staged", "component-replaced", "before-manifest", "manifest-replaced", "verified-before-activation" })
        {
            using var fixture = new Fixture(); Interrupt(fixture, phase);
            var delivery = fixture.Delivery();
            var plan = delivery.PreviewRecovery(fixture.Target, fixture.Transaction, false, None);
            var result = delivery.Recover(fixture.Target, fixture.Transaction, false, plan.Confirmation, None);
            using var pack = PackageIntegrity.Open(fixture.Target, true);
            Check.Equal(result.ActiveIdentity, pack.ManifestHash, "reprise relue après " + phase);
            Check.Equal("new:Domenia.exe", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "nouveau code entier");
            using var backup = PackageIntegrity.Open(fixture.Backup, true); Check.True(backup.Packaged, "preuve ancienne conservée");
        }
    }

    [Test]
    public static void Explicit_restore_reloads_verified_old_code_without_touching_configuration_or_database()
    {
        using var fixture = new Fixture(old: Release('a'), next: Release('b', 2));
        var database = Path.Combine(fixture.Root, "operator.db"); File.WriteAllText(database, "operator data");
        var config = Path.Combine(fixture.Target, "Domenia.config.json"); File.WriteAllText(config, "operator configuration");
        var delivery = fixture.Delivery(); var update = delivery.PreviewUpdate(fixture.Target, None);
        Check.True(update.Advice.Any(a => a.Contains("plus récent", StringComparison.Ordinal)), "avis de schéma avant confirmation");
        delivery.Update(fixture.Target, update.Confirmation, None);
        var restore = delivery.PreviewRecovery(fixture.Target, fixture.Transaction, true, None);
        Check.True(restore.Advice.Any(a => a.Contains("code plus ancien", StringComparison.Ordinal)), "retour de schéma expliqué, sans toucher aux données");
        delivery.Recover(fixture.Target, fixture.Transaction, true, restore.Confirmation, None);
        using var verified = PackageIntegrity.Open(fixture.Target, true);
        Check.Equal("old:Domenia.exe", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "ancienne version entière restaurée");
        Check.Equal("operator data", File.ReadAllText(database), "aucune ouverture ni écriture SQLite");
        Check.Equal("operator configuration", File.ReadAllText(config), "configuration conservée");
    }

    [Test]
    public static void Damaged_backup_or_foreign_current_bytes_never_get_overwritten_by_recovery()
    {
        foreach (var damageBackup in new[] { true, false })
        {
            using var fixture = new Fixture(); Interrupt(fixture, "component-replaced");
            var path = Path.Combine(damageBackup ? fixture.Backup : fixture.Target, "Domenia.Core.dll"); File.WriteAllText(path, "foreign bytes");
            Check.Throws<InvalidDataException>(() => fixture.Delivery().PreviewRecovery(fixture.Target, fixture.Transaction, true, None), "preuve incohérente refusée");
            Check.Equal("foreign bytes", File.ReadAllText(path), "octets étrangers conservés");
            Check.True(File.Exists(Path.Combine(fixture.Target, ".update.pending")), "activation impossible");
        }
    }

    [Test]
    public static void Cancellation_after_pending_keeps_proofs_and_requires_a_fresh_explicit_recovery()
    {
        using var fixture = new Fixture(); using var stop = new CancellationTokenSource(); var reached = false;
        var delivery = fixture.Delivery(point => { if (point == "pending-written") { reached = true; stop.Cancel(); } });
        var plan = delivery.PreviewUpdate(fixture.Target, None);
        Check.Throws<OperationCanceledException>(() => delivery.Update(fixture.Target, plan.Confirmation, stop.Token), "annulation après journal durable");
        Check.True(reached, "pas un refus avant le chemin voulu");
        using (var backup = PackageIntegrity.Open(fixture.Backup, true)) { Check.True(backup.Packaged, "sauvegarde déjà vérifiée"); }
        var fresh = fixture.Delivery(); var restore = fresh.PreviewRecovery(fixture.Target, fixture.Transaction, true, None);
        fresh.Recover(fixture.Target, fixture.Transaction, true, restore.Confirmation, None);
        Check.Equal("old:Domenia.exe", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "retour seulement après demande explicite");
    }

    [Test]
    public static void Recovery_refuses_a_pending_replacement_between_preview_and_exclusive_open()
    {
        using var fixture = new Fixture(); Interrupt(fixture, "component-replaced");
        var marker = Path.Combine(fixture.Target, ".update.pending"); var original = File.ReadAllText(marker); var reached = false;
        var foreign = "{\"format\":1,\"transaction\":\"" + Guid.NewGuid().ToString("N") + "\",\"journalSha256\":\"" + new string('a', 64) + "\"}";
        var delivery = fixture.Delivery(point =>
        {
            if (point != "before-marker-open" || reached) { return; }
            reached = true; File.Move(marker, Path.Combine(fixture.Root, "original.pending")); File.WriteAllText(marker, foreign);
        });
        var plan = delivery.PreviewRecovery(fixture.Target, fixture.Transaction, false, None);
        Check.Contains("remplacé", Check.Throws<InvalidDataException>(() => delivery.Recover(fixture.Target, fixture.Transaction, false, plan.Confirmation, None), "remplacement précis refusé").Message, "refus au handle avant troncature");
        Check.True(reached, "course réellement exercée"); Check.Equal(foreign, File.ReadAllText(marker), "entrée étrangère intacte");
        Check.Equal(original, File.ReadAllText(Path.Combine(fixture.Root, "original.pending")), "preuve originale conservée");
    }

    [Test]
    public static void Explicit_recovery_repairs_the_exact_empty_marker_that_was_previewed()
    {
        using var fixture = new Fixture(); Interrupt(fixture, "pending-written");
        File.WriteAllBytes(Path.Combine(fixture.Target, ".update.pending"), []);
        var delivery = fixture.Delivery(); var plan = delivery.PreviewRecovery(fixture.Target, fixture.Transaction, true, None);
        Check.Equal(0L, plan.PendingMarker!.Length, "marqueur tronqué lié à l’aperçu");
        delivery.Recover(fixture.Target, fixture.Transaction, true, plan.Confirmation, None);
        using var pack = PackageIntegrity.Open(fixture.Target, true); Check.True(pack.Packaged, "ancienne version activée après réparation explicite");
    }

    [Test]
    public static void Recovery_keeps_a_real_staged_file_modified_after_the_confirmed_preview()
    {
        using var fixture = new Fixture(); Interrupt(fixture, "component-staged");
        var preview = fixture.Delivery().PreviewRecovery(fixture.Target, fixture.Transaction, false, None);
        var temporary = preview.TemporaryFiles.Single(); var path = Path.Combine(fixture.Target, temporary.Path); var reached = false;
        Check.True(preview.Removed.Contains(temporary.Path) && !preview.Preserved.Contains(temporary.Path), "nettoyage de cette copie précise annoncé");
        Check.Equal("new:Domenia.exe", File.ReadAllText(path), "copie réellement produite par le moteur avant interruption");
        var delivery = fixture.Delivery(point => { if (point == "before-marker-open") { reached = true; File.WriteAllText(path, "changed"); } });
        Check.Contains("depuis l’aperçu", Check.Throws<InvalidDataException>(() => delivery.Recover(fixture.Target, fixture.Transaction, false, preview.Confirmation, None), "copie temporaire changée après requalification initiale").Message, "comparaison à la preuve confirmée");
        Check.True(reached, "interleaving réellement atteint"); Check.Equal("changed", File.ReadAllText(path), "octets modifiés conservés");
        Check.True(File.Exists(Path.Combine(fixture.Target, ".update.pending")), "aucune activation du mélange");
    }

    [Test]
    public static void Uninstall_deletes_only_matching_code_and_keeps_data_changed_files_and_the_owned_lock()
    {
        using var fixture = new Fixture(); var changed = Path.Combine(fixture.Target, "web/js/main.js"); File.WriteAllText(changed, "operator edit");
        var config = Path.Combine(fixture.Target, "Domenia.config.json"); File.WriteAllText(config, "configuration");
        var database = Path.Combine(fixture.Root, "profile.db"); File.WriteAllText(database, "profile");
        var lockPath = Path.Combine(fixture.Target, ".lifecycle.lock"); var reached = false;
        var delivery = fixture.Delivery(point =>
        {
            if (point != "verified-before-activation") { return; }
            reached = true; Check.Throws<IOException>(() => File.Move(lockPath, Path.Combine(fixture.Root, "stolen.lock")), "le verrou propriétaire interdit le remplacement avant fin");
        });
        var plan = delivery.PreviewUninstall(fixture.Target, None);
        Check.True(plan.Preserved.Contains("web/js/main.js"), "modification annoncée avant confirmation");
        var result = delivery.Uninstall(fixture.Target, plan.Confirmation, None);
        Check.True(reached, "interleaving du verrou réellement atteint");
        Check.False(File.Exists(Path.Combine(fixture.Target, "Domenia.exe")), "code conforme retiré");
        Check.Equal("operator edit", File.ReadAllText(changed), "code modifié conservé");
        Check.Equal("configuration", File.ReadAllText(config), "configuration conservée"); Check.Equal("profile", File.ReadAllText(database), "profil conservé");
        Check.True(File.Exists(lockPath) && result.Preserved.Contains(".lifecycle.lock"), "métadonnée de verrou conservée et annoncée");
        Check.False(File.Exists(Path.Combine(fixture.Target, PackageIntegrity.ManifestName)), "ancien manifeste retiré seulement après les composants");
    }

    [Test]
    public static void Uninstall_rechecks_each_object_and_keeps_a_file_changed_after_confirmation()
    {
        using var fixture = new Fixture(); var reached = false; var path = Path.Combine(fixture.Target, "Domenia.Core.dll");
        var delivery = fixture.Delivery(point => { if (point == "component-removed" && !reached) { reached = true; File.WriteAllText(path, "new external edit"); } });
        var plan = delivery.PreviewUninstall(fixture.Target, None); var result = delivery.Uninstall(fixture.Target, plan.Confirmation, None);
        Check.True(reached, "un premier fichier réellement retiré avant la modification");
        Check.True(result.Preserved.Contains("Domenia.Core.dll"), "modification tardive annoncée dans le résultat");
        Check.Equal("new external edit", File.ReadAllText(path), "comparaison et décision sur le même objet");
    }

    [Test]
    public static void Interrupted_uninstall_resumes_without_deleting_a_previously_preserved_file()
    {
        using var fixture = new Fixture(); var changed = Path.Combine(fixture.Target, "web/js/main.js"); File.WriteAllText(changed, "keep me"); var reached = false;
        var delivery = fixture.Delivery(point => { if (point == "component-removed") { reached = true; throw new IOException("stop uninstall"); } });
        var preview = delivery.PreviewUninstall(fixture.Target, None);
        Check.Equal("stop uninstall", Check.Throws<IOException>(() => delivery.Uninstall(fixture.Target, preview.Confirmation, None), "interruption après suppression réelle").Message, "bon chemin");
        Check.True(reached && File.Exists(Path.Combine(fixture.Target, ".update.pending")), "arrêt durablement bloquant");
        var fresh = fixture.Delivery(); var plan = fresh.PreviewRecovery(fixture.Target, fixture.Transaction, false, None);
        fresh.Recover(fixture.Target, fixture.Transaction, false, plan.Confirmation, None);
        Check.Equal("keep me", File.ReadAllText(changed), "conservation persistante au-delà d’une instance");
        Check.False(File.Exists(Path.Combine(fixture.Target, ".update.pending")), "reprise vérifiée achevée");
    }

    [Test]
    public static void Qualified_identity_and_schema_reject_reused_builds_downgrades_and_malformed_metadata()
    {
        Check.Equal("2.1.8", ProductInfo.QualifyBuild(null), "version stable déclarée identifiable");
        var identity = ProductInfo.DevelopmentVersion + "+" + new string('a', 64);
        Check.Equal(identity, ProductInfo.QualifyBuild(identity), "identité compilée exacte");
        Check.Throws<InvalidDataException>(() => ProductInfo.QualifyBuild(ProductInfo.DevelopmentVersion + "+short"), "pas d’identité ressemblante");
        Check.Throws<InvalidDataException>(() => ProductInfo.QualifyBuild("2.0.0-dev+" + new string('a', 64)), "ancien canal refusé pour cette version stable");
        using (var reused = new Fixture(old: Release('a'), next: Release('a')))
        { Check.Contains("déjà utilisée", Check.Throws<InvalidDataException>(() => reused.Delivery().PreviewUpdate(reused.Target, None), "build réutilisé pour autres octets").Message, "identité distincte du seul numéro de version"); }
        using (var downgrade = new Fixture(old: Release('a', 2), next: Release('b', 1)))
        { Check.Contains("plus ancien", Check.Throws<InvalidDataException>(() => downgrade.Delivery().PreviewUpdate(downgrade.Target, None), "rétrogradation non explicite refusée").Message, "avis exact"); }
        using (var malformed = new Fixture(next: new("2.0.0-dev", "looks-like-a-build", 11, 1)))
        { Check.Throws<InvalidDataException>(() => malformed.Delivery().PreviewUpdate(malformed.Target, None), "métadonnées invalides ne deviennent pas un avis de schéma"); }
    }

    [Test]
    public static void Manifest_paths_refuse_reserved_superscripts_without_refusing_ordinary_indices()
    {
        foreach (var name in new[] { "COM¹.dll", "web/LPT².json", "runtime/COM³", "com1.dll" })
        { Check.False(PackageIntegrity.ValidRelativePath(name), "nom Windows réservé : " + name); }
        foreach (var name in new[] { "web/item1.json", "COM10.dll", "web/LPT20.js" })
        { Check.True(PackageIntegrity.ValidRelativePath(name), "indice ordinaire admis : " + name); }
    }

    [Test]
    public static void Release_metadata_case_cannot_bypass_schema_qualification()
    {
        using var fixture = new Fixture(old: Release('a', 2), next: Release('b', 1));
        Manifest(fixture.Source, Components.Append("PACKAGE-RELEASE.JSON"));
        using (var valid = PackageIntegrity.Open(fixture.Source, true)) { Check.True(valid.Packaged, "paquet valide à chemin de casse différente"); }
        Check.Contains("plus ancien", Check.Throws<InvalidDataException>(() => fixture.Delivery().PreviewUpdate(fixture.Target, None), "métadonnées reconnues malgré la casse").Message,
            "schéma déclaré connu et rétrogradation refusée");
    }

    [Test]
    public static void Declared_configuration_and_lifecycle_metadata_are_not_uninstallable_code()
    {
        foreach (var name in new[] { "DOMENIA.CONFIG.JSON", ".lifecycle.lock", "PACKAGE-MANIFEST.JSON" })
        {
            using var fixture = new Fixture();
            if (name == "DOMENIA.CONFIG.JSON") { File.WriteAllText(Path.Combine(fixture.Target, name), "operator configuration"); }
            Manifest(fixture.Target, Components.Append(name));
            Check.Throws<InvalidDataException>(() => fixture.Delivery().PreviewUninstall(fixture.Target, None), "nom réservé refusé au parseur partagé");
            Check.Equal("old:Domenia.exe", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "aucun retrait anticipé");
            Check.False(Directory.Exists(fixture.Storage), "aucune transaction pour manifeste invalide");
        }
    }

    [Test]
    public static void Development_targets_links_and_source_target_overlap_are_refused_before_mutation()
    {
        using var fixture = new Fixture(); var delivery = fixture.Delivery();
        Check.Throws<InvalidDataException>(() => delivery.PreviewUpdate(fixture.Source, None), "pas d’auto-remplacement du processus actif");
        Directory.CreateDirectory(Path.Combine(fixture.Target, "src"));
        Check.Throws<InvalidDataException>(() => delivery.PreviewUninstall(fixture.Target, None), "arbre DEV conservé");
        Directory.Delete(Path.Combine(fixture.Target, "src"));
        var link = Path.Combine(fixture.Root, "redirected"); Directory.CreateSymbolicLink(link, fixture.Target);
        try { Check.Throws<InvalidDataException>(() => delivery.PreviewUpdate(link, None), "racine redirigée refusée"); }
        finally { Directory.Delete(link); }
        Check.False(Directory.Exists(fixture.Storage), "aucune transaction engagée");
    }

    [Test]
    public static void Publisher_policy_qualifies_the_activated_image_and_binds_the_confirmation()
    {
        using var fixture = new Fixture(); var pin = new string('A', 64);
        PackageNativeSignature Native(FileStream file)
        {
            file.Position = 0;
            return file.ReadByte() == 'n' ? new(0, pin, "Éditeur de test") : new(PackagePublisherTrust.NoSignature, null, null);
        }
        var required = PackagePublisherPolicy.Parse([pin], true);
        var delivery = new PackageLifecycle(fixture.Source, TestClock.Fixed()) { PublisherPolicy = required, SignatureVerifier = Native };
        var preview = delivery.PreviewUpdate(fixture.Target, None);
        Check.True(preview.Publisher?.Trusted == true, "nouvel exécutable signé et épinglé, ancien exécutable non signé conservé comme sauvegarde");
        var optional = new PackageLifecycle(fixture.Source, TestClock.Fixed()) { PublisherPolicy = PackagePublisherPolicy.Parse([pin], false), SignatureVerifier = Native };
        Check.Throws<InvalidDataException>(() => optional.Update(fixture.Target, preview.Confirmation, None), "changement de politique exige un nouvel aperçu");
        Check.False(Directory.Exists(fixture.Storage), "aucune transaction avant confirmation sous la même politique");
        var result = delivery.Update(fixture.Target, preview.Confirmation, None);
        Check.Equal("update", result.Action, "une ancienne copie non épinglée ne bloque pas le nouveau code admis");
        Check.Equal("new:Domenia.exe", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "image désirée réellement publiée");
        Check.Throws<InvalidDataException>(() => delivery.PreviewRecovery(fixture.Target, result.Transaction, true, None), "retour vers l’ancienne image non signée refusé sous la politique obligatoire");
    }

    [Test]
    public static void Delivery_command_requires_a_reviewed_confirmation_and_reports_a_verified_result()
    {
        using var fixture = new Fixture(); using var output = new StringWriter();
        Check.Equal(0, PackageLifecycleCommand.Run(fixture.Source, ["livraison", "apercu", fixture.Target], output, TestClock.Fixed(), signatureVerifier: UnsignedFixture), "aperçu réel accessible sans composition UI");
        using var preview = JsonDocument.Parse(output.ToString()); var confirmation = preview.RootElement.GetProperty("Confirmation").GetString()!;
        Check.False(Directory.Exists(fixture.Storage), "commande d’aperçu sans écritures");
        output.GetStringBuilder().Clear();
        Check.Equal(2, PackageLifecycleCommand.Run(fixture.Source, ["livraison", "appliquer", fixture.Target, "invalid"], output, TestClock.Fixed(), signatureVerifier: UnsignedFixture), "refus explicite, pas un succès de code retour");
        output.GetStringBuilder().Clear();
        Check.Equal(0, PackageLifecycleCommand.Run(fixture.Source, ["livraison", "appliquer", fixture.Target, confirmation], output, TestClock.Fixed(), signatureVerifier: UnsignedFixture), "application confirmée");
        using var result = JsonDocument.Parse(output.ToString()); using var verified = PackageIntegrity.Open(fixture.Target, true);
        Check.Equal(verified.ManifestHash, result.RootElement.GetProperty("ActiveIdentity").GetString(), "réponse qualifiée par relecture indépendante des fichiers");
    }
}
