using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Reads of the Assistance screen (docs/ops/assistance.md), served by the source of the mode: the simulated directory now,
/// Active Directory and the local base with Domenia.Ad (wave 3). Read only by construction: every method reads, none writes.
/// </summary>
public interface IAssistanceReader : IScreenReader
{
    /// <summary>Accounts and workstations whose name, login, display name or DNS name holds the text (local index), <paramref name="limit"/> at most.</summary>
    Task<ImmutableArray<SubjectHit>> SearchAsync(string text, int limit, CancellationToken cancellationToken);

    /// <summary>Subjects worth a look (locked or expired accounts, workstations of the working OU to watch), from the local data only.</summary>
    Task<ImmutableArray<SubjectSuggestion>> SuggestionsAsync(ScopeSelection? scope, CancellationToken cancellationToken);

    /// <summary>Fresh read of one account or workstation (the controller in directory mode, after the operator's gesture); null when absent.</summary>
    Task<SubjectRecord?> ReadSubjectAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Finds an object again by its GUID, wherever it was moved since it was pinned; null when it no longer exists.</summary>
    Task<SubjectRecord?> LocateAsync(Guid id, CancellationToken cancellationToken);

    /// <summary>
    /// The single read of one step of a recipe, from the closed list (<see cref="AssistanceRecipes.Actions"/>). A refusal by the
    /// target raises <see cref="DomeniaOperationException"/> with <see cref="AssistanceErrors.ReadRefused"/>; nothing is retried.
    /// </summary>
    Task<StepReading> RunStepAsync(AssistanceAction action, SubjectRecord subject, CancellationToken cancellationToken);

    /// <summary>Warnings and errors the source recorded earlier in the session (the session journal itself is read by the engine).</summary>
    Task<ImmutableArray<RawIncident>> SessionIncidentsAsync(CancellationToken cancellationToken);

    /// <summary>Rows of the local data for an offline dossier (read only, no network, no directory bind).</summary>
    Task<DossierData> DossierDataAsync(DossierRequest request, CancellationToken cancellationToken);
}
