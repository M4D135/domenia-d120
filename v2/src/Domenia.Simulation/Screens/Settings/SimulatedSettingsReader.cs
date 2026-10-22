using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Reads of the Paramètres screen in simulation (docs/PLATFORM.md § 4): the fictitious local base of
/// <see cref="SimulatedLocalStore"/> and the facts of the simulation. Memory only; realistic and cancellable delays of their
/// own sub-sequences (« latency/screen/settings/… »), none with <see cref="SimulationLatency.None"/>.
/// </summary>
public sealed class SimulatedSettingsReader : ISettingsReader
{
    private readonly SimulatedDirectorySource source;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedSettingsReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public async Task<LocalStoreSnapshot> LocalStoreAsync(CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("settings/store", 40, 120, cancellationToken).ConfigureAwait(false);
        return SimulatedLocalStore.For(source).Snapshot();
    }

    public async Task<LocalStoreSnapshot> MeasureAsync(CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("settings/measure", 380, 760, cancellationToken).ConfigureAwait(false);
        return SimulatedLocalStore.For(source).Measure(source.Clock.GetUtcNow());
    }

    public async Task<LocalStoreSnapshot> CheckIntegrityAsync(CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("settings/integrity", 420, 880, cancellationToken).ConfigureAwait(false);
        return SimulatedLocalStore.For(source).CheckIntegrity(source.Clock.GetUtcNow());
    }

    public Task<SimulationFacts?> SimulationAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var world = source.World;
        var directory = source.CurrentDirectory;
        var facts = new SimulationFacts(
            source.Options.Seed,
            world.Reference,
            world.TimeZone.Id,
            world.Weekend,
            source.Options.Latency == SimulationLatency.Realistic,
            directory.Domain.DnsName,
            world.Session.Controller?.DnsName ?? "",
            world.Session.Account.Login,
            directory.OrganizationalUnits.Length,
            directory.Users.Length,
            directory.Computers.Length,
            directory.Groups.Length,
            source.Overlay.Version,
            source.Overlay.ChangedObjects,
            source.PresenceRound,
            world.ComputeFingerprint());
        return Task.FromResult<SimulationFacts?>(facts);
    }
}
