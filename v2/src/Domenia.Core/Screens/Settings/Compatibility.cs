using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Status of an environment in the matrix, from the most to the least reassuring (Inconnu is a verdict only).</summary>
public enum CompatibilityStatus
{
    Qualified,
    Tested,
    Expected,
    Unsupported,
    Unknown,
}

/// <summary>
/// Facts of this workstation read locally (registry, process, file versions): every fact may be unknown (null), and an
/// unknown fact is never taken as compatible.
/// </summary>
public sealed record EnvironmentFacts(
    string? Product,
    int? Build,
    string? DisplayVersion,
    bool? Is64BitProcess,
    string? Runtime,
    string? WebViewMode,
    string? WebViewVersion,
    bool? SqlitePresent,
    string? SqliteVersion);

/// <summary>Conditions of an entry; an empty condition is documentation only and never matches observed facts.</summary>
public sealed record CompatibilityMatch(
    string? Product = null,
    int? MinBuild = null,
    int? MaxBuild = null,
    bool? Is64Bit = null,
    int? MinRuntimeMajor = null,
    int? MaxRuntimeMajor = null,
    string? WebViewMode = null,
    int? MinWebViewMajor = null,
    bool? SqlitePresent = null)
{
    public bool IsEmpty => Product is null && MinBuild is null && MaxBuild is null && Is64Bit is null && MinRuntimeMajor is null && MaxRuntimeMajor is null
        && WebViewMode is null && MinWebViewMajor is null && SqlitePresent is null;
}

/// <summary>One environment of a dimension, with its status, the evidence that supports it and a note.</summary>
public sealed record CompatibilityEntry(string Id, string Label, CompatibilityMatch Match, CompatibilityStatus Status, string? Evidence, string Note);

/// <summary>One dimension of the matrix (Windows, process, .NET, WebView2, SQLite, directory, workstations).</summary>
public sealed record CompatibilityDimension(string Id, string Label, bool Observed, ImmutableArray<CompatibilityEntry> Entries);

/// <summary>The matrix shipped with Domenia 2 (never downloaded): statuses really supported by evidence of this repository.</summary>
public sealed record CompatibilityMatrix(string ReviewedOn, string Source, ImmutableArray<CompatibilityDimension> Dimensions);

/// <summary>One observed dimension of the verdict.</summary>
public sealed record CompatibilityRow(string Dimension, string Label, string Observed, CompatibilityStatus Status, string StatusLabel, Tone Tone, string Entry, string Note, string Message);

/// <summary>Verdict for this workstation (PAR-001): the least reassuring observed row decides.</summary>
public sealed record CompatibilityVerdict(CompatibilityStatus Overall, string OverallLabel, Tone Tone, string Text, string ReviewedOn, ImmutableArray<CompatibilityRow> Rows, ImmutableArray<CompatibilityEntry> Documented);

/// <summary>
/// Compatibility of the workstation (Domenia 1 PAR-001, point 145, rebuilt for Domenia 2 as the catalogue asks: Windows,
/// .NET embedded, WebView2 fixed or Evergreen). Pure rules: the caller reads the local facts; a fact not read stays unknown
/// and gives « Inconnu », never « compatible ». « Qualifié » needs a qualification report bound to the delivered ZIP: no
/// entry has it, and no « Testé » is claimed without a run of the test suites (decision of 21/10: tests at the very end).
/// </summary>
public static class Compatibility
{
    private const string NoCampaign = "Domenia 2 compilé et lancé en simulation dans la VM du labo (captures du 22/10/2026) ; aucune campagne de tests exécutée (décision du 21/10 : tests à la toute fin).";

