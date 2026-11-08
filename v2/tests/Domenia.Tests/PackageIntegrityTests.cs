using System.Security.Cryptography;
using System.Text.Json;
using Domenia.App;

namespace Domenia.Tests;

internal static partial class PackageIntegrityTests
{
    private static readonly string[] Components = ["Domenia.exe", "Domenia.dll", "Domenia.deps.json", "Domenia.runtimeconfig.json",
        "Domenia.Core.dll", "Domenia.Ad.dll", "Domenia.Store.dll", "Domenia.Inventory.dll", "Domenia.Engine.dll",
        "Domenia.Bridge.dll", "Domenia.Simulation.dll", "web/index.html", "runtime/webview2/msedgewebview2.exe", "web/js/main.js"];

    private static void Pack(TemporaryFolder folder)
    {
        foreach (var name in Components)
        {
            var file = folder.File(name); Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, "trusted fixture " + name);
        }
        File.WriteAllBytes(folder.File(".lifecycle.lock"), []);
        Manifest(folder, Components);
    }

    private static void Manifest(TemporaryFolder folder, IEnumerable<string> names)
    {
        var files = names.Select(name => new { path = name, length = new FileInfo(folder.File(name)).Length,
            sha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(folder.File(name)))) });
        File.WriteAllText(folder.File(PackageIntegrity.ManifestName), JsonSerializer.Serialize(new { format = 1, files }));
    }

    [Test]
    public static void Valid_package_holds_files_and_lifecycle_until_shutdown()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        using (var pack = PackageIntegrity.Open(folder.Path, true))
        {
            Check.True(pack.Packaged, "paquet reconnu"); Check.Equal(Components.Length, pack.FilesChecked, "tous les fichiers contrôlés");
            Check.Throws<IOException>(() => { using var stream = new FileStream(folder.File(".lifecycle.lock"), FileMode.Open, FileAccess.ReadWrite, FileShare.None); }, "mise à jour concurrente refusée");
            Check.Throws<IOException>(() => File.WriteAllText(folder.File("web/js/main.js"), "modified"), "module protégé après vérification");
        }
        File.WriteAllText(folder.File("web/js/main.js"), "changed after exit");
        Check.Contains("changed after exit", File.ReadAllText(folder.File("web/js/main.js")), "verrou libéré à la fermeture");
    }

    [Test]
    public static void A_changed_component_or_an_unlisted_module_prevents_startup()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        File.WriteAllText(folder.File("web/js/main.js"), "tampered");
        Check.Contains("SHA-256", Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "modification refusée").Message, "diagnostic contient preuve");
        Pack(folder); File.WriteAllText(folder.File("web/js/stale.js"), "stale");
        Check.Contains("hors manifeste", Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "module obsolète refusé").Message, "extra identifié");
    }

    [Test]
    public static void Required_manifest_cannot_be_removed_to_bypass_checks()
    {
        using var folder = new TemporaryFolder();
        using (var development = PackageIntegrity.Open(folder.Path, false)) { Check.False(development.Packaged, "compilation non publiée explicite"); }
        Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "pack publié exige manifeste");
        Pack(folder); Manifest(folder, Components.Where(x => x != "Domenia.Core.dll"));
        Check.Contains("incomplet", Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "composant omis refusé").Message, "manifeste incomplet");
    }

    [Test]
    public static void An_interrupted_update_is_refused_even_without_a_manifest()
    {
        using var folder = new TemporaryFolder(); Directory.CreateDirectory(folder.File("Support"));
        File.WriteAllText(folder.File("Support/.update.pending"), "interrupted");
        Check.Contains("interrompue", Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, false).Dispose(), "marqueur bloque toute ouverture").Message, "restauration demandée");
    }

    [Test]
    public static void Duplicate_components_and_unsafe_windows_paths_are_rejected()
    {
        using var folder = new TemporaryFolder(); Pack(folder); Manifest(folder, Components.Append(Components[0]));
        Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "doublon refusé");
        foreach (var name in new[] { "../outside.dll", "/root.dll", "web/../module.js", "C:/x.dll", "web/x:stream", "web\\x.js", "web/x. ", "CON.dll", "web/LPT1.js", "web//x.js" })
        { Check.False(PackageIntegrity.ValidRelativePath(name), "chemin dangereux refusé : " + name); }
        Check.True(PackageIntegrity.ValidRelativePath("runtime/webview2/125.0/fr.pak"), "chemin relatif ordinaire accepté");
    }

    [Test]
    public static void Operator_configuration_is_not_a_pack_component()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        File.WriteAllText(folder.File("Domenia.config.json"), "{}");
        using var pack = PackageIntegrity.Open(folder.Path, true);
        File.WriteAllText(folder.File("Domenia.config.json"), "{\"setting\":true}");
        Check.True(pack.Packaged, "configuration locale distincte des fichiers runtime");
    }

    [Test]
    public static void Optional_remote_tools_are_a_closed_policy_and_unapproved_bytes_never_become_pack_components()
    {
        foreach (var name in new[] { "PsExec.exe", "psexec64.EXE", "wad/PsExec.exe", "wad/PsExec64.exe" })
        {
            Check.True(Domenia.Inventory.RemoteReadTools.IsOptionalPackageComponent(name), "nom portable facultatif reconnu");
            using var folder = new TemporaryFolder(); Pack(folder);
            var path = folder.File(name); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, "Ce fichier inerte n’est pas le binaire approuvé.");
            var error = Check.Throws<IOException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "nom seul insuffisant au démarrage");
            Check.Contains("Empreinte PsExec", error.Message, "la politique du transport vérifie les octets avant admission");
            File.Delete(path); // A rejected optional component must release every earlier package lease.
            File.WriteAllText(folder.File("web/js/main.js"), "lease released after failure");
        }
        foreach (var name in new[] { "other.exe", "nested/PsExec.exe", "wad/../PsExec.exe", "PsExec.exe:stream", "PsExec.exe.bak" })
        { Check.False(Domenia.Inventory.RemoteReadTools.IsOptionalPackageComponent(name), "pas d’exemption générique des exécutables"); }
    }
    [Test]
    public static void Streaming_integrity_hashes_all_bytes_and_reports_verified_files_only()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        var bytes = new byte[2 * 1024 * 1024 + 3];
        RandomNumberGenerator.Fill(bytes);
        File.WriteAllBytes(folder.File("web/js/main.js"), bytes); Manifest(folder, Components);
        var updates = new List<(int Done, int Total)>();
        using (var pack = PackageIntegrity.Open(folder.Path, true, progress: (done, total) => updates.Add((done, total))))
        {
            Check.Equal(Components.Sum(name => new FileInfo(folder.File(name)).Length), pack.BytesHashed, "chaque octet vérifié");
            Check.Equal((long)Components.Length + 2, pack.HashReads, "un tampon partagé de 1 Mio, trois blocs pour le grand fichier");
            Check.True(updates.Select(p => p.Done).SequenceEqual(Enumerable.Range(1, Components.Length)), "progression réelle sans pourcentage estimé");
            Check.True(updates.All(p => p.Total == Components.Length), "nombre exact issu du manifeste");
        }
        var file = folder.File("web/js/main.js"); var timestamp = File.GetLastWriteTimeUtc(file);
        bytes[bytes.Length - 1] ^= 0xff; File.WriteAllBytes(file, bytes); File.SetLastWriteTimeUtc(file, timestamp);
        Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "même taille/date n’accordent aucune confiance");
    }

    [Test]
    public static void Cancelled_integrity_never_publishes_a_package_and_releases_its_leases()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        using var stop = new CancellationTokenSource();
        Check.Throws<OperationCanceledException>(() => PackageIntegrity.Open(folder.Path, true, stop.Token, (done, _) =>
        { if (done == 2) stop.Cancel(); }).Dispose(), "annulation entre deux composants vérifiés");
        File.WriteAllText(folder.File("Domenia.exe"), "leases released");
        using var exclusive = new FileStream(folder.File(".lifecycle.lock"), FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        Check.True(exclusive.CanWrite, "verrou de cycle de vie libéré seulement après arrêt effectif");
    }

    [Test]
    public static void Mutable_data_cannot_be_admitted_as_code_and_line_ending_changes_remain_visible()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        foreach (var data in new[] { "data/user.json", "wad/data/cache.db", "WaD/DaTa/profile.json" })
        {
            Directory.CreateDirectory(Path.GetDirectoryName(folder.File(data))!); File.WriteAllText(folder.File(data), "{}");
            Manifest(folder, Components.Append(data));
            Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "données exclues même explicitement ajoutées au manifeste");
            File.Delete(folder.File(data));
        }
        File.WriteAllText(folder.File("web/js/main.js"), "line1\nline2\n"); Manifest(folder, Components);
        File.WriteAllText(folder.File("web/js/main.js"), "line1\r\nline2\r\n");
        Check.Contains("SHA-256", Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "aucune tolérance silencieuse sur les octets de code").Message, "écart explicite");
        using var excessive = new MemoryStream(JsonSerializer.SerializeToUtf8Bytes(new { format = 1, files = Enumerable.Range(0, PackageIntegrity.MaximumFiles + 1).Select(n => new { path = $"web/{n}.js", length = 0, sha256 = new string('a', 64) }) }));
        Check.Throws<InvalidDataException>(() => PackageIntegrity.ReadManifest(excessive), "plafond ferme avant fichiers");
    }

    [Test]
    public static void Interrupted_update_explains_recovery_without_trusting_marker_locations_or_removing_evidence()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        var id = new string('a', 32); var marker = folder.File(".update.pending");
        File.WriteAllText(marker, JsonSerializer.Serialize(new { format = 1, transaction = id, journalSha256 = new string('b', 64) }));
        var bytes = File.ReadAllBytes(marker);
        var error = Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "aucun lancement mixte");
        Check.Contains("livraison apercu-restauration", error.Message, "commande préalable concrète");
        Check.Contains(id, error.Message, "identifiant relu du marqueur"); Check.Contains(".domenia-lifecycle", error.Message, "sauvegarde du code nommée");
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(marker)), "marqueur intact");
        foreach (var invalid in new[] { "{}", "{\"format\":1,\"format\":1,\"transaction\":\"" + id + "\",\"journalSha256\":\"" + new string('b',64) + "\"}", new string('x', 5000) })
        {
            File.WriteAllText(marker, invalid);
            var hint = PendingRecoveryHint.Describe(folder.Path, marker);
            Check.Contains("IDENTIFIANT_TRANSACTION", hint, "aucun identifiant inventé");
            Check.False(hint.Contains(id, StringComparison.Ordinal), "doublon JSON refusé");
        }
    }

    [Test]
    public static void Check_only_runs_the_real_package_and_module_contract_and_returns_only_success_or_failure()
    {
        using var folder = new TemporaryFolder(); Pack(folder);
        using var package = PackageIntegrity.Open(folder.Path, true);
        var output = new List<string>();
        Check.Equal(0, StartupCheckCommand.Run(package, [typeof(Domenia.Bridge.SessionOperations).Assembly], output.Add), "commande réellement utilisée par Program");
        Check.Contains(Components.Length + " fichiers vérifiés", output.Single(), "compteur réel");
        Check.Contains("plafond 4096", output.Single(), "borne du pack autonome annoncée");
        output.Clear();
        Check.Equal(1, StartupCheckCommand.Run(package, [], output.Add), "modules manquants : échec et aucun démarrage");
        Check.Contains("non validé", output.Single(), "pas de succès fabriqué");
    }

}
