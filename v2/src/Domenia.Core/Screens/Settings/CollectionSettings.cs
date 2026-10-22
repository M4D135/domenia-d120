using System.Collections.Immutable;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>A freshness family whose reuse delay the operator may set (Domenia 1 Get-DomeniaFreshnessFamilies).</summary>
public sealed record FreshnessFamily(string Id, string Label, int Minimum, int Maximum, string Effect);

/// <summary>A usage profile: durations per family (seconds) and its default collection window (Get-DomeniaCollectionProfiles).</summary>
public sealed record CollectionProfile(string Id, string Label, string Description, string Window, ImmutableDictionary<string, int> Seconds);

/// <summary>One bounded budget of the collection (concurrency, reuse, ceilings, retries).</summary>
public sealed record CollectionBudgetDefinition(string Id, string Label, int Default, int Minimum, int Maximum, ImmutableArray<int> Choices, string Unit, string Effect);

/// <summary>
/// Collection settings of the operator, as stored in the local preferences (key « settings.collection »): profile,
/// durations changed per profile, window per profile, budgets. Values are always bounded: an unreadable or out-of-bounds
/// value is dropped and reported (<see cref="CollectionSettingsRules.Read"/>), never guessed.
/// </summary>
public sealed record CollectionSettings(
    string Profile,
    ImmutableDictionary<string, ImmutableDictionary<string, int>> Freshness,
    ImmutableDictionary<string, string> Windows,
    ImmutableDictionary<string, int> Budgets);

/// <summary>A choice offered by an editor (value and its label).</summary>
public sealed record SettingsChoice(int Value, string Label);

/// <summary>One family row of the freshness table (Resolve-DomeniaFreshnessTable).</summary>
public sealed record FreshnessRow(
    string Family,
    string Label,
    int Seconds,
    string Duration,
    int ProfileSeconds,
    string ProfileDuration,
    string Source,
    string SourceLabel,
    string Effect,
    ImmutableArray<SettingsChoice> Choices);

/// <summary>A usage profile as offered by the selector.</summary>
public sealed record CollectionProfileView(string Id, string Label, string Description, string Window, string WindowLabel, bool Active);

/// <summary>One budget as shown by the page.</summary>
public sealed record CollectionBudgetView(string Id, string Label, int Value, int Default, int Minimum, int Maximum, string Unit, string ValueLabel, string Effect, ImmutableArray<SettingsChoice> Choices);

/// <summary>Result of a window check (settings.collection.window.check, and the window of the view).</summary>
public sealed record CollectionWindowView(
    string Text,
    bool Valid,
    CollectionWindowMode Mode,
    ImmutableArray<string> Errors,
    bool Open,
    DateTimeOffset? NextChange,
    string Sentence,
    ImmutableArray<ImmutableArray<bool>> Grid);

/// <summary>Result of settings.collection.</summary>
public sealed record CollectionSettingsView(
    CollectionProfileView Profile,
    ImmutableArray<CollectionProfileView> Profiles,
    ImmutableArray<FreshnessRow> Freshness,
    bool FreshnessCustom,
    CollectionWindowView Window,
    string ProfileWindow,
    bool WindowCustom,
    ImmutableArray<string> WindowSources,
    ImmutableArray<CollectionBudgetView> Budgets,
    ImmutableArray<string> Rules,
    ImmutableArray<string> Warnings);

/// <summary>
/// Pure rules of the collection settings (Domenia 1 PAR-037 to PAR-041): profiles, freshness per family, window per profile,
/// budgets of the surveys and of the widget collections. Nothing here reads the network: these values bound what later
/// reads may do.
/// </summary>
public static class CollectionSettingsRules
{
    /// <summary>Preference key of the collection settings (screen « settings »).</summary>
    public const string PreferenceKey = "settings.collection";

    public const string Standard = "standard";
    public const string SlowNetwork = "slowNetwork";
    public const string Troubleshooting = "troubleshooting";

