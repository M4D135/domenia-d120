using System.Collections.Immutable;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Core.Queries;

/// <summary>Families a collection reads again (« Collecter seulement les données manquantes », « Actualiser ce poste »).</summary>
public sealed record QueryMeasureRequest(ImmutableArray<Guid> Computers, bool Presence, bool Console, bool Inventory, ImmutableArray<string> Probes);

/// <summary>Outcome of one collection: objects read, answered, failed; the dataset version after it.</summary>
public sealed record QueryMeasureResult(int Requested, int Answered, int Failed, int SkippedDisabled, long Version, DateTimeOffset At);

/// <summary>
/// Read interface of the query workshop. <see cref="DatasetAsync"/> reads the last known state (local base in directory mode,
/// the fictitious directory in simulation): never the network. <see cref="MeasureAsync"/> is the explicit collection of the
/// missing measures (network read in directory mode, bounded to the planned workstations, after the operator's gesture).
/// </summary>
public interface IQueryWorkshopReader : IScreenReader
{
    Task<QueryDataset> DatasetAsync(CancellationToken cancellationToken);

    Task<QueryMeasureResult> MeasureAsync(QueryMeasureRequest request, CancellationToken cancellationToken);
}

public sealed record WmiNamespaceList(string Computer, string Namespace, ImmutableArray<string> Children, bool Truncated, DateTimeOffset ReadAt);

public sealed record WmiClassInfo(string Name, int Properties, int Keys, string? Remark);

public sealed record WmiClassList(string Computer, string Namespace, string? Filter, ImmutableArray<WmiClassInfo> Classes, bool Truncated, DateTimeOffset ReadAt);

public sealed record WmiPropertyInfo(string Name, string CimType, bool Key, string Unit, string Description);

public sealed record WmiClassSchema(string Computer, string Namespace, string ClassName, string Description, ImmutableArray<WmiPropertyInfo> Properties, ImmutableArray<string> SecretsLeftOut, DateTimeOffset ReadAt);

/// <summary>One instance read by an advanced SELECT: identity and the requested values as text (never a secret property).</summary>
public sealed record WmiInstanceRow(string Id, ImmutableDictionary<string, string?> Values);

public sealed record WmiSelectResult(
    string Computer,
    Guid ComputerGuid,
    string Namespace,
    string ClassName,
    string CanonicalQuery,
    ImmutableArray<string> Columns,
    ImmutableArray<WmiInstanceRow> Rows,
    bool Truncated,
    long Count,
    DateTimeOffset ReadAt,
    string RequestKey,
    string Note);

/// <summary>
/// Advanced WMI reads on one workstation (Domenia 1 Domenia-QuerySchema): namespaces one level at a time, class definitions,
/// one class schema, a parsed SELECT, a declared relation. Network reads in directory mode, each after an explicit gesture,
/// bounded (500 namespaces, 2 000 classes, 1 024 properties, 2 000 instances); served by a fictitious catalog in simulation.
/// </summary>
public interface IQueryWmiReader : IScreenReader
{
    Task<WmiNamespaceList> NamespacesAsync(Guid computer, string ns, CancellationToken cancellationToken);

    Task<WmiClassList> ClassesAsync(Guid computer, string ns, string? filter, CancellationToken cancellationToken);

    Task<WmiClassSchema> SchemaAsync(Guid computer, string ns, string className, CancellationToken cancellationToken);

    Task<WmiSelectResult> SelectAsync(Guid computer, string ns, WqlSelect select, int limit, CancellationToken cancellationToken);

    Task<WmiSelectResult> RelatedAsync(Guid computer, string ns, string sourceClass, WmiInstanceRow source, WmiRelationPreset preset, CancellationToken cancellationToken);
}
