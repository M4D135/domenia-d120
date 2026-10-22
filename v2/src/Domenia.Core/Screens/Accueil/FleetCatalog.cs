using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Diagnostics.CodeAnalysis;

namespace Domenia.Core.Accueil;

/// <summary>Kind of data of a fleet widget (Domenia 1, New-DomeniaBoardEntry).</summary>
public enum FleetDataKind
{
    Value,
    Distribution,
    Series,
    Timeline,
    Health,
    List,
}

/// <summary>Where a widget of the layout comes from: the built-in catalog, the WMI probe catalog or a saved query.</summary>
public enum FleetWidgetSource
{
    Builtin,
    Probe,
    Query,
}

/// <summary>One built-in widget of the fleet board (Domenia 1 catalog « Fleet », Domenia-Boards.Model.ps1).</summary>
public sealed record FleetWidgetDefinition(
    string Key,
    string Group,
    string Title,
    FleetDataKind Kind,
    string Visual,
    string Size,
    string Description,
    bool Default);

/// <summary>One item of the layout of the fleet board: widget, representation, size, optional title, paused or not.</summary>
public sealed record FleetLayoutItem(
    string Id,
    FleetWidgetSource Source,
    string Key,
    string Visual,
    string Size,
    string? Title,
    bool Paused,
    string Group);

/// <summary>Layout of the fleet board and whether the operator changed the delivered one.</summary>
public sealed record FleetLayout(ImmutableArray<FleetLayoutItem> Items, bool Customized);

/// <summary>
/// The 34 built-in widgets of the fleet board of Domenia 1 (same keys, groups, titles, kinds, representations and sizes),
/// their allowed representations, the delivered layout and the presets. Pure: no I/O.
/// </summary>
public static class FleetCatalog
{
    public const string Health = "fleet.health";
    public const string Attention = "fleet.attention";
    public const int MaxItems = 64;
    public const int MaxTitleLength = 80;