    /// <summary>The matrix of this version.</summary>
    public static CompatibilityMatrix Matrix { get; } = new(
        "2026-10-22",
        "Environnements réellement exécutés par Domenia 2. Qualifié exige un rapport de qualification lié au SHA-256 du ZIP livré ; aucun environnement ne l’a encore. Testé exige une campagne de tests exécutée ; aucune ne l’est encore.",
        [
            new("windows", "Windows", true,
            [
                new("win11-24h2-plus", "Windows 11 24H2 ou ultérieur (build 26100 et plus)", new(Product: "Client", MinBuild: 26100, MaxBuild: 99999), CompatibilityStatus.Expected, null, NoCampaign),
                new("win11-older", "Windows 11 23H2 ou antérieur (builds 22000 à 26099)", new(Product: "Client", MinBuild: 22000, MaxBuild: 26099), CompatibilityStatus.Expected, null, "Jamais exécuté."),
                new("win10-22h2", "Windows 10 22H2 (build 19045)", new(Product: "Client", MinBuild: 19045, MaxBuild: 19045), CompatibilityStatus.Expected, null, "Dernière version de Windows 10 ; jamais exécuté."),
                new("win10-older", "Windows 10 avant 22H2", new(Product: "Client", MinBuild: 10240, MaxBuild: 19044), CompatibilityStatus.Unsupported, null, "Versions sans support Microsoft : non prises en charge par Domenia."),
                new("client-legacy", "Windows 8.1 ou antérieur", new(Product: "Client", MinBuild: 0, MaxBuild: 10239), CompatibilityStatus.Unsupported, null, ".NET 10 et WebView2 ne s’y exécutent pas."),
                new("server-2016-plus", "Windows Server 2016 ou ultérieur", new(Product: "Server", MinBuild: 14393, MaxBuild: 99999), CompatibilityStatus.Expected, null, "Poste d’administration sur serveur : jamais exécuté."),
                new("server-legacy", "Windows Server 2012 R2 ou antérieur", new(Product: "Server", MinBuild: 0, MaxBuild: 14392), CompatibilityStatus.Unsupported, null, "Hors support Microsoft."),
            ]),
            new("process", "Processus", true,
            [
                new("x64", "Processus 64 bits", new(Is64Bit: true), CompatibilityStatus.Expected, null, NoCampaign),
                new("x86", "Processus 32 bits", new(Is64Bit: false), CompatibilityStatus.Unsupported, null, "Le pack est publié pour win-x64 seulement."),
            ]),
            new("runtime", ".NET embarqué", true,
            [
                new("net10", ".NET 10 (LTS, embarqué dans le pack)", new(MinRuntimeMajor: 10, MaxRuntimeMajor: 10), CompatibilityStatus.Expected, null, "Runtime livré dans le dossier de l’application : rien à installer. " + NoCampaign),
                new("net-other", "Autre version de .NET", new(MinRuntimeMajor: 0, MaxRuntimeMajor: 9), CompatibilityStatus.Unsupported, null, "Domenia 2 cible .NET 10."),
            ]),
            new("webview", "Moteur web WebView2", true,
            [
                new("webview-fixed", "WebView2 version fixe du pack (154 et plus)", new(WebViewMode: "embarque", MinWebViewMajor: 154), CompatibilityStatus.Expected, null, "Moteur fixe livré dans runtime/webview2, signature Microsoft vérifiée à la construction du pack. " + NoCampaign),
                new("webview-evergreen", "WebView2 Evergreen installé dans Windows", new(WebViewMode: "windows", MinWebViewMajor: 120), CompatibilityStatus.Expected, null, "Repli quand le moteur fixe est absent ; jamais exécuté avec un moteur antérieur au pack."),
                new("webview-old", "WebView2 antérieur à la version 120", new(MinWebViewMajor: 0), CompatibilityStatus.Unsupported, null, "Modules ES, transitions de vue et CSS récents requis."),
            ]),
            new("sqlite", "SQLite de Windows (winsqlite3.dll)", true,
            [
                new("winsqlite-present", "winsqlite3.dll fourni par Windows", new(SqlitePresent: true), CompatibilityStatus.Expected, null, "Base locale de Domenia 2 prévue sur winsqlite3.dll (vague 3) ; pas encore exercée."),
                new("winsqlite-absent", "winsqlite3.dll absent", new(SqlitePresent: false), CompatibilityStatus.Unsupported, null, "Sans winsqlite3.dll, la base locale serait indisponible."),
            ]),
            new("directory", "Annuaire (LDAP, System.DirectoryServices)", false,
            [
                new("ad-lab", "Active Directory du labo cnamts.local", new(), CompatibilityStatus.Expected, null, "Lecture réelle de l’annuaire prévue en vague 3, écritures dans OU=Domenia-Tests en vague 4."),
                new("ad-other", "Autres domaines Active Directory", new(), CompatibilityStatus.Expected, null, "Lecture LDAP standard ; jamais exécuté."),
            ]),
            new("cim", "Postes interrogés (CIM/WMI sur DCOM)", false,
            [
                new("cim-dcom", "Windows 10 et 11 par CIM sur DCOM", new(), CompatibilityStatus.Expected, null, "Lectures distantes prévues avec Domenia.Inventory ; jamais exécuté."),
                new("cim-wsman", "CIM sur WS-Management (WinRM)", new(), CompatibilityStatus.Expected, null, "Domenia ne modifie jamais la configuration WinRM."),
            ]),
        ]);

