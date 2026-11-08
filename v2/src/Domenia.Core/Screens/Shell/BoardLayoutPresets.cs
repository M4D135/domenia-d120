using System.Collections.Immutable;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Core;

/// <summary>D1 Get-DomeniaBoardPresetLayout: add missing priorities, then stably order their whole groups.</summary>
public static class BoardLayoutPresets
{
    public static ImmutableArray<string> Keys(string board, string preset)
    {
        if (board is not ("Fleet" or "Computer" or "Software")) throw new InvalidDataException("Tableau inconnu.");
        string[] keys = preset switch
        {
            "support" => ["computer.attention", "computer.health", "computer.uptime", "computer.disk.system", "fleet.attention", "fleet.health", "fleet.reach", "fleet.presence", "software.count"],
            "inventory" => ["computer.identity", "computer.adaccount", "computer.os", "computer.model", "computer.memory", "fleet.machines", "fleet.os", "fleet.models", "fleet.ram", "software.count", "software.largest"],
            "health" => ["computer.health", "computer.attention", "computer.firewall", "computer.bitlocker", "computer.disk.system", "fleet.health", "fleet.attention", "fleet.diskfree", "fleet.uptime"],
            _ => throw new InvalidDataException("Disposition prédéfinie inconnue."),
        };
        var prefix = board.ToLowerInvariant() + ".";
        return [.. keys.Where(key => key.StartsWith(prefix, StringComparison.Ordinal))];
    }

    public static ImmutableArray<FleetLayoutItem> Apply(string board, string preset, IReadOnlyList<FleetLayoutItem> current)
    {
        ArgumentNullException.ThrowIfNull(current);
        var keys = Keys(board, preset);
        if (board == "Fleet") return FleetCatalog.ApplyPreset(preset, current);
        var items = PosteBoardLayouts.Normalize(board, current).ToList();
        var ids = items.Select(i => i.Id).ToHashSet(StringComparer.Ordinal);
        var catalog = PosteBoardLayouts.Catalog(board);
        foreach (var key in keys)
        {
            if (items.Any(i => i.Source == FleetWidgetSource.Builtin && i.Key == key)) continue;
            var definition = catalog.Single(d => d.Source == FleetWidgetSource.Builtin && d.Key == key);
            var stem = "p-" + key;
            var id = stem;
            for (var suffix = 2; !ids.Add(id); suffix++) id = stem + "-" + suffix.ToString(System.Globalization.CultureInfo.InvariantCulture);
            items.Add(new(id, FleetWidgetSource.Builtin, key, definition.Visual, definition.Size, null, false, ""));
        }
        if (items.Count > PosteBoardLayouts.MaxItems) throw new InvalidDataException("Le préréglage dépasserait 64 cartes ; aucune carte existante n’a été supprimée.");
        int Rank(FleetLayoutItem item)
        {
            var index = item.Source == FleetWidgetSource.Builtin ? keys.IndexOf(item.Key) : -1;
            return index < 0 ? 1000 : index;
        }
        var groups = items.GroupBy(i => i.Group, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Min(Rank), StringComparer.Ordinal);
        return [.. items.Select((item, index) => (item, index)).OrderBy(x => groups[x.item.Group]).ThenBy(x => Rank(x.item)).ThenBy(x => x.index).Select(x => x.item)];
    }
}
