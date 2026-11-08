using System.Collections.Immutable;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Core.Queries;

/// <summary>The exact missing sources of one target in a confirmed plan, under the request's single total budget.</summary>
public sealed record QueryMeasureMask(bool Presence, bool Console, bool Inventory, ImmutableArray<string> Probes, ImmutableArray<string> DetailKeys);

/// <summary>
/// Families a collection reads again (« Collecter seulement les données manquantes », « Actualiser ce poste »). <see cref="Details"/>:
/// WMI SELECT saved with a recipe, read again on each workstation (bounded by its own limit; never an arbitrary WQL).
/// </summary>
public sealed record QueryMeasureRequest(ImmutableArray<Guid> Computers, bool Presence, bool Console, bool Inventory, ImmutableArray<string> Probes, ImmutableArray<WmiReadDefinition> Details = default)
{
    /// <summary>The SELECT definitions to read again (empty when none).</summary>
    public ImmutableArray<WmiReadDefinition> DetailReads => Details.IsDefault ? [] : Details;
    public ImmutableDictionary<Guid, QueryComputerIdentity>? ExpectedIdentities { get; init; }
    public long? ExpectedEpoch { get; init; }
    public long? ExpectedAccountVersion { get; init; }
    public long? ExpectedMachineGeneration { get; init; }
    /// <summary>Internal campaign optimization: return counters only, without rebuilding the whole dataset after this
    /// workstation. Version is then 0 and must never be used as a dataset receipt. Bridge commands leave this false.</summary>
    public bool OnlyOutcome { get; init; }
    /// <summary>Set only by a caller that already holds the local collection lease. Never accepted from bridge arguments.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool OwnsCampaign { get; init; }
    public ImmutableArray<Accueil.FrozenProbe> PersonalProbes { get; init; } = [];
    public ImmutableDictionary<Guid, QueryMeasureMask>? TargetMeasures { get; init; }

    public void ValidateTargetMeasures()
    {
        if (TargetMeasures is not { } masks) { return; }
        if (masks.Count != Computers.Length || Computers.Any(id => !masks.ContainsKey(id))
            || masks.Values.Any(m => m is null || !m.Presence && !m.Console && !m.Inventory && m.Probes.IsDefaultOrEmpty && m.DetailKeys.IsDefaultOrEmpty
                || m.Presence && !Presence || m.Console && !Console || m.Inventory && !Inventory
                || m.Probes.IsDefault || m.DetailKeys.IsDefault || m.Probes.Distinct(StringComparer.Ordinal).Count() != m.Probes.Length
                || m.DetailKeys.Distinct(StringComparer.Ordinal).Count() != m.DetailKeys.Length || m.Probes.Any(p => !Probes.Contains(p))
                || m.DetailKeys.Any(key => !DetailReads.Any(d => d.RequestKey == key)))
            || masks.Values.SelectMany(m => m.Probes).Distinct(StringComparer.Ordinal).Count() != Probes.Length
            || masks.Values.SelectMany(m => m.DetailKeys).Distinct(StringComparer.Ordinal).Count() != DetailReads.Length
            || masks.Values.Any(m => m.Presence) != Presence || masks.Values.Any(m => m.Console) != Console || masks.Values.Any(m => m.Inventory) != Inventory)
            throw new QueryDefinitionException("Les sources par cible diffèrent du plan confirmé ; aucune collecte.");
    }

    public QueryMeasureRequest ForComputer(Guid computer)
    {
        if (TargetMeasures is null) { return this; }
        var mask = TargetMeasures.GetValueOrDefault(computer) ?? throw new QueryDefinitionException("Cible absente du plan de mesures.");
        return this with { Computers = [computer], Presence = mask.Presence, Console = mask.Console, Inventory = mask.Inventory, Probes = mask.Probes,
            Details = [.. DetailReads.Where(d => mask.DetailKeys.Contains(d.RequestKey))],
            PersonalProbes = [.. (PersonalProbes.IsDefault ? [] : PersonalProbes).Where(p => mask.Probes.Contains(p.Key))], TargetMeasures = null };
    }
}

/// <summary>Identity selected when an explicit plan is prepared; no later object sharing its GUID may be silently substituted.</summary>
public sealed record QueryComputerIdentity(Guid Guid, string Dn, DateTimeOffset Created, string? Sid, string? Host, string? Account, int UserAccountControl)
{
    public static QueryComputerIdentity Of(DirectoryComputer computer) => new(computer.ObjectGuid, computer.DistinguishedName, computer.WhenCreated, computer.Sid, computer.DnsHostName, computer.SamAccountName, computer.UserAccountControl);
    public bool Matches(DirectoryComputer actual) => actual.ObjectGuid == Guid && actual.WhenCreated == Created && actual.Sid == Sid && actual.UserAccountControl == UserAccountControl
        && DistinguishedName.AreEqual(actual.DistinguishedName, Dn) && string.Equals(actual.DnsHostName, Host, StringComparison.OrdinalIgnoreCase)
        && string.Equals(actual.SamAccountName, Account, StringComparison.OrdinalIgnoreCase);
}

/// <summary>Outcome of one collection: objects read, answered, failed; the dataset version after it.</summary>
public sealed record QueryMeasureResult(int Requested, int Answered, int Failed, int SkippedDisabled, long Version, DateTimeOffset At)
{
    public int NotRead { get; init; }
    public string? StopReason { get; init; }
}

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
