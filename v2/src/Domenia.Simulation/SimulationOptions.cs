namespace Domenia.Simulation;

public enum SimulationLatency
{
    /// <summary>Realistic waits: 120 to 250 ms for a local read, 400 to 900 ms for a refresh.</summary>
    Realistic,

    /// <summary>No wait (tests).</summary>
    None,
}

/// <summary>Seed and latency of the simulation. Same seed, reference date and time zone give the same directory.</summary>
public sealed record SimulationOptions(ulong Seed, SimulationLatency Latency)
{
    public const ulong DefaultSeed = 20261021;

    public static SimulationOptions Default { get; } = new(DefaultSeed, SimulationLatency.Realistic);
}
