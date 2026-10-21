using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Domenia.E2E.Driver;

namespace Domenia.E2E.Scenarios;

/// <summary>Step kinds of a scenario file (docs/E2E.md § 4).</summary>
internal enum StepAction
{
    Go,
    Click,
    Hover,
    Type,
    Press,
    Expect,
    Wait,
    Shot,
    Scroll,
    Journal,
}

/// <summary>Mode Domenia is started in: simulation (--simulation) or annuaire (joined workstation, integrated auth).</summary>
internal enum RunMode
{
    Simulation,
    Annuaire,
}

/// <summary>A validated scenario: <c>tests/e2e/&lt;écran&gt;/&lt;nom&gt;.json</c>, identified as « écran/nom ».</summary>
internal sealed record Scenario(
    string Id,
    string File,
    string Name,
    string? Description,
    IReadOnlyList<RunMode> Modes,
    string Start,
    string? Theme,
    string? Motion,
    bool AllowConsoleErrors,
    IReadOnlyList<Step> Steps)
{
    /// <summary>Route id the start screen sets in data-ready (part before « ? »).</summary>
    public string StartScreen => Step.ScreenOf(Start);
}

/// <summary>A validated step. Unused fields are null; defaults are applied by the loader.</summary>
internal sealed record Step(
    int Index,
    StepAction Action,
    string? Title,
    int TimeoutMs,
    string? Selector,
    string? Text,
    string? Contains,
    string? Within,
    int? Nth,
    string? Route,
    KeyChord? Key,
    int Repeat,
    int? Ms,
    string? Ready,
    int? Count,
    bool Absent,
    string? Property,
    string? Attribute,
    JsonElement Expected,
    string? Name,
    Regex? Pattern,
    bool Clear,
    int ClickCount,
    string Button,
    double? DeltaY)
{
    private const string Nb = " ";

    public static string ScreenOf(string route)
    {
        var mark = route.IndexOf('?', StringComparison.Ordinal);
        return mark < 0 ? route : route[..mark];
    }

    /// <summary>Locator of the element a click, hover, type, shot or scroll acts on (the typed text is not a locator).</summary>
    public JsonObject Locator(bool hit, bool enabled, string? defaultSelector = null)
    {
        var locator = new JsonObject { ["hit"] = hit, ["enabled"] = enabled };
        var selector = Selector ?? defaultSelector;
        if (selector is not null)
        {
            locator["selector"] = selector;
        }
        if (Action is not StepAction.Type && Text is not null)
        {
            locator["text"] = Text;
        }
        if (Within is not null)
        {
            locator["within"] = Within;
        }
        if (Nth is int nth)
        {
            locator["nth"] = nth;
        }
        return locator;
    }

    /// <summary>Facts the page reports for expect and wait.</summary>
    public JsonObject ProbeSpec()
    {
        var spec = new JsonObject();
        if (Selector is not null)
        {
            spec["selector"] = Selector;
        }
        if (Text is not null)
        {
            spec["text"] = Text;
        }
        if (Contains is not null)
        {
            spec["contains"] = Contains;
        }
        if (Within is not null)
        {
            spec["within"] = Within;
        }
        if (Nth is int nth)
        {
            spec["nth"] = nth;
        }
        if (Property is not null)
        {
            spec["property"] = Property;
        }
        if (Attribute is not null)
        {
            spec["attribute"] = Attribute;
        }
        return spec;
    }

    /// <summary>French description for the console and the report; the scenario's own title wins.</summary>
    public string Describe()
    {
        if (!string.IsNullOrWhiteSpace(Title))
        {
            return Title;
        }
        var where = Within is null ? "" : " dans " + Within;
        return Action switch
        {
            StepAction.Go => $"Aller à l’écran {Q(Route)}",
            StepAction.Click => (ClickCount == 2 ? "Double-cliquer sur " : Button == "right" ? "Clic droit sur " : "Cliquer sur ") + Target() + where,
            StepAction.Hover => "Survoler " + Target() + where,
            StepAction.Type => $"Saisir {Q(Text)}" + (Selector is null ? "" : " dans " + Selector) + (Clear ? " (après effacement)" : ""),
            StepAction.Press => $"Appuyer sur {Key?.Label}" + (Repeat > 1 ? $" ({Repeat} fois)" : ""),
            StepAction.Expect => "Vérifier" + Nb + ": " + Condition() + where,
            StepAction.Wait => Ms is int ms ? $"Attendre {ms}{Nb}ms" : "Attendre" + Nb + ": " + Condition() + where,
            StepAction.Shot => $"Capture {Q(Name)}" + (Selector is null ? "" : " de " + Selector),
            StepAction.Scroll => $"Faire défiler {Selector ?? ".main"} de {DeltaY?.ToString("0", System.Globalization.CultureInfo.InvariantCulture)}{Nb}px",
            StepAction.Journal => "Journal technique" + Nb + ": " + (Absent ? "ne contient pas " : "contient ") + (Pattern is null ? Q(Contains) : "l’expression " + Q(Pattern.ToString())),
            _ => Action.ToString(),
        };
    }

    private string Target() => Text is not null ? Q(Text) + (Selector is null ? "" : " (" + Selector + ")") : Selector ?? "?";

    private string Condition()
    {
        if (Ready is not null)
        {
            return $"écran {Q(Ready)} prêt";
        }
        if (Property is not null || Attribute is not null)
        {
            var name = Property is not null ? "propriété " + Property : "attribut " + Attribute;
            return $"{name} de {Target()} = {Expected.GetRawText()}";
        }
        if (Contains is not null)
        {
            return $"texte {Q(Contains)} {(Absent ? "absent" : "présent")}";
        }
        if (Count is int count)
        {
            return $"{count} élément(s) visible(s) pour {Target()}";
        }
        return $"{Target()} {(Absent ? "absent" : "visible")}";
    }

    private static string Q(string? text) => "«" + Nb + text + Nb + "»";
}
