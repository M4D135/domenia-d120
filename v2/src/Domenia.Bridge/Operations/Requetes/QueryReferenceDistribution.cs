using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Bridge.Operations.Requetes;

public sealed record QueryReferenceOffer(string Id, string FileName, long Version, string Sha256);
public sealed record QueryReferenceListing(string Folder, ImmutableArray<QueryReferenceOffer> Offers, string Notice);

/// <summary>Explicit read-only acquisition from the configured update folder. Only server-retained IDs enter ReadAsync.</summary>
internal sealed partial class QueryReferenceDistribution(EngineContext context) : IDisposable
{
    private sealed record Offer(QueryReferenceOffer View, string Folder, string CatalogSha, DateTimeOffset Expires);
    private readonly SemaphoreSlim serial = new(1, 1);
    private readonly Dictionary<string, Offer> offers = new(StringComparer.Ordinal);
    private const int CatalogLimit = 2 * 1024 * 1024;
    [GeneratedRegex(@"^Domenia-reference-[a-zA-Z0-9_-]{1,160}-v([1-9][0-9]{0,6})\.json$", RegexOptions.CultureInvariant)]
    private static partial Regex PatchName();
    internal static QueryReferenceDistribution From(EngineContext context) => context.Shared(c => new QueryReferenceDistribution(c));

    private async Task<string> FolderAsync(CancellationToken token)
    {
        if (context.Mode == AppMode.Simulation || context.Directory.Kind == DirectorySourceKind.Simulation)
        { throw new QueryDefinitionException("Un partage réel est interdit depuis la démonstration."); }
        var current = context.Preferences is IAtomicPreferenceStore atomic ? await atomic.ReadLatestAsync("updates.distributionFolder", token).ConfigureAwait(false)
            : context.Preferences.TryGet("updates.distributionFolder", out var saved) ? (JsonElement?)saved : null;
        if (current is null || current.Value.ValueKind != JsonValueKind.String || current.Value.GetString() is not { } path)
        { throw new QueryDefinitionException("Choisissez d’abord le dossier de diffusion dans Paramètres → Mises à jour."); }
        return QualifiedFolder(path);
    }

    internal static string QualifiedFolder(string path)
    {
        if (path.Length is 0 or > 512 || !Path.IsPathFullyQualified(path) || path.StartsWith(@"\\?", StringComparison.Ordinal) || path.StartsWith(@"\\.", StringComparison.Ordinal))
        { throw new QueryDefinitionException("Dossier de diffusion local ou UNC absolu ordinaire attendu."); }
        var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        if (!string.Equals(full, Path.TrimEndingDirectorySeparator(path), StringComparison.OrdinalIgnoreCase)) { throw new QueryDefinitionException("Dossier de diffusion ambigu."); }
        var relative = full.StartsWith(@"\\", StringComparison.Ordinal) ? full[2..] : full.Length >= 3 && char.IsAsciiLetter(full[0]) && full[1..3] == @":\" ? full[3..] : "";
        if (relative.Length == 0 || relative.Split('\\').Any(p => !SafeName(p)) || full.StartsWith(@"\\", StringComparison.Ordinal) && relative.Split('\\').Length < 2)
        { throw new QueryDefinitionException("Dossier de diffusion non canonique."); }
        return full;
    }

    private static bool SafeName(string name)
    {
        if (name.Length is 0 or > 234 || name is "." or ".." || name.EndsWith(' ') || name.EndsWith('.') || name.Any(c => char.IsControl(c) || "<>:\"/\\|?*".Contains(c))) { return false; }
        var first = name.Split('.')[0].ToUpperInvariant();
        return first is not ("CON" or "PRN" or "AUX" or "NUL" or "CLOCK$" or "CONIN$" or "CONOUT$")
            && !(first.Length == 4 && (first.StartsWith("COM", StringComparison.Ordinal) || first.StartsWith("LPT", StringComparison.Ordinal)) && "123456789¹²³".Contains(first[3]));
    }

