using System.ComponentModel;
using Domenia.App;

namespace Domenia.Tests;

internal static partial class PackageLifecycleTests
{
    private static PackageLifecycle DataDelivery(Fixture fixture, string profile, Action<string>? hook = null) => new(fixture.Source, TestClock.Fixed())
    { ProfileRoot = () => profile, SignatureVerifier = UnsignedFixture, PublisherPolicy = PackagePublisherPolicy.Unconfigured, Checkpoint = hook };
    [Test]
    public static void Uninstall_choices_are_explicit_exact_and_preserve_a_private_copy_of_selected_data()
    {
        using var fixture = new Fixture(); var profile = Path.Combine(fixture.Root, "profile"); Directory.CreateDirectory(profile);
        var local = Path.Combine(fixture.Target, "data"); Directory.CreateDirectory(local);
        File.WriteAllText(Path.Combine(local, "user.db"), "local data"); File.WriteAllText(Path.Combine(profile, "preferences.json"), "shared preferences");
        var delivery = DataDelivery(fixture, profile); var keep = delivery.PreviewUninstall(fixture.Target, None);
        Check.Equal(0, keep.DataRemoval!.Files.Count, "aucune suppression de données par défaut");
        var options = new PackageUninstallOptions(true, true); var plan = delivery.PreviewUninstall(fixture.Target, None, options);
        Check.Equal(2, plan.DataRemoval!.Files.Count, "deux fichiers précisément listés"); Check.Equal(profile, plan.DataRemoval.ProfileRoot, "profil partagé identifié avant confirmation");
        Check.Throws<InvalidDataException>(() => delivery.Uninstall(fixture.Target, keep.Confirmation, None, options), "confirmation conserver n’autorise jamais supprimer");
        var result = delivery.Uninstall(fixture.Target, plan.Confirmation, None, options);
        Check.False(File.Exists(Path.Combine(local, "user.db")) || File.Exists(Path.Combine(profile, "preferences.json")), "seuls fichiers confirmés retirés");
        var backup = Path.Combine(fixture.Storage, result.Transaction, "removed-data");
        Check.Equal("local data", File.ReadAllText(Path.Combine(backup, "local/data/user.db")), "données locales conservées hors installation");
        Check.Equal("shared preferences", File.ReadAllText(Path.Combine(backup, "profile/preferences.json")), "préférences partagées conservées dans la preuve");
        Check.True(Directory.Exists(profile) && Directory.Exists(local), "aucun nettoyage récursif des dossiers");
        Check.True(File.Exists(Path.Combine(fixture.Target, ".lifecycle.lock")), "verrou propriétaire conservé");
    }
    [Test]
    public static void Changed_or_occupied_data_refuse_deletion_before_any_code_is_removed()
    {
        using var fixture = new Fixture(); var profile = Path.Combine(fixture.Root, "profile"); Directory.CreateDirectory(profile);
        var file = Path.Combine(profile, "active.db"); File.WriteAllText(file, "before"); var options = new PackageUninstallOptions(false, true);
        var delivery = DataDelivery(fixture, profile); var plan = delivery.PreviewUninstall(fixture.Target, None, options);
        File.WriteAllText(file, "after");
        Check.Throws<InvalidDataException>(() => delivery.Uninstall(fixture.Target, plan.Confirmation, None, options), "aperçu périmé refusé");
        plan = delivery.PreviewUninstall(fixture.Target, None, options);
        using (var occupied = new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite))
            Check.Throws<IOException>(() => delivery.Uninstall(fixture.Target, plan.Confirmation, None, options), "écrivain actif bloque déjà la relecture de l’inventaire");
        using (var reader = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read))
            Check.Throws<Win32Exception>(() => delivery.Uninstall(fixture.Target, plan.Confirmation, None, options), "lecture existante sans partage DELETE bloque l’acquisition collective");
        Check.True(File.Exists(Path.Combine(fixture.Target, "Domenia.exe")), "code conservé lors du refus de données");
        Check.Equal("after", File.ReadAllText(file), "modification conservée"); Check.False(Directory.Exists(fixture.Storage), "pas de transaction engagée avant réservation des fichiers");
    }
    [Test]
    public static void Interrupted_data_uninstall_resumes_its_original_set_and_keeps_new_or_modified_files()
    {
        using var fixture = new Fixture(); var profile = Path.Combine(fixture.Root, "profile"); Directory.CreateDirectory(profile);
        var first = Path.Combine(profile, "first.json"); var second = Path.Combine(profile, "second.json");
        File.WriteAllText(first, "old1"); File.WriteAllText(second, "old2"); var options = new PackageUninstallOptions(false, true);
        var delivery = DataDelivery(fixture, profile, point => { if (point == "component-removed") throw new IOException("stop"); });
        var plan = delivery.PreviewUninstall(fixture.Target, None, options);
        Check.Throws<IOException>(() => delivery.Uninstall(fixture.Target, plan.Confirmation, None, options), "interruption après création de la preuve");
        File.WriteAllText(second, "new2"); File.WriteAllText(Path.Combine(profile, "new.json"), "new file");
        var fresh = DataDelivery(fixture, profile); var resume = fresh.PreviewRecovery(fixture.Target, fixture.Transaction, false, None);
        var result = fresh.Recover(fixture.Target, fixture.Transaction, false, resume.Confirmation, None);
        Check.False(File.Exists(first), "donnée initiale inchangée retirée"); Check.Equal("new2", File.ReadAllText(second), "donnée modifiée préservée");
        Check.Equal("new file", File.ReadAllText(Path.Combine(profile, "new.json")), "aucune extension implicite de l’inventaire après confirmation");
        Check.True(result.Preserved.Contains("profile:second.json"), "conservation explicitée dans résultat");
    }
    [Test]
    public static void Data_and_preservation_handles_block_replacement_until_deletion_finishes()
    {
        using var fixture = new Fixture(); var profile = Path.Combine(fixture.Root, "profile"); Directory.CreateDirectory(profile);
        var file = Path.Combine(profile, "settings.json"); File.WriteAllText(file, "kept"); var options = new PackageUninstallOptions(false, true);
        var reached = false; var delivery = DataDelivery(fixture, profile, point =>
        {
            if (point != "pending-written") return; reached = true;
            Check.Throws<IOException>(() => File.Move(file, file + ".other"), "même objet détenu avant suppression");
            Check.Throws<IOException>(() => File.WriteAllText(Path.Combine(fixture.Storage, fixture.Transaction, "removed-data/profile/settings.json"), "damaged"), "copie de conservation détenue jusqu’à la fin réelle");
        });
        var plan = delivery.PreviewUninstall(fixture.Target, None, options);
        var result = delivery.Uninstall(fixture.Target, plan.Confirmation, None, options);
        Check.True(reached, "frontière réelle atteinte"); Check.False(File.Exists(file), "suppression confirmée terminée");
        Check.Equal("kept", File.ReadAllText(Path.Combine(fixture.Storage, result.Transaction, "removed-data/profile/settings.json")), "octets conservés et relus après libération");
    }
    [Test]
    public static void A_damaged_preservation_copy_refuses_resume_before_any_further_removal()
    {
        using var fixture = new Fixture(); var profile = Path.Combine(fixture.Root, "profile"); Directory.CreateDirectory(profile);
        var file = Path.Combine(profile, "settings.json"); File.WriteAllText(file, "kept"); var options = new PackageUninstallOptions(false, true);
        var delivery = DataDelivery(fixture, profile, point => { if (point == "pending-written") throw new IOException("interrupt"); });
        var plan = delivery.PreviewUninstall(fixture.Target, None, options);
        Check.Throws<IOException>(() => delivery.Uninstall(fixture.Target, plan.Confirmation, None, options), "interruption avec journal et copies durables");
        File.WriteAllText(Path.Combine(fixture.Storage, fixture.Transaction, "removed-data/profile/settings.json"), "damaged");
        var fresh = DataDelivery(fixture, profile); var resume = fresh.PreviewRecovery(fixture.Target, fixture.Transaction, false, None);
        Check.Throws<InvalidDataException>(() => fresh.Recover(fixture.Target, fixture.Transaction, false, resume.Confirmation, None), "copie relue avant retrait du code et des données");
        Check.Equal("kept", File.ReadAllText(file), "original conservé"); Check.True(File.Exists(Path.Combine(fixture.Target, "Domenia.exe")), "code non supprimé sans copie vérifiée");
    }
    [Test]
    public static void Uninstall_command_exposes_two_closed_choices_and_never_accepts_a_profile_path()
    {
        using var fixture = new Fixture(); var local = Path.Combine(fixture.Target, "data"); Directory.CreateDirectory(local);
        var data = Path.Combine(local, "test.db"); File.WriteAllText(data, "local"); using var output = new StringWriter();
        var previewArgs = new[] { "livraison", "apercu-desinstallation", fixture.Target, "local=supprimer", "profil=conserver" };
        Check.Equal(0, PackageLifecycleCommand.Run(fixture.Source, previewArgs, output, TestClock.Fixed(), signatureVerifier: UnsignedFixture), "aperçu des choix effectifs");
        using var json = System.Text.Json.JsonDocument.Parse(output.ToString()); var confirmation = json.RootElement.GetProperty("Confirmation").GetString()!;
        output.GetStringBuilder().Clear();
        Check.Equal(2, PackageLifecycleCommand.Run(fixture.Source, ["livraison", "desinstaller", fixture.Target, confirmation, "local=supprimer", "profil=" + fixture.Root], output, TestClock.Fixed(), signatureVerifier: UnsignedFixture), "aucun chemin de profil arbitraire");
        Check.True(File.Exists(data), "refus sans mutation"); output.GetStringBuilder().Clear();
        Check.Equal(0, PackageLifecycleCommand.Run(fixture.Source, ["livraison", "desinstaller", fixture.Target, confirmation, "local=supprimer", "profil=conserver"], output, TestClock.Fixed(), signatureVerifier: UnsignedFixture), "choix exacts et confirmation appliqués");
        Check.False(File.Exists(data), "donnée locale listée retirée");
    }
    [Test]
    public static void Shared_profile_overlap_and_redirects_are_refused_without_removal()
    {
        using var fixture = new Fixture(); var options = new PackageUninstallOptions(false, true);
        Check.Throws<InvalidDataException>(() => DataDelivery(fixture, fixture.Root).PreviewUninstall(fixture.Target, None, options), "profil ancêtre de la preuve refusé");
        var profile = Path.Combine(fixture.Root, "profile"); Directory.CreateDirectory(profile);
        var redirected = Path.Combine(fixture.Root, "profile-link"); Directory.CreateSymbolicLink(redirected, profile);
        try { Check.Throws<InvalidDataException>(() => DataDelivery(fixture, redirected).PreviewUninstall(fixture.Target, None, options), "profil redirigé refusé"); }
        finally { Directory.Delete(redirected); }
        Check.True(File.Exists(Path.Combine(fixture.Target, "Domenia.exe")), "code intact"); Check.False(Directory.Exists(fixture.Storage), "aucune preuve ni suppression engagée");
    }
}
