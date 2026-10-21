using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// What drives the presence rounds: a fixed rank per active workstation of the working OU, the probes always in error and
/// the workstations that never answer the ping (inactive in the directory, or ICMP filtered).
/// </summary>
public sealed record PresenceModel(
    ulong Seed,
    int Target,
    ImmutableArray<Guid> Workstations,
    ImmutableArray<int> Ranks,
    ImmutableHashSet<Guid> ErrorProbes,
    ImmutableHashSet<Guid> NeverAnswer);

/// <summary>The generated fictitious world: directory, initial observations (round 0), daily history, journal and session.</summary>
public sealed record SimulatedWorld(
    DateTimeOffset Reference,
    TimeZoneInfo TimeZone,
    bool Weekend,
    DirectorySnapshot Directory,
    FleetObservations Observations,
    ImmutableArray<DailyFigures> History,
    ImmutableArray<JournalEntry> Journal,
    SessionSnapshot Session,
    PresenceModel Presence)
{
    private static readonly JsonSerializerOptions FingerprintJson = new() { WriteIndented = false };

    public DirectoryState InitialState => new(Directory, Observations, History, Journal);

    /// <summary>SHA-256 of the canonical JSON of the generated data (declaration order, arrays in generation order).</summary>
    public string ComputeFingerprint()
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new { Directory, Observations, History, Journal }, FingerprintJson);
        return Convert.ToHexStringLower(SHA256.HashData(bytes));
    }
}

/// <summary>Presence rounds after the initial one (docs/SIMULATION.md § 5.3). Pure.</summary>
public static class PresenceRounds
{
    public static FleetObservations Apply(PresenceModel model, FleetObservations previous, int round, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(model);
        ArgumentNullException.ThrowIfNull(previous);
        ArgumentOutOfRangeException.ThrowIfLessThan(round, 1);
        var random = new SeededRandom(model.Seed).Fork("presence/" + round.ToString(System.Globalization.CultureInfo.InvariantCulture));
        var spread = random.Next(-SimulationProfile.RoundSpread, SimulationProfile.RoundSpread + 1);
        var candidates = new List<(Guid Id, int Score, int Rank)>(model.Workstations.Length);
        for (var i = 0; i < model.Workstations.Length; i++)
        {
            var id = model.Workstations[i];
            if (model.ErrorProbes.Contains(id) || model.NeverAnswer.Contains(id))
            {
                continue;
            }
            candidates.Add((id, model.Ranks[i] + random.Next(SimulationProfile.RoundJitter), model.Ranks[i]));
        }
        var count = Math.Clamp(model.Target + spread, 0, candidates.Count);
        var responders = candidates.OrderBy(c => c.Score).ThenBy(c => c.Rank).Take(count).Select(c => c.Id).ToHashSet();
        var probed = model.Workstations.ToHashSet();
        var updated = previous.Workstations.Select(observation =>
        {
            var id = observation.ComputerGuid;
            if (!probed.Contains(id) || model.ErrorProbes.Contains(id))
            {
                // A probe in error keeps its previous reading.
                return observation;
            }
            var presence = responders.Contains(id)
                ? new PresenceMeasure(MeasureState.Known, true, at, at)
                : new PresenceMeasure(MeasureState.Known, false, at, observation.Presence.LastOnlineAt);
            return observation with { Presence = presence };
        }).ToImmutableArray();
        return new FleetObservations(at, updated);
    }
}
