using System.Collections.Immutable;

namespace Domenia.Core.Queries;

/// <summary>GUID-bound query readings. A failed attempt replaces its verdict, never inventing a zero count.</summary>
public sealed record QueryComputerReadings(Guid Computer, string Dn, DateTimeOffset Created,
    ImmutableArray<ProbeReading> Probes, ImmutableArray<StoredWmiResult> Details);

public sealed record QueryStoredReadings(long Revision, ImmutableArray<QueryComputerReadings> Computers)
{
    public static QueryStoredReadings Empty { get; } = new(0, []);
}

public interface IQueryResultsStore
{
    Task<QueryStoredReadings> ReadQueryResultsAsync(CancellationToken cancellationToken);
    Task<QueryStoredReadings> SaveQueryResultsAsync(QueryComputerReadings readings, CancellationToken cancellationToken);
}

/// <summary>Optional local capabilities of a directory source; accessing them never contacts a server.</summary>
public interface IQueryLocalSource
{
    IQueryLibraryStore? QueryLibraryStore { get; }
}
