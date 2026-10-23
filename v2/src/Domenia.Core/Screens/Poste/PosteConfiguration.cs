using System.Collections.Immutable;
using System.Globalization;
using System.Net;
using System.Text.Json;

namespace Domenia.Core.Poste;

public interface IPosteSettingsReader : IScreenReader
{
    Task<PosteConfiguration> CurrentAsync(CancellationToken cancellationToken);
}

/// <summary>Non-secret workstation settings. Parsing never contacts a machine or resolves an executable.</summary>
public sealed record PosteConfiguration(ConfigurationFileState State, string? Problem, PosteOptions Options,
    bool UseCim, bool UseRemoteRegistry, bool UseProfilesShare, bool UseSecurityLog,
    bool UseTaskFallback, bool UsePsExecFallback, bool AllowRemoteArtifacts, int PortTimeoutMs,
    ImmutableArray<string> Warnings)
{
    public static PosteConfiguration Defaults { get; } = new(ConfigurationFileState.Absent, null,
        new(true, false, "Réveil désactivé (Features.WakeOnLan).", [], 300, PosteRemote.RestartMinutes, null,
            [Tool("pesto", "Pesto", null, null), Tool("filpro", "FILPRO", null, null)], ""),
        true, true, true, false, true, true, false, 1200, []);

    public static PosteConfiguration Invalid(string reason) => Defaults with { State = ConfigurationFileState.Invalid, Problem = reason };

    public static PosteConfiguration Parse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > LegacyConfiguration.MaxBytes) { return Invalid("fichier de plus de 1 Mo"); }
        if (bytes.StartsWith("\uFEFF"u8)) { bytes = bytes[3..]; }
        try
        {
            using var document = JsonDocument.Parse(bytes.ToArray(), new JsonDocumentOptions { MaxDepth = 16 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) { return Invalid("objet JSON attendu"); }
            if (Duplicates(root)) { return Invalid("clé en double, y compris avec une casse différente"); }
            var warnings = ImmutableArray.CreateBuilder<string>();
            JsonElement Section(string name)
            {
                var value = Get(root, name);
                if (value.ValueKind is JsonValueKind.Undefined or JsonValueKind.Object) { return value; }
                warnings.Add(name + " : objet attendu, valeurs par défaut conservées."); return default;
            }
            bool Boolean(JsonElement section, string key, bool fallback)
            {
                var value = Get(section, key);
                if (value.ValueKind is JsonValueKind.True or JsonValueKind.False) { return value.GetBoolean(); }
                if (value.ValueKind != JsonValueKind.Undefined) { warnings.Add(key + " : booléen attendu, valeur par défaut conservée."); }
                return fallback;
            }
            int Number(JsonElement section, string key, int fallback, int min, int max)
            {
                var value = Get(section, key);
                if (value.ValueKind == JsonValueKind.Undefined) { return fallback; }
                if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var number)) { warnings.Add(key + " : entier attendu, valeur par défaut conservée."); return fallback; }
                if (number < min || number > max) { warnings.Add(key + " : valeur ramenée dans les limites admises."); }
                return Math.Clamp(number, min, max);
            }
            var remote = Section("Remote"); var features = Section("Features"); var restart = Section("Restart"); var suite = Section("Suite"); var wake = Section("WakeOnLan");
            var networks = ImmutableArray.CreateBuilder<string>();
            var configuredNetworks = Get(wake, "AllowedNetworks");
            if (configuredNetworks.ValueKind != JsonValueKind.Undefined)
            {
                if (configuredNetworks.ValueKind != JsonValueKind.Array || configuredNetworks.GetArrayLength() > 128)
                { warnings.Add("WakeOnLan.AllowedNetworks : tableau de 128 réseaux au plus attendu ; périmètre refusé."); }
                else
                {
                    foreach (var value in configuredNetworks.EnumerateArray())
                    {
                        if (value.ValueKind == JsonValueKind.String && Network(value.GetString()) is { } network) { networks.Add(network); }
                        else { warnings.Add("WakeOnLan.AllowedNetworks : réseau IPv4 canonique /8 à /30 attendu ; entrée ignorée."); }
                    }
                }
            }
            var enabled = Boolean(features, "WakeOnLan", false);
            var options = Defaults.Options with
            {
                UseWinRm = Boolean(remote, "UseWinRM", true), WakeOnLan = enabled,
                WakeReason = !enabled ? "Réveil désactivé (Features.WakeOnLan)." : networks.Count == 0 ? "Aucun réseau de réveil autorisé (WakeOnLan.AllowedNetworks)." : "Réveil limité aux réseaux configurés, sur geste explicite pour un poste.",
                WakeNetworks = [.. networks.Distinct(StringComparer.Ordinal)],
                RestartDelaySeconds = Number(restart, "DefaultDelaySeconds", 300, 60, 3600),
                SuiteTools = [Tool("pesto", "Pesto", SafeText(Get(suite, "PestoPath")), SafeText(Get(suite, "PestoSha256"))),
                    Tool("filpro", "FILPRO", SafeText(Get(suite, "FilProPath")), SafeText(Get(suite, "FilProSha256")))],
            };
            var result = new PosteConfiguration(ConfigurationFileState.Read, null, options,
                Boolean(remote, "UseCim", true), Boolean(remote, "UseRemoteRegistry", true), Boolean(remote, "UseProfilesShare", true),
                Boolean(remote, "UseSecurityLog", false), Boolean(remote, "UseTaskFallback", true), Boolean(remote, "UsePsExecFallback", true),
                Boolean(remote, "AllowRemoteArtifacts", false), Number(remote, "PortTimeoutMs", 1200, 200, 5000), []);
            return result with { Warnings = warnings.ToImmutable() };
        }
        catch (JsonException) { return Invalid("JSON illisible ou trop profond"); }
    }

    private static JsonElement Get(JsonElement parent, string name) => parent.ValueKind == JsonValueKind.Object
        ? parent.EnumerateObject().FirstOrDefault(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase)).Value : default;

    private static bool Duplicates(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Array) { return element.EnumerateArray().Any(Duplicates); }
        if (element.ValueKind != JsonValueKind.Object) { return false; }
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return element.EnumerateObject().Any(p => !names.Add(p.Name) || Duplicates(p.Value));
    }

    private static string? SafeText(JsonElement value) => value.ValueKind == JsonValueKind.String && value.GetString()?.Trim() is { Length: > 0 and <= 1024 } text
        && !text.Any(char.IsControl) ? text : null;

    private static SuiteTool Tool(string id, string label, string? path, string? sha)
    {
        // A lexical declaration only. The host still verifies existence, signature/hash and launch contract at the click.
        var usablePath = path is { Length: > 3 } && Path.IsPathFullyQualified(path) && path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);
        var usableHash = sha is { Length: 64 } && sha.All(char.IsAsciiHexDigit);
        return new(id, label, usablePath && usableHash,
            !usablePath ? "Exécutable non configuré par un chemin absolu (Suite." + (id == "pesto" ? "Pesto" : "FilPro") + "Path)."
                : !usableHash ? "Empreinte SHA-256 attendue non configurée pour " + label + "." : "Chemin et empreinte déclarés ; vérification au lancement.", PosteRemote.SuiteFields)
            { Path = usablePath ? path : null, Sha256 = usableHash ? sha!.ToUpperInvariant() : null };
    }

    private static string? Network(string? value)
    {
        if (value is null || value.Length > 18) { return null; }
        var parts = value.Split('/');
        if (parts.Length != 2 || !IPAddress.TryParse(parts[0], out var address) || address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork
            || address.ToString() != parts[0] || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var prefix) || prefix is < 8 or > 30) { return null; }
        var bytes = address.GetAddressBytes();
        var number = ((uint)bytes[0] << 24) | ((uint)bytes[1] << 16) | ((uint)bytes[2] << 8) | bytes[3];
        var mask = uint.MaxValue << (32 - prefix);
        return (number & mask) == number && bytes[0] is > 0 and < 224 && bytes[0] != 127 ? address + "/" + prefix.ToString(CultureInfo.InvariantCulture) : null;
    }
}
