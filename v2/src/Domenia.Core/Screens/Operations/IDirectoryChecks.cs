using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Directory checks of « Vérifier l’application » in directory mode (Domenia 1 Start-SelfCheck, OPE-007): RootDSE binding, read of
/// the base, one user, one computer and one group searched, first level of the tree, DACL of the base, and in a full check three
/// repeated searches. Read only, bounded (size limits of 1 to 25 objects, 10 s per read), never retried, after the operator's
/// gesture only. Served by Domenia.Ad for the Active Directory source; the simulation answers through
/// <see cref="IOperationsReader.CheckDirectoryAsync"/>, which wins when both exist.
/// </summary>
public interface IDirectoryChecks : IScreenReader
{
    /// <summary>The rows of the directory checks, in the order of Domenia 1; a failed read is a row in error, never an exception.</summary>
    Task<ImmutableArray<CheckRow>> CheckDirectoryAsync(bool full, CancellationToken cancellationToken);
}