    /// <summary>French label of a status.</summary>
    public static string Label(CompatibilityStatus status) => status switch
    {
        CompatibilityStatus.Qualified => "qualifié",
        CompatibilityStatus.Tested => "testé en labo, non qualifié",
        CompatibilityStatus.Expected => "prévu, jamais testé",
        CompatibilityStatus.Unsupported => "non pris en charge",
        _ => "inconnu",
    };

    /// <summary>Tone of a status (an expected environment is information, never a success).</summary>
    public static Tone ToneOf(CompatibilityStatus status) => status switch
    {
        CompatibilityStatus.Qualified => Tone.Ok,
        CompatibilityStatus.Tested => Tone.Ok,
        CompatibilityStatus.Expected => Tone.Info,
        CompatibilityStatus.Unsupported => Tone.Alert,
        _ => Tone.Warn,
    };

    private static int? Major(string? version) =>
        version is not null && int.TryParse(version.Split('.')[0], System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var major) ? major : null;

    /// <summary>Match, NoMatch or Unknown (a needed fact was not read).</summary>
    public static bool? Matches(CompatibilityMatch match, EnvironmentFacts facts)
    {
        ArgumentNullException.ThrowIfNull(match);
        ArgumentNullException.ThrowIfNull(facts);
        if (match.IsEmpty)
        {
            return false;
        }
        var unknown = false;
        bool? Test(bool hasCondition, bool? outcome)
        {
            if (!hasCondition)
            {
                return true;
            }
            if (outcome is null)
            {
                unknown = true;
                return true;
            }
            return outcome;
        }
        var results = new[]
        {
            Test(match.Product is not null, facts.Product is null ? null : string.Equals(facts.Product, match.Product, StringComparison.Ordinal)),
            Test(match.MinBuild is not null, facts.Build is null ? null : facts.Build >= match.MinBuild),
            Test(match.MaxBuild is not null, facts.Build is null ? null : facts.Build <= match.MaxBuild),
            Test(match.Is64Bit is not null, facts.Is64BitProcess is null ? null : facts.Is64BitProcess == match.Is64Bit),
            Test(match.MinRuntimeMajor is not null, Major(facts.Runtime) is int r1 ? r1 >= match.MinRuntimeMajor : null),
            Test(match.MaxRuntimeMajor is not null, Major(facts.Runtime) is int r2 ? r2 <= match.MaxRuntimeMajor : null),
            Test(match.WebViewMode is not null, facts.WebViewMode is null ? null : string.Equals(facts.WebViewMode, match.WebViewMode, StringComparison.Ordinal)),
            Test(match.MinWebViewMajor is not null, Major(facts.WebViewVersion) is int w ? w >= match.MinWebViewMajor : null),
            Test(match.SqlitePresent is not null, facts.SqlitePresent is null ? null : facts.SqlitePresent == match.SqlitePresent),
        };
        if (results.Any(r => r == false))
        {
            return false;
        }
        return unknown ? null : true;
    }

