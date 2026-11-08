using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Schema read of the simulation (docs/ops/schema.md § 14): the definitions of <see cref="SimulatedSchemaDefinitions"/>, for
/// the domain and the controller of the fictitious session, after realistic and cancellable delays (« latency/screen/schema/… »:
/// schema context, attributes, classes). The limits apply as on a real controller: one entry more than the limit proves the
/// limit and marks the read truncated. No network, no disk.
/// </summary>
public sealed class SimulatedSchemaReader : ISchemaReader
{
    private readonly SimulatedDirectorySource source;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedSchemaReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public async Task<SchemaReadResult> ReadDefinitionsAsync(SchemaReadLimits limits, IProgress<SchemaReadStage>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(limits);
        var world = source.World;
        var domain = world.Directory.Domain;
        progress?.Report(SchemaReadStage.Context);
        await source.SimulateScreenLatencyAsync("schema/context", 80, 200, cancellationToken).ConfigureAwait(false);
        progress?.Report(SchemaReadStage.Attributes);
        await source.SimulateScreenLatencyAsync("schema/attributes", 420, 900, cancellationToken).ConfigureAwait(false);
        var (attributes, attributesCut) = Bounded(SimulatedSchemaDefinitions.Attributes, limits.MaxAttributes);
        progress?.Report(SchemaReadStage.Classes);
        await source.SimulateScreenLatencyAsync("schema/classes", 220, 560, cancellationToken).ConfigureAwait(false);
        var (classes, classesCut) = Bounded(SimulatedSchemaDefinitions.Classes, limits.MaxClasses);
        // Duration reported for the read on the fictitious controller: drawn from the screen stream, never measured.
        var duration = source.ScreenStream("schema").Fork("duration").Next(1900, 3600);
        var controller = world.Session.Controller?.DnsName ?? domain.Controllers.FirstOrDefault()?.DnsName ?? "DC01." + domain.DnsName;
        return new SchemaReadResult(
            attributes, classes, controller, source.Clock.GetUtcNow(), attributesCut || classesCut, duration, domain.RootDn,
            "CN=Schema,CN=Configuration," + domain.RootDn);
    }

    private static (ImmutableArray<T> Items, bool Truncated) Bounded<T>(ImmutableArray<T> all, int limit) =>
        all.Length > limit ? ([.. all.Take(limit)], true) : (all, false);
}
