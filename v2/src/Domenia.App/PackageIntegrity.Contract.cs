using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.App;

internal sealed record PackageReleaseContract(string Label, string Version, string Build, string Stage, string Channel,
    string SourceCommit, string RegistryFingerprint, string ExecutableSha256, string ExecutableVersion, string ComponentsFingerprint);

internal sealed partial class PackageIntegrity
{
    internal const string ContractName = "package-contract.json";
    internal PackageReleaseContract? Contract { get; private set; }

    internal void VerifyReleaseContract(string root, bool required)
    {
        var relative = PackageLayout.Relative(root, ContractName);
        var entry = Components.SingleOrDefault(c => c.Path == relative);
        if (entry is null)
        {
            if (required) throw Invalid("Contrat de livraison absent ; aucune opération du paquet admise.");
            return; // Legacy packs remain readable for explicit upgrade/rollback.
        }
        var stream = held.SingleOrDefault(f => string.Equals(f.Name, Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)), StringComparison.OrdinalIgnoreCase))
            ?? throw Invalid("Contrat non tenu par le contrôle d’intégrité.");
        if (stream.Length > 64 * 1024) throw Invalid("Contrat de livraison hors limites.");
        stream.Position = 0;
        using var json = JsonDocument.Parse(stream, new JsonDocumentOptions { MaxDepth = 8 });
        var value = json.RootElement;
        Fields(value, ["format", "label", "version", "build", "stage", "channel", "sourceCommit", "sourceDate", "registryFingerprint", "executableSha256", "executableVersion", "componentsFingerprint"]);
        string Text(string name) => value.GetProperty(name).ValueKind == JsonValueKind.String && value.GetProperty(name).GetString() is { Length: > 0 and <= 200 } text ? text : throw Invalid("Valeur de contrat invalide.");
        var version = Text("version"); var build = Text("build"); var stage = Text("stage"); var channel = Text("channel");
        var commit = Text("sourceCommit"); var date = Text("sourceDate"); var registry = Text("registryFingerprint");
        static bool Hex(string value, int length) => value.Length == length && value.All(char.IsAsciiHexDigit) && value == value.ToLowerInvariant();
        if (Text("format") != "Domenia.Release/1" || stage != "candidate" || channel != "manual"
            || !Version.TryParse(version, out var parsed) || parsed.Revision != -1 || parsed.Build < 0
            || !build.StartsWith(version + "+", StringComparison.Ordinal) || !Hex(build[(version.Length + 1)..], 64)
            || !Hex(commit, 40) || !Hex(registry, 64) || !DateOnly.TryParseExact(date, "yyyy.MM.dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _))
            throw Invalid("Identité, étape ou canal du contrat invalide.");
        var label = date + "-DOMENIA-" + version + "-CANDIDATE-" + build[(version.Length + 1)..];
        if (Text("label") != label) throw Invalid("Étiquette de livraison contradictoire.");
        var registryPath = PackageLayout.Relative(root, "contracts/operation-contracts.json");
        var registryFile = held.SingleOrDefault(f => string.Equals(f.Name, Path.Combine(root, registryPath.Replace('/', Path.DirectorySeparatorChar)), StringComparison.OrdinalIgnoreCase))
            ?? throw Invalid("Registre de livraison absent des composants détenus.");
        if (registryFile.Length > 2 * 1024 * 1024) throw Invalid("Registre de livraison hors limites.");
        registryFile.Position = 0;
        using var registryDocument = JsonDocument.Parse(registryFile, new JsonDocumentOptions { MaxDepth = 8 });
        if (VerifyOperationRegistry(registryDocument.RootElement) != registry)
            throw Invalid("Registre livré différent du contrat.");
        var exe = Components.Single(c => c.Path == "Domenia.exe");
        var executableVersion = Text("executableVersion");
        if (Text("executableSha256") != exe.Sha256 || !Version.TryParse(executableVersion, out var exeVersion)
            || exeVersion.Major != parsed.Major || exeVersion.Minor != parsed.Minor || exeVersion.Build != parsed.Build)
            throw Invalid("Version et empreinte de l’exécutable non appariées.");
        var actualVersion = System.Diagnostics.FileVersionInfo.GetVersionInfo(Path.Combine(root, "Domenia.exe")).FileVersion;
        if (actualVersion != executableVersion) throw Invalid("Version réelle de l’exécutable différente du contrat.");
        var fingerprint = ComponentFingerprint(Components.Where(c => c.Path != relative));
        if (Text("componentsFingerprint") != fingerprint) throw Invalid("Composants différents du contrat de livraison.");
        var release = PackageLifecycle.Release(root, Components);
        if (release is null || release.Version != version || release.Build != build || release.SourceCommit != commit || release.ExecutableSha256 != exe.Sha256)
            throw Invalid("Métadonnées et contrat de livraison contradictoires.");
        foreach (var component in Components)
            if (ForbiddenPayload(component.Path, release.PackageType == "DEV")) throw Invalid("Contenu de recette ou donnée privée dans le runtime : " + component.Path);
        Contract = new(label, version, build, stage, channel, commit, registry, exe.Sha256, executableVersion, fingerprint);
    }

    private static readonly string[] RegistryOperations = ["DnsReverseLookup", "LegacyMigration", "LocalIndexRead", "LocalStore", "ParkSharedSync",
        "StorageBackup", "StorageIntegrity", "StorageMaintenance", "StoragePurge", "StorageRetention", "StorageUsage"];
    private static readonly string[] RegistryProjects = ["Domenia.Core", "Domenia.Store", "Domenia.Ad", "Domenia.Bridge", "Domenia.Inventory", "Domenia.App", "Domenia.Engine", "Domenia.Simulation"];

    private static string VerifyOperationRegistry(JsonElement root)
    {
        Fields(root, ["format", "scope", "operations", "files", "fingerprint"]);
        static string Text(JsonElement value, string key, int maximum) => value.GetProperty(key).ValueKind == JsonValueKind.String
            && value.GetProperty(key).GetString() is { Length: > 0 } text && text.Length <= maximum
            ? text : throw Invalid("Champ du registre compilé invalide.");
        static bool Hash(string hash) => hash.Length == 64 && hash.All(char.IsAsciiHexDigit) && hash == hash.ToLowerInvariant();
        static string Digest(StringBuilder text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text.ToString())));
        static bool SourcePath(string name)
        {
            if (!ValidRelativePath(name)) return false;
            if (name is "Directory.Build.props" or "global.json" or "NuGet.config") return true;
            var parts = name.Split('/');
            return parts.Length >= 3 && parts[0] == "src" && RegistryProjects.Contains(parts[1], StringComparer.Ordinal)
                && !parts.Skip(2).Any(p => p.Equals("bin", StringComparison.OrdinalIgnoreCase) || p.Equals("obj", StringComparison.OrdinalIgnoreCase))
                && (name.EndsWith(".cs", StringComparison.Ordinal) || name.EndsWith(".csproj", StringComparison.Ordinal));
        }
        if (Text(root, "format", 64) != "Domenia.OperationContracts/1" || Text(root, "scope", 64) != "compiled-implementation-closure")
            throw Invalid("Version ou périmètre du registre compilé invalide.");
        var files = root.GetProperty("files"); var operations = root.GetProperty("operations");
        if (files.ValueKind != JsonValueKind.Array || files.GetArrayLength() is < 10 or > 4096
            || operations.ValueKind != JsonValueKind.Array || operations.GetArrayLength() != RegistryOperations.Length)
            throw Invalid("Population du registre compilé hors contrat.");
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase); string? previous = null;
        var implementationLines = new StringBuilder();
        foreach (var file in files.EnumerateArray())
        {
            Fields(file, ["path", "sha256"]); var name = Text(file, "path", 512); var hash = Text(file, "sha256", 64);
            if (!SourcePath(name) || !Hash(hash) || !names.Add(name) || previous is not null && StringComparer.Ordinal.Compare(previous, name) >= 0)
                throw Invalid("Sources du registre compilé invalides, répétées ou non ordonnées.");
            previous = name; implementationLines.Append(name).Append('=').Append(hash).Append('\n');
        }
        var implementation = Digest(implementationLines); var registryLines = new StringBuilder(); var index = 0;
        foreach (var operation in operations.EnumerateArray())
        {
            Fields(operation, ["name", "implementationSha256"]); var name = Text(operation, "name", 64); var hash = Text(operation, "implementationSha256", 64);
            if (name != RegistryOperations[index++] || hash != implementation)
                throw Invalid("Corps ou nom du registre compilé différent de sa fermeture réelle.");
            registryLines.Append(name).Append('=').Append(hash).Append('\n');
        }
        var fingerprint = Digest(registryLines);
        if (Text(root, "fingerprint", 64) != fingerprint) throw Invalid("Empreinte déclarée du registre différente de ses corps.");
        return fingerprint;
    }

    internal void VerifyCompiledRelease(IEnumerable<Assembly> assemblies)
    {
        var loaded = assemblies.ToArray();
        CompiledOperationContracts.RequireAssemblies(loaded);
        if (Contract is not { } contract) return;
        if (contract.Build != ProductInfo.Version || contract.Version != ProductInfo.DevelopmentVersion || contract.RegistryFingerprint != CompiledOperationContracts.Fingerprint)
            throw Invalid("Contrat différent du produit et du registre compilés ; aucune mise en file autorisée.");
        foreach (var assembly in loaded)
        {
            var identity = assembly.GetCustomAttributes<AssemblyMetadataAttribute>().SingleOrDefault(a => a.Key == "DomeniaBuildIdentity")?.Value;
            if (identity != contract.Build) throw Invalid("Assemblages issus de livraisons différentes.");
        }
    }

    internal static bool ForbiddenPayload(string path, bool developer)
    {
        if (developer && path.StartsWith("wad/developer/", StringComparison.Ordinal) || path.StartsWith("wad/runtime/", StringComparison.Ordinal)) return false;
        var parts = path.Split('/');
        if (parts.Any(p => new[] { "test", "tests", "fixture", "fixtures", "sample", "samples", "preview", "previews", "screenshots", "developer", "node_modules", ".git", ".env" }.Contains(p, StringComparer.OrdinalIgnoreCase))) return true;
        var file = parts[^1];
        return new[] { ".ps1", ".cmd", ".bat", ".sh", ".py", ".pdb", ".log", ".db", ".sqlite", ".env" }.Contains(Path.GetExtension(file), StringComparer.OrdinalIgnoreCase)
            || new[] { "Domenia.Tests.", "Domenia.WebTests.", "Domenia.E2e.", "Domenia.Capture." }.Any(p => file.StartsWith(p, StringComparison.OrdinalIgnoreCase));
    }

    internal static string ComponentFingerprint(IEnumerable<PackageComponent> components) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(
        string.Concat(components.OrderBy(c => c.Path, StringComparer.Ordinal).Select(c => c.Path + "=" + c.Sha256 + ":" + c.Length.ToString(CultureInfo.InvariantCulture) + "\n")))));
}