    /// <summary>Readable observed value of a dimension (« Windows 11 24H2 (build 26100) »), or « non relevé ».</summary>
    public static string Observed(string dimension, EnvironmentFacts facts)
    {
        ArgumentNullException.ThrowIfNull(facts);
        return dimension switch
        {
            "windows" when facts.Product is not null && facts.Build is int build =>
                (facts.Product == "Server" ? "Windows Server" : build >= 22000 ? "Windows 11" : "Windows 10")
                + (string.IsNullOrWhiteSpace(facts.DisplayVersion) ? "" : " " + facts.DisplayVersion.Trim()) + " (build " + build.ToString(System.Globalization.CultureInfo.InvariantCulture) + ")",
            "process" when facts.Is64BitProcess is bool x64 => x64 ? "processus 64 bits" : "processus 32 bits",
            "runtime" when facts.Runtime is not null => ".NET " + facts.Runtime,
            "webview" when facts.WebViewMode is not null => (facts.WebViewMode == "embarque" ? "moteur fixe du pack" : facts.WebViewMode == "windows" ? "moteur installé dans Windows" : "aperçu dans un navigateur")
                + (facts.WebViewVersion is null ? "" : " " + facts.WebViewVersion),
            "sqlite" when facts.SqlitePresent is bool present => present ? "winsqlite3.dll présent" + (string.IsNullOrWhiteSpace(facts.SqliteVersion) ? "" : " (" + facts.SqliteVersion.Trim() + ")") : "winsqlite3.dll absent",
            _ => "non relevé",
        };
    }

    /// <summary>
    /// Verdict: one row per observed dimension (first matching entry), Inconnu when a fact is missing or the environment is
    /// not in the matrix. Overall: the least reassuring row. Documentation-only dimensions are listed apart.
    /// </summary>
    public static CompatibilityVerdict Verdict(CompatibilityMatrix matrix, EnvironmentFacts facts)
    {
        ArgumentNullException.ThrowIfNull(matrix);
        ArgumentNullException.ThrowIfNull(facts);
        var rows = new List<CompatibilityRow>();
        foreach (var dimension in matrix.Dimensions.Where(d => d.Observed))
        {
            var observed = Observed(dimension.Id, facts);
            var status = CompatibilityStatus.Unknown;
            CompatibilityEntry? found = null;
            var unknown = false;
            foreach (var entry in dimension.Entries)
            {
                var result = Matches(entry.Match, facts);
                if (result is null)
                {
                    unknown = true;
                    continue;
                }
                if (result == true)
                {
                    found = entry;
                    status = entry.Status;
                    break;
                }
            }
            var message = found is not null
                ? dimension.Label + FrenchText.Colon + observed + ", " + Label(status) + "."
                : unknown || observed == "non relevé"
                    ? dimension.Label + FrenchText.Colon + observed + " ; compatibilité inconnue."
                    : dimension.Label + FrenchText.Colon + observed + ", absent de la matrice ; compatibilité inconnue.";
            rows.Add(new CompatibilityRow(dimension.Id, dimension.Label, observed, status, Label(status), ToneOf(status), found?.Label ?? "", found?.Note ?? "", message));
        }
        CompatibilityStatus[] order = [CompatibilityStatus.Unsupported, CompatibilityStatus.Unknown, CompatibilityStatus.Expected, CompatibilityStatus.Tested, CompatibilityStatus.Qualified];
        var overall = rows.Count == 0 ? CompatibilityStatus.Unknown : order.First(candidate => rows.Any(r => r.Status == candidate));
        var text = "Compatibilité de ce poste" + FrenchText.Colon + "environnement " + Label(overall) + ".";
        var decisive = rows.FirstOrDefault(r => r.Status == overall);
        if (overall != CompatibilityStatus.Qualified && decisive is not null)
        {
            text += " " + decisive.Message;
        }
        return new CompatibilityVerdict(overall, Label(overall), ToneOf(overall), text, matrix.ReviewedOn, [.. rows],
            [.. matrix.Dimensions.Where(d => !d.Observed).SelectMany(d => d.Entries)]);
    }
}
