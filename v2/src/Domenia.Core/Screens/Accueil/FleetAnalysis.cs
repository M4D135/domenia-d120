using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Accueil;

/// <summary>One cause of a variation between two readings (perimeter, coverage, rules, observed state) and its status.</summary>
public sealed record FleetFactor(string Factor, string Status, string Text);

/// <summary>One counter of the comparison, before, after and the signed difference.</summary>
public sealed record FleetComparisonRow(string Measure, string Before, string After, string Delta);

/// <summary>Result of accueil.analysis.compare (Compare-DomeniaHealthSnapshots, point 78).</summary>
public sealed record FleetComparison(
    bool Comparable,
    string Category,
    string Summary,
    ImmutableArray<FleetFactor> Factors,
    ImmutableArray<string> Limits,
    ImmutableArray<FleetComparisonRow> Rows,
    bool Swapped,
    string BeforeLabel,
    string AfterLabel);

/// <summary>One row of a cross table: its counts and the keys of the exact sets of its cells and total.</summary>
public sealed record FleetMatrixRow(string Label, ImmutableArray<int> Counts, ImmutableArray<string?> Keys, int Total, string TotalKey);

/// <summary>Result of accueil.analysis.pivots (ConvertTo-DomeniaPivotMatrix, point 79): every workstation sits in exactly one cell.</summary>
public sealed record FleetMatrix(
    string Table,
    string Title,
    string RowTitle,
    string ColumnTitle,
    ImmutableArray<string> Columns,
    ImmutableArray<FleetMatrixRow> Rows,
    ImmutableArray<int> ColumnTotals,
    ImmutableArray<string> ColumnKeys,
    int GrandTotal,
    string GrandKey,
    int Folded,
    int Cells,
    int Total,
    bool Filtered,
    string Revision);

/// <summary>The four cross tables of the fleet analysis.</summary>
public sealed record FleetPivotTable(string Id, string Title, string RowTitle, string ColumnTitle);

/// <summary>
/// « Analyser la vue » of Domenia 1 (Domenia-Boards.Model.ps1): comparison of two readings that separates perimeter, coverage,
/// rules and observed state, and cross tables whose every cell opens its exact workstations. Pure.
/// </summary>
public static class FleetAnalysis
{
    public const int MaxColumns = 24;

    public static ImmutableArray<FleetPivotTable> Tables { get; } =
    [
        new("ouWindows", "OU × version de Windows", "OU", "Version de Windows"),
        new("modelRam", "Modèle × mémoire", "Modèle", "RAM"),
        new("siteCoverage", "OU ou site × couverture ping et inventaire WMI", "OU / site", "Couverture"),
        new("modelBios", "Modèle × version du BIOS", "Modèle", "Version du BIOS"),
    ];

    private static readonly string[] CoverageOrder = ["Ping et inventaire WMI", "Ping sans inventaire WMI", "Inventaire WMI sans ping", "Ni ping ni inventaire WMI"];
    private static readonly string[] RamOrder = ["≤" + FrenchText.Nbsp + "4 Go", "5 à 8 Go", "9 à 16 Go", "17 à 32 Go", ">" + FrenchText.Nbsp + "32 Go", "RAM non lue"];

    // ---------------------------------------------------------------- comparison

