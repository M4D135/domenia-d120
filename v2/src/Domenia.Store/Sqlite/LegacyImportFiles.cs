using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Store;

internal sealed record LegacyImportRow(string Kind, string Key, ImmutableDictionary<string, string> Values);
internal sealed record LegacyImportFile(LegacyFile Info, ImmutableArray<LegacyImportRow> Rows);

/// <summary>The same share-read handles supply hashes and rows, and remain held through the import transaction.</summary>
internal sealed class LegacyImportFiles : IDisposable
{
    private readonly List<FileStream> handles = [];
    internal ImmutableArray<LegacyImportFile> Files { get; private set; } = [];
    internal string Marker { get; private set; } = "";

    internal static LegacyImportFiles Read(IReadOnlyList<string> roots, CancellationToken token, TimeZoneInfo zone)
    {
        var result = new LegacyImportFiles();
        try
        {
            var files = ImmutableArray.CreateBuilder<LegacyImportFile>();
            long totalBytes = 0;
            foreach (var kind in LegacyRules.FileKinds)
            {
                token.ThrowIfCancellationRequested();
                var path = roots.Select(root => System.IO.Path.Combine(root, kind.File.Replace('\\', System.IO.Path.DirectorySeparatorChar))).FirstOrDefault(File.Exists);
                if (path is null) { continue; }
                CompatibleDirectoryCache.ValidateLocalPath(path);
                var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                result.handles.Add(stream);
                totalBytes += stream.Length;
                if (stream.Length > LegacyRules.MaxFileBytes || totalBytes > 256L * 1024 * 1024)
                { throw new InvalidDataException("Sources historiques trop volumineuses (128 Mio par fichier, 256 Mio pour le lot)."); }
                var hash = Convert.ToHexStringLower(SHA256.HashData(stream)); stream.Position = 0;
                using var reader = new StreamReader(stream, new UTF8Encoding(false, true), true, 4096, leaveOpen: true);
                var rows = ImmutableArray.CreateBuilder<LegacyImportRow>(); var rejected = 0; var count = 0;
                if (kind.Kind == "Liens")
                {
                    var text = reader.ReadToEnd(); token.ThrowIfCancellationRequested();
                    var csv = RelationImport.ParseCsv(text, checked((int)LegacyRules.MaxRows));
                    if (csv.Truncated || csv.Total > LegacyRules.MaxRows) { throw new InvalidDataException("Plus de 250 000 associations historiques."); }
                    foreach (var raw in csv.Rows)
                    {
                        token.ThrowIfCancellationRequested();
                        if (raw.Sum(x => x.Key.Length + x.Value.Length) > 262144) { throw new InvalidDataException("Association historique supérieure à 256 Kio."); }
                        try { rows.Add(Link(raw, zone)); }
                        catch (Exception ex) when (ex is FormatException or ArgumentException) { rejected++; }
                    }
                }
                else
                {
                    while (reader.ReadLine() is { } line)
                    {
                        token.ThrowIfCancellationRequested(); count++;
                        if (count > LegacyRules.MaxRows + 1) { throw new InvalidDataException("Plus de 250 000 lignes dans une source historique."); }
                        if (line.Length > 262144) { throw new InvalidDataException("Ligne historique supérieure à 256 Kio."); }
                        if (string.IsNullOrWhiteSpace(line)) { continue; }
                        var fields = line.Split('\t');
                        if (count == 1 && fields[0] == (kind.Kind switch { "Objets" => "Type", "Recherches" => "Login", _ => "Computer" })) { continue; }
                        try { rows.Add(Tsv(kind.Kind, fields, zone)); }
                        catch (Exception ex) when (ex is FormatException or ArgumentException) { rejected++; }
                    }
                }
                if (kind.Kind == "Liens")
                {
                    var selected = rows.GroupBy(x => x.Key, StringComparer.OrdinalIgnoreCase).Select(x => x.OrderByDescending(r => r.Values["at"], StringComparer.Ordinal).First()).ToArray();
                    rows.Clear(); rows.AddRange(selected);
                }
                var duplicates = rows.GroupBy(x => x.Key, StringComparer.OrdinalIgnoreCase).Sum(x => Math.Max(0, x.Count() - 1));
                var domains = rows.SelectMany(x => x.Kind == "Objets" ? new[] { x.Values["dn"] } : x.Kind == "Liens" ? new[] { x.Values["userDn"], x.Values["computerDn"] } : [])
                    .Where(x => x.Length > 0).Select(x => LegacyRules.DomainOf(x) ?? "Domaine illisible")
                    .Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.Ordinal).ToImmutableArray();
                files.Add(new(new(kind.Kind, path, stream.Length, rows.Count, rejected, duplicates, hash, domains, true), rows.ToImmutable()));
            }
            result.Files = files.ToImmutable();
            result.Marker = BackupPreferencesRules.Sha256(string.Join('\n', result.Files.Select(x => x.Info.Kind + "|" + x.Info.Path + "|" + x.Info.Sha256)));
            return result;
        }
        catch { result.Dispose(); throw; }
    }

    private static LegacyImportRow Tsv(string kind, string[] f, TimeZoneInfo zone)
    {
        string Get(int index) => index < f.Length ? f[index].Trim() : "";
        var values = ImmutableDictionary.CreateBuilder<string, string>(StringComparer.Ordinal);
        string key;
        switch (kind)
        {
            case "Objets":
                if (f.Length < 9 || string.IsNullOrWhiteSpace(Get(8)) || LegacyRules.DomainOf(Get(8)) is null) { throw new FormatException("Objet historique incomplet."); }
                _ = DistinguishedName.Parse(Get(8));
                if (Get(12).Length > 0 && (!Guid.TryParse(Get(12), out var guid) || guid == Guid.Empty)) { throw new FormatException("GUID historique invalide."); }
                values["guid"] = Get(12).Length == 0 ? "" : Guid.Parse(Get(12)).ToString("D");
                values["type"] = Get(0); values["name"] = Get(1); values["login"] = Get(2); values["upn"] = Get(3);
                values["display"] = Get(4); values["description"] = Get(5); values["extra"] = Get(6); values["state"] = Get(7); values["dn"] = Get(8);
                values["changed"] = Date(zone, Get(9)); values["usn"] = Number(Get(10), long.MaxValue); values["logon"] = Date(zone, Get(11));
                key = values["guid"].Length > 0 ? values["guid"] : (Get(0) + "|" + Get(8)).ToLowerInvariant();
                break;
            case "Parc":
                if (f.Length < 4) { throw new FormatException("État du parc incomplet."); }
                key = Computer(Get(0)); values["computer"] = key; values["at"] = Date(zone, Get(1)); values["status"] = Get(2); values["user"] = Get(3); values["attempts"] = Number(Get(4));
                break;
            case "Recherches":
                if (f.Length < 7 || Get(0).Length == 0 || Get(2) is not ("0" or "1")) { throw new FormatException("Recherche historique incomplète."); }
                key = Get(0).ToLowerInvariant(); values["login"] = Get(0); values["at"] = Date(zone, Get(1)); values["scanned"] = Get(2);
                values["candidates"] = Number(Get(3)); values["reachable"] = Number(Get(4)); values["probed"] = Number(Get(5)); values["found"] = Get(6);
                break;
            case "Secrets":
                if (f.Length < 8) { throw new FormatException("Métadonnées historiques incomplètes."); }
                key = Computer(Get(0)); values["computer"] = key; values["at"] = Date(zone, Get(1)); values["keys"] = Number(Get(2)); values["newest"] = Date(zone, Get(3));
                values["scheme"] = Get(4); values["expiry"] = Date(zone, Get(5)); values["verdict"] = Get(6);
                break;
            default: throw new ArgumentException("Source historique inconnue.");
        }
        return new(kind, key, values.ToImmutable());
    }
    private static LegacyImportRow Link(IReadOnlyDictionary<string, string> row, TimeZoneInfo zone)
    {
        string Get(string key) => row.FirstOrDefault(x => x.Key.Equals(key, StringComparison.OrdinalIgnoreCase)).Value?.Trim() ?? "";
        var key = Computer(Get("Computer")); var user = RelationImport.NormalizeUser(Get("UserLogin"));
        if (user.Length == 0) { throw new FormatException("Association historique incomplète."); }
        var verified = Get("VerifiedInAD").ToLowerInvariant() switch { "" or "0" or "false" => "0", "1" or "true" => "1", _ => throw new FormatException("Indicateur historique invalide.") };
        var values = ImmutableDictionary.CreateBuilder<string, string>(StringComparer.Ordinal);
        values["computer"] = key; values["user"] = user; values["source"] = "Import CSV"; values["confidence"] = Number(Get("Confidence"), 100);
        values["verified"] = verified; values["at"] = Date(zone, Get("When"), required: true);
        // Free-form details are deliberately not copied, including the historical source text.
        values["details"] = "Reprise historique sans détail libre";
        foreach (var (input, output) in new[] { ("UserGuid", "userGuid"), ("ComputerGuid", "computerGuid") })
        {
            var text = Get(input);
            if (text.Length > 0 && (!Guid.TryParse(text, out var id) || id == Guid.Empty)) { throw new FormatException("Identité historique invalide."); }
            values[output] = text.Length == 0 ? "" : Guid.Parse(text).ToString("D");
        }
        foreach (var (input, output) in new[] { ("UserDn", "userDn"), ("ComputerDn", "computerDn") })
        { var text = Get(input); if (text.Length > 0) { _ = DistinguishedName.Parse(text); } values[output] = text; }
        return new("Liens", key, values.ToImmutable());
    }
    private static string Computer(string value)
    {
        var normalized = RelationImport.NormalizeComputer(value);
        if (normalized.Length is < 1 or > 63 || normalized.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '-')) { throw new FormatException("Nom de poste historique invalide."); }
        return normalized;
    }
    private static string Number(string value, long maximum = int.MaxValue) => value.Length == 0 ? "0"
        : long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) && parsed >= 0 && parsed <= maximum
            ? parsed.ToString(CultureInfo.InvariantCulture) : throw new FormatException("Nombre historique invalide.");
    private static string Date(TimeZoneInfo zone, string value, bool required = false)
    {
        if (value.Length == 0) { return required ? throw new FormatException("Date historique absente.") : ""; }
        if (value.Contains('T', StringComparison.Ordinal) && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
        { return parsed.ToString("O", CultureInfo.InvariantCulture); }
        if (DateTime.TryParseExact(value, ["dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "dd/MM/yyyy", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"], CultureInfo.GetCultureInfo("fr-FR"), DateTimeStyles.None, out var local)
            && !zone.IsInvalidTime(local) && !zone.IsAmbiguousTime(local))
        { return new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(local, zone), TimeSpan.Zero).ToString("O", CultureInfo.InvariantCulture); }
        throw new FormatException("Date historique invalide ou heure locale ambiguë.");
    }
    public void Dispose() { foreach (var handle in handles) { handle.Dispose(); } handles.Clear(); }
}
