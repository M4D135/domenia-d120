using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Simulation;

internal sealed partial class SimulatedQueryState
{
    private ProbeReading PersonalReading(QueryProbe probe, DirectoryComputer computer, DateTimeOffset at)
    {
        ProbeReading Missing(string reason, bool skipped = false) => new(probe.Id, at, skipped ? null : reason, skipped, false, null, false, [])
        { PersonalDeclaration = probe.PersonalDeclaration };
        if ((computer.UserAccountControl & AdValues.ServerTrustAccount) != 0) { return Missing("Contrôleur de domaine exclu.", true); }
        var definition = SimulatedWmiCatalog.Find(probe.Namespace, probe.Class);
        var select = QueryPersonalProbes.Select(probe, at);
        if (definition is null || select.ReferencedProperties.Any(p => !definition.Properties.Any(f => f.Name.Equals(p, StringComparison.OrdinalIgnoreCase))))
        { return Missing("Propriété absente du monde simulé ; aucune valeur inventée."); }
        var limit = probe.Mode == "First" ? 1 : 500;
        var all = SimulatedWmiCatalog.Instances(source, computer.ObjectGuid, definition)
            .Select(ForFilter).Where(row => WqlRules.Matches(select.Where, row)).Take(limit + 1).ToArray();
        var rows = ImmutableArray.CreateBuilder<ProbeInstance>();
        foreach (var item in all.Take(limit))
        {
            var values = ImmutableDictionary.CreateBuilder<string, object?>(StringComparer.OrdinalIgnoreCase);
            var incomplete = ImmutableArray.CreateBuilder<string>();
            foreach (var field in probe.Fields)
            {
                var text = item.GetValueOrDefault(field.Name);
                object? value = text;
                // The simulated schema exposes scalar text. An array is not reconstructed from a display string.
                if (field.IsArray) { value = null; incomplete.Add(field.Name); }
                else if (field.Kind == QueryFieldKind.Number)
                { value = QueryProbeCatalog.Number(text); if (text is not null && value is null) { incomplete.Add(field.Name); } }
                else if (field.Kind == QueryFieldKind.Boolean)
                { value = bool.TryParse(text, out var flag) ? flag : null; if (text is not null && value is null) { incomplete.Add(field.Name); } }
                values[field.Name] = value;
            }
            rows.Add(new(rows.Count.ToString(CultureInfo.InvariantCulture), values.ToImmutable(), incomplete.ToImmutable()));
        }
        return new(probe.Id, at, null, false, all.Length > limit && probe.Mode != "First", rows.Count, all.Length <= limit, rows.ToImmutable())
        { PersonalDeclaration = probe.PersonalDeclaration };

        IReadOnlyDictionary<string, string?> ForFilter(IReadOnlyDictionary<string, string?> row)
        {
            var result = new Dictionary<string, string?>(row, StringComparer.OrdinalIgnoreCase);
            foreach (var property in definition.Properties.Where(p => p.CimType.Equals("datetime", StringComparison.OrdinalIgnoreCase)))
                if (result.TryGetValue(property.Name, out var value) && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var time))
                { result[property.Name] = time.UtcDateTime.ToString("yyyyMMddHHmmss.ffffff'+000'", CultureInfo.InvariantCulture); }
            return result;
        }
    }
}
