using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// One read of a list: the plan of the text (or of the OU, or of a view), the type, the base and depth, and the keyset
/// continuation (rows in name order after <see cref="After"/>, those already given in <see cref="Known"/> skipped).
/// </summary>
public sealed record SearchQuery(
    SearchListKind Kind,
    SearchPlan Plan,
    SearchTypeFilter Type,
    string BaseDn,
    bool Subtree,
    string? ViewId,
    string? After,
    IReadOnlySet<string> Known,
    int Take);

/// <summary>
/// Rows of one read, in name order, and whether more rows match (<see cref="More"/>: one row more than asked was found).
/// <see cref="LastKey"/> is the folded name of the last row (cursor of the next page).
/// </summary>
public sealed record SearchPage(ImmutableArray<SearchRow> Rows, bool More, string? LastKey, DateTimeOffset ReadAt, string SourceLabel);

/// <summary>
/// Read interface of the search screen (docs/ops/rechercher.md). Served by the simulated directory now (Domenia.Simulation,
/// Screens/SimulatedSearchReader.cs), by Active Directory and the local base later (vague 3, § « Mode annuaire »). Read only,
/// by construction: no method writes anything; survey and diagnostic reads measure, they never change a workstation.
/// </summary>
public interface ISearchReader : IScreenReader
{
    /// <summary>Global search, OU list or ready-made view (network read in directory mode, after the operator’s gesture).</summary>
    Task<SearchPage> FindAsync(SearchQuery query, CancellationToken cancellationToken);

    /// <summary>
    /// Containers of the domain root (CN=Users, CN=Computers, system containers). With <paramref name="counts"/>, the objects
    /// they hold are counted too (one more read per container in directory mode: only on an explicit request); without, the
    /// count is -1 (unknown).
    /// </summary>
    Task<ImmutableArray<SearchContainer>> ContainersAsync(bool counts, CancellationToken cancellationToken);

    /// <summary>
    /// Rows of the local base for a simple search (RCH-055), shown while the directory read goes on: marked with their
    /// source and observation date, replaced by the fresh rows (no network).
    /// </summary>
    Task<SearchPage> CachedAsync(SearchQuery query, CancellationToken cancellationToken);

    /// <summary>Workstations whose stored readings carry this IPv4 or MAC address (local base, no network).</summary>
    Task<SearchPage> FindAddressAsync(SearchAddress address, int limit, CancellationToken cancellationToken);

    /// <summary>Local query on the workstations of an OU (local base, no network), with the verdict of each one.</summary>
    Task<(SearchPage Page, SearchVerdictTotals Totals)> LocalQueryAsync(string queryId, string baseDn, bool subtree, string verdict, int limit, CancellationToken cancellationToken);

    /// <summary>Objects of the local base whose name, account or display name starts with or contains the text (no network).</summary>
    Task<ImmutableArray<SearchSuggestion>> SuggestAsync(string text, SearchTypeFilter type, int max, CancellationToken cancellationToken);

    /// <summary>Stored fiche of one object (local base), or null when the object is not known locally.</summary>
    Task<SearchPreview?> PreviewAsync(Guid id, CancellationToken cancellationToken);

    /// <summary>Two to eight objects of one kind side by side (local base); objects unknown locally are left out.</summary>
    Task<SearchComparison> CompareAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken);

    /// <summary>Rows of these objects as stored locally (no network): targets of a survey, rows to restore.</summary>
    Task<ImmutableArray<SearchRow>> LocalRowsAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken);

    /// <summary>These objects read again (network read in directory mode): revalidation of a list, after a survey.</summary>
    Task<ImmutableArray<SearchRow>> RereadAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken);

    /// <summary>Reverse DNS of an IPv4 (network read, explicit gesture only); null when no name is found.</summary>
    Task<string?> ReverseDnsAsync(string ipv4, CancellationToken cancellationToken);

    /// <summary>
    /// One workstation of a survey: echo, then console user and inventory per mode (network read, one attempt). A light
    /// inventory younger than <paramref name="inventoryReuse"/> is kept instead of a CIM request (outcome InventoryReused).
    /// </summary>
    Task<SurveyOutcome> ProbeAsync(Guid id, SurveyMode mode, int run, TimeSpan inventoryReuse, CancellationToken cancellationToken);

    /// <summary>
    /// Saved searches of Domenia 1, read once for their takeover as OU favourites (RCH-004): its settings file with the local
    /// base in directory mode, a fixed sample in simulation. Never written, empty when there is none.
    /// </summary>
    Task<ImmutableArray<SearchLegacySaved>> LegacySavedSearchesAsync(CancellationToken cancellationToken);

    /// <summary>Network diagnostic of one workstation: echo then TCP ports 445, 135, 5985, 5986 (network read, no account sent).</summary>
    Task<NetworkDiagnosticLine> DiagnoseAsync(Guid id, CancellationToken cancellationToken);
}