    public static ImmutableArray<FleetWidgetDefinition> All { get; } =
    [
        new("fleet.health", "Santé", "Santé du parc", FleetDataKind.Health, "HealthSummary", "L", "Part des postes sans point critique ni à surveiller, et les points à vérifier : un clic déplie les postes concernés.", true),
        new("fleet.attention", "Santé", "Points d’attention", FleetDataKind.List, "List", "L", "Problèmes détectés sur le périmètre : un clic déplie les postes concernés.", false),
        new("fleet.machines", "Inventaire du périmètre", "Comptes ordinateur", FleetDataKind.Value, "Kpi", "S", "Tous les comptes AD : activés, désactivés et état inconnu.", true),
        new("fleet.enabled", "Inventaire du périmètre", "Comptes AD activés", FleetDataKind.Value, "Kpi", "S", "État AD ; aucune déduction de présence réseau.", true),
        new("fleet.accountunknown", "Inventaire du périmètre", "État AD inconnu", FleetDataKind.Value, "Kpi", "S", "userAccountControl non lu.", false),
        new("fleet.accountstatus", "Inventaire du périmètre", "État des comptes AD", FleetDataKind.Distribution, "Pie", "M", "Activés, désactivés et inconnus.", true),
        new("fleet.stale", "Inventaire du périmètre", "Sans connexion AD au-delà du seuil", FleetDataKind.Value, "Kpi", "S", "Seuil réglé dans les règles de santé (90 j par défaut) ; lastLogonTimestamp à 14 jours près.", true),
        new("fleet.disabled", "Inventaire du périmètre", "Comptes désactivés encore dans l’OU", FleetDataKind.Value, "Kpi", "S", "Comptes ordinateur désactivés à déplacer ou supprimer.", true),
        new("fleet.created", "Inventaire du périmètre", "Créés ces 30 jours", FleetDataKind.Value, "Kpi", "S", "Attribut whenCreated.", true),
        new("fleet.pwdold", "Inventaire du périmètre", "Mot de passe machine de plus de 60 j", FleetDataKind.Value, "Kpi", "S", "Attribut pwdLastSet.", true),
        new("fleet.servers", "Inventaire du périmètre", "Serveurs / postes", FleetDataKind.Distribution, "Pie", "M", "Attribut operatingSystem : serveurs et postes de travail.", false),
        new("fleet.laps", "Sécurité", "Sans LAPS", FleetDataKind.Value, "Kpi", "S", "Expiration LAPS lue avec la base autonome, jamais le mot de passe.", true),
        new("fleet.bitlocker", "Sécurité", "Sans clé BitLocker", FleetDataKind.Value, "Kpi", "S", "Présence des clés de récupération, lue sur demande pour l’OU affichée.", true),
        new("fleet.versions", "Versions de Windows", "Versions de Windows", FleetDataKind.Distribution, "Pie", "M", "Attribut operatingSystemVersion de tout le périmètre.", true),
        new("fleet.eos", "Versions de Windows", "Fin de service", FleetDataKind.Value, "Kpi", "S", "Versions plus maintenues ou bientôt (90 jours avant la date).", true),
        new("fleet.win10", "Versions de Windows", "Postes sous Windows 10", FleetDataKind.Value, "Kpi", "S", "Hors LTSC, LTSB et IoT.", true),
        new("fleet.os", "Répartition", "Systèmes d’exploitation", FleetDataKind.Distribution, "Pie", "M", "Systèmes déclarés dans l’annuaire.", true),
        new("fleet.lastlogon", "Répartition", "Dernière connexion au domaine", FleetDataKind.Series, "Column", "M", "Ancienneté de la dernière connexion.", true),
        new("fleet.ou", "Répartition", "Postes par unité d’organisation", FleetDataKind.Distribution, "Bar", "M", "Postes par OU ou sous-OU.", true),
        new("fleet.presence", "Relevés des postes", "Présence réseau", FleetDataKind.Distribution, "Pie", "M", "Dernier ping de moins de 30 jours ; sans réponse ne prouve pas un arrêt.", false),
        new("fleet.wmi", "Relevés des postes", "Réponse WMI", FleetDataKind.Distribution, "Pie", "M", "Dernière lecture WMI datée, indépendante du ping ; un échec ne prouve pas un arrêt.", false),
        new("fleet.reach", "Relevés des postes", "Ping et WMI", FleetDataKind.Distribution, "Bar", "M", "Réponse au ping et réponse WMI comparées pour chaque poste actif.", false),
        new("fleet.users", "Relevés des postes", "Utilisateurs détectés", FleetDataKind.Value, "Kpi", "S", "Utilisateurs distincts vus en session sur les postes.", false),
        new("fleet.lastcheck", "Relevés des postes", "Dernier ping", FleetDataKind.Value, "Kpi", "S", "Date du dernier relevé des postes.", false),
        new("fleet.models", "Relevés des postes", "Modèles", FleetDataKind.Distribution, "Bar", "M", "Modèles des postes analysés.", false),
        new("fleet.releases", "Relevés des postes", "Versions relevées", FleetDataKind.Distribution, "Pie", "M", "Versions commerciales relevées par WMI.", false),
        new("fleet.ram", "Relevés des postes", "Mémoire installée", FleetDataKind.Series, "Column", "M", "Postes par quantité de mémoire.", false),
        new("fleet.diskfree", "Relevés des postes", "Espace libre sur C:", FleetDataKind.Series, "Column", "M", "Postes par espace libre du disque système.", false),
        new("fleet.lowdisk", "Relevés des postes", "Disque C: presque plein", FleetDataKind.Value, "Kpi", "S", "Postes avec moins de 10 % libre.", false),
        new("fleet.uptime", "Relevés des postes", "Non redémarrés depuis 30 j", FleetDataKind.Value, "Kpi", "S", "Postes à redémarrer.", false),
        new("fleet.trend", "Évolution", "Postes à traiter sur 90 jours", FleetDataKind.Timeline, "Line", "L", "Instantanés quotidiens locaux de l’OU affichée.", false),
        new("fleet.trend.win10", "Évolution", "Windows 10 sur 90 jours", FleetDataKind.Timeline, "Line", "L", "Postes sous Windows 10 hors LTSC, LTSB et IoT, instantanés quotidiens.", false),
        new("fleet.trend.stale", "Évolution", "Inactifs sur 90 jours", FleetDataKind.Timeline, "Line", "L", "Postes sans connexion AD au-delà du seuil réglé, instantanés quotidiens.", false),
        new("fleet.trend.lowdisk", "Évolution", "Disques C: presque pleins sur 90 jours", FleetDataKind.Timeline, "Line", "L", "Postes analysés avec moins de 10 % libre, instantanés quotidiens.", false),
    ];

    private static readonly FrozenDictionary<string, FleetWidgetDefinition> ByKey = All.ToFrozenDictionary(w => w.Key, StringComparer.Ordinal);

    /// <summary>Group order of the catalog (sections of the board), as in Domenia 1.</summary>
    public static ImmutableArray<string> Groups { get; } = [.. All.Select(w => w.Group).Distinct()];

