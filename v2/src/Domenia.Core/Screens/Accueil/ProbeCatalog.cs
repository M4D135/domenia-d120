using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Domenia.Core.Accueil;

/// <summary>One typed field of a probe (Domenia-ProbeCatalog.json).</summary>
public sealed record ProbeField(string Name, string CimType, string Kind, bool IsArray, string Unit, string Description);

/// <summary>
/// One read-only WMI probe: a CIM projection (namespace, class, properties, filter, mode) and its transform, never code. The
/// catalog is the list of allowed classes (Domenia 1, Get-DomeniaProbeCatalog).
/// </summary>
public sealed record ProbeDefinition(
    string Id,
    string Category,
    string Name,
    string Namespace,
    string Class,
    ImmutableArray<string> Properties,
    string Filter,
    string Mode,
    string Transform,
    string Visual,
    bool Slow,
    bool SkipOnDc,
    string Origin,
    string Description,
    string Rights,
    string Compatibility,
    string UnknownMeaning,
    string Limitations,
    ImmutableArray<string> SourceUrls,
    ImmutableArray<ProbeField> Fields,
    string Qualification)
{
    /// <summary>Values compared as numbers (Get-DomeniaProbeVisuals).</summary>
    public bool Numeric => Mode == "Count" || ProbeCatalog.NumericTransform(Transform);
}

/// <summary>Contract of a probe (Domenia.ProbeContract/1), its check and its isolation plan, as text sections.</summary>
public sealed record ProbeContract(
    string Id,
    string Name,
    string Origin,
    string Summary,
    string PrivilegeLevel,
    string CostLevel,
    bool Valid,
    ImmutableArray<ProbeContractLine> Lines,
    ImmutableArray<string> Warnings,
    ImmutableArray<string> Errors);

public sealed record ProbeContractLine(string Section, string Value);

/// <summary>One probe reading of one workstation: raw values as read (text), or the reason why none is usable.</summary>
public sealed record ProbeReading(MeasureState State, DateTimeOffset? At, ImmutableArray<string> Values, string? Error);

/// <summary>Probe readings kept for the session, by probe then by computer GUID.</summary>
public sealed record ProbeReadings(ImmutableDictionary<string, ImmutableDictionary<Guid, ProbeReading>> ByProbe)
{
    public static ProbeReadings Empty { get; } = new(ImmutableDictionary<string, ImmutableDictionary<Guid, ProbeReading>>.Empty.WithComparers(StringComparer.Ordinal));

    /// <summary>The newest readings win, probe by probe and workstation by workstation.</summary>
    public ProbeReadings Merge(ProbeReadings newer)
    {
        ArgumentNullException.ThrowIfNull(newer);
        var result = ByProbe;
        foreach (var (probe, machines) in newer.ByProbe)
        {
            var current = result.GetValueOrDefault(probe) ?? ImmutableDictionary<Guid, ProbeReading>.Empty;
            foreach (var (guid, reading) in machines)
            {
                if (!current.TryGetValue(guid, out var old) || (reading.At ?? DateTimeOffset.MinValue) >= (old.At ?? DateTimeOffset.MinValue))
                {
                    current = current.SetItem(guid, reading);
                }
            }
            result = result.SetItem(probe, current);
        }
        return new ProbeReadings(result);
    }
}

/// <summary>Aggregate of one probe over the workstations of a view (Measure-DomeniaWidgetData).</summary>
public sealed record ProbeMeasure(ImmutableArray<(string Label, int Value, ImmutableArray<Guid> Targets)> Items, int Machines, string Summary, bool Numeric, DateTimeOffset? Oldest, DateTimeOffset? Newest);

/// <summary>
/// The probe catalog of Domenia 1: 78 built-in probes and 33 detailed, documented ones, their representations, their contract
/// and the aggregation of their readings over the fleet. Pure: data embedded in the assembly, clock as input.
/// </summary>
public static partial class ProbeCatalog
{
    private static readonly Lazy<ImmutableArray<ProbeDefinition>> Loaded = new(Load, LazyThreadSafetyMode.ExecutionAndPublication);
    private static readonly Lazy<FrozenDictionary<string, ProbeDefinition>> Index = new(() => All.ToFrozenDictionary(p => p.Id, StringComparer.Ordinal), LazyThreadSafetyMode.ExecutionAndPublication);

