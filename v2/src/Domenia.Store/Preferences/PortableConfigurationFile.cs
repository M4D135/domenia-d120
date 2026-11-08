using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Store;

public sealed record PortableConfigurationSource(PortableConfigurationDocument Document, string FileSha256);

public static class PortableConfigurationFile
{
    /// <summary>Requalifies the same fixed source and holds it against replacement throughout the preference commit.</summary>
    public static IDisposable Hold(string path, string fileSha256, CancellationToken token) => LegacyBoardLayoutFile.HoldSources(
        new LegacyBoardPreview(path, fileSha256, [new("Fleet", null, "ready", "Configuration distribuable", 0, [], null)], []) { SourceKind = "configuration" }, "Fleet", token);

    private static readonly UTF8Encoding Utf8 = new(false, true);
    /// <summary>Local fixed/explicit path only; qualified ancestors and file, bounded allocation, exact read and EOF.</summary>
    public static PortableConfigurationSource? Read(string path, CancellationToken token)
    {
        var bytes = LegacyBoardLayoutFile.ReadBounded(path, PortableConfiguration.MaxBytes, token);
        if (bytes is null) return null;
        var offset = bytes.AsSpan().StartsWith(new byte[] { 0xef, 0xbb, 0xbf }) ? 3 : 0;
        var document = PortableConfiguration.Read(Utf8.GetString(bytes.AsSpan(offset)));
        token.ThrowIfCancellationRequested();
        return new(document, Convert.ToHexStringLower(SHA256.HashData(bytes)));
    }
}