    internal static Dictionary<string, string> Checksums(byte[] bytes)
    {
        if (bytes.Length is 0 or > CatalogLimit) { throw new QueryDefinitionException("SHA256SUMS.txt limité à 2 Mio."); }
        string text;
        try { text = new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException) { throw new QueryDefinitionException("SHA256SUMS.txt doit être UTF-8 valide."); }
        if (text.StartsWith('\uFEFF')) { text = text[1..]; }
        var entries = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.EndsWith('\r') ? raw[..^1] : raw;
            if (line.Length == 0) { continue; }
            if (line.Length is < 67 or > 300 || !line[..64].All(char.IsAsciiHexDigit) || line[64] != ' ' || line[65] is not (' ' or '*') || !SafeName(line[66..])
                || !entries.TryAdd(line[66..], line[..64].ToLowerInvariant()) || entries.Count > 512)
            { throw new QueryDefinitionException("SHA256SUMS.txt invalide, dupliqué ou hors limites ; aucun fichier sélectionné."); }
        }
        if (entries.Count == 0) { throw new QueryDefinitionException("SHA256SUMS.txt ne contient aucune empreinte."); }
        return entries;
    }

    private static byte[] ReadBytes(string path, int maximum, CancellationToken token)
    {
        using var stream = ReferenceFileAccess.OpenRead(path) ?? throw new IOException("Fichier de diffusion absent.");
        if (stream.Length is <= 0 || stream.Length > maximum) { throw new QueryDefinitionException("Fichier de diffusion vide ou hors limites."); }
        var bytes = new byte[(int)stream.Length];
        for (var offset = 0; offset < bytes.Length;)
        {
            token.ThrowIfCancellationRequested(); var count = stream.Read(bytes, offset, Math.Min(65536, bytes.Length - offset));
            if (count == 0) { throw new IOException("Copie de diffusion interrompue."); } offset += count;
        }
        if (stream.ReadByte() != -1) { throw new IOException("Fichier de diffusion modifié pendant copie."); }
        token.ThrowIfCancellationRequested(); return bytes;
    }
    private static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    internal async Task<QueryReferenceListing> ListAsync(CancellationToken token)
    {
        var folder = await FolderAsync(token).ConfigureAwait(false); var access = await QueryReferenceContext.Capture(context, token).ConfigureAwait(false);
        await serial.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var catalog = await Task.Run(() =>
            {
                using var physical = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Storage);
                using var pins = ReferenceFileAccess.PinParents(Path.Combine(folder, "SHA256SUMS.txt"));
                access.Validate(); var bytes = ReadBytes(Path.Combine(folder, "SHA256SUMS.txt"), CatalogLimit, token); access.Validate(); return bytes;
            }, token).ConfigureAwait(false);
            if (await FolderAsync(token).ConfigureAwait(false) != folder) { throw new QueryDefinitionException("Dossier de diffusion changé pendant la lecture."); }
            var entries = Checksums(catalog).Where(p => PatchName().IsMatch(p.Key)).ToArray();
            if (entries.Length > 32) { throw new QueryDefinitionException("Plus de 32 patches publiés ; réduisez le catalogue de diffusion."); }
            offers.Clear();
            foreach (var entry in entries)
            {
                var version = long.Parse(PatchName().Match(entry.Key).Groups[1].Value, CultureInfo.InvariantCulture);
                if (version > 1_000_000) { throw new QueryDefinitionException("Version de référence hors limites."); }
                var view = new QueryReferenceOffer(Guid.NewGuid().ToString("N"), entry.Key, version, entry.Value);
                offers.Add(view.Id, new(view, folder, Hash(catalog), context.Clock.GetUtcNow().AddMinutes(10)));
            }
            return new(folder, [.. offers.Values.Select(p => p.View).OrderByDescending(p => p.Version).ThenBy(p => p.FileName, StringComparer.Ordinal)],
                "Empreintes annoncées par SHA256SUMS.txt ; les octets du patch seront vérifiés après votre sélection. Aucune signature éditeur supposée.");
        }
        finally { serial.Release(); }
    }

    internal async Task<QueryImportPlan> ReadAsync(string id, CancellationToken token)
    {
        var folder = await FolderAsync(token).ConfigureAwait(false); var access = await QueryReferenceContext.Capture(context, token).ConfigureAwait(false);
        await serial.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (!offers.TryGetValue(id, out var offer) || offer.Folder != folder || context.Clock.GetUtcNow() >= offer.Expires)
            { throw new QueryDefinitionException("Sélection de diffusion absente, modifiée ou expirée ; relancez la recherche."); }
            var bytes = await Task.Run(() =>
            {
                using var physical = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Storage);
                using var pins = ReferenceFileAccess.PinParents(Path.Combine(folder, "SHA256SUMS.txt"));
                access.Validate();
                if (Hash(ReadBytes(Path.Combine(folder, "SHA256SUMS.txt"), CatalogLimit, token)) != offer.CatalogSha)
                { throw new QueryDefinitionException("SHA256SUMS.txt modifié depuis la sélection."); }
                var data = ReadBytes(Path.Combine(folder, offer.View.FileName), QueryReferenceCodec.MaxBytes, token);
                if (Hash(data) != offer.View.Sha256) { throw new QueryDefinitionException("SHA-256 du fichier reçu différent ; aucun aperçu accepté."); }
                if (Hash(ReadBytes(Path.Combine(folder, "SHA256SUMS.txt"), CatalogLimit, token)) != offer.CatalogSha)
                { throw new QueryDefinitionException("Catalogue changé pendant la copie ; relancez la recherche."); }
                access.Validate(); return data;
            }, token).ConfigureAwait(false);
            if (await FolderAsync(token).ConfigureAwait(false) != folder || context.Clock.GetUtcNow() >= offer.Expires) { throw new QueryDefinitionException("Source de diffusion modifiée ou expirée pendant copie."); }
            string text;
            try { text = new UTF8Encoding(false, true).GetString(bytes); }
            catch (DecoderFallbackException) { throw new QueryDefinitionException("Patch reçu en UTF-8 invalide."); }
            var parsed = QueryReferenceCodec.Read(text, context.Clock.GetUtcNow());
            if (parsed.Version != offer.View.Version) { throw new QueryDefinitionException("Nom de fichier et version du patch ne correspondent pas."); }
            var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false); access.Validate();
            var plan = await RequetesServices.Library(context).ExamineReferencePatchAsync(session.Domain?.RootDn ?? throw new QueryDefinitionException("Domaine absent."), text, access, token).ConfigureAwait(false);
            offers.Remove(id); return plan;
        }
        finally { serial.Release(); }
    }
    public void Dispose() => serial.Dispose();
}
