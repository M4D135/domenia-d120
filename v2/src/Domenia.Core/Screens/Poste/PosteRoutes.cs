using System.Collections.Immutable;

namespace Domenia.Core.Poste;

/// <summary>
/// Views of the console and the former tab names of Domenia 1 they absorb (Get-DomeniaComputerViewNames,
/// Resolve-DomeniaComputerViewRoute, UX-21, improved: deep routes « #/poste?vue=…&amp;onglet=… » shared by the palette, the
/// links and the history). An unknown name resolves to nothing: the page keeps the current view. Pure.
/// </summary>
public static class PosteRoutes
{
    /// <summary>The six views of the console, in their order.</summary>
    public static ImmutableArray<(string Id, string Label)> Views { get; } =
    [
        ("ensemble", "Vue d’ensemble"),
        ("inventaire", "Inventaire"),
        ("diagnostic", "Diagnostic"),
        ("releves", "Sondes et relevés"),
        ("intervenir", "Intervenir"),
        ("secrets", "Secrets"),
    ];

    /// <summary>Inner tabs of the views that have some.</summary>
    public static ImmutableArray<(string View, string Tab, string Label)> Tabs { get; } =
    [
        ("inventaire", "materiel", "Matériel et système"),
        ("inventaire", "logiciels", "Logiciels"),
        ("inventaire", "services", "Services"),
        ("inventaire", "processus", "Processus"),
        ("inventaire", "sessions", "Sessions"),
        ("diagnostic", "reseau", "Diagnostic réseau"),
        ("diagnostic", "rapide", "Diagnostic rapide"),
        ("diagnostic", "lent", "Poste lent"),
        ("diagnostic", "evenements", "Événements"),
        ("diagnostic", "wmi", "Explorateur WMI"),
        ("diagnostic", "jonction", "Jonction et SSO"),
    ];

    /// <summary>Resolves a view, a D2 tab or a former Domenia 1 tab name; null when unknown.</summary>
    public static PosteRoute? Resolve(string? name)
    {
        var key = (name ?? "").Trim();
        if (key.Length == 0)
        {
            return null;
        }
        var view = Views.FirstOrDefault(v => string.Equals(v.Id, key, StringComparison.OrdinalIgnoreCase));
        if (view.Id is not null)
        {
            return new PosteRoute(view.Id, null, null, view.Label);
        }
        var tab = Tabs.FirstOrDefault(t => string.Equals(t.Tab, key, StringComparison.OrdinalIgnoreCase));
        if (tab.Tab is not null)
        {
            return new PosteRoute(tab.View, tab.Tab, null, tab.Label);
        }
        return key switch
        {
            "TabComputer" => new PosteRoute("ensemble", null, null, "Vue d’ensemble"),
            "TabComputerDashboard" => new PosteRoute("ensemble", null, "tableau", "Tableau de bord du poste"),
            "TabComputerAdmin" => new PosteRoute("intervenir", null, null, "Intervenir"),
            "TabSessions" => new PosteRoute("inventaire", "sessions", null, "Sessions"),
            "TabComputerServices" => new PosteRoute("inventaire", "services", null, "Services"),
            "TabComputerDetails" => new PosteRoute("inventaire", null, null, "Inventaire"),
            "TabInventory" => new PosteRoute("inventaire", "materiel", null, "Matériel et système"),
            "TabSoftware" => new PosteRoute("inventaire", "logiciels", null, "Logiciels"),
            "TabComputerHealth" or "TabComputerChecks" => new PosteRoute("diagnostic", "reseau", null, "Diagnostic réseau"),
            "TabWmi" => new PosteRoute("diagnostic", "wmi", null, "Explorateur WMI"),
            "TabSecurity" => new PosteRoute("secrets", null, null, "Secrets"),
            "ComputerSecrets" => new PosteRoute("secrets", null, null, "Vue Secrets du poste"),
            "ComputerActions" => new PosteRoute("intervenir", null, null, "Vue Intervenir"),
            _ => null,
        };
    }
}