    public const string DocumentationReviewed = "2026-10-13";

    public static ImmutableArray<ProbeDefinition> All => Loaded.Value;

    public static ProbeDefinition? Find(string? id) => id is not null && Index.Value.TryGetValue(id, out var probe) ? probe : null;

    public static bool NumericTransform(string transform) =>
        transform is "GB" or "GBfromKB" or "MB" or "Mbps" or "Number" or "DaysSince" or "PercentFree" or "Year";

    /// <summary>Representations offered for a probe on the fleet board: numbers in buckets, texts shared out.</summary>
    public static ImmutableArray<string> Visuals(ProbeDefinition probe)
    {
        ArgumentNullException.ThrowIfNull(probe);
        var numeric = probe.Mode == "Count" || probe.Transform is "GB" or "GBfromKB" or "MB" or "Mbps" or "Number" or "DaysSince" or "PercentFree";
        return numeric ? ["Column", "Kpi", "Text"] : ["Pie", "Bar", "Text", "Kpi"];
    }

    /// <summary>Unit shown after a number (Get-DomeniaProbeUnit).</summary>
    public static string Unit(ProbeDefinition probe)
    {
        ArgumentNullException.ThrowIfNull(probe);
        return probe.Transform switch
        {
            "GB" or "GBfromKB" => FrenchText.Nbsp + "Go",
            "MB" => FrenchText.Nbsp + "Mo",
            "Mbps" => FrenchText.Nbsp + "Mbit/s",
            "DaysSince" => FrenchText.Nbsp + "j",
            "PercentFree" => FrenchText.Nbsp + "%",
            _ => "",
        };
    }

    // ---------------------------------------------------------------- values and aggregation

    /// <summary>
    /// Values of one probe for one workstation after the transform (Get-DomeniaProbeValues): a reading in error, refused or not
    /// known gives no value and the workstation is not counted. A value outside a map keeps its raw text.
    /// </summary>
    public static ImmutableArray<string> Values(ProbeDefinition probe, ProbeReading reading, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(probe);
        ArgumentNullException.ThrowIfNull(reading);
        if (reading.State != MeasureState.Known || reading.Error is not null)
        {
            return [];
        }
        var raw = probe.Mode switch
        {
            "Count" => reading.Values.Length > 0 ? [reading.Values[0]] : ImmutableArray<string>.Empty,
            "All" => reading.Values,
            _ => reading.Values.Length > 0 ? [reading.Values[0]] : ImmutableArray<string>.Empty,
        };
        var result = ImmutableArray.CreateBuilder<string>();
        foreach (var value in raw)
        {
            if (string.IsNullOrWhiteSpace(value) && !probe.Transform.StartsWith("Map:", StringComparison.Ordinal))
            {
                continue;
            }
            var transformed = Transform(probe, value, now);
            if (transformed is not null)
            {
                result.Add(transformed);
            }
        }
        return result.ToImmutable();
    }

