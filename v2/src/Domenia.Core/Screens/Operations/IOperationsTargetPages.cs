using System.Collections.Immutable;
using Domenia.Core.Queries;

namespace Domenia.Core;

/// <summary>
/// Immutable local campaign identities, stored separately from the small progress document.
/// Implementations verify bounded pages and their manifest before returning a snapshot. References
/// are content fingerprints, never file names, remote addresses, or instructions to replay work.
/// </summary>
public interface IOperationsTargetPages
{
    string WriteHome(ImmutableArray<QueryComputerIdentity> targets);
    ImmutableArray<QueryComputerIdentity> ReadHome(string fingerprint, int count);
    string WriteSurvey(ImmutableArray<SurveyTarget> targets);
    ImmutableArray<SurveyTarget> ReadSurvey(string fingerprint, int count);
}
