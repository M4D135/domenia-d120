using System.Collections.Immutable;

namespace Domenia.Core.Poste;

/// <summary>Options of a software read (Domenia 1 ChkSoftwarePerUser, ChkSoftwareStore, ChkSoftwareUpdates).</summary>
public sealed record SoftwareRequest(bool PerUser, bool Store, bool Updates);

/// <summary>One software row of the grid; a value that was not read stays null (never « 0 » nor « pas de désinstallation »).</summary>
public sealed record SoftwareRow(
    string Id,
    string Name,
    string? Version,
    string? Publisher,
    DateOnly? InstallDate,
    long? SizeBytes,
    string Architecture,
    string Scope,
    string? Profile,
    string? Location,
    string? Uninstall,
    string Source,
    string? Family,
    string? FamilyLabel);

/// <summary>What was read for one scope (Machine, Utilisateur, Store): status and items.</summary>
public sealed record SoftwareScopeAccess(string Scope, SourceStatus Status, string StatusLabel, int Items, string Detail);

/// <summary>A tile of the software summary (count, publishers, size, recent, multi-version, duplicates…).</summary>
public sealed record SoftwareTile(string Key, string Label, string Value, string Detail, Tone? State, bool Empty);

/// <summary>A part of a ring or a bar; <see cref="Clickable"/> is false for « Autres » and « non renseigné » (FO-09).</summary>
public sealed record SoftwarePart(string Field, string Value, string Label, int Count, long? Bytes, bool Clickable);

/// <summary>Synthesis of the software list (Domenia 1 Get-DomeniaSoftwareBoardData).</summary>
public sealed record SoftwareBoard(
    ImmutableArray<SoftwareTile> Tiles,
    ImmutableArray<SoftwarePart> Publishers,
    ImmutableArray<SoftwarePart> Architectures,
    ImmutableArray<SoftwarePart> Scopes,
    ImmutableArray<SoftwarePart> Largest);

/// <summary>Which columns the grid shows (Get-DomeniaSoftwareColumnVisibility): a column never read is hidden.</summary>
public sealed record SoftwareColumns(bool Publisher, bool InstallDate, bool Size, bool Location, bool Uninstall, bool Source, bool Profile);

/// <summary>Result of poste.software and poste.software.cached.</summary>
public sealed record SoftwareResult(
    string Computer,
    DateTimeOffset? ReadAt,
    string Origin,
    string Provenance,
    bool Complete,
    int Total,
    ImmutableArray<SoftwareRow> Rows,
    ImmutableArray<SoftwareScopeAccess> Access,
    string AccessSummary,
    string? NotCovered,
    SoftwareColumns Columns,
    SoftwareBoard Board,
    ImmutableArray<PosteFact> Facts);

/// <summary>An admitted source of the software inventory (Domenia 1 Get-DomeniaSoftwareSources): never an MSI provider class.</summary>
public sealed record SoftwareSource(string Id, string Label, string Scope, string Transport);

/// <summary>Rules of the software inventory (Domenia 1 D073, FO-09, FO-15, PF-22). Pure: no registry, no WMI, no clock.</summary>
public static class PosteSoftware
{
    public const int KeyCap = 400;
    public const string UnknownPublisher = "Éditeur non renseigné";

    public static ImmutableArray<SoftwareSource> Sources { get; } =
    [
        new("Uninstall64", "Registre Uninstall 64 bits", "Machine", "WinRM ou StdRegProv"),
        new("Uninstall32", "Registre Uninstall 32 bits (WOW6432Node)", "Machine", "WinRM ou StdRegProv"),
        new("Sccm", "Inventaire SCCM (Win32Reg_AddRemovePrograms)", "Machine", "CIM"),
        new("UserHives", "Ruches HKU chargées (profils ouverts)", "Utilisateur", "StdRegProv"),
        new("Appx", "Applications du Store (Appx)", "Store", "WinRM"),
    ];

