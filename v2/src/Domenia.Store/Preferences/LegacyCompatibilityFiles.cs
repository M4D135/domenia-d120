using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Store;

public sealed record LegacyCompatibilityCopy(string Id, string Source, string Destination, string State, long Bytes, string? Sha256, string Notice);
public sealed record LegacyCompatibilityPreview(bool Available, string? DataRoot, ImmutableArray<LegacyCompatibilityCopy> Copies, string Fingerprint, string? Reason = null);
public sealed record LegacyCompatibilityReceipt(bool Applied, string Destination, string Sha256, long Bytes, string Summary);

/// <summary>Fixed D1 compatibility copies. Inspection never writes; only an explicit, current preview can publish one absent file.</summary>
public static class LegacyCompatibilityFiles
{
    private const int Limit = 1_048_576;
    private static readonly string[] Names = ["config.json", "login-mode.cfg", "theme.cfg", "ui-profile.cfg"];

    public static LegacyCompatibilityPreview Preview(string app, string user, CancellationToken token)
    {
        var (data, _) = LegacyBoardLayoutFile.Layout(app, user, token);
        var copies = ImmutableArray.CreateBuilder<LegacyCompatibilityCopy>();
        foreach (var suffix in Names) Add("adcc." + suffix, Path.Combine(app, "ADCC." + suffix), Path.Combine(app, "Domenia." + suffix));
        Add("settings", Path.Combine(data, "Domenia.settings.json"), Path.Combine(data, "Preferences", "Domenia.settings.json"));
        var result = copies.ToImmutable();
        var stamp = Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new { data, copies = result })));
        return new(true, data, result, stamp);

        void Add(string id, string source, string destination)
        {
            token.ThrowIfCancellationRequested();
            if (LegacyBoardLayoutFile.Qualify(destination, false, token))
            { copies.Add(new(id, source, destination, "kept", 0, null, "Destination déjà présente, même vide : elle ne sera jamais remplacée.")); return; }
            var bytes = LegacyBoardLayoutFile.ReadBounded(source, Limit, token);
            if (bytes is null) { copies.Add(new(id, source, destination, "absent", 0, null, "Source absente.")); return; }
            try { Validate(id, bytes); }
            catch (Exception ex) when (ex is JsonException or DecoderFallbackException or InvalidDataException)
            { copies.Add(new(id, source, destination, "refused", bytes.Length, Hash(bytes), "Source incompatible ; original conservé, aucune copie.")); return; }
            copies.Add(new(id, source, destination, "ready", bytes.Length, Hash(bytes), id == "settings"
                ? "Copie de compatibilité dans Preferences ; les vues et dispositions sont reprises séparément dans Domenia 2."
                : "Copie de compatibilité ADCC vers Domenia ; original conservé. Le fichier de configuration sera relu au prochain lancement."));
        }
    }

    public static LegacyCompatibilityReceipt Apply(string app, string user, string id, string fingerprint, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var preview = Preview(app, user, token);
        if (fingerprint != preview.Fingerprint) throw new InvalidDataException("Aperçu de compatibilité périmé ; relisez les sources. Aucun fichier remplacé.");
        var item = preview.Copies.SingleOrDefault(c => c.Id == id) ?? throw new InvalidDataException("Copie de compatibilité inconnue.");
        if (item.State != "ready" || item.Sha256 is null) throw new InvalidDataException("Cette copie n’est pas disponible ; aucune destination remplacée.");
        var parent = Path.GetDirectoryName(item.Destination)!;
        var existingParent = item.Id == "settings" ? preview.DataRoot! : parent;
        using var sourcePins = new SharedParkPublicationFile.PathPins(Path.GetDirectoryName(item.Source)!, token);
        using var targetPins = new SharedParkPublicationFile.PathPins(existingParent, token);
        using var source = new FileStream(item.Source, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan);
        if (!LegacyBoardLayoutFile.Qualify(item.Source, false, token) || source.Length != item.Bytes || source.Length > Limit)
            throw new InvalidDataException("Source modifiée depuis l’aperçu.");
        var bytes = new byte[checked((int)source.Length)]; source.ReadExactly(bytes);
        if (source.ReadByte() != -1 || Hash(bytes) != item.Sha256) throw new InvalidDataException("Source modifiée depuis l’aperçu.");
        Validate(id, bytes);
        token.ThrowIfCancellationRequested();
        // No alternate root or cross-mode fallback: only the validated selected data root can receive Preferences.
        if (item.Id == "settings")
        {
            if (!LegacyBoardLayoutFile.Qualify(parent, true, token)) Directory.CreateDirectory(parent);
            targetPins.Add(parent);
        }
        if (LegacyBoardLayoutFile.Qualify(item.Destination, false, token)) throw new IOException("La destination existe maintenant ; elle est conservée.");
        var temporary = Path.Combine(parent, ".domenia-compat-" + Guid.NewGuid().ToString("N") + ".tmp");
        var owned = false;
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                owned = true; output.Write(bytes); output.Flush(true); output.Position = 0;
                if (Convert.ToHexStringLower(SHA256.HashData(output)) != item.Sha256) throw new IOException("Copie provisoire différente de sa source.");
            }
            token.ThrowIfCancellationRequested();
            // Confirm mode/config and source priority after waits, before any final file exists.
            if (Preview(app, user, token).Fingerprint != fingerprint) throw new InvalidDataException("Sources ou mode modifiés pendant la préparation ; relisez l’aperçu.");
            File.Move(temporary, item.Destination, overwrite: false); owned = false;
            // Cancellation after publication never hides the durable copy. A retry sees 'kept', never overwrites it.
            var stored = LegacyBoardLayoutFile.ReadBounded(item.Destination, Limit, CancellationToken.None);
            if (stored is null || Hash(stored) != item.Sha256) throw new IOException("Copie publiée mais relecture non confirmée ; fichier conservé, relisez l’assistant.");
            return new(true, item.Destination, item.Sha256, bytes.Length, "Copie vérifiée et relue ; fichier d’origine conservé, aucun fichier existant remplacé.");
        }
        finally { if (owned) File.Delete(temporary); }
    }

    private static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    private static void Validate(string id, byte[] bytes)
    {
        var offset = bytes.AsSpan().StartsWith(new byte[] { 0xef, 0xbb, 0xbf }) ? 3 : 0;
        var text = new UTF8Encoding(false, true).GetString(bytes, offset, bytes.Length - offset);
        if (id is "settings" or "adcc.config.json")
        {
            using var json = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 32 });
            if (json.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Objet de réglages attendu.");
            Check(json.RootElement);
        }
        else if (text.Length > 4096 || text.Any(c => char.IsControl(c) && c is not ('\r' or '\n' or '\t')))
            throw new InvalidDataException("Préférence de compatibilité non textuelle.");
        static void Check(JsonElement value)
        {
            if (value.ValueKind == JsonValueKind.Object)
            {
                var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var field in value.EnumerateObject()) { if (!names.Add(field.Name)) throw new InvalidDataException("Champ de réglage dupliqué."); Check(field.Value); }
            }
            else if (value.ValueKind == JsonValueKind.Array) foreach (var item in value.EnumerateArray()) Check(item);
        }
    }
}
