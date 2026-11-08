using System.Collections.Immutable;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

/// <summary>Small provenance labels driven by catalog definitions, never inferred from an operator's widget title.</summary>
public static class FleetWidgetSources
{
    public static ImmutableArray<string> Builtin(string key) => key switch
    {
        "fleet.machines" or "fleet.enabled" or "fleet.accountunknown" or "fleet.accountstatus" or "fleet.stale"
            or "fleet.disabled" or "fleet.created" or "fleet.pwdold" or "fleet.servers" or "fleet.laps" or "fleet.bitlocker"
            or "fleet.versions" or "fleet.win10" or "fleet.os" or "fleet.lastlogon" or "fleet.ou" => ["AD"],
        "fleet.eos" => ["AD", "Référentiel"],
        "fleet.presence" or "fleet.lastcheck" => ["Réseau"],
        "fleet.wmi" or "fleet.models" or "fleet.releases" or "fleet.ram" or "fleet.diskfree" or "fleet.lowdisk" or "fleet.uptime" => ["WMI"],
        "fleet.users" => ["AD", "WMI"],
        "fleet.reach" => ["Réseau", "WMI"],
        "fleet.health" or "fleet.attention" => ["Calcul local"],
        "fleet.trend" or "fleet.trend.win10" or "fleet.trend.stale" or "fleet.trend.lowdisk" => ["Historique"],
        _ => [],
    };

    public static ImmutableArray<string> Query(CompiledQuery query)
    {
        ArgumentNullException.ThrowIfNull(query);
        var origins = new HashSet<string>(StringComparer.Ordinal);
        foreach (var id in query.RequestedFields)
        {
            if (query.FindField(id) is not { } field) continue;
            switch (field.Source)
            {
                case QuerySource.Ad:
                case QuerySource.Ldap: origins.Add("AD"); break;
                case QuerySource.Local: origins.Add("AD"); origins.Add("Calcul local"); break;
                case QuerySource.Observation:
                    origins.Add(field.Clock == "presence" ? "Réseau" : field.Clock is "inventory" or "console" ? "WMI" : "Relevé");
                    if (field.Clock == "console") origins.Add("AD");
                    break;
                case QuerySource.Probe:
                case QuerySource.Instance:
                case QuerySource.Detail: origins.Add("WMI"); break;
            }
        }
        // A condition-free object counter is a count of the directory copy.
        if (query.RequestedFields.IsEmpty) origins.Add("AD");
        return [.. new[] { "AD", "Réseau", "WMI", "Relevé", "Calcul local" }.Where(origins.Contains)];
    }
}