    /// <summary>Operator names of the representations (Get-DomeniaBoardVisualNames).</summary>
    public static FrozenDictionary<string, string> VisualNames { get; } = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["Kpi"] = "Chiffre clé",
        ["Gauge"] = "Jauge",
        ["Pie"] = "Anneau",
        ["Bar"] = "Barres",
        ["Column"] = "Histogramme",
        ["Line"] = "Courbe",
        ["Text"] = "Liste",
        ["List"] = "Liste de points",
        ["HealthSummary"] = "Score et points",
        ["Health"] = "Score",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    public static FrozenDictionary<string, string> SizeNames { get; } = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["S"] = "Compacte",
        ["M"] = "Moyenne",
        ["L"] = "Large",
    }.ToFrozenDictionary(StringComparer.Ordinal);

    /// <summary>Presets of Domenia 1 (Get-DomeniaBoardPresetLayout), fleet part.</summary>
    public static ImmutableArray<FleetPreset> Presets { get; } =
    [
        new("support", "Assistance", "Points d’attention, santé, joignabilité et présence réseau en tête.", ["fleet.attention", "fleet.health", "fleet.reach", "fleet.presence"]),
        new("inventory", "Inventaire", "Comptes ordinateur, systèmes, modèles et mémoire en tête.", ["fleet.machines", "fleet.os", "fleet.models", "fleet.ram"]),
        new("health", "Santé", "Santé, points d’attention, espace disque et redémarrages en tête.", ["fleet.health", "fleet.attention", "fleet.diskfree", "fleet.uptime"]),
    ];

    public static bool TryGet(string? key, [NotNullWhen(true)] out FleetWidgetDefinition? definition)
    {
        if (key is not null && ByKey.TryGetValue(key, out var found))
        {
            definition = found;
            return true;
        }
        definition = null;
        return false;
    }

    /// <summary>
    /// Representations that make sense for a kind of data, preferred first (Get-DomeniaBoardVisuals): a curve only for dated
    /// values, buckets and shares never as a time line.
    /// </summary>
    public static ImmutableArray<string> VisualsFor(FleetDataKind kind) => kind switch
    {
        FleetDataKind.Value => ["Kpi", "Text"],
        FleetDataKind.Distribution => ["Pie", "Bar", "Column", "Text", "Kpi"],
        FleetDataKind.Series => ["Column", "Bar", "Text", "Kpi"],
        FleetDataKind.Timeline => ["Line", "Column", "Text"],
        FleetDataKind.List => ["List"],
        FleetDataKind.Health => ["HealthSummary", "Health", "Kpi"],
        _ => ["Kpi", "Text"],
    };

    /// <summary>The stored representation when still allowed for the data, else the preferred one.</summary>
    public static string ResolveVisual(string? visual, FleetDataKind kind)
    {
        var allowed = VisualsFor(kind);
        return visual is not null && allowed.Contains(visual, StringComparer.Ordinal) ? visual : allowed[0];
    }

    public static bool IsSize(string? size) => size is "S" or "M" or "L";

    /// <summary>
    /// Delivered layout (Get-DomeniaBoardCatalogLayout): catalog order without the catalog-only widgets, health after the
    /// inventory.
    /// </summary>
    public static ImmutableArray<FleetLayoutItem> DefaultLayout()
    {
        var items = All.Where(w => w.Default).Select(w => Item(w)).ToList();
        return [.. items.Where(i => i.Group != "Santé"), .. items.Where(i => i.Group == "Santé")];
    }

    /// <summary>
    /// A preset applied to a layout (Get-DomeniaBoardPresetLayout): its widgets are added when missing, then the groups and the
    /// widgets of the preset come first; every other widget keeps its relative place.
    /// </summary>
    public static ImmutableArray<FleetLayoutItem> ApplyPreset(string presetId, IReadOnlyList<FleetLayoutItem> layout)
    {
        ArgumentNullException.ThrowIfNull(layout);
        var preset = Presets.FirstOrDefault(p => p.Id == presetId) ?? throw new ArgumentException("Unknown preset.", nameof(presetId));
        var items = new List<FleetLayoutItem>(layout);
        foreach (var key in preset.Keys)
        {
            if (!items.Any(i => i.Source == FleetWidgetSource.Builtin && i.Key == key) && TryGet(key, out var definition))
            {
                items.Add(Item(definition));
            }
        }
        int Rank(FleetLayoutItem item)
        {
            var index = item.Source == FleetWidgetSource.Builtin ? preset.Keys.IndexOf(item.Key) : -1;
            return index < 0 ? 1000 : index;
        }
        var groupRank = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var item in items)
        {
            var rank = Rank(item);
            if (!groupRank.TryGetValue(item.Group, out var known) || rank < known)
            {
                groupRank[item.Group] = rank;
            }
        }
        return [.. items.Select((item, position) => (item, position)).OrderBy(x => groupRank[x.item.Group]).ThenBy(x => Rank(x.item)).ThenBy(x => x.position).Select(x => x.item)];
    }

    /// <summary>Layout item of a built-in widget with its delivered representation and size.</summary>
    public static FleetLayoutItem Item(FleetWidgetDefinition definition)
    {
        ArgumentNullException.ThrowIfNull(definition);
        return new FleetLayoutItem("b-" + definition.Key, FleetWidgetSource.Builtin, definition.Key, definition.Visual, definition.Size, null, false, definition.Group);
    }

    /// <summary>True when the stored layout is exactly the delivered one (identifiers aside).</summary>
    public static bool IsDefault(IReadOnlyList<FleetLayoutItem> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        var delivered = DefaultLayout();
        if (items.Count != delivered.Length)
        {
            return false;
        }
        for (var i = 0; i < items.Count; i++)
        {
            var a = items[i];
            var b = delivered[i];
            if (a.Source != b.Source || a.Key != b.Key || a.Visual != b.Visual || a.Size != b.Size || a.Title is not null || a.Paused || a.Group != b.Group)
            {
                return false;
            }
        }
        return true;
    }
}

/// <summary>A delivered arrangement of the board.</summary>
public sealed record FleetPreset(string Id, string Label, string Description, ImmutableArray<string> Keys);