    /// <summary>
    /// Family of a product from its declared name and publisher only (FO-15): runtimes (Visual C++, .NET, WebView2) and
    /// browsers; WebView2 before the browsers, Chromium before Chrome.
    /// </summary>
    public static (string? Family, string? Label) Family(string? name, string? publisher)
    {
        var text = ((name ?? "") + " " + (publisher ?? "")).ToLowerInvariant();
        if (text.Trim().Length == 0)
        {
            return (null, null);
        }
        if (text.Contains("webview2", StringComparison.Ordinal))
        {
            return ("Runtime", "WebView2");
        }
        if (new[] { "visual c++", "vc++", "vcredist", "vc-redist" }.Any(m => text.Contains(m, StringComparison.Ordinal)))
        {
            return ("Runtime", "Visual C++");
        }
        if (new[] { ".net framework", ".net core", ".net runtime", ".net desktop", "asp.net core", "netcore", "dotnet" }.Any(m => text.Contains(m, StringComparison.Ordinal)))
        {
            return ("Runtime", ".NET");
        }
        (string Label, string[] Marks)[] browsers =
        [
            ("Chromium", ["chromium"]), ("Chrome", ["chrome"]), ("Edge", ["microsoft edge", "msedge"]), ("Firefox", ["firefox"]),
            ("Brave", ["brave browser", "brave software"]), ("Opera", ["opera browser", "opera software"]), ("Vivaldi", ["vivaldi"]),
        ];
        foreach (var (label, marks) in browsers)
        {
            if (marks.Any(m => text.Contains(m, StringComparison.Ordinal)))
            {
                return ("Browser", label);
            }
        }
        return (null, null);
    }

