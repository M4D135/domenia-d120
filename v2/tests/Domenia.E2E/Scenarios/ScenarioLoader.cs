using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Domenia.E2E.Driver;

namespace Domenia.E2E.Scenarios;

/// <summary>Shape of a scenario file, as written (docs/E2E.md § 3). Unknown fields are refused.</summary>
internal sealed class ScenarioDocument
{
    [JsonPropertyName("$schema")]
    public string? Schema { get; set; }

    public string? Name { get; set; }

    public string? Description { get; set; }

    public string[]? Modes { get; set; }

    public string? Start { get; set; }

    public string? Theme { get; set; }

    public string? Motion { get; set; }

    public bool? AllowConsoleErrors { get; set; }

    public int? TimeoutMs { get; set; }

    public StepDocument[]? Steps { get; set; }
}

/// <summary>Shape of one step: « do » names the action, the other fields depend on it (docs/E2E.md § 4).</summary>
internal sealed class StepDocument
{
    public string? Do { get; set; }

    public string? Title { get; set; }

    public int? TimeoutMs { get; set; }

    public string? Selector { get; set; }

    public string? Text { get; set; }

    public string? Contains { get; set; }

    public string? Within { get; set; }

    public int? Nth { get; set; }

    public string? Route { get; set; }

    public string? Key { get; set; }

    public int? Repeat { get; set; }

    public int? Ms { get; set; }

    public string? Ready { get; set; }

    public int? Count { get; set; }

    public bool? Absent { get; set; }

    public string? Property { get; set; }

    public string? Attribute { get; set; }

    /// <summary>Undefined when absent; JSON null is a value (an attribute that must be missing).</summary>
    [JsonPropertyName("equals")]
    public JsonElement ExpectedValue { get; set; }

    public string? Name { get; set; }

    public string? Pattern { get; set; }

    public bool? Clear { get; set; }

    public int? ClickCount { get; set; }

    public string? Button { get; set; }

    public double? DeltaY { get; set; }
}