    public const string Concurrency = "concurrency";
    public const string CacheMinutes = "cacheMinutes";
    public const string MaxTargets = "maxTargets";
    public const string WidgetMax = "widgetMax";
    public const string WmiRetries = "wmiRetries";
    public const string WmiRetryDelaySeconds = "wmiRetryDelaySeconds";

    private const int Week = 604800;

    /// <summary>Families whose reuse delay is a setting (only those a reader really applies).</summary>
    public static ImmutableArray<FreshnessFamily> Families { get; } =
    [
        new("presence", "Présence réseau (ping)", 0, Week, "Le dernier ping reste affiché comme récent pendant cette durée ; au-delà il est marqué à relire."),
        new("console", "Utilisateur console", 0, Week, "L’utilisateur console relevé reste récent pendant cette durée. Un relevé relit toujours la console."),
        new("attributes", "Attributs AD", 0, Week, "Les attributs AD affichés restent récents pendant cette durée ; au-delà la fiche indique « à relire »."),
        new("inventory", "Inventaire léger WMI", 0, Week, "Un relevé réutilise l’inventaire léger plus récent que cette durée au lieu de le relire."),
        new("staticProbe", "Sondes WMI stables", 0, Week, "Un relevé réutilise le résultat des sondes stables (matériel, BIOS, système) plus récent que cette durée."),
        new("volatileProbe", "Sondes WMI variables", 0, Week, "Un relevé réutilise le résultat des sondes variables (services, réseau, charge, journaux) plus récent que cette durée."),
    ];

    /// <summary>The three usage profiles; an unknown identifier falls back to Standard.</summary>
    public static ImmutableArray<CollectionProfile> Profiles { get; } =
    [
        new(Standard, "Standard", "Réseau local ou rapide : durées habituelles de Domenia, travaux de fond permis à tout moment.", "",
            Durations(120, 300, 900, 300, 900, 60)),
        new(SlowNetwork, "Réseau lent ou site distant", "Mesures réutilisées plus longtemps ; travaux de fond limités aux heures creuses.",
            "lun-ven 00:00-08:00 12:00-14:00 18:00-24:00; sam-dim", Durations(600, 900, 3600, 3600, 14400, 300)),
        new(Troubleshooting, "Dépannage en direct", "Mesures relues rapidement pendant une intervention ; travaux de fond permis à tout moment.", "",
            Durations(30, 60, 300, 120, 300, 30)),
    ];

    /// <summary>Durations offered by the editor (Get-DomeniaFreshnessDurationChoices).</summary>
    public static ImmutableArray<int> DurationChoices { get; } = [0, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 43200, 86400, Week];

    /// <summary>Budgets of the surveys (Domenia 1 Collection.* and Park.MaxTargets), with their bounds and defaults.</summary>
    public static ImmutableArray<CollectionBudgetDefinition> BudgetDefinitions { get; } =
    [
        new(Concurrency, "Postes lus en même temps", 4, 1, 8, [1, 2, 4, 6, 8], "postes",
            "Nombre de postes interrogés en parallèle pendant un relevé ; plus bas ménage un réseau lent."),
        new(CacheMinutes, "Réutilisation des mesures fraîches", 15, 0, 1440, [0, 5, 15, 60], "min",
            "Une mesure plus récente que cette durée est réutilisée au lieu d’être relue ; la durée retenue est la plus courte entre le profil et ce réglage, 0 force la relecture."),
        new(MaxTargets, "Plafond d’un relevé de liste", 500, 1, 20000, [100, 250, 500, 1000, 2000, 5000], "postes",
            "Nombre de postes au plus pour un relevé de la liste affichée ou de sa sélection (réglage Park.MaxTargets, désormais réglable ici)."),
        new(WidgetMax, "Plafond des widgets", 0, 0, 100000, [0, 500, 1000, 2000, 5000], "postes",
            "Nombre de postes au plus pour la collecte d’un widget ; 0 : aucun plafond. La confirmation au-delà de 200 postes reste active même sans plafond."),
        new(WmiRetries, "Nouveaux essais WMI", 2, 0, 4, [0, 1, 2, 3, 4], "essais",
            "Nouveaux essais d’une lecture WMI après un incident transitoire seulement ; jamais après un refus, un poste éteint ou une classe absente."),
        new(WmiRetryDelaySeconds, "Premier délai avant un nouvel essai", 30, 10, 120, [10, 30, 60, 120], "s",
            "Délai avant le premier nouvel essai, puis ×4 jusqu’à 5 min."),
    ];

