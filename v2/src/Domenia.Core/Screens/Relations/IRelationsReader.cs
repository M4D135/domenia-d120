namespace Domenia.Core;

/// <summary>
/// Perimeter of a detection (Domenia 1 D047): known candidates, a list loaded elsewhere (names or DNs of workstations), or an
/// explicit OU. <see cref="SubjectGuid"/> and <see cref="SubjectLogin"/> are the identity the page showed: the account read
/// again must still be that object with that identifier (Domenia 1 REL-019: recreated or renamed account, stop).
/// </summary>
public sealed record RelationDetectionRequest(string Dn, Guid SubjectGuid, string SubjectLogin, string Scope, string? OuDn, IReadOnlyList<string> Computers, int Limit, bool Kerberos);

/// <summary>Perimeter of a relevé: the priority queue of the working OU, or a list loaded elsewhere (Domenia 1: rows shown in Rechercher).</summary>
public sealed record RelationSweepRequest(int Limit, ScopeSelection Scope, IReadOnlyList<string> Computers);

/// <summary>Text of an import file, sent by the page in parts and joined in memory (never written to disk).</summary>
public sealed record RelationImportRequest(string Id, RelationImportAdapter Adapter, string FileName, string Text);

/// <summary>
/// Read interface of the « Utilisateurs et postes » screen (docs/ops/relations.md). Served by the simulated directory now
/// (Domenia.Simulation, Screens/Relations), by Active Directory and the local base later (wave 3). Read only by construction:
/// associations change only through the write circuit (<see cref="IRelationChangeExecutor"/>, write.execute).
/// <list type="bullet">
/// <item>local reads, no network in any mode: <see cref="OverviewAsync"/>, <see cref="ListAsync"/>, <see cref="SubjectAsync"/>,
/// <see cref="SubjectsAsync"/>, <see cref="JournalAsync"/>, <see cref="ImportPreviewAsync"/>, <see cref="HarvestEstimateAsync"/>,
/// <see cref="SweepPlanAsync"/>, <see cref="PendingAsync"/>, <see cref="ObserveAsync"/> (session memory only);</item>
/// <item>network reads in directory mode, after an explicit gesture and bounded: <see cref="TargetsAsync"/> (LDAP),
/// <see cref="CollectAsync"/> (LDAP and controller journal), <see cref="ProbeAsync"/> (CIM/DCOM of the confirmed workstations
/// only), <see cref="ComputerSessionAsync"/> (CIM/DCOM of one workstation), <see cref="HarvestAsync"/> (controller journal),
/// <see cref="OrphansAsync"/> (LDAP), <see cref="CompareAsync"/> (group paths).</item>
/// </list>
/// </summary>
public interface IRelationsReader : IScreenReader
{
    /// <summary>Figures of the whole store.</summary>
    Task<RelationsOverview> OverviewAsync(CancellationToken cancellationToken);

    /// <summary>Every association, qualified (« Toutes les associations »).</summary>
    Task<RelationList> ListAsync(CancellationToken cancellationToken);

    /// <summary>The relations of one user or workstation, named by DN, sAMAccountName or workstation name (relation.unknown otherwise).</summary>
    Task<RelationSubjectView> SubjectAsync(string reference, CancellationToken cancellationToken);

    /// <summary>Users and workstations of the local index whose name contains the text; suggestions when the text is empty.</summary>
    Task<RelationSubjectMatches> SubjectsAsync(string text, CancellationToken cancellationToken);

    /// <summary>Objects of the opposite type, in the whole domain, by name, identifier or DNS name (2 characters at least, 50 results).</summary>
    Task<RelationTargetSearch> TargetsAsync(string subjectDn, string text, CancellationToken cancellationToken);

    /// <summary>Phase 1 of a detection: account read again, known associations, AD clues, optional Kerberos clues, then the plan.</summary>
    Task<RelationDetection> CollectAsync(RelationDetectionRequest request, CancellationToken cancellationToken);

    /// <summary>
    /// Phase 2: console reads of the workstations of a confirmed plan only. <paramref name="stop"/> ends the probe early with a
    /// declared partial result; <paramref name="cancellationToken"/> is the closing of the application.
    /// </summary>
    Task<RelationDetection> ProbeAsync(string planId, IProgress<RelationProbeProgress>? progress, CancellationToken stop, CancellationToken cancellationToken);

    /// <summary>« Lire la session de ce poste »: the console account of one workstation and its identity check.</summary>
    Task<RelationComputerReading> ComputerSessionAsync(string dn, CancellationToken cancellationToken);

    /// <summary>Impact of a harvest of the controller journal, to confirm before it runs.</summary>
    Task<RelationHarvestEstimate> HarvestEstimateAsync(int days, int maxEvents, CancellationToken cancellationToken);

    /// <summary>Harvest of the controller journal (4768, 4769, 4624) confirmed by <paramref name="estimateId"/>.</summary>
    Task<RelationHarvest> HarvestAsync(string estimateId, CancellationToken cancellationToken);

    /// <summary>The local journal of the relations and every removal that can still be restored.</summary>
    Task<RelationJournal> JournalAsync(CancellationToken cancellationToken);

    /// <summary>Preview of an import: every record with its decision, checked against the local index; nothing written.</summary>
    Task<RelationImportPreview> ImportPreviewAsync(RelationImportRequest request, CancellationToken cancellationToken);

    /// <summary>Links whose user or workstation is no longer found; declared and imported links are never proposed.</summary>
    Task<RelationOrphanCheck> OrphansAsync(CancellationToken cancellationToken);

    /// <summary>Groups and organisation attributes of two users (the second named by identifier, DOMAINE\compte, UPN or DN).</summary>
    Task<UserGroupComparison> CompareAsync(string leftDn, string right, CancellationToken cancellationToken);

    /// <summary>
    /// Incremental relevé: workstations of the working OU never read first, then the oldest readings, bounded; or the workstations
    /// of a list loaded elsewhere (names or DNs, 50 at most), in their order.
    /// </summary>
    Task<RelationDetectionPlan> SweepPlanAsync(RelationSweepRequest request, CancellationToken cancellationToken);

    /// <summary>Observations kept by the engine and not saved yet, by result and by source (saved by batches of 64).</summary>
    Task<RelationPendingObservations> PendingAsync(CancellationToken cancellationToken);

    /// <summary>
    /// Shared service for the other screens (Domenia 1 REL-017, Merge-DomeniaLiveLinkMemory): a console account read elsewhere
    /// joins the observations of the session (« Session uniquement ») when the account is an AD user of the domain with a DN
    /// and the workstation is found; a local account, another domain or a bare name is refused with the reason. Nothing is
    /// saved: the operator saves it through a plan of the write circuit.
    /// </summary>
    Task<RelationObservationReceipt> ObserveAsync(RelationObservationRequest request, CancellationToken cancellationToken);
}
