using System.Collections.Immutable;

namespace Domenia.Core;

public enum DirectorySourceKind
{
    Simulation,
    ActiveDirectory,
}

/// <summary>Measure families of the home page (docs/OPERATIONS.md § 6).</summary>
public enum MeasureFamily
{
    Directory,
    Presence,
    Inventory,
    /// <summary>Recomputation from the last known state; never reads the network, in any mode.</summary>
    LocalComputation,
}

/// <summary>Working branch of the workstation widgets.</summary>
public sealed record ScopeSelection(string Dn, string Label, bool Subtree);

/// <summary>One line of the operations journal.</summary>
public sealed record JournalEntry(DateTimeOffset At, string Label, Tone Tone);

/// <summary>
/// Last known state of a source: directory snapshot, local observations, daily history and the journal kept by the source
/// (local base, or the fictitious journal of the simulation). Session operations are added by <see cref="DashboardService"/>.
/// </summary>
public sealed record DirectoryState(
    DirectorySnapshot Directory,
    FleetObservations Observations,
    ImmutableArray<DailyFigures> History,
    ImmutableArray<JournalEntry> Journal);

/// <summary>Read-only access to a directory and to the local observations of its workstations. No write method, by design.</summary>
public interface IDirectorySource
{
    DirectorySourceKind Kind { get; }

    /// <summary>Session state in memory; never reads the network.</summary>
    Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken);

    /// <summary>Last known state (local base in directory mode).</summary>
    Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken);

    /// <summary>
    /// Measures one family again on an explicit request (network read in directory mode, bounded to the working OU;
    /// <see cref="MeasureFamily.LocalComputation"/> only reloads the last known state). Calls are made one after another.
    /// </summary>
    Task<DirectoryState> RefreshAsync(MeasureFamily family, CancellationToken cancellationToken);
}

/// <summary>Scope guard shared by every source: workstation measures never run on the whole domain.</summary>
public static class ScopeRules
{
    public static void EnsureNotDomainRoot(ScopeSelection? scope, string rootDn)
    {
        if (scope is null || DistinguishedName.AreEqual(scope.Dn, rootDn))
        {
            throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, DomeniaErrors.ScopeTooWideMessage);
        }
    }
}