    public static ImmutableArray<SoftwareRow> Rows(IEnumerable<SoftwareEntry> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);
        var n = 0;
        return
        [
            .. entries.Where(e => !string.IsNullOrWhiteSpace(e.Name))
                .OrderBy(e => e.Name, PosteText.French).ThenBy(e => e.Version, StringComparer.Ordinal).ThenBy(e => e.Scope, StringComparer.Ordinal).ThenBy(e => e.Architecture, StringComparer.Ordinal)
                .Select(e =>
                {
                    var (family, label) = Family(e.Name, e.Publisher);
                    return new SoftwareRow("s" + (n++).ToString(System.Globalization.CultureInfo.InvariantCulture), e.Name.Trim(), e.Version, string.IsNullOrWhiteSpace(e.Publisher) ? null : e.Publisher.Trim(),
                        e.InstallDate, e.SizeBytes is > 0 ? e.SizeBytes : null, e.Architecture, e.Scope, e.Profile, e.Location, e.Uninstall, e.Source, family, label);
                }),
        ];
    }

    /// <summary>One line per scope of what was read (Get-DomeniaSoftwareAccessSummary); an unknown status is said as it is.</summary>
    public static string AccessSummary(IReadOnlyList<SoftwareScopeAccess> access)
    {
        ArgumentNullException.ThrowIfNull(access);
        if (access.Count == 0)
        {
            return "Aucune portée lue.";
        }
        return string.Join(" · ", access.Select(a => a.Scope + FrenchText.Colon + a.StatusLabel.ToLowerInvariant() + (a.Items > 0 ? " (" + FrenchText.Integer(a.Items) + ")" : "")));
    }

    /// <summary>Categories not covered after the read (improvement: « Non couvert : … » under the grid).</summary>
    public static string? NotCovered(IReadOnlyList<SoftwareScopeAccess> access, SoftwareRequest request)
    {
        ArgumentNullException.ThrowIfNull(access);
        ArgumentNullException.ThrowIfNull(request);
        var missing = new List<string>();
        void Check(string scope, bool asked, string label)
        {
            var found = access.FirstOrDefault(a => a.Scope == scope);
            if (!asked)
            {
                missing.Add(label + " (non demandé)");
            }
            else if (found is null || found.Status is not (SourceStatus.Ok or SourceStatus.Empty))
            {
                missing.Add(label + (found is null ? "" : " (" + found.StatusLabel.ToLowerInvariant() + ")"));
            }
        }
        Check("Machine", true, "logiciels de la machine");
        Check("Utilisateur", request.PerUser, "logiciels des profils");
        Check("Store", request.Store, "applications du Store");
        if (!request.Updates)
        {
            missing.Add("mises à jour (non demandées)");
        }
        return missing.Count == 0 ? null : "Non couvert : " + string.Join(", ", missing) + ".";
    }

    /// <summary>Visible columns: technical columns stay behind « Colonnes »; a column empty for every row is hidden.</summary>
    public static SoftwareColumns Columns(IReadOnlyCollection<SoftwareRow> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        return new SoftwareColumns(
            rows.Any(r => r.Publisher is not null),
            rows.Any(r => r.InstallDate is not null),
            rows.Any(r => r.SizeBytes is not null),
            rows.Any(r => r.Location is not null),
            rows.Any(r => r.Uninstall is not null),
            rows.Select(r => r.Source).Distinct(StringComparer.Ordinal).Count() > 1,
            rows.Any(r => r.Profile is not null));
    }

    /// <summary>Synthesis tiles and charts (Get-DomeniaSoftwareBoardData); « Sans date » is never a reassuring 0.</summary>
    public static SoftwareBoard Board(IReadOnlyList<SoftwareRow> rows, DateOnly today)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var tiles = ImmutableArray.CreateBuilder<SoftwareTile>();
        var publishers = rows.Where(r => r.Publisher is not null).Select(r => r.Publisher!).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        tiles.Add(new SoftwareTile("software.count", "Logiciels", FrenchText.Integer(rows.Count), FrenchText.Count(publishers, "éditeur", "éditeurs"), null, rows.Count == 0));
        var sized = rows.Where(r => r.SizeBytes is not null).ToList();
        tiles.Add(new SoftwareTile("software.size", "Taille déclarée", sized.Count == 0 ? "—" : PosteText.Size(sized.Sum(r => r.SizeBytes!.Value)),
            sized.Count == 0 ? "Aucune taille déclarée" : FrenchText.Integer(sized.Count) + " sur " + FrenchText.Integer(rows.Count) + " déclarent une taille", null, sized.Count == 0));
        var dated = rows.Where(r => r.InstallDate is not null).ToList();
        var recent = dated.Where(r => r.InstallDate!.Value > today.AddDays(-30)).OrderByDescending(r => r.InstallDate).ToList();
        tiles.Add(new SoftwareTile("software.recent", "Installés ces 30 jours", dated.Count == 0 ? "Sans date" : FrenchText.Integer(recent.Count),
            dated.Count == 0 ? "Aucune date d’installation déclarée" : recent.Count == 0 ? "Aucun" : "Dernier : " + recent[0].Name + " (" + FrenchText.ShortDate(recent[0].InstallDate!.Value) + ")", recent.Count > 0 ? Tone.Info : null, dated.Count == 0));
        var multi = rows.GroupBy(r => r.Name, StringComparer.OrdinalIgnoreCase).Where(g => g.Select(r => r.Version ?? "").Distinct(StringComparer.Ordinal).Count() > 1).ToList();
        tiles.Add(new SoftwareTile("software.multiversion", "En plusieurs versions", FrenchText.Integer(multi.Count), multi.Count == 0 ? "Aucun" : string.Join(", ", multi.Take(2).Select(g => g.Key)) + (multi.Count > 2 ? "…" : ""), multi.Count > 0 ? Tone.Warn : null, multi.Count == 0));
        var duplicates = rows.GroupBy(r => (Name: r.Name.ToLowerInvariant(), Version: r.Version ?? "")).Where(g => g.Count() > 1).ToList();
        tiles.Add(new SoftwareTile("software.duplicates", "En double", FrenchText.Integer(duplicates.Count), duplicates.Count == 0 ? "Aucun (même nom et version)" : "Même nom et version sur plusieurs architectures, portées ou profils ; rien n’est fusionné", duplicates.Count > 0 ? Tone.Info : null, duplicates.Count == 0));
        var noPublisher = rows.Count(r => r.Publisher is null);
        tiles.Add(new SoftwareTile("software.nopublisher", "Sans éditeur", FrenchText.Integer(noPublisher), noPublisher == 0 ? "Aucun" : "Éditeur non déclaré par l’entrée de désinstallation", noPublisher > 0 ? Tone.Warn : null, noPublisher == 0));
        var runtimes = rows.Where(r => r.Family == "Runtime").GroupBy(r => r.FamilyLabel!, StringComparer.Ordinal).Select(g => g.Key + " (" + FrenchText.Integer(g.Count()) + ")").ToList();
        tiles.Add(new SoftwareTile("software.runtime", "Composants d’exécution", runtimes.Count == 0 ? "Aucun" : FrenchText.Integer(rows.Count(r => r.Family == "Runtime")), runtimes.Count == 0 ? "Visual C++, .NET ou WebView2 non trouvés" : string.Join(", ", runtimes), null, runtimes.Count == 0));
        var browsers = rows.Where(r => r.Family == "Browser").GroupBy(r => r.FamilyLabel!, StringComparer.Ordinal)
            .Select(g => g.Key + " " + string.Join("/", g.Select(r => Major(r.Version)).Where(v => v.Length > 0).Distinct(StringComparer.Ordinal))).ToList();
        tiles.Add(new SoftwareTile("software.browsers", "Navigateurs", browsers.Count == 0 ? "Aucun" : FrenchText.Integer(browsers.Count), browsers.Count == 0 ? "Aucun navigateur déclaré" : string.Join(", ", browsers), null, browsers.Count == 0));

        var byPublisher = rows.GroupBy(r => r.Publisher ?? UnknownPublisher, StringComparer.OrdinalIgnoreCase).Select(g => (Key: g.Key, Count: g.Count()))
            .OrderByDescending(g => g.Count).ThenBy(g => g.Key, PosteText.French).ToList();
        var top = byPublisher.Where(g => g.Key != UnknownPublisher).Take(6).ToList();
        var publisherParts = ImmutableArray.CreateBuilder<SoftwarePart>();
        publisherParts.AddRange(top.Select(g => new SoftwarePart("publisher", g.Key, g.Key, g.Count, null, true)));
        var rest = byPublisher.Where(g => g.Key != UnknownPublisher && !top.Contains(g)).Sum(g => g.Count);
        if (rest > 0)
        {
            publisherParts.Add(new SoftwarePart("publisher", "Autres", "Autres", rest, null, false));
        }
        var unknown = byPublisher.FirstOrDefault(g => g.Key == UnknownPublisher).Count;
        if (unknown > 0)
        {
            publisherParts.Add(new SoftwarePart("publisher", UnknownPublisher, "Non renseigné", unknown, null, false));
        }
        var arch = rows.GroupBy(r => r.Architecture, StringComparer.Ordinal).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.Ordinal)
            .Select(g => new SoftwarePart("architecture", g.Key, g.Key, g.Count(), null, g.Key != "Non précisé")).ToImmutableArray();
        var scopes = rows.GroupBy(r => r.Scope, StringComparer.Ordinal).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.Ordinal)
            .Select(g => new SoftwarePart("scope", g.Key, g.Key, g.Count(), null, true)).ToImmutableArray();
        // Labels are told apart by version, then scope, then architecture (Domenia 1 sorted fully to stay stable).
        var largest = rows.Where(r => r.SizeBytes is not null).OrderByDescending(r => r.SizeBytes).ThenBy(r => r.Name, StringComparer.Ordinal).ThenBy(r => r.Version, StringComparer.Ordinal).Take(8).ToList();
        var largestParts = largest.Select(r =>
        {
            var same = largest.Count(o => string.Equals(o.Name, r.Name, StringComparison.OrdinalIgnoreCase));
            var label = same > 1 ? r.Name + " " + (r.Version ?? "") + " · " + r.Scope + " · " + r.Architecture : r.Name;
            return new SoftwarePart("name", r.Name, label.Trim(), 1, r.SizeBytes, true);
        }).ToImmutableArray();
        return new SoftwareBoard(tiles.ToImmutable(), publisherParts.ToImmutable(), arch, scopes, largestParts);
    }

    /// <summary>Major and minor of a browser version: the build number says nothing to the operator.</summary>
    public static string Major(string? version)
    {
        var parts = (version ?? "").Split('.');
        return parts.Length >= 2 ? parts[0] + "." + parts[1] : parts[0];
    }
}
