using System.Text;
using System.Text.Json;
using Domenia.Core.Queries;

namespace Domenia.Store;

internal static class LegacyQueryFile
{
    // Encoded preferences can contain a JSON string twice; cap the physical input before allocating it.
    internal const int MaxPreferenceBytes = 64 * 1024 * 1024;
    internal static string? Read(IEnumerable<string> paths, CancellationToken token)
    {
        foreach (var primary in paths.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            token.ThrowIfCancellationRequested();
            var path = File.Exists(primary) ? primary : primary + ".bak";
            CompatibleDirectoryCache.ValidateLocalPath(path);
            if (!File.Exists(path)) continue;
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length > MaxPreferenceBytes) throw new InvalidDataException("Préférences historiques supérieures à 64 Mio : reprise différée, source conservée.");
            var bytes = new byte[checked((int)file.Length)]; file.ReadExactly(bytes);
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 96 });
            if (document.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Préférences historiques invalides.");
            var values = document.RootElement.EnumerateObject().Where(p => p.Name.Equals("Query.Library", StringComparison.OrdinalIgnoreCase)).ToArray();
            if (values.Length > 1) throw new InvalidDataException("Préférence Query.Library dupliquée ; aucune reprise ambiguë.");
            if (values.Length == 0) continue;
            if (values[0].Value.ValueKind != JsonValueKind.String) throw new InvalidDataException("Préférence Query.Library non textuelle ; source conservée.");
            var value = values[0].Value.GetString();
            if (value is not null && Encoding.UTF8.GetByteCount(value) > QueryLibrary.MaxDocumentBytes)
                throw new InvalidDataException("Ancienne bibliothèque supérieure à 16 Mio ; source conservée.");
            return value;
        }
        return null;
    }
}
