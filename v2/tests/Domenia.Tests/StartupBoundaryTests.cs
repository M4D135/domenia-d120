using Domenia.App;

namespace Domenia.Tests;

internal static class StartupBoundaryTests
{
    [Test]
    public static void Foreground_is_one_opportunity_and_never_retried_after_refusal_or_departure()
    {
        var calls = 0; var allowed = new StartupActivation();
        Check.Contains("obtenu", allowed.TryActivate(true, () => { calls++; return true; }), "activation explicite");
        Check.Contains("déjà", allowed.TryActivate(true, () => { calls++; return true; }), "pas de seconde tentative");
        var refused = new StartupActivation();
        Check.Contains("refusée", refused.TryActivate(true, () => { calls++; return false; }), "refus Windows final");
        refused.TryActivate(true, () => { calls++; return true; });
        var away = new StartupActivation(); away.UserSwitchedAway();
        Check.Contains("session", away.TryActivate(true, () => { calls++; return true; }), "retour de session ne réactive pas");
        var foreign = new StartupActivation();
        Check.Contains("autre fenêtre", foreign.TryActivate(false, () => { calls++; return true; }), "focus extérieur respecté");
        foreign.TryActivate(true, () => { calls++; return true; });
        Check.Equal(2, calls, "seules les deux demandes admises atteignent Windows");
    }

    [Test]
    public static void Bootstrap_precedes_product_modules_and_keeps_bounded_masked_evidence_on_local_disk()
    {
        using var folder = new TemporaryFolder();
        var line = StartupBootstrap.FirstLine("2.fixture");
        Check.Contains(Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture), line, "PID réel");
        Check.Contains("hôte Domenia.exe", line, "hôte compilé nommé"); Check.Contains("64 bits", line, "architecture réelle");
        var path = StartupBootstrap.WriteAt(folder.Path, "Domenia-bootstrap.log", line);
        Check.NotNull(path, "écriture locale confirmée");
        Check.Contains("version 2.fixture", File.ReadAllText(path!), "première ligne relue");
        StartupBootstrap.WriteAt(folder.Path, "Domenia-startup-error.log", "password=ne-jamais-conserver");
        Check.False(File.ReadAllText(folder.File("Domenia-startup-error.log")).Contains("ne-jamais-conserver", StringComparison.Ordinal), "secret absent avant modules");
        var huge = new string('x', 9000);
        Check.False(StartupBootstrap.Clean(huge).Contains(huge, StringComparison.Ordinal), "message non borné non conservé");
        File.WriteAllText(path!, new string('x', 256 * 1024));
        StartupBootstrap.WriteAt(folder.Path, "Domenia-bootstrap.log", "nouveau démarrage");
        Check.True(File.Exists(path + ".1"), "trace précédente conservée à la rotation");
        Check.True(new FileInfo(path!).Length < 1000, "fichier actif borné");
        Check.Null(StartupBootstrap.WriteAt(folder.Path, "arbitrary.txt", "refus"), "noms de fichier fermés");
        using var locked = new FileStream(path!, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        Check.Null(StartupBootstrap.WriteAt(folder.Path, "Domenia-bootstrap.log", "refus"), "erreur disque ne masque pas la panne initiale");
    }

    [Test]
    public static void Host_signature_never_confuses_hash_consistency_with_publisher_trust()
    {
        Check.Contains("révocation en ligne non interrogée", StartupHostCheck.DescribeSignature(0), "limite locale explicite");
        Check.Contains("éditeur non certifié", StartupHostCheck.DescribeSignature(unchecked((int)0x800B0100)), "packs non signés explicitement identifiés");
        foreach (var status in new[] { unchecked((int)0x80096010), unchecked((int)0x800B0111), unchecked((int)0x800B0109), -1 })
            Check.Contains("DOMENIA_HOST_SIGNATURE", Check.Throws<InvalidDataException>(() => StartupHostCheck.DescribeSignature(status), "mauvais hash/certificat/refus Windows").Message, "aucune acceptation implicite");
    }

    [Test]
    public static void Application_root_has_one_compiled_candidate_and_never_guesses_from_current_directory()
    {
        using var folder = new TemporaryFolder();
        var root = folder.Path;
        Check.Equal(root, PackageLayout.ResolveApplicationRoot(root, false), "disposition plate");
        Check.Equal(root, PackageLayout.ResolveApplicationRoot(Path.Combine(root, "wad"), true), "disposition prod exe plus wad");
        Check.Throws<InvalidDataException>(() => PackageLayout.ResolveApplicationRoot("relative", false), "aucun repli sur cwd");
        Check.Throws<InvalidDataException>(() => PackageLayout.ResolveApplicationRoot(root, true), "wad absent refusé, aucun candidat alternatif");
        // No ROOT variables or registry lookup participate in this API: even the host's process base is passed explicitly.
        Check.False(PackageLayout.ResolveApplicationRoot(root, false).Equals(Environment.CurrentDirectory, StringComparison.OrdinalIgnoreCase), "dossier courant étranger ignoré");
    }
}