    /// <summary>
    /// Compares two readings; they are put back in chronological order first. Perimeter (which GUIDs), coverage (which
    /// workstations could be assessed, with which data) and rules (thresholds, rules, active suspensions) are compared by their
    /// fingerprints; only when all three are unchanged is a variation a real change of the observed state. A cause is never
    /// inferred from a counter alone.
    /// </summary>
    public static FleetComparison Compare(FleetSnapshot before, FleetSnapshot after)
    {
        ArgumentNullException.ThrowIfNull(before);
        ArgumentNullException.ThrowIfNull(after);
        var limits = new List<string>();
        var swapped = false;
        if (before.ComputedAt > after.ComputedAt)
        {
            (before, after) = (after, before);
            swapped = true;
            limits.Add("Relevés remis dans l’ordre chronologique.");
        }
        var a = before.Figures;
        var b = after.Figures;
        void Missing(string oldHash, string newHash, string what)
        {
            if (oldHash.Length == 0)
            {
                limits.Add("Le premier relevé ne conserve pas l’empreinte " + what + " : comparaison limitée aux compteurs.");
            }
            if (newHash.Length == 0)
            {
                limits.Add("Le second relevé ne conserve pas l’empreinte " + what + " : comparaison limitée aux compteurs.");
            }
        }
        Missing(a.PopulationHash, b.PopulationHash, "de la population");
        Missing(a.CoverageHash, b.CoverageHash, "de la couverture");
        Missing(a.PolicyHash, b.PolicyHash, "des règles");
        static string Hash(string x, string y) => x.Length == 0 || y.Length == 0 ? "unknown" : string.Equals(x, y, StringComparison.Ordinal) ? "same" : "changed";

        var population = Hash(a.PopulationHash, b.PopulationHash);
        var perimeterStatus = population == "same" ? "Inchangé" : population == "changed" || a.Machines != b.Machines ? "Modifié" : "Inconnu";
        var perimeterText = "Comptes activés" + FrenchText.Colon + Arrow(a.Machines, b.Machines);
        perimeterText += population switch
        {
            "same" => " ; mêmes GUID",
            "changed" when a.Machines == b.Machines => " ; même nombre, composition différente (entrées et sorties)",
            "unknown" => " ; composition non vérifiable",
            _ => "",
        };

        var coverageHash = Hash(a.CoverageHash, b.CoverageHash);
        var assessedHash = Hash(a.AssessedHash, b.AssessedHash);
        var coverageStatus = coverageHash == "same" && assessedHash == "same" ? "Inchangé" : coverageHash == "changed" || assessedHash == "changed" || a.Assessed != b.Assessed ? "Modifié" : "Inconnu";
        double? Share(int assessed, int machines) => machines <= 0 ? null : Math.Round(100.0 * assessed / machines, 1);
        var pa = Share(a.Assessed, a.Machines);
        var pb = Share(b.Assessed, b.Machines);
        var coverageText = "Postes évalués" + FrenchText.Colon + Arrow(a.Assessed, b.Assessed) + " · part évaluée" + FrenchText.Colon + Arrow(pa, pb, FrenchText.Nbsp + "%");
        var direction = "";
        if (coverageStatus == "Modifié")
        {
            if (pa is double x && pb is double y && y > x)
            {
                direction = "up";
                coverageText += " ; des postes jusque-là non mesurés entrent dans le score";
            }
            else if (pa is double x2 && pb is double y2 && y2 < x2)
            {
                direction = "down";
                coverageText += " ; des postes sortent du score faute de données";
            }
            else
            {
                coverageText += " ; données disponibles différentes";
            }
        }

        var policyHash = Hash(a.PolicyHash, b.PolicyHash);
        if (a.FormatVersion != b.FormatVersion)
        {
            policyHash = "unknown";
            limits.Add("Empreinte des règles relevée dans un format différent entre les deux relevés : comparaison des règles limitée aux compteurs.");
        }
        var policyStatus = policyHash switch { "same" => "Inchangé", "changed" => "Modifié", _ => "Inconnu" };
        var policyText = policyHash switch
        {
            "same" => "Règles, seuils et suspensions actives identiques",
            "changed" => "Règles, seuils ou suspensions actives modifiés",
            _ => "Règles non décrites par ce relevé",
        };

        var stateStatus = a.Problems == b.Problems && a.Healthy == b.Healthy ? "Inchangé" : "Modifié";
        var stateText = "Avec un problème" + FrenchText.Colon + Arrow(a.Problems, b.Problems) + " · sans problème détecté" + FrenchText.Colon + Arrow(a.Healthy, b.Healthy)
            + " · score" + FrenchText.Colon + (a.Score is null || b.Score is null ? "non calculé sur au moins un relevé" : Arrow(a.Score, b.Score));
        var factors = ImmutableArray.Create(
            new FleetFactor("Périmètre", perimeterStatus, perimeterText),
            new FleetFactor("Couverture", coverageStatus, coverageText),
            new FleetFactor("Règles", policyStatus, policyText),
            new FleetFactor("État observé", stateStatus, stateText));
        var causes = factors.Take(3).Where(f => f.Status == "Modifié").Select(f => f.Factor).ToList();
        var unknown = factors.Take(3).Count(f => f.Status == "Inconnu");
        string category;
        string summary;
        if (unknown > 0)
        {
            category = "Limitée";
            summary = "Comparaison limitée aux compteurs : un des relevés ne décrit pas sa population, sa couverture ou ses règles. Ne pas lire la variation du score comme un gain ou une dégradation du parc.";
        }
        else if (causes.Count == 0)
        {
            (category, summary) = stateStatus == "Inchangé"
                ? ("Stable", "Aucun changement : même population, même couverture, mêmes règles et même état observé.")
                : ("Réel", "Changement réel de l’état observé : même population, mêmes données et mêmes règles. Ce constat ne dit pas pourquoi l’état a changé.");
        }
        else if (causes.Count > 1)
        {
            category = "Mixte";
            summary = "Effets mêlés (" + string.Join(", ", causes.Select(c => c.ToLowerInvariant())) + " modifiés) : ne pas lire la variation du score comme un gain ou une dégradation du parc.";
        }
        else
        {
            (category, summary) = causes[0] switch
            {
                "Périmètre" => ("Périmètre", "Évolution du périmètre : des postes sont entrés ou sortis ; la variation ne décrit pas un changement d’état des mêmes postes."),
                "Couverture" => ("Couverture", direction switch
                {
                    "up" => "Amélioration de la couverture : davantage de postes ou de données évalués ; une baisse du score peut révéler des problèmes jusque-là non mesurés.",
                    "down" => "Couverture réduite : moins de postes ou de données évalués ; une hausse du score peut venir de postes qui ne sont plus mesurés.",
                    _ => "Couverture modifiée : les données disponibles ne sont plus les mêmes ; la variation ne décrit pas seulement l’état du parc.",
                }),
                _ => ("Règles", "Règles modifiées : la variation peut venir des seuils, des contrôles activés ou des suspensions, pas du parc."),
            };
        }
        var rows = new List<FleetComparisonRow>
        {
            Row("Comptes activés", a.Machines, b.Machines),
            Row("Postes évalués", a.Assessed, b.Assessed),
            Row("Postes incomplets", a.Unassessed, b.Unassessed),
            Row("Sans problème détecté", a.Healthy, b.Healthy),
            Row("Avec un problème", a.Problems, b.Problems),
            Row("Ping renseigné", a.PingRead, b.PingRead),
            Row("Inventaire WMI renseigné", a.WmiRead, b.WmiRead),
            Row("Score", a.Score, b.Score),
            Row("Part des comptes évalués (%)", pa, pb),
        };
        return new FleetComparison(category is "Stable" or "Réel", category, summary, factors, [.. limits], [.. rows], swapped, before.Label, after.Label);
    }

