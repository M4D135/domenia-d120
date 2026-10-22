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
/// <see cref="HistoryScope"/> is the working OU the workstation figures of <see cref="History"/> were recorded for (null:
/// unknown, taken as the current scope); for another OU those figures are left out, never shown as if they were its own.
/// </summary>
public sealed record DirectoryState(
    DirectorySnapshot Directory,
    FleetObservations Observations,
    ImmutableArray<DailyFigures> History,
    ImmutableArray<JournalEntry> Journal,
    ScopeSelection? HistoryScope = null);

/// <summary>Read-only access to a directory and to the local observations of its workstations. No write method, by design.</summary>
public interface IDirectorySource
{
    DirectorySourceKind Kind { get; }

    /// <summary>Session state in memory; never reads the network.</summary>
    Task<SessionSnapshot> GetSessionAsync(CancellationToken cancellationToken);

    /// <summary>Explicit connection gesture; the simulation already has its local session.</summary>
    Task<SessionSnapshot> ConnectAsync(CancellationToken cancellationToken) => GetSessionAsync(cancellationToken);

    /// <summary>Last known state (local base in directory mode).</summary>
    Task<DirectoryState> ReadLocalAsync(CancellationToken cancellationToken);

    /// <summary>
    /// Measures one family again on an explicit request (network read in directory mode, bounded to the working OU
    /// <paramref name="scope"/>; <see cref="MeasureFamily.LocalComputation"/> only reloads the last known state). Presence and
    /// inventory refuse the domain root or a missing scope (scope.tooWide). Calls are made one after another.
    /// </summary>
    Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken cancellationToken);
}

/// <summary>Scope guard shared by every source: workstation measures never run on the whole domain.</summary>
public static class ScopeRules
{
    public static void EnsureNotDomainRoot(ScopeSelection? scope, string rootDn)
    {
        if (scope is null || IsDomainRoot(scope, rootDn))
        {
            throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, DomeniaErrors.ScopeTooWideMessage);
        }
    }

    /// <summary>True when the scope is the whole domain (malformed DNs are never the root).</summary>
    public static bool IsDomainRoot(ScopeSelection scope, string? rootDn)
    {
        ArgumentNullException.ThrowIfNull(scope);
        return rootDn is not null && SameDn(scope.Dn, rootDn);
    }

    /// <summary>Same branch: same DN (escaping and case ignored) and same depth choice.</summary>
    public static bool SameScope(ScopeSelection? left, ScopeSelection? right) =>
        left is not null && right is not null && left.Subtree == right.Subtree && SameDn(left.Dn, right.Dn);

    /// <summary>True when the object DN lies in the scope (direct child only unless the scope includes sub-OUs).</summary>
    public static bool Contains(ScopeSelection scope, string objectDn)
    {
        ArgumentNullException.ThrowIfNull(scope);
        try
        {
            return DistinguishedName.IsWithin(objectDn, scope.Dn, scope.Subtree);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static bool SameDn(string left, string right)
    {
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