/// <summary>Reads and validates scenario files; every refusal is a French sentence naming the step and the field.</summary>
internal static partial class ScenarioLoader
{
    public const int DefaultTimeoutMs = 10_000;
    public const int MaxTimeoutMs = 120_000;
    public const int MaxSteps = 200;
    private const int MaxTextLength = 500;

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        MaxDepth = 16,
    };

    /// <summary>Fields admitted by each action, besides do, title and timeoutMs.</summary>
    private static readonly Dictionary<StepAction, string[]> Allowed = new()
    {
        [StepAction.Go] = ["route"],
        [StepAction.Click] = ["selector", "text", "within", "nth", "button", "clickCount"],
        [StepAction.Hover] = ["selector", "text", "within", "nth"],
        [StepAction.Type] = ["text", "selector", "within", "nth", "clear"],
        [StepAction.Press] = ["key", "repeat"],
        [StepAction.Expect] = ["selector", "text", "contains", "within", "nth", "count", "absent", "property", "attribute", "equals"],
        [StepAction.Wait] = ["ms", "ready", "selector", "text", "contains", "within", "nth", "count", "absent"],
        [StepAction.Shot] = ["name", "selector", "within", "nth"],
        [StepAction.Scroll] = ["deltaY", "selector", "within", "nth"],
        [StepAction.Journal] = ["contains", "pattern", "absent"],
    };

    public static Scenario Load(string path, string id)
    {
        ArgumentNullException.ThrowIfNull(path);
        ScenarioDocument? document;
        try
        {
            var bytes = File.ReadAllBytes(path);
            if (bytes.Length > 1024 * 1024)
            {
                throw new ScenarioException("fichier de plus de 1 Mo");
            }
            document = JsonSerializer.Deserialize<ScenarioDocument>(bytes, Options);
        }
        catch (JsonException ex)
        {
            var where = ex.Path is null ? "" : $" à {ex.Path}";
            var line = ex.LineNumber is long n ? $" (ligne {n + 1})" : "";
            throw new ScenarioException(ex.Message.Contains("could not be mapped", StringComparison.Ordinal)
                ? $"champ non admis{where}{line}"
                : $"JSON invalide{where}{line}");
        }
        if (document is null)
        {
            throw new ScenarioException("le fichier ne contient pas d’objet JSON");
        }
        return Validate(document, path, id);
    }

    public static Scenario Validate(ScenarioDocument document, string file, string id)
    {
        ArgumentNullException.ThrowIfNull(document);
        var name = RequireText(document.Name, "name", 120) ?? throw new ScenarioException("champ « name » obligatoire (titre du scénario)");
        var description = RequireText(document.Description, "description", 1000);
        var modes = new List<RunMode>();
        foreach (var mode in document.Modes ?? ["simulation"])
        {
            RunMode parsed = mode switch
            {
                "simulation" => RunMode.Simulation,
                "annuaire" => RunMode.Annuaire,
                _ => throw new ScenarioException($"mode « {mode} » inconnu (simulation ou annuaire)"),
            };
            if (!modes.Contains(parsed))
            {
                modes.Add(parsed);
            }
        }
        if (modes.Count == 0)
        {
            throw new ScenarioException("« modes » ne peut pas être vide");
        }
        var start = document.Start ?? "accueil";
        if (!RoutePattern().IsMatch(start))
        {
            throw new ScenarioException($"écran de départ « {start} » invalide (nom en minuscules, requête facultative après « ? »)");
        }
        if (document.Theme is not (null or "dark" or "light" or "contrast"))
        {
            throw new ScenarioException("« theme » vaut dark, light ou contrast");
        }
        if (document.Motion is not (null or "full" or "reduced"))
        {
            throw new ScenarioException("« motion » vaut full ou reduced");
        }
        var timeout = CheckTimeout(document.TimeoutMs, "timeoutMs") ?? DefaultTimeoutMs;
        if (document.Steps is null || document.Steps.Length == 0)
        {
            throw new ScenarioException("« steps » doit contenir au moins une étape");
        }
        if (document.Steps.Length > MaxSteps)
        {
            throw new ScenarioException($"{MaxSteps} étapes au plus");
        }
        var steps = new List<Step>(document.Steps.Length);
        for (var n = 0; n < document.Steps.Length; n++)
        {
            try
            {
                steps.Add(ValidateStep(document.Steps[n] ?? throw new ScenarioException("étape vide"), n + 1, timeout));
            }
            catch (ScenarioException ex)
            {
                throw new ScenarioException($"étape {n + 1} ({document.Steps[n]?.Do ?? "?"}) : {ex.Message}");
            }
        }
        return new Scenario(id, file, name, description, modes, start, document.Theme, document.Motion, document.AllowConsoleErrors ?? false, steps);
    }

    private static Step ValidateStep(StepDocument s, int index, int scenarioTimeout)
    {
        StepAction action = s.Do switch
        {
            "go" => StepAction.Go,
            "click" => StepAction.Click,
            "hover" => StepAction.Hover,
            "type" => StepAction.Type,
            "press" => StepAction.Press,
            "expect" => StepAction.Expect,
            "wait" => StepAction.Wait,
            "shot" => StepAction.Shot,
            "scroll" => StepAction.Scroll,
            "journal" => StepAction.Journal,
            null => throw new ScenarioException("champ « do » obligatoire"),
            _ => throw new ScenarioException($"action « {s.Do} » inconnue (go, click, hover, type, press, expect, wait, shot, scroll, journal)"),
        };
        var present = Present(s);
        var allowed = Allowed[action];
        foreach (var field in present)
        {
            if (!allowed.Contains(field))
            {
                throw new ScenarioException($"champ « {field} » non admis pour cette action");
            }
        }
        var selector = RequireText(s.Selector, "selector", 300);
        var text = RequireText(s.Text, "text", MaxTextLength, allowBlank: action == StepAction.Type);
        var contains = RequireText(s.Contains, "contains", MaxTextLength);
        var within = RequireText(s.Within, "within", 300);
        if (s.Nth is < 0 or > 1000)
        {
            throw new ScenarioException("« nth » va de 0 à 1000");
        }
        if (s.Count is < 0 or > 10_000)
        {
            throw new ScenarioException("« count » va de 0 à 10 000");
        }
        var timeout = CheckTimeout(s.TimeoutMs, "timeoutMs") ?? scenarioTimeout;
        var absent = s.Absent ?? false;
        KeyChord? key = null;
        Regex? pattern = null;
        string? route = null;
        string? ready = null;
        switch (action)
        {
            case StepAction.Go:
                route = s.Route ?? throw new ScenarioException("« route » obligatoire");
                if (!RoutePattern().IsMatch(route))
                {
                    throw new ScenarioException($"route « {route} » invalide (nom en minuscules, requête facultative après « ? »)");
                }
                break;
            case StepAction.Click or StepAction.Hover:
                RequireLocator(selector, text);
                if (s.Button is not (null or "left" or "right"))
                {
                    throw new ScenarioException("« button » vaut left ou right");
                }
                if (s.ClickCount is not (null or 1 or 2))
                {
                    throw new ScenarioException("« clickCount » vaut 1 ou 2");
                }
                break;
            case StepAction.Type:
                if (text is null)
                {
                    throw new ScenarioException("« text » obligatoire (texte à saisir)");
                }
                break;
            case StepAction.Press:
                key = Keys.Parse(s.Key, out var keyError) ?? throw new ScenarioException(keyError ?? "touche invalide");
                if (s.Repeat is < 1 or > 50)
                {
                    throw new ScenarioException("« repeat » va de 1 à 50");
                }
                break;
            case StepAction.Expect:
                ValidateCondition(s, selector, text, contains, absent);
                break;
            case StepAction.Wait:
                var families = (s.Ms is null ? 0 : 1) + (s.Ready is null ? 0 : 1) + (selector is null && text is null && contains is null ? 0 : 1);
                if (families != 1)
                {
                    throw new ScenarioException("indiquez une seule attente : « ms », « ready », ou un élément (« selector », « text », « contains »)");
                }
                if (s.Ms is < 0 or > 30_000)
                {
                    throw new ScenarioException("« ms » va de 0 à 30 000");
                }
                if (s.Ready is not null)
                {
                    ready = s.Ready;
                    if (!ScreenPattern().IsMatch(ready))
                    {
                        throw new ScenarioException($"écran « {ready} » invalide (nom d’écran sans requête)");
                    }
                }
                else if (s.Ms is null)
                {
                    ValidateCondition(s, selector, text, contains, absent);
                }
                break;
            case StepAction.Shot:
                if (s.Name is null || !NamePattern().IsMatch(s.Name))
                {
                    throw new ScenarioException("« name » obligatoire : minuscules, chiffres et tirets, 40 caractères au plus");
                }
                break;
            case StepAction.Scroll:
                if (s.DeltaY is not double delta || double.IsNaN(delta) || delta is < -20_000 or > 20_000 || delta == 0)
                {
                    throw new ScenarioException("« deltaY » obligatoire, de −20 000 à 20 000 pixels, non nul");
                }
                break;
            case StepAction.Journal:
                if ((contains is null) == (s.Pattern is null))
                {
                    throw new ScenarioException("indiquez « contains » ou « pattern » (un seul)");
                }
                if (s.Pattern is not null)
                {
                    if (s.Pattern.Length > MaxTextLength)
                    {
                        throw new ScenarioException("« pattern » trop long");
                    }
                    try
                    {
                        pattern = new Regex(s.Pattern, RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
                    }
                    catch (ArgumentException)
                    {
                        throw new ScenarioException("« pattern » n’est pas une expression régulière .NET valide");
                    }
                }
                break;
        }
        return new Step(index, action, RequireText(s.Title, "title", 200), timeout, selector, text, contains, within, s.Nth, route, key, s.Repeat ?? 1,
            s.Ms, ready, s.Count, absent, s.Property, s.Attribute, s.ExpectedValue, s.Name, pattern, s.Clear ?? false, s.ClickCount ?? 1, s.Button ?? "left", s.DeltaY);
    }

    private static void ValidateCondition(StepDocument s, string? selector, string? text, string? contains, bool absent)
    {
        if (selector is null && text is null && contains is null)
        {
            throw new ScenarioException("indiquez ce qui est attendu : « selector », « text » ou « contains »");
        }
        if (contains is not null && (selector is not null || text is not null))
        {
            throw new ScenarioException("« contains » s’emploie seul (avec « within » pour le limiter à une zone)");
        }
        var valued = s.Property is not null || s.Attribute is not null;
        if (s.Property is not null && s.Attribute is not null)
        {
            throw new ScenarioException("« property » ou « attribute », pas les deux");
        }
        if (s.Property is not null && !PropertyPattern().IsMatch(s.Property))
        {
            throw new ScenarioException("« property » : nom de propriété DOM (lettres et chiffres)");
        }
        if (s.Attribute is not null && !AttributePattern().IsMatch(s.Attribute))
        {
            throw new ScenarioException("« attribute » : nom d’attribut HTML");
        }
        if (valued && contains is not null)
        {
            throw new ScenarioException("« property » et « attribute » portent sur un élément (« selector » ou « text »)");
        }
        if (valued != (s.ExpectedValue.ValueKind != JsonValueKind.Undefined))
        {
            throw new ScenarioException("« equals » accompagne « property » ou « attribute », et eux seuls");
        }
        if (valued && s.ExpectedValue.ValueKind is not (JsonValueKind.String or JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False or JsonValueKind.Null))
        {
            throw new ScenarioException("« equals » : texte, nombre, true, false ou null");
        }
        if (valued && (absent || s.Count is not null))
        {
            throw new ScenarioException("« property » et « attribute » ne se combinent pas avec « absent » ni « count »");
        }
        if (absent && s.Count is not null)
        {
            throw new ScenarioException("« absent » et « count » ne se combinent pas (écrire count: 0)");
        }
    }

    private static void RequireLocator(string? selector, string? text)
    {
        if (selector is null && text is null)
        {
            throw new ScenarioException("indiquez l’élément : « selector » ou « text » (texte visible)");
        }
    }

    private static int? CheckTimeout(int? value, string field)
    {
        if (value is < 100 or > MaxTimeoutMs)
        {
            throw new ScenarioException($"« {field} » va de 100 à {MaxTimeoutMs} ms");
        }
        return value;
    }

    private static string? RequireText(string? value, string field, int max, bool allowBlank = false)
    {
        if (value is null)
        {
            return null;
        }
        if ((!allowBlank && string.IsNullOrWhiteSpace(value)) || value.Length > max)
        {
            throw new ScenarioException($"« {field} » vide ou trop long ({max} caractères au plus)");
        }
        if (value.Any(c => char.IsControl(c) && c is not '\n' and not '\t'))
        {
            throw new ScenarioException($"« {field} » contient un caractère de contrôle");
        }
        return value;
    }

    /// <summary>Names of the fields set in a step (other than do, title and timeoutMs).</summary>
    private static List<string> Present(StepDocument s)
    {
        var fields = new List<string>();
        void Add(bool set, string name)
        {
            if (set)
            {
                fields.Add(name);
            }
        }
        Add(s.Selector is not null, "selector");
        Add(s.Text is not null, "text");
        Add(s.Contains is not null, "contains");
        Add(s.Within is not null, "within");
        Add(s.Nth is not null, "nth");
        Add(s.Route is not null, "route");
        Add(s.Key is not null, "key");
        Add(s.Repeat is not null, "repeat");
        Add(s.Ms is not null, "ms");
        Add(s.Ready is not null, "ready");
        Add(s.Count is not null, "count");
        Add(s.Absent is not null, "absent");
        Add(s.Property is not null, "property");
        Add(s.Attribute is not null, "attribute");
        Add(s.ExpectedValue.ValueKind != JsonValueKind.Undefined, "equals");
        Add(s.Name is not null, "name");
        Add(s.Pattern is not null, "pattern");
        Add(s.Clear is not null, "clear");
        Add(s.ClickCount is not null, "clickCount");
        Add(s.Button is not null, "button");
        Add(s.DeltaY is not null, "deltaY");
        return fields;
    }

    /// <summary>Same form as the capture routes (docs/CAPTURE.md § 1).</summary>
    [GeneratedRegex(@"^[a-z][a-z0-9-]{1,30}(\?[A-Za-z0-9=&%._,-]{0,200})?$", RegexOptions.CultureInvariant)]
    public static partial Regex RoutePattern();

    [GeneratedRegex("^[a-z0-9]+(-[a-z0-9]+)*$", RegexOptions.CultureInvariant)]
    private static partial Regex ScreenPattern();

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{0,39}$", RegexOptions.CultureInvariant)]
    public static partial Regex NamePattern();

    [GeneratedRegex("^[a-zA-Z][a-zA-Z0-9]{0,39}$", RegexOptions.CultureInvariant)]
    private static partial Regex PropertyPattern();

    [GeneratedRegex("^[a-zA-Z][a-zA-Z0-9_:.-]{0,59}$", RegexOptions.CultureInvariant)]
    private static partial Regex AttributePattern();
}

/// <summary>Refusal of a scenario file (French message, without the file name).</summary>
internal sealed class ScenarioException(string message) : Exception(message)
{
}
