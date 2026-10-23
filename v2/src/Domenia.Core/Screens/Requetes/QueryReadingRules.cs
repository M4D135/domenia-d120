using System.Collections.Immutable;

namespace Domenia.Core.Queries;

public static class QueryReadingRules
{
    public static QueryComputerReadings Merge(QueryComputerReadings? old, QueryComputerReadings next)
    {
        if (old is null || old.Computer != next.Computer || old.Created != next.Created
            || !DistinguishedName.AreEqual(old.Dn, next.Dn)) { return next; }
        var probes = old.Probes.ToDictionary(p => p.ProbeId, StringComparer.Ordinal);
        foreach (var p in next.Probes) { if (!probes.TryGetValue(p.ProbeId, out var prior) || prior.CheckedAt <= p.CheckedAt) { probes[p.ProbeId] = p; } }
        var details = old.Details.ToDictionary(p => p.RequestKey, StringComparer.Ordinal);
        foreach (var d in next.Details) { if (!details.TryGetValue(d.RequestKey, out var prior) || prior.At <= d.At) { details[d.RequestKey] = d; } }
        return next with { Probes = [.. probes.Values.OrderBy(p => p.ProbeId, StringComparer.Ordinal)],
            Details = [.. details.Values.OrderByDescending(d => d.At).ThenBy(d => d.RequestKey, StringComparer.Ordinal).Take(512)] };
    }

    public static void Validate(QueryComputerReadings value, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (value.Computer == Guid.Empty || value.Created == DateTimeOffset.MinValue || value.Created > now || value.Dn.Length is 0 or > 4096
            || value.Probes.IsDefault || value.Details.IsDefault || value.Probes.Length > QueryProbeCatalog.All.Length || value.Details.Length > 512
            || value.Probes.Select(p => p.ProbeId).Distinct(StringComparer.Ordinal).Count() != value.Probes.Length
            || value.Details.Select(p => p.RequestKey).Distinct(StringComparer.Ordinal).Count() != value.Details.Length)
        { throw new InvalidDataException("Identité ou collection de requêtes invalide."); }
        _ = DistinguishedName.Parse(value.Dn);
        foreach (var probe in value.Probes)
        {
            var definition = QueryProbeCatalog.Find(probe.ProbeId);
            if (definition is null || probe.CheckedAt is not { } at || at < value.Created || at > now.AddMinutes(2)
                || probe.Instances.IsDefault || probe.Instances.Length > 2000 || probe.Error?.Length > 2048
                || probe.Count < 0 || probe.CountComplete && (probe.Count != probe.Instances.Length || probe.Truncated || probe.Error is not null || probe.Skipped)
                || probe.Instances.Any(i => i.Id.Length > 4096 || i.Values.Count > 64 || i.Values.Keys.Any(p => !definition.Properties.Contains(p, StringComparer.OrdinalIgnoreCase))
                    || i.Values.Values.Any(v => !Scalar(v)) || i.Incomplete.IsDefault
                    || i.Incomplete.Any(p => !definition.Properties.Contains(p, StringComparer.OrdinalIgnoreCase))))
            { throw new InvalidDataException("Sonde de requête hors contrat."); }
        }
        foreach (var detail in value.Details)
        {
            if (detail.RequestKey.Length != 64 || !detail.RequestKey.All(char.IsAsciiHexDigit) || detail.At is not { } at || at < value.Created || at > now.AddMinutes(2)
                || detail.StoredCount is < 0 or > 2000 || detail.CountComplete && (!detail.Success || detail.Truncated))
            { throw new InvalidDataException("Résultat SELECT hors contrat."); }
        }
    }

    private static bool Scalar(object? value) => value switch
    {
        null or bool or byte or sbyte or short or ushort or int or uint or long or ulong or decimal => true,
        float number => float.IsFinite(number), double number => double.IsFinite(number),
        string text => text.Length <= 4096,
        Array items => items.Rank == 1 && items.Length <= 256 && items.Cast<object?>().All(v => v is not Array && Scalar(v)),
        System.Text.Json.JsonElement json => json.ValueKind switch
        {
            System.Text.Json.JsonValueKind.Null or System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False => true,
            System.Text.Json.JsonValueKind.String => json.GetString()!.Length <= 4096,
            System.Text.Json.JsonValueKind.Number => json.TryGetDecimal(out _),
            System.Text.Json.JsonValueKind.Array => json.GetArrayLength() <= 256 && json.EnumerateArray().All(v => v.ValueKind != System.Text.Json.JsonValueKind.Array && Scalar(v)),
            _ => false,
        },
        _ => false,
    };
}