    /// <summary>Settings when nothing is stored.</summary>
    public static CollectionSettings Default { get; } = new(
        Standard,
        ImmutableDictionary<string, ImmutableDictionary<string, int>>.Empty,
        ImmutableDictionary<string, string>.Empty,
        BudgetDefinitions.ToImmutableDictionary(b => b.Id, b => b.Default, StringComparer.Ordinal));

    private static ImmutableDictionary<string, int> Durations(int presence, int console, int attributes, int inventory, int staticProbe, int volatileProbe) =>
        new Dictionary<string, int>(StringComparer.Ordinal)
        {
            ["presence"] = presence, ["console"] = console, ["attributes"] = attributes,
            ["inventory"] = inventory, ["staticProbe"] = staticProbe, ["volatileProbe"] = volatileProbe,
        }.ToImmutableDictionary(StringComparer.Ordinal);

    /// <summary>Profile of an identifier (case ignored); unknown or empty: Standard.</summary>
    public static CollectionProfile Profile(string? id) =>
        Profiles.FirstOrDefault(p => string.Equals(p.Id, (id ?? "").Trim(), StringComparison.OrdinalIgnoreCase)) ?? Profiles[0];

    /// <summary>True for a known profile identifier (exact case).</summary>
    public static bool IsProfile(string? id) => Profiles.Any(p => string.Equals(p.Id, id, StringComparison.Ordinal));

    /// <summary>Definition of a budget, or null.</summary>
    public static CollectionBudgetDefinition? Budget(string id) => BudgetDefinitions.FirstOrDefault(b => string.Equals(b.Id, id, StringComparison.Ordinal));

    /// <summary>Family of an identifier, or null.</summary>
    public static FreshnessFamily? Family(string id) => Families.FirstOrDefault(f => string.Equals(f.Id, id, StringComparison.Ordinal));

