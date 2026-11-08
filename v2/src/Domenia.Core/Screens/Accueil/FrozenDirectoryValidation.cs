using System.Collections.Immutable;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

/// <summary>Validation is reusable only for the same immutable directory picture and exact frozen identities.
/// Session/store admission is checked by the caller on every use, even on a local validation hit.</summary>
internal sealed class FrozenDirectoryValidation
{
    private readonly object gate = new();
    private DirectorySnapshot? confirmed;
    private ImmutableDictionary<Guid, QueryComputerIdentity>? confirmedIdentities;

    /// <returns>True when this picture required a full validation; false when that exact picture was already confirmed.</returns>
    internal bool Confirm(DirectorySnapshot snapshot, ImmutableDictionary<Guid, QueryComputerIdentity> identities)
    {
        lock (gate)
        {
            if (ReferenceEquals(snapshot, confirmed) && ReferenceEquals(identities, confirmedIdentities)) { return false; }
            var actual = snapshot.Computers.ToDictionary(c => c.ObjectGuid);
            if (identities.Any(p => !actual.TryGetValue(p.Key, out var pc) || !p.Value.Matches(pc)))
            { throw new DomeniaOperationException(AccueilService.RefreshScopeChanged, "Identité, session ou base modifiée depuis le plan ; préparez une nouvelle actualisation."); }
            confirmed = snapshot;
            confirmedIdentities = identities;
            return true;
        }
    }
}
