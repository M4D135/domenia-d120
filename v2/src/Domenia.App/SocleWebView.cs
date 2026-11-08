using System.Security.Cryptography;
using System.Text.Json;

namespace Domenia.App;

/// <summary>
/// Pinned index of the shared Socle WebView2 fixed runtime (M4D135/socle-windows). A PROD-LIGHT pack never ships it;
/// when Evergreen is absent an operator may extract that one archive into wad\, and every byte is then checked against this index.
/// </summary>
internal sealed record SocleWebView(string Version, IReadOnlyList<PackageComponent> Files)
{
    internal const string Folder = "runtime/webview2";
    internal const string PinnedVersion = "156.0.4314.42";
    internal const string Archive = "Socle_WebView2-" + PinnedVersion + "_Windows-x64.zip";
    internal const string ReleaseUrl = "https://github.com/M4D135/socle-windows/releases/tag/webview2-" + PinnedVersion;
    // SHA-256 of webview2-<version>.files.json as published with the Socle release; the embedded copy must be those bytes.
    private const string IndexSha256 = "a846d3785426fabe872f7e53188e3ba998d4a0ebde34f6af66ac4fe04acf77d3";
    private static readonly Lazy<SocleWebView> pinned = new(Load);

    internal static SocleWebView Pinned => pinned.Value;

    private static SocleWebView Load()
    {
        using var stream = typeof(SocleWebView).Assembly.GetManifestResourceStream("Domenia.Socle.WebView2")
            ?? throw new InvalidDataException("Index du pack WebView2 du Socle absent de Domenia.");
        var bytes = new byte[stream.Length];
        stream.ReadExactly(bytes);
        if (Convert.ToHexStringLower(SHA256.HashData(bytes)) != IndexSha256)
            throw new InvalidDataException("Index du pack WebView2 du Socle différent de celui épinglé.");
        var index = Parse(bytes);
        return index.Version == PinnedVersion ? index : throw new InvalidDataException("Version de l’index du pack WebView2 du Socle inattendue.");
    }

    internal static SocleWebView Parse(ReadOnlySpan<byte> bytes)
    {
        using var document = JsonDocument.Parse(bytes.ToArray(), new JsonDocumentOptions { MaxDepth = 4 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || Text(root, "component") != "webview2-fixed" || Text(root, "root") != Folder
            || !System.Version.TryParse(Text(root, "version"), out var version) || version.Revision < 0 || version.ToString() != Text(root, "version")
            || !root.TryGetProperty("files", out var list) || list.ValueKind != JsonValueKind.Array || list.GetArrayLength() is < 2 or > PackageIntegrity.MaximumFiles
            || !root.TryGetProperty("file_count", out var count) || count.ValueKind != JsonValueKind.Number || !count.TryGetInt32(out var declared) || declared != list.GetArrayLength())
            throw Invalid();
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var files = new List<PackageComponent>();
        foreach (var file in list.EnumerateArray())
        {
            var path = Text(file, "path"); var sha = Text(file, "sha256");
            if (!PackageIntegrity.ValidRelativePath(path) || !path!.StartsWith(Folder + "/", StringComparison.Ordinal) || !names.Add(path)
                || sha is not { Length: 64 } || !sha.All(Uri.IsHexDigit) || !file.TryGetProperty("bytes", out var size) || size.ValueKind != JsonValueKind.Number || !size.TryGetInt64(out var length)
                || length is < 0 or > 2L * 1024 * 1024 * 1024)
                throw Invalid();
            files.Add(new(path, length, sha.ToLowerInvariant()));
        }
        if (!names.Contains(Folder + "/msedgewebview2.exe") || !names.Contains(Folder + "/msedge.dll")) throw Invalid();
        return new(version.ToString(), files.AsReadOnly());
    }

    private static string? Text(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var field)
        && field.ValueKind == JsonValueKind.String ? field.GetString() : null;

    private static InvalidDataException Invalid() => new("Index du pack WebView2 du Socle invalide.");
}