    /// <summary>
    /// Reads the stored settings. Every value outside its bounds, an unknown profile, family or budget, a window that does
    /// not parse is dropped and reported in <paramref name="warnings"/>; the defaults apply to it.
    /// </summary>
    public static CollectionSettings Read(JsonElement? stored, List<string> warnings)
    {
        ArgumentNullException.ThrowIfNull(warnings);
        if (stored is not JsonElement root || root.ValueKind == JsonValueKind.Undefined || root.ValueKind == JsonValueKind.Null)
        {
            return Default;
        }
        if (root.ValueKind != JsonValueKind.Object)
        {
            warnings.Add("Réglages de collecte illisibles : les valeurs par défaut s’appliquent.");
            return Default;
        }
        var profile = Standard;
        if (root.TryGetProperty("profile", out var p))
        {
            if (p.ValueKind == JsonValueKind.String && IsProfile(p.GetString()))
            {
                profile = p.GetString()!;
            }
            else
            {
                warnings.Add("Profil de collecte inconnu : le profil Standard s’applique.");
            }
        }
        var freshness = ImmutableDictionary.CreateBuilder<string, ImmutableDictionary<string, int>>(StringComparer.Ordinal);
        if (root.TryGetProperty("freshness", out var f) && f.ValueKind == JsonValueKind.Object)
        {
            foreach (var byProfile in f.EnumerateObject())
            {
                if (!IsProfile(byProfile.Name) || byProfile.Value.ValueKind != JsonValueKind.Object)
                {
                    warnings.Add("Durées d’un profil inconnu ignorées.");
                    continue;
                }
                var values = ImmutableDictionary.CreateBuilder<string, int>(StringComparer.Ordinal);
                foreach (var entry in byProfile.Value.EnumerateObject())
                {
                    var family = Family(entry.Name);
                    if (family is null)
                    {
                        warnings.Add("Famille inconnue ignorée" + FrenchText.Colon + entry.Name);
                        continue;
                    }
                    if (entry.Value.ValueKind != JsonValueKind.Number || !entry.Value.TryGetInt32(out var seconds))
                    {
                        warnings.Add("Durée non entière ignorée" + FrenchText.Colon + family.Label);
                        continue;
                    }
                    if (seconds < family.Minimum || seconds > family.Maximum)
                    {
                        warnings.Add("Durée hors limites ignorée" + FrenchText.Colon + family.Label);
                        continue;
                    }
                    values[family.Id] = seconds;
                }
                if (values.Count > 0)
                {
                    freshness[byProfile.Name] = values.ToImmutable();
                }
            }
        }
        var windows = ImmutableDictionary.CreateBuilder<string, string>(StringComparer.Ordinal);
        if (root.TryGetProperty("windows", out var w) && w.ValueKind == JsonValueKind.Object)
        {
            foreach (var entry in w.EnumerateObject())
            {
                if (!IsProfile(entry.Name) || entry.Value.ValueKind != JsonValueKind.String)
                {
                    warnings.Add("Fenêtre d’un profil inconnu ignorée.");
                    continue;
                }
                var text = entry.Value.GetString()!;
                if (!CollectionWindowRules.Parse(text).Valid)
                {
                    warnings.Add("Fenêtre de collecte enregistrée illisible : travaux de fond suspendus jusqu’à correction.");
                }
                windows[entry.Name] = text.Trim();
            }
        }
        var budgets = Default.Budgets.ToBuilder();
        foreach (var definition in BudgetDefinitions)
        {
            if (!root.TryGetProperty(definition.Id, out var value))
            {
                continue;
            }
            if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) && number >= definition.Minimum && number <= definition.Maximum)
            {
                budgets[definition.Id] = number;
            }
            else
            {
                warnings.Add("Réglage hors limites ignoré" + FrenchText.Colon + definition.Label);
            }
        }
        return new CollectionSettings(profile, freshness.ToImmutable(), windows.ToImmutable(), budgets.ToImmutable());
    }

    /// <summary>Stored form of the settings (camelCase, families and profiles in catalogue order).</summary>
    public static JsonElement ToJson(CollectionSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteString("profile", settings.Profile);
            writer.WriteStartObject("freshness");
            foreach (var profile in Profiles)
            {
                if (!settings.Freshness.TryGetValue(profile.Id, out var values) || values.Count == 0)
                {
                    continue;
                }
                writer.WriteStartObject(profile.Id);
                foreach (var family in Families)
                {
                    if (values.TryGetValue(family.Id, out var seconds))
                    {
                        writer.WriteNumber(family.Id, seconds);
                    }
                }
                writer.WriteEndObject();
            }
            writer.WriteEndObject();
            writer.WriteStartObject("windows");
            foreach (var profile in Profiles)
            {
                if (settings.Windows.TryGetValue(profile.Id, out var text))
                {
                    writer.WriteString(profile.Id, text);
                }
            }
            writer.WriteEndObject();
            foreach (var definition in BudgetDefinitions)
            {
                writer.WriteNumber(definition.Id, settings.Budgets.GetValueOrDefault(definition.Id, definition.Default));
            }
            writer.WriteEndObject();
        }
        using var document = JsonDocument.Parse(buffer.ToArray());
        return document.RootElement.Clone();
    }

    /// <summary>Window in force for the profile of the settings: the operator's text, else the default of the profile.</summary>
    public static string WindowText(CollectionSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return settings.Windows.TryGetValue(settings.Profile, out var text) ? text : Profile(settings.Profile).Window;
    }

    /// <summary>Effective durations of the active profile, then the operator's overrides (Resolve-DomeniaFreshnessTable).</summary>
    public static ImmutableArray<FreshnessRow> FreshnessTable(CollectionSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var profile = Profile(settings.Profile);
        var custom = settings.Freshness.GetValueOrDefault(profile.Id) ?? ImmutableDictionary<string, int>.Empty;
        return
        [
            .. Families.Select(family =>
            {
                var baseSeconds = profile.Seconds[family.Id];
                var overridden = custom.TryGetValue(family.Id, out var value);
                var seconds = overridden ? value : baseSeconds;
                return new FreshnessRow(
                    family.Id,
                    family.Label,
                    seconds,
                    SettingsFormat.Duration(seconds),
                    baseSeconds,
                    SettingsFormat.Duration(baseSeconds),
                    overridden ? "custom" : "profile",
                    overridden ? "Personnalisé" : "Profil",
                    family.Effect,
                    [.. DurationChoices.Where(c => c >= family.Minimum && c <= family.Maximum).Select(c => new SettingsChoice(c, SettingsFormat.Duration(c)))]);
            }),
        ];
    }

    /// <summary>Label of a budget value (« Sans plafond », « Forcer la relecture », « 500 postes », « 30 s »).</summary>
    public static string BudgetLabel(CollectionBudgetDefinition definition, int value)
    {
        ArgumentNullException.ThrowIfNull(definition);
        return definition.Id switch
        {
            WidgetMax when value == 0 => "Sans plafond",
            CacheMinutes when value == 0 => "Forcer la relecture",
            CacheMinutes => "Au plus " + FrenchText.Count(value, "minute", "minutes"),
            WmiRetryDelaySeconds => SettingsFormat.Duration(value),
            WmiRetries => value == 0 ? "Aucun nouvel essai" : FrenchText.Count(value, "nouvel essai", "nouveaux essais"),
            Concurrency => FrenchText.Count(value, "poste", "postes"),
            _ => FrenchText.Count(value, "poste", "postes"),
        };
    }

    /// <summary>The window check (pure): validity, state now, sentence and week grid.</summary>
    public static CollectionWindowView CheckWindow(string? text, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var window = CollectionWindowRules.Parse(text);
        var state = CollectionWindowRules.StateAt(window, now, zone);
        return new CollectionWindowView(window.Text, window.Valid, window.Mode, window.Errors, state.Open, state.NextChange,
            CollectionWindowRules.Sentence(state, now, zone), CollectionWindowRules.WeekGrid(window));
    }

    /// <summary>The whole view of settings.collection.</summary>
    public static CollectionSettingsView View(CollectionSettings settings, IReadOnlyList<string> warnings, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(warnings);
        ArgumentNullException.ThrowIfNull(zone);
        var active = Profile(settings.Profile);
        CollectionProfileView ProfileView(CollectionProfile p) => new(p.Id, p.Label, p.Description, p.Window,
            p.Window.Length == 0 ? "Travaux de fond à tout moment" : "Heures creuses" + FrenchText.Colon + p.Window, p.Id == active.Id);
        var freshness = FreshnessTable(settings);
        var budgets = BudgetDefinitions.Select(d =>
        {
            var value = settings.Budgets.GetValueOrDefault(d.Id, d.Default);
            var choices = d.Choices.Contains(value) ? d.Choices : [.. d.Choices.Append(value).Order()];
            return new CollectionBudgetView(d.Id, d.Label, value, d.Default, d.Minimum, d.Maximum, d.Unit, BudgetLabel(d, value), d.Effect,
                [.. choices.Select(c => new SettingsChoice(c, BudgetLabel(d, c)))]);
        });
        var windowText = WindowText(settings);
        return new CollectionSettingsView(
            ProfileView(active),
            [.. Profiles.Select(ProfileView)],
            freshness,
            freshness.Any(r => r.Source == "custom"),
            CheckWindow(windowText, now, zone),
            active.Window,
            settings.Windows.ContainsKey(active.Id),
            CollectionWindowRules.Sources,
            [.. budgets],
            [
                "La durée retenue pour une mesure est la plus courte entre le profil et la réutilisation des mesures fraîches ; 0 force la relecture.",
                "Les réglages sont lus au début de chaque relevé : un relevé en cours garde ceux de son départ.",
                "La confirmation au-delà de 200 postes reste active, même sans plafond des widgets.",
                "Une fenêtre fermée ne retient que les travaux de fond ; un relevé lancé à la main reste possible et sa confirmation le signale.",
            ],
            [.. warnings]);
    }
}
