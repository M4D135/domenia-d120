namespace Domenia.Core;

/// <summary>
/// Read interface of the schema screen (docs/ops/schema.md). Served by the simulated directory now
/// (Domenia.Simulation/Screens/Schema), by Active Directory later (vague 3: the classSchema and attributeSchema entries of the
/// schema naming context of the session controller, « Mode annuaire »). Read only by construction: the schema is never
/// changed, no object value is ever read.
/// </summary>
public interface ISchemaReader : IScreenReader
{
    /// <summary>
    /// Reads the schema definitions once, bounded by <paramref name="limits"/> (one entry more than the limit proves the limit
    /// and marks the read truncated). Network read in directory mode, after the operator’s gesture only.
    /// </summary>
    Task<SchemaReadResult> ReadDefinitionsAsync(SchemaReadLimits limits, IProgress<SchemaReadStage>? progress, CancellationToken cancellationToken);
}
