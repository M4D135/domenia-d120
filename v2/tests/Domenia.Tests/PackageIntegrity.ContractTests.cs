using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.App;
using Domenia.Core;

namespace Domenia.Tests;

internal static partial class PackageIntegrityTests
{
    private static void ContractPack(TemporaryFolder folder, Action<Dictionary<string, object>>? change = null, Action<Dictionary<string, object>>? registryChange = null)
    {
        Pack(folder);
        // Real PE version resource, read only as bytes; this file is never executed by the fixture.
        File.Copy(typeof(ProductInfo).Assembly.Location, folder.File("Domenia.exe"), true);
        var version = ProductInfo.DevelopmentVersion;
        var build = version + "+" + new string('a', 64);
        var exeHash = Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(folder.File("Domenia.exe"))));
        File.WriteAllText(folder.File("package-release.json"), JsonSerializer.Serialize(new { version, build, project = "Domenia", architecture = "win-x64", packageType = "PROD", sourceCommit = new string('b', 40),
            executableSha256 = exeHash, dataSchemaVersion = 11, dataSchemaRevision = 2, dependencies = new Dictionary<string, string> { [".NET"] = "10.0.13", ["WebView2"] = "1.0" } }));
        Directory.CreateDirectory(folder.File("contracts"));
        var registry = ContractRegistry(); var registryFingerprint = (string)registry["fingerprint"];
        registryChange?.Invoke(registry);
        File.WriteAllText(folder.File("contracts/operation-contracts.json"), JsonSerializer.Serialize(registry));
        var names = Components.Concat(["package-release.json", "contracts/operation-contracts.json"]).ToArray();
        var components = names.Select(name => new PackageComponent(name, new FileInfo(folder.File(name)).Length,
            Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(folder.File(name)))))).ToArray();
        var contract = new Dictionary<string, object>
        {
            ["format"] = "Domenia.Release/1", ["label"] = "2026.11.01-DOMENIA-" + version + "-CANDIDATE-" + new string('a', 64),
            ["version"] = version, ["build"] = build, ["stage"] = "candidate", ["channel"] = "manual", ["sourceCommit"] = new string('b', 40),
            ["sourceDate"] = "2026.11.01", ["registryFingerprint"] = registryFingerprint,
            ["executableSha256"] = exeHash, ["executableVersion"] = FileVersionInfo.GetVersionInfo(folder.File("Domenia.exe")).FileVersion!,
            ["componentsFingerprint"] = PackageIntegrity.ComponentFingerprint(components),
        };
        change?.Invoke(contract);
        File.WriteAllText(folder.File(PackageIntegrity.ContractName), JsonSerializer.Serialize(contract));
        Manifest(folder, names.Append(PackageIntegrity.ContractName));
    }

    private static Dictionary<string, object> ContractRegistry()
    {
        string[] projects = ["Domenia.Core", "Domenia.Store", "Domenia.Ad", "Domenia.Bridge", "Domenia.Inventory", "Domenia.App", "Domenia.Engine", "Domenia.Simulation"];
        var files = projects.Select(p => "src/" + p + "/Body.cs").Concat(["Directory.Build.props", "global.json", "NuGet.config"])
            .Order(StringComparer.Ordinal).Select(p => new Dictionary<string, string> { ["path"] = p, ["sha256"] = new string('a', 64) }).ToArray();
        static string Hash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
        var implementation = Hash(string.Concat(files.Select(f => f["path"] + "=" + f["sha256"] + "\n")));
        string[] names = ["DnsReverseLookup", "LegacyMigration", "LocalIndexRead", "LocalStore", "ParkSharedSync", "StorageBackup", "StorageIntegrity", "StorageMaintenance", "StoragePurge", "StorageRetention", "StorageUsage"];
        var operations = names.Select(n => new Dictionary<string, string> { ["name"] = n, ["implementationSha256"] = implementation }).ToArray();
        return new() { ["format"] = "Domenia.OperationContracts/1", ["scope"] = "compiled-implementation-closure", ["files"] = files,
            ["operations"] = operations, ["fingerprint"] = Hash(string.Concat(names.Select(n => n + "=" + implementation + "\n"))) };
    }

    [Test]
    public static void Registry_contents_are_recomputed_even_when_manifest_and_component_fingerprint_are_resealed()
    {
        Action<Dictionary<string, object>>[] corruptions =
        [
            registry => ((Dictionary<string, string>[])registry["files"])[0]["sha256"] = new string('b', 64),
            registry => ((Dictionary<string, string>[])registry["files"])[0]["path"] = "../foreign.cs",
            registry => ((Dictionary<string, string>[])registry["files"])[0]["extra"] = "ignored?",
            registry => registry["files"] = ((Dictionary<string, string>[])registry["files"]).Reverse().ToArray(),
            registry => registry["files"] = Array.Empty<object>(),
            registry => registry["files"] = Enumerable.Repeat(((Dictionary<string, string>[])registry["files"])[0], 4097).ToArray(),
            registry => ((Dictionary<string, string>[])registry["files"])[1]["path"] = ((Dictionary<string, string>[])registry["files"])[0]["path"],
            registry => ((Dictionary<string, string>[])registry["files"])[0]["path"] = "src/Domenia.Core/obj/Generated.cs",
            registry => ((Dictionary<string, string>[])registry["files"])[0]["sha256"] = new string('A', 64),
            registry => ((Dictionary<string, string>[])registry["operations"])[0]["name"] = "ForeignOperation",
            registry => ((Dictionary<string, string>[])registry["operations"])[0]["implementationSha256"] = new string('0', 64),
            registry => registry["operations"] = Array.Empty<object>(),
        ];
        foreach (var change in corruptions)
        {
            using var folder = new TemporaryFolder(); ContractPack(folder, registryChange: change);
            Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true).Dispose(), "registre altéré refusé avant composition malgré identités déclarées conservées");
        }
    }

    [Test]
    public static void Release_contract_pairs_real_executable_version_and_all_components_without_claiming_publisher_trust()
    {
        using var folder = new TemporaryFolder(); ContractPack(folder);
        using var pack = PackageIntegrity.Open(folder.Path, true);
        Check.NotNull(pack.Contract, "contrat lu sur fichier tenu");
        Check.Equal("candidate", pack.Contract!.Stage, "qualification distincte d’une publication");
        Check.Throws<InvalidDataException>(() => pack.VerifyCompiledRelease([typeof(ProductInfo).Assembly]), "mêmes octets de paquet ne prouvent pas la même compilation en mémoire");
    }

    [Test]
    public static void Self_consistent_manifest_cannot_hide_a_contradictory_contract_or_an_unpaired_executable()
    {
        foreach (var key in new[] { "label", "version", "sourceDate", "sourceCommit", "executableSha256", "executableVersion", "componentsFingerprint" })
        {
            using var folder = new TemporaryFolder(); ContractPack(folder, contract => contract[key] = key.EndsWith("Fingerprint", StringComparison.Ordinal) || key.EndsWith("Sha256", StringComparison.Ordinal) ? new string('0', 64) : "contradiction");
            Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(folder.Path, true), "contradiction refusée malgré nouveau manifeste : " + key);
        }
        Check.True(PackageIntegrity.ForbiddenPayload("wad/tests/fixture.txt", false), "recette exclue du runtime");
        Check.True(PackageIntegrity.ForbiddenPayload("wad/start.cmd", false), "lanceur exclu");
        Check.False(PackageIntegrity.ForbiddenPayload("wad/Domenia.Simulation.dll", false), "fonction démonstration du produit conservée");
        Check.False(PackageIntegrity.ForbiddenPayload("wad/developer/v2/tests/fixture.cs", true), "sources du DEV explicites");
    }
}