    private static FleetComparisonRow Row(string measure, double? before, double? after) => new(measure, Text(before), Text(after), Signed(before, after));

    private static string Text(double? value) => value is double v ? (v == Math.Floor(v) ? FrenchText.Integer((long)v) : FrenchText.Decimal(v, 1)) : "Non renseigné";

    private static string Signed(double? before, double? after)
    {
        if (before is not double a || after is not double b)
        {
            return "Non comparable";
        }
        var delta = Math.Round(b - a, 1);
        var text = delta == Math.Floor(delta) ? FrenchText.Integer((long)Math.Abs(delta)) : FrenchText.Decimal(Math.Abs(delta), 1);
        return delta > 0 ? "+" + text : delta < 0 ? FrenchText.Minus + text : "0";
    }

    private static string Arrow(double? before, double? after, string unit = "")
    {
        if (before is null || after is null)
        {
            return "non renseigné";
        }
        return Text(before) + unit + " → " + Text(after) + unit + " (" + Signed(before, after) + unit + ")";
    }

    // ---------------------------------------------------------------- cross tables

    /// <summary>
    /// One cross table as a matrix with row, column and grand totals (ConvertTo-DomeniaPivotMatrix). A filter keeps whole cells
    /// whose row or column label matches; columns beyond 24 are folded into one visible remainder column, never dropped.
    /// </summary>
    public static (FleetMatrix Matrix, ImmutableDictionary<string, ImmutableArray<Guid>> Targets) Pivot(string table, IReadOnlyDictionary<Guid, FleetPivotFacts> facts, string? filter, string revision)
    {
        ArgumentNullException.ThrowIfNull(facts);
        var definition = Tables.FirstOrDefault(t => t.Id == table) ?? throw new ArgumentException("Unknown table.", nameof(table));
        var cells = new List<(string Row, string Column, Guid Guid)>();
        foreach (var (guid, f) in facts)
        {
            var coverage = f.Ping && f.Inventory ? CoverageOrder[0] : f.Ping ? CoverageOrder[1] : f.Inventory ? CoverageOrder[2] : CoverageOrder[3];
            var (row, column) = table switch
            {
                "ouWindows" => (f.Site, f.Version),
                "modelRam" => (f.Model, f.Ram),
                "siteCoverage" => (f.Site, coverage),
                _ => (f.Model, f.Bios),
            };
            cells.Add((row, column, guid));
        }
        var text = (filter ?? "").Trim();
        var wanted = text.Length == 0 ? cells : [.. cells.Where(c => FrenchText.Fold(c.Row).Contains(FrenchText.Fold(text), StringComparison.Ordinal) || FrenchText.Fold(c.Column).Contains(FrenchText.Fold(text), StringComparison.Ordinal))];
        var columnCounts = wanted.GroupBy(c => c.Column, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Count(), StringComparer.Ordinal);
        var natural = table switch { "modelRam" => RamOrder, "siteCoverage" => CoverageOrder, _ => [] };
        var ordered = natural.Where(columnCounts.ContainsKey).ToList();
        ordered.AddRange(columnCounts.OrderByDescending(p => p.Value).ThenBy(p => p.Key, StringComparer.Ordinal).Select(p => p.Key).Where(k => !ordered.Contains(k)));
        var folded = 0;
        var columns = ordered;
        if (ordered.Count > MaxColumns)
        {
            folded = ordered.Count - (MaxColumns - 1);
            columns = [.. ordered.Take(MaxColumns - 1), "Autres colonnes (" + FrenchText.Integer(folded) + ")"];
        }
        var index = columns.Select((c, i) => (c, i)).ToDictionary(x => x.c, x => x.i, StringComparer.Ordinal);
        var other = columns.Count - 1;
        var targets = new Dictionary<string, List<Guid>>(StringComparer.Ordinal);
        string KeyOf(string kind, string row, int col) => "pivot:" + table + ":" + kind + ":" + row + "|" + (col < 0 ? "" : columns[col]);
        void Put(string key, Guid guid)
        {
            if (!targets.TryGetValue(key, out var list))
            {
                targets[key] = list = [];
            }
            list.Add(guid);
        }
        var rows = new List<FleetMatrixRow>();
        var columnTotals = new int[columns.Count];
        foreach (var group in wanted.GroupBy(c => c.Row, StringComparer.Ordinal).OrderBy(g => g.Key, StringComparer.Ordinal))
        {
            var counts = new int[columns.Count];
            foreach (var cell in group)
            {
                var col = index.TryGetValue(cell.Column, out var i) ? i : other;
                counts[col]++;
                columnTotals[col]++;
                Put(KeyOf("cell", group.Key, col), cell.Guid);
                Put(KeyOf("row", group.Key, -1), cell.Guid);
                Put("pivot:" + table + ":column:" + columns[col], cell.Guid);
                Put("pivot:" + table + ":all", cell.Guid);
            }
            var keys = counts.Select((n, col) => n > 0 ? KeyOf("cell", group.Key, col) : null).ToImmutableArray();
            rows.Add(new FleetMatrixRow(group.Key, [.. counts], keys, counts.Sum(), KeyOf("row", group.Key, -1)));
        }
        var matrix = new FleetMatrix(table, definition.Title, definition.RowTitle, definition.ColumnTitle, [.. columns], [.. rows], [.. columnTotals],
            [.. columns.Select(c => "pivot:" + table + ":column:" + c)], wanted.Count, "pivot:" + table + ":all", folded, wanted.GroupBy(c => (c.Row, c.Column)).Count(), facts.Count, text.Length > 0, revision);
        return (matrix, targets.ToImmutableDictionary(p => p.Key, p => p.Value.ToImmutableArray(), StringComparer.Ordinal));
    }

    /// <summary>Label of a snapshot day for the lists (« 20/10/2026 · relevé quotidien »).</summary>
    public static string DailyLabel(DateOnly day) => day.ToString("dd'/'MM'/'yyyy", CultureInfo.InvariantCulture) + " · relevé quotidien";
}
