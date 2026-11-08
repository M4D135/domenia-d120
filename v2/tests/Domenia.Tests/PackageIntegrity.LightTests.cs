using System.Reflection.PortableExecutable;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.App;

namespace Domenia.Tests;

internal static partial class PackageIntegrityTests
{
    internal static void LightPack(TemporaryFolder folder, string type = PackageIntegrity.LightType, string engine = "Evergreen")
    {
        ContractPack(folder);
        var wad = folder.File("wad");
        Directory.CreateDirectory(wad);
        foreach (var item in Directory.GetFileSystemEntries(folder.Path))
        {
            if (item == wad || Path.GetFileName(item) == "Domenia.exe") continue;
            var target = Path.Combine(wad, Path.GetFileName(item));
            if (Directory.Exists(item)) Directory.Move(item, target); else File.Move(item, target);
        }
        Directory.Delete(Path.Combine(wad, "runtime", "webview2"), true);
        var releaseName = Path.Combine(wad, "package-release.json");
        var release = JsonNode.Parse(File.ReadAllBytes(releaseName))!.AsObject();
        release["packageType"] = type;
        release["dependencies"]!["WebView2"] = engine;
        File.WriteAllText(releaseName, release.ToJsonString());
        foreach (var name in new[] { "dotnet.exe", "host/fxr/10.0.13/hostfxr.dll", "shared/Microsoft.NETCore.App/10.0.13/coreclr.dll",
            "shared/Microsoft.NETCore.App/10.0.13/System.Private.CoreLib.dll", "shared/Microsoft.WindowsDesktop.App/10.0.13/System.Windows.Forms.dll" })
        {
            var file = Path.Combine(wad, "runtime", "dotnet", name);
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, "fixture privée " + name);
        }
        var files = Directory.GetFiles(folder.Path, "*", SearchOption.AllDirectories).Select(file =>
            new PackageComponent(Path.GetRelativePath(folder.Path, file).Replace('\\', '/'), new FileInfo(file).Length,
                Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(file)))))
            .Where(c => c.Path is not ("wad/.lifecycle.lock" or "wad/package-contract.json" or "wad/package-manifest.json")).ToList();
        var contractName = Path.Combine(wad, PackageIntegrity.ContractName);
        var contract = JsonNode.Parse(File.ReadAllBytes(contractName))!.AsObject();
        contract["componentsFingerprint"] = PackageIntegrity.ComponentFingerprint(files);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(contract);
        File.WriteAllBytes(contractName, bytes);
        files.Add(new("wad/" + PackageIntegrity.ContractName, bytes.Length, Convert.ToHexStringLower(SHA256.HashData(bytes))));
        File.WriteAllText(Path.Combine(wad, PackageIntegrity.ManifestName), JsonSerializer.Serialize(new { format = 2, packageType = PackageIntegrity.LightType,
            files = files.Select(c => new { path = c.Path, length = c.Length, sha256 = c.Sha256 }) }));
    }

    [Test]
    public static void Only_a_matching_light_release_and_manifest_can_omit_the_packaged_browser()
    {
        using var valid = new TemporaryFolder(); LightPack(valid);
        using (var pack = PackageIntegrity.Open(valid.Path, true))
            Check.True(pack.IsLight && pack.Contract is not null, "variante explicite, contrat et .NET privé vérifiés");
        var marker = valid.File("wad/package-manifest.json");
        var original = File.ReadAllBytes(marker);
        var manifest = JsonNode.Parse(original)!.AsObject();
        manifest.Remove("packageType"); manifest["format"] = 1;
        File.WriteAllText(marker, manifest.ToJsonString());
        Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(valid.Path, true).Dispose(), "un pack v1 incomplet n’utilise jamais Windows en repli");
        File.WriteAllBytes(marker, original);
        Directory.CreateDirectory(valid.File("wad/runtime/webview2"));
        Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(valid.Path, true).Dispose(), "moteur fixe résiduel refusé même si le dossier est vide");
        foreach (var (type, engine) in new[] { ("PROD", "Evergreen"), ("DEV", "Evergreen"), (PackageIntegrity.LightType, "155.0.4283.62") })
        {
            using var changed = new TemporaryFolder(); LightPack(changed, type, engine);
            Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(changed.Path, true).Dispose(), "métadonnées contradictoires malgré empreintes recalculées");
        }
    }

    [Test]
    public static void Evergreen_selection_requires_the_system_tree_Microsoft_x64_and_the_same_qualified_version()
    {
        using var folder = new TemporaryFolder();
        const string benchVersion = "140.0.3485.54";
        foreach (var name in new[] { "140.0.3485.53", benchVersion, "156.0.0.1", "180.1.2.3-beta" })
            Directory.CreateDirectory(folder.File(name));
        foreach (var unsupported in new string?[] { null, "140.0.3485.53", "140.0.3485", "180.1.2.3-beta", "157.0.0.1" })
            Check.Throws<InvalidDataException>(() => PackageIntegrity.FindEvergreen([folder.Path], unsupported),
                "pas de repli vers un dossier présent si la version active est trop ancienne, absente ou une préversion");
        Check.Equal(folder.File("156.0.0.1"), PackageIntegrity.FindEvergreen([folder.Path], "156.0.0.1").Folder, "version ultérieure enregistrée");
        var (chosen, version) = PackageIntegrity.FindEvergreen([folder.Path], benchVersion);
        Check.Equal(folder.File(benchVersion), chosen, "le moteur du banc est actif même en présence d’un autre dossier plus récent");
        PackageIntegrity.RequireEvergreenBinary(version, version.ToString(), Machine.Amd64, true, "Microsoft Corporation");
        foreach (var (fileVersion, machine, valid, signer) in new[] { ("140.0.3485.55", Machine.Amd64, true, "Microsoft Corporation"),
            (benchVersion, Machine.I386, true, "Microsoft Corporation"), (benchVersion, Machine.Amd64, false, "Microsoft Corporation"),
            (benchVersion, Machine.Amd64, true, "Autre éditeur") })
            Check.Throws<InvalidDataException>(() => PackageIntegrity.RequireEvergreenBinary(version, fileVersion, machine, valid, signer), "binaire différent ou non qualifié");
    }
}
