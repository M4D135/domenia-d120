namespace Domenia.Core.Queries;

/// <summary>Only a successful, qualified hardware identity fact can outlive the normal probe TTL.</summary>
internal static class QueryIdentityCache
{
    internal static bool Qualified(DirectoryComputer computer, ProbeReading reading, DateTimeOffset now)
    {
        if (!Accueil.CollectionCachePolicy.IdentityFact(reading.ProbeId)
            || reading.Identity is not { } identity || !identity.Matches(computer)
            || string.IsNullOrWhiteSpace(identity.Sid) || string.IsNullOrWhiteSpace(identity.Host) || string.IsNullOrWhiteSpace(identity.Account)
            || reading.CheckedAt is not { } at || at < computer.WhenCreated || at > now.AddMinutes(1)
            || reading.Error is not null || reading.Skipped || reading.Truncated || reading.PersonalDeclaration is not null
            || reading.Instances.IsDefaultOrEmpty || reading.Instances.Length != 1 || !reading.Instances[0].Incomplete.IsEmpty) return false;
        var probe = QueryProbeCatalog.Find(reading.ProbeId)!;
        var values = QueryProbeCatalog.Values(probe, reading, now);
        return values.Count == 1 && values[0] is string value && !string.IsNullOrWhiteSpace(value)
            && !value.Trim().Equals("unknown", StringComparison.OrdinalIgnoreCase)
            && !value.Trim().Equals("not specified", StringComparison.OrdinalIgnoreCase)
            && !value.Trim().Equals("to be filled by o.e.m.", StringComparison.OrdinalIgnoreCase);
    }
}
