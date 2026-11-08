using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Local index of the Assistance screen (docs/ops/assistance.md § 10): the subject search, the suggestions, the computers of a
/// pasted list, the incidents the source recorded and the rows of an offline dossier. Served from memory in simulation and by
/// the local base in directory mode: it never touches the network nor binds to the directory, so the operations it serves
/// (LocalRead) may run when the page loads. Same split as <see cref="IOrganizationalUnitIndex"/> and
/// <see cref="IDirectoryTreeReader"/>: what reads the network lives in <see cref="IAssistanceReader"/>.
/// </summary>
public interface IAssistanceIndex : IScreenReader
{
    /// <summary>Accounts and workstations whose name, login, display name or DNS name holds the text, <paramref name="limit"/> at most.</summary>
    Task<ImmutableArray<SubjectHit>> SearchAsync(string text, int limit, CancellationToken cancellationToken);

    /// <summary>Subjects worth a look (locked or expired accounts, workstations of the working OU to watch), from the local data only.</summary>
    Task<ImmutableArray<SubjectSuggestion>> SuggestionsAsync(ScopeSelection? scope, CancellationToken cancellationToken);

    /// <summary>
    /// The workstations whose name, account name (with or without its « $ ») or DNS name is exactly one of
    /// <paramref name="names"/> (case ignored), one entry per name that matched, in the order of the names; a name that matches
    /// nothing is left out (the caller lists them as unknown). Never a partial match.
    /// </summary>
    Task<ImmutableArray<NamedComputer>> ComputersNamedAsync(IReadOnlyList<string> names, CancellationToken cancellationToken);

    /// <summary>Warnings and errors the source recorded earlier in the session (the session journal itself is read by the engine).</summary>
    Task<ImmutableArray<RawIncident>> SessionIncidentsAsync(CancellationToken cancellationToken);

    /// <summary>Rows of the local data for an offline dossier (read only, no network, no directory bind).</summary>
    Task<DossierData> DossierDataAsync(DossierRequest request, CancellationToken cancellationToken);
}

/// <summary>
/// Reads of the Assistance screen that leave the workstation in directory mode (the controller, a workstation), always after
/// the operator's gesture: the fresh read of a subject, finding a pinned object again by its GUID and the single read of a
/// recipe step. Served by the simulated directory now, by Domenia.Ad later (wave 3). Read only by construction.
/// </summary>
public interface IAssistanceReader : IScreenReader
{
    /// <summary>Fresh read of one account or workstation (the controller in directory mode, after the operator's gesture); null when absent.</summary>
    Task<SubjectRecord?> ReadSubjectAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Finds an object again by its GUID, wherever it was moved since it was pinned; null when it no longer exists.</summary>
    Task<SubjectRecord?> LocateAsync(Guid id, CancellationToken cancellationToken);

    /// <summary>
    /// The single read of one step of a recipe, from the closed list (<see cref="AssistanceRecipes.Actions"/>). A refusal by the
    /// target raises <see cref="DomeniaOperationException"/> with <see cref="AssistanceErrors.ReadRefused"/>; nothing is retried.
    /// </summary>
    Task<StepReading> RunStepAsync(AssistanceAction action, SubjectRecord subject, CancellationToken cancellationToken);
}