    private static string? Transform(ProbeDefinition probe, string value, DateTimeOffset now)
    {
        var transform = probe.Transform;
        double? Number(string text) => double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var n) && double.IsFinite(n) ? n : null;
        string Invariant(double n) => n.ToString("0.###", CultureInfo.InvariantCulture);
        switch (transform)
        {
            case "GB":
                return Number(value) is double gb ? Invariant(Math.Round(gb / (1L << 30), 1)) : null;
            case "GBfromKB":
                return Number(value) is double kb ? Invariant(Math.Round(kb / (1 << 20), 1)) : null;
            case "MB":
                return Number(value) is double mb ? Invariant(Math.Round(mb / (1 << 20))) : null;
            case "Mbps":
                return Number(value) is double bits ? Invariant(Math.Round(bits / 1_000_000)) : null;
            case "Number":
                return Number(value) is double n ? Invariant(n) : null;
            case "DaysSince":
                return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var since) ? Invariant(Math.Round((now - since).TotalDays)) : null;
            case "Year":
                return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var year) ? year.Year.ToString(CultureInfo.InvariantCulture) : null;
            case "PercentFree":
                {
                    var cells = value.Split('|');
                    if (cells.Length >= 2 && Number(cells[0]) is double free && Number(cells[1]) is double size && size > 0)
                    {
                        return Invariant(Math.Round(100.0 * free / size));
                    }
                    return null;
                }
            case "Release":
                {
                    var cells = value.Split('|');
                    var kind = cells.Length >= 2 && cells[1] is not ("" or "1") ? "Server" : "";
                    var info = WindowsLifecycle.Evaluate(cells[0], kind, DateOnly.FromDateTime(now.UtcDateTime));
                    return info.Name.Length > 0 ? info.Name : "Build " + cells[0];
                }
            default:
                if (transform.StartsWith("Map:", StringComparison.Ordinal))
                {
                    foreach (var pair in transform[4..].Split(';'))
                    {
                        var kv = pair.Split('=');
                        if (kv.Length == 2 && kv[0] == value)
                        {
                            return kv[1];
                        }
                    }
                    return value;
                }
                return value.Trim();
        }
    }

    /// <summary>
    /// Aggregates one probe over workstations (Measure-DomeniaWidgetData): few distinct numbers one bar each, other numbers in
    /// buckets with whole bounds and their unit, texts counted (8 + « Autres »). Readings older than 30 days are left out.
    /// </summary>
    public static ProbeMeasure Measure(ProbeDefinition probe, IEnumerable<(Guid Guid, ProbeReading Reading)> readings, string visual, DateTimeOffset now, int maxAgeDays = 30)
    {
        ArgumentNullException.ThrowIfNull(probe);
        ArgumentNullException.ThrowIfNull(readings);
        var samples = new List<(Guid Guid, ImmutableArray<string> Values)>();
        DateTimeOffset? oldest = null;
        DateTimeOffset? newest = null;
        foreach (var (guid, reading) in readings)
        {
            if (reading.At is not DateTimeOffset at || at > now + TimeSpan.FromMinutes(5) || now - at > TimeSpan.FromDays(maxAgeDays))
            {
                continue;
            }
            var values = Values(probe, reading, now);
            if (values.Length == 0)
            {
                continue;
            }
            samples.Add((guid, probe.Mode == "All" ? [.. values.Distinct(StringComparer.Ordinal)] : [values[0]]));
            oldest = oldest is null || at < oldest ? at : oldest;
            newest = newest is null || at > newest ? at : newest;
        }
        var unit = Unit(probe);
        var numeric = samples.Count > 0 && samples.All(s => s.Values.All(v => double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out _)));
        var items = new List<(string Label, int Value, ImmutableArray<Guid> Targets)>();
        string summary;
        if (numeric && visual != "Pie")
        {
            var flat = samples.SelectMany(s => s.Values.Select(v => (s.Guid, Value: double.Parse(v, CultureInfo.InvariantCulture)))).ToList();
            var distinct = flat.Select(f => f.Value).Distinct().Order().ToList();
            var mean = flat.Average(f => f.Value);
            if (distinct.Count <= 8 && probe.Transform is "Number" or "DaysSince")
            {
                foreach (var d in distinct)
                {
                    var guids = flat.Where(f => f.Value == d).Select(f => f.Guid).Distinct().ToImmutableArray();
                    items.Add((Format(d) + unit, flat.Count(f => f.Value == d), guids));
                }
            }
            else
            {
                var max = distinct[^1];
                double[] edges = probe.Transform switch
                {
                    "GB" or "GBfromKB" => [4, 8, 16, 32, 64, 128, 256, 512],
                    "DaysSince" => [1, 7, 30, 90, 180, 365],
                    "PercentFree" => [10, 25, 50, 75],
                    "Mbps" => [100, 1000],
                    _ => max <= 10 ? new double[] { 0, 1, 2, 3, 5, 10 } : NiceEdges(max),
                };
                edges = [.. edges.Distinct()];
                if (edges.Length == 0)
                {
                    edges = [Math.Ceiling(max)];
                }
                for (var i = 0; i <= edges.Length; i++)
                {
                    var low = i == 0 ? double.NegativeInfinity : edges[i - 1];
                    var high = i == edges.Length ? double.PositiveInfinity : edges[i];
                    var label = i == 0 ? "≤" + FrenchText.Nbsp + Format(edges[0]) + unit
                        : i == edges.Length ? ">" + FrenchText.Nbsp + Format(edges[i - 1]) + unit
                        : edges[i] - edges[i - 1] <= 1 ? Format(edges[i]) + unit
                        : ">" + FrenchText.Nbsp + Format(edges[i - 1]) + " à " + Format(edges[i]) + unit;
                    var inRange = flat.Where(f => f.Value > low && f.Value <= high).ToList();
                    items.Add((label, inRange.Count, [.. inRange.Select(f => f.Guid).Distinct()]));
                }
            }
            summary = "Moyenne " + Format(Math.Round(mean, 1)) + " · min " + Format(distinct[0]) + " · max " + Format(distinct[^1]);
        }
        else
        {
            var groups = samples.SelectMany(s => s.Values.Select(v => (s.Guid, Value: v)))
                .GroupBy(x => x.Value, StringComparer.Ordinal)
                .Select(g => (Label: g.Key, Count: g.Count(), Guids: g.Select(x => x.Guid).Distinct().ToImmutableArray()))
                .OrderByDescending(g => g.Count).ThenBy(g => g.Label, StringComparer.Ordinal).ToList();
            items.AddRange(groups.Take(8).Select(g => (g.Label, g.Count, g.Guids)));
            var others = groups.Skip(8).ToList();
            if (others.Count > 0)
            {
                items.Add(("Autres", others.Sum(g => g.Count), [.. others.SelectMany(g => g.Guids).Distinct()]));
            }
            summary = groups.Count > 0 ? "Le plus fréquent" + FrenchText.Colon + groups[0].Label + " (" + FrenchText.Integer(groups[0].Count) + ")" : "Aucune valeur";
        }
        return new ProbeMeasure([.. items], samples.Count, summary, numeric, oldest, newest);
    }

    private static string Format(double n) => n == Math.Floor(n) ? FrenchText.Integer((long)n) : FrenchText.Decimal(n, 1);

    /// <summary>Rounded graduations (1, 2 or 5 × 10^n) below the maximum (Get-DomeniaChartTicks), whole steps.</summary>
    private static double[] NiceEdges(double max)
    {
        var raw = Math.Max(max, 1) / 5;
        var power = Math.Pow(10, Math.Floor(Math.Log10(raw)));
        var step = 10 * power;
        foreach (var factor in new[] { 1, 2, 5, 10 })
        {
            if (factor * power >= raw)
            {
                step = factor * power;
                break;
            }
        }
        step = Math.Max(1, step);
        var edges = new List<double>();
        for (var v = step; v < max; v += step)
        {
            edges.Add(Math.Round(v, 6));
        }
        return [.. edges];
    }

    // ---------------------------------------------------------------- contract (points 135 and 136)

    private static readonly string[] DeniedClasses = ["Win32_Product", "CIM_Product", "Win32_SoftwareFeature", "Win32_SoftwareElement", "Win32_ReliabilityRecords"];
    private static readonly string[] DeniedNamespaces = [@"root\subscription", @"root\directory\LDAP", @"root\RSOP", @"root\RSOP\Computer", @"root\RSOP\User", @"root\default", @"root\security"];
    private static readonly string[] SingleInstanceClasses = ["Win32_ComputerSystem", "Win32_OperatingSystem", "Win32_BIOS", "Win32_TimeZone", "MSFT_MpComputerStatus", "Win32_Tpm", "Win32_DeviceGuard", "Win32_PhysicalMemoryArray"];

    /// <summary>Contract, check and isolation of one catalog probe (ConvertTo-DomeniaProbeContract, Test-DomeniaProbeContract).</summary>
    public static ProbeContract Contract(ProbeDefinition probe)
    {
        ArgumentNullException.ThrowIfNull(probe);
        var local = probe.Namespace.StartsWith(@"root\cimv2\Security\", StringComparison.OrdinalIgnoreCase)
            || probe.Namespace.Equals(@"root\SecurityCenter2", StringComparison.OrdinalIgnoreCase)
            || probe.Class is "Win32_EncryptableVolume" or "Win32_Tpm";
        var privilegeLevel = local ? "AdministrateurLocal" : "LectureDistanteWmi";
        var privilegeText = (probe.Rights.Length > 0 ? probe.Rights + " " : "") + (local
            ? "Administrateur local du poste : ce fournisseur refuse les autres comptes, même délégués sur l’espace de noms."
            : "Administrateur du poste, ou compte délégué « Activer à distance » sur l’espace de noms et autorisé en DCOM ou WinRM.");
        string costLevel;
        string costReason;
        if (probe.Slow)
        {
            costLevel = "Lourd";
            costReason = "Requête signalée lente : journal, liste volumineuse ou fournisseur coûteux. Collecte explicite sur une liste courte.";
        }
        else if (SingleInstanceClasses.Contains(probe.Class, StringComparer.Ordinal))
        {
            costLevel = "Léger";
            costReason = "Classe à instance unique ou très courte.";
        }
        else if (probe.Filter.Length > 0)
        {
            costLevel = "Modéré";
            costReason = "Énumère les instances filtrées de la classe.";
        }
        else if (probe.Mode == "First")
        {
            costLevel = "Modéré";
            costReason = "Énumère la classe pour en retenir la première instance.";
        }
        else
        {
            costLevel = "Modéré";
            costReason = "Énumère toutes les instances de la classe.";
        }
        var tests = new List<(string Id, string Text)>
        {
            ("Projection", "Une ligne lue produit la valeur transformée attendue."),
            ("Inconnu", "Erreur, refus ou absence de ligne : aucune valeur, jamais zéro."),
            ("Refus", "Accès refusé : erreur conservée, poste non compté."),
        };
        if (probe.Mode != "Count")
        {
            tests.Add(("Troncature", "Lecture tronquée : aucune valeur partielle présentée comme complète."));
        }
        if (probe.SkipOnDc)
        {
            tests.Add(("Contrôleur", "Contrôleur de domaine : lecture ignorée et signalée, jamais comptée."));
        }
        if (probe.Filter.Contains("{SINCE_", StringComparison.Ordinal))
        {
            tests.Add(("Fenêtre", "Fenêtre temporelle remplacée par le collecteur avant l’appel."));
        }
        if (probe.Transform.StartsWith("Map:", StringComparison.Ordinal))
        {
            tests.Add(("Correspondance", "Valeur absente de la table conservée brute, jamais inventée."));
        }
        var errors = new List<string>();
        var warnings = new List<string>();
        if (!IdPattern().IsMatch(probe.Id))
        {
            errors.Add("Identifiant de sonde invalide.");
        }
        if (!NamespacePattern().IsMatch(probe.Namespace))
        {
            errors.Add("Espace de noms invalide.");
        }
        else if (DeniedNamespaces.Contains(probe.Namespace, StringComparer.OrdinalIgnoreCase))
        {
            errors.Add("Espace de noms refusé" + FrenchText.Colon + probe.Namespace + ".");
        }
        if (!ClassPattern().IsMatch(probe.Class))
        {
            errors.Add("Classe invalide.");
        }
        else if (DeniedClasses.Contains(probe.Class, StringComparer.OrdinalIgnoreCase))
        {
            errors.Add("Classe refusée" + FrenchText.Colon + probe.Class + ".");
        }
        if (probe.Class is "Win32_UserAccount" or "Win32_Group" or "Win32_GroupUser" && !probe.SkipOnDc && !LocalAccountFilter().IsMatch(probe.Filter))
        {
            errors.Add("Comptes et groupes : lecture limitée aux comptes locaux ou exclue des contrôleurs requise.");
        }
        if (probe.Mode is not ("First" or "All" or "Count"))
        {
            errors.Add("Mode de projection invalide.");
        }
        if (probe.Properties.Length is < 1 or > 64)
        {
            errors.Add("Nombre de propriétés hors limites (1 à 64).");
        }
        if (probe.Filter.Length > 512)
        {
            errors.Add("Filtre trop long.");
        }
        if (!FilterPattern().IsMatch(probe.Filter))
        {
            errors.Add("Filtre : caractère non admis.");
        }
        foreach (Match token in TokenPattern().Matches(probe.Filter))
        {
            if (token.Value is not ("{SINCE_24H}" or "{SINCE_7D}"))
            {
                errors.Add("Jeton de filtre inconnu" + FrenchText.Colon + token.Value + ".");
            }
        }
        foreach (var name in probe.Properties)
        {
            if (!probe.Fields.Any(f => f.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
            {
                errors.Add("Propriété sans type déclaré" + FrenchText.Colon + name + ".");
            }
        }
        foreach (var field in probe.Fields.Where(f => f.CimType.Length == 0))
        {
            warnings.Add("Type CIM de " + field.Name + " à qualifier : valeur gardée en texte.");
        }
        if (probe.SourceUrls.Length == 0)
        {
            if (probe.Origin == "Intégrée")
            {
                warnings.Add("Aucune référence documentaire propre : documentation de la classe à rattacher.");
            }
            else
            {
                errors.Add("Référence documentaire primaire requise.");
            }
        }
        foreach (var url in probe.SourceUrls)
        {
            if (!SourcePattern().IsMatch(url))
            {
                errors.Add("Référence documentaire non autorisée.");
            }
        }
        var typed = string.Join(" · ", probe.Fields.Select(f => f.Name + " (" + (f.CimType.Length > 0 ? f.CimType : "à qualifier") + (f.Unit.Length > 0 && f.Unit != "Valeur brute" ? ", " + f.Unit : "") + ")"));
        var lines = new List<ProbeContractLine>
        {
            new("Origine", probe.Origin),
            new("Entrées", probe.Namespace + " · " + probe.Class + " · " + string.Join(", ", probe.Properties) + (probe.Filter.Length > 0 ? " · filtre " + probe.Filter : "") + " · mode " + probe.Mode),
            new("Types", typed),
            new("Privilèges", privilegeText),
            new("Coût", costLevel + FrenchText.Colon + costReason),
            new("Comportement", "Lecture CIM déclarative : aucune écriture, aucun code, aucune méthode WMI ; cible : poste choisi ou liste affichée."),
            new("Limites", probe.Limitations + " Inconnu" + FrenchText.Colon + probe.UnknownMeaning),
            new("Sources", probe.SourceUrls.Length > 0 ? string.Join(" · ", probe.SourceUrls) : "Aucune référence propre à cette sonde."),
            new("Qualification", probe.Qualification),
            new("Tests attendus", string.Join(" · ", tests.Select(t => t.Id + FrenchText.Colon + t.Text))),
            new("Isolement", "Isolement : moteur de Domenia, hors interface. Aucun code fourni par la sonde : le collecteur construit une lecture SELECT à partir de noms validés. "
                + "Aucune écriture : aucune méthode WMI n’est appelée. Lecture hors du fil d’interface, délai de requête d’au moins 10 s, tâche plafonnée à 300 s ; détails bornés à 2 000 instances et 256 Kio"
                + (probe.SkipOnDc ? " ; contrôleurs de domaine exclus (type de système lu avant la requête)" : "") + ". Non garanti : le fournisseur WMI du poste exécute la requête avec les droits du compte utilisé ; aucun bac à sable PowerShell."),
        };
        lines.AddRange(warnings.Select(w => new ProbeContractLine("Avertissement", w)));
        lines.AddRange(errors.Select(e => new ProbeContractLine("Refus", e)));
        var summary = "Droits" + FrenchText.Colon + (local ? "administrateur local du poste" : "lecture WMI distante (administrateur ou délégation)")
            + ". Coût" + FrenchText.Colon + costLevel + " — " + costReason + " Lecture déclarative : aucune écriture, aucun code.";
        return new ProbeContract(probe.Id, probe.Name, probe.Origin, summary, privilegeLevel, costLevel, errors.Count == 0, [.. lines], [.. warnings], [.. errors]);
    }

    // ---------------------------------------------------------------- loading

    private static ImmutableArray<ProbeDefinition> Load()
    {
        using var document = JsonDocument.Parse(ProbeCatalogData.Extended);
        var extended = document.RootElement.GetProperty("Probes").EnumerateArray().Select(ReadExtended).ToList();
        var result = new List<ProbeDefinition>();
        foreach (var line in ProbeCatalogData.Builtin.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var p = line.Split('|');
            if (p.Length < 10)
            {
                continue;
            }
            var flags = p.Length >= 11 ? p[10].Split(',', StringSplitOptions.TrimEntries) : [];
            var properties = p[5].Split(',', StringSplitOptions.RemoveEmptyEntries).ToImmutableArray();
            // Historical probes reuse the documented class properties of the detailed catalog (Add-DomeniaProbeMetadata).
            var peers = extended.Where(e => e.Class.Equals(p[4], StringComparison.OrdinalIgnoreCase) && e.Namespace.Equals(p[3], StringComparison.OrdinalIgnoreCase)).ToList();
            var classPeer = peers.FirstOrDefault();
            var covering = peers.FirstOrDefault(e => properties.All(x => e.Properties.Contains(x, StringComparer.OrdinalIgnoreCase)));
            var fieldsByName = peers.SelectMany(e => e.Fields).GroupBy(f => f.Name, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
            var fields = properties.Select(name => fieldsByName.GetValueOrDefault(name) ?? new ProbeField(name, "", "Text", false, "Valeur brute", "Propriété du fournisseur ; type détaillé à qualifier.")).ToImmutableArray();
            var limits = covering?.Limitations ?? "Disponibilité selon fournisseur et droits. La lecture conserve une date ; elle ne prouve pas un état courant après expiration.";
            if (p[7] == "First")
            {
                limits += " Résumé fondé sur la première instance ; le choix de cette instance dépend du fournisseur.";
            }
            if (flags.Contains("NoDC"))
            {
                limits += " Lecture exclue sur les contrôleurs de domaine.";
            }
            result.Add(new ProbeDefinition(
                p[0], p[1], p[2], p[3], p[4], properties, p[6], p[7], p[8], p[9], flags.Contains("Slow"), flags.Contains("NoDC"), "Intégrée",
                p[2] + ". Source" + FrenchText.Colon + p[4] + ".",
                classPeer?.Rights ?? "Lecture distante du namespace WMI/CIM ; compte et accès au poste autorisés.",
                classPeer?.Compatibility ?? "Fournisseur Windows requis ; présence et version à qualifier sur la cible.",
                "Absence, refus, erreur, donnée périmée ou incomplète restent inconnus ; un résultat vide n’est zéro qu’après une énumération complète.",
                limits, classPeer?.SourceUrls ?? [], fields, "À qualifier sous Windows"));
        }
        result.AddRange(extended);
        return [.. result];
    }

    private static ProbeDefinition ReadExtended(JsonElement p)
    {
        string S(string name) => p.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()! : "";
        bool B(string name) => p.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;
        ImmutableArray<string> A(string name) => p.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Array
            ? [.. v.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!)]
            : [];
        var fields = p.TryGetProperty("Fields", out var f) && f.ValueKind == JsonValueKind.Array
            ? f.EnumerateArray().Select(x => new ProbeField(
                x.GetProperty("Name").GetString()!,
                x.TryGetProperty("CimType", out var c) ? c.GetString() ?? "" : "",
                x.TryGetProperty("Kind", out var k) ? k.GetString() ?? "Text" : "Text",
                x.TryGetProperty("IsArray", out var a) && a.ValueKind == JsonValueKind.True,
                x.TryGetProperty("Unit", out var u) ? u.GetString() ?? "" : "",
                x.TryGetProperty("Description", out var d) ? d.GetString() ?? "" : "")).ToImmutableArray()
            : [];
        return new ProbeDefinition(S("Id"), S("Category"), S("Name"), S("Namespace"), S("Class"), A("Properties"), S("Filter"), S("Mode"), S("Transform"), S("Visual"),
            B("Slow"), B("SkipOnDc"), "Catalogue détaillé", S("Description"), S("Rights"), S("Compatibility"), S("UnknownMeaning"), S("Limitations"), A("SourceUrls"),
            fields, S("ProviderQualification").Length > 0 ? S("ProviderQualification") : "À qualifier sous Windows");
    }

    [GeneratedRegex(@"^[a-z][a-z0-9_.-]{1,127}$")]
    private static partial Regex IdPattern();

    [GeneratedRegex(@"^[A-Za-z0-9_\\]+$")]
    private static partial Regex NamespacePattern();

    [GeneratedRegex(@"^[A-Za-z_][A-Za-z0-9_]*$")]
    private static partial Regex ClassPattern();

    [GeneratedRegex(@"LocalAccount\s*=\s*TRUE", RegexOptions.IgnoreCase)]
    private static partial Regex LocalAccountFilter();

    [GeneratedRegex(@"^[A-Za-z0-9_ ='<>().:{}%\-]*$")]
    private static partial Regex FilterPattern();

    [GeneratedRegex(@"\{[^}]*\}")]
    private static partial Regex TokenPattern();

    [GeneratedRegex(@"^https://(learn\.microsoft\.com/|github\.com/(microsoft|MicrosoftDocs)/)")]
    private static partial Regex SourcePattern();
}
