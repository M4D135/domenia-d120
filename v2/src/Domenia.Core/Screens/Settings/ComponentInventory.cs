using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>A delivered file as read on the disk by the host: path relative to the application folder, size, SHA-256 and version resources.</summary>
public sealed record ComponentFile(string Path, long Bytes, string? Sha256, string? FileVersion, string? ProductVersion);

/// <summary>A group of delivered files counted without hashing each one (web interface, .NET runtime, WebView2 engine).</summary>
public sealed record ComponentFolder(string Id, int Files, long Bytes, ComponentFile? Reference);

/// <summary>One row of the inventory (PAR-002): a version is shown only when it is bound to the file itself.</summary>
public sealed record ComponentRow(string Name, string Path, string Kind, long Bytes, string BytesText, string? Version, string VersionSource, bool Bound, string? Sha256, string? Sha256Short, string Licence, string Provenance, string Note, string Display);

/// <summary>Result of the inventory: rows of the binaries of Domenia, the counted folders and a sentence.</summary>
public sealed record ComponentInventoryView(ImmutableArray<ComponentRow> Rows, long TotalBytes, string TotalText, string Summary);

/// <summary>
/// Inventory of the delivered components (Domenia 1 PAR-002, Get-DomeniaComponentInventory, now shown in À propos as the
/// catalogue asks). A version is displayed only when it is bound to that exact file: its own version resource read on the
/// file whose SHA-256 is shown. A version tied to a package name alone is never shown. Pure.
/// </summary>
public static class ComponentInventory
{
    private static readonly char[] VersionCuts = ['+', ' ', '@'];

    private static (string Name, string Licence, string Provenance) Describe(string path)
    {
        var file = path.Replace('\\', '/').Split('/')[^1];
        return file.ToLowerInvariant() switch
        {
            "domenia.exe" => ("Domenia (exécutable)", "Interne", "Compilé dans la VM du labo depuis ce dépôt"),
            "domenia.dll" => ("Domenia (hôte)", "Interne", "Compilé dans la VM du labo depuis ce dépôt"),
            var f when f.StartsWith("domenia.", StringComparison.Ordinal) => (file[..^4], "Interne", "Compilé dans la VM du labo depuis ce dépôt"),
            "microsoft.web.webview2.core.dll" or "microsoft.web.webview2.winforms.dll" or "microsoft.web.webview2.wpf.dll" or "webview2loader.dll"
                => (file[..^4], "BSD 3 clauses (Microsoft)", "Paquet NuGet Microsoft.Web.WebView2, empreinte dans vendor/nuget/SHA256SUMS"),
            "msedgewebview2.exe" => ("Moteur WebView2 (version fixe)", "Microsoft, redistribution du moteur fixe", "Moteur fixe du pack, signature Microsoft vérifiée à la construction"),
            "coreclr.dll" => (".NET (CoreCLR)", "MIT", "Runtime .NET embarqué par la publication autonome"),
            _ => (file, "Non documentée", "Non documentée"),
        };
    }

    /// <summary>Rows of the hashed files, then one row per counted folder.</summary>
    public static ComponentInventoryView Build(IEnumerable<ComponentFile> files, IEnumerable<ComponentFolder> folders)
    {
        ArgumentNullException.ThrowIfNull(files);
        ArgumentNullException.ThrowIfNull(folders);
        var rows = new List<ComponentRow>();
        foreach (var file in files.OrderBy(f => f.Path, StringComparer.OrdinalIgnoreCase))
        {
            rows.Add(Row(file, "binary"));
        }
        foreach (var folder in folders)
        {
            var (label, licence, provenance) = folder.Id switch
            {
                "web" => ("Interface web (HTML, CSS, modules JavaScript)", "Interne", "Dossier web/ du dépôt, servi par domenia.local"),
                "runtime" => (".NET embarqué (" + FrenchText.Count(folder.Files, "fichier", "fichiers") + ")", "MIT", "Publication autonome win-x64"),
                "webview" => ("Moteur WebView2 fixe (" + FrenchText.Count(folder.Files, "fichier", "fichiers") + ")", "Microsoft, redistribution du moteur fixe", "Dossier runtime/webview2 du pack"),
                _ => (folder.Id, "Non documentée", "Non documentée"),
            };
            if (folder.Reference is ComponentFile reference)
            {
                var row = Row(reference, folder.Id);
                rows.Add(row with
                {
                    Name = label,
                    Bytes = folder.Bytes,
                    BytesText = SettingsFormat.Size(folder.Bytes),
                    Licence = licence,
                    Provenance = provenance,
                    Note = row.Bound ? "Version lue sur " + reference.Path + ", dont l’empreinte est affichée." : row.Note,
                });
            }
            else
            {
                rows.Add(new ComponentRow(label, folder.Id + "/", folder.Id, folder.Bytes, SettingsFormat.Size(folder.Bytes), null, "", false, null, null, licence, provenance,
                    folder.Id == "web" ? "Fichiers produits par ce dépôt, sans manifeste de livraison : version non reliée aux fichiers." : "Aucun fichier de référence lu : version non affichée.",
                    label + " · version non reliée au fichier"));
            }
        }
        // The host counts each folder without the files hashed apart: the rows never overlap.
        var total = rows.Sum(r => r.Bytes);
        var bound = rows.Count(r => r.Bound);
        return new ComponentInventoryView([.. rows], total, SettingsFormat.Size(total),
            FrenchText.Count(rows.Count, "composant", "composants") + ", dont " + FrenchText.Integer(bound) + " avec une version liée à l’empreinte du fichier. Aucune version n’est tirée du seul nom d’un paquet.");
    }

    private static ComponentRow Row(ComponentFile file, string kind)
    {
        var (name, licence, provenance) = Describe(file.Path);
        var sha = SettingsFormat.Sha256Text(file.Sha256);
        var version = (file.ProductVersion ?? file.FileVersion)?.Trim();
        if (version is not null)
        {
            // « 2.0.0-dev+abcdef » and « 10,0,1226,42308 @Commit: … » keep their source revision out of the display; the SHA-256
            // identifies the file. Native resources separate the parts with commas: shown with dots.
            var cut = version.IndexOfAny(VersionCuts);
            version = (cut > 0 ? version[..cut] : version).Replace(',', '.');
        }
        string note;
        var bound = false;
        if (sha is null)
        {
            note = "Empreinte non calculée : aucune version affichée.";
            version = null;
        }
        else if (string.IsNullOrWhiteSpace(version))
        {
            note = "Aucune ressource de version dans ce fichier : version non affichée.";
            version = null;
        }
        else
        {
            bound = true;
            note = "Version lue dans la ressource du fichier dont l’empreinte est affichée.";
        }
        var display = bound ? name + " " + version + " · SHA-256 " + sha![..12] : name + " · version non reliée au fichier";
        return new ComponentRow(name, file.Path, kind, file.Bytes, SettingsFormat.Size(file.Bytes), version, bound ? "Ressource de version du fichier livré" : "", bound, sha, sha is null ? null : SettingsFormat.ShortSha(sha), licence, provenance, note, display);
    }
}
