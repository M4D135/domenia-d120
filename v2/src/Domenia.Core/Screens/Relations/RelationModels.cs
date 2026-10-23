using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Nature of the proof behind a user/workstation relation (Domenia 1 Get-DomeniaRelationKind): an assignment declared by an
/// operator, a console or remote session read on the workstation, an old logon read in a journal or a profile, a line of an
/// imported file, a clue (AD attribute, inventory), or an origin that cannot be recognised.
/// </summary>
public enum RelationKind
{
    Assignment,
    Console,
    RemoteSession,
    History,
    Imported,
    Hint,
    Unknown,
}

/// <summary>Explainable qualification shown on a relation (Domenia 1 D043, DS-17): never a percentage.</summary>
public enum RelationBadge
{
    Declared,
    Observed,
    History,
    Imported,
    Hint,
    Contradictory,
    ToCheck,
}

/// <summary>Subject of the relations screen: a user or a workstation (both directions, Domenia 1 D041).</summary>
public enum RelationSubjectKind
{
    User,
    Computer,
}

/// <summary>
/// Whether a stored link belongs to the object shown (Domenia 1 point 9): same GUID, another object that reused the name, or
/// a legacy link without GUID whose identity cannot be checked.
/// </summary>
public enum RelationIdentityMatch
{
    Same,
    Different,
    Unknown,
}

/// <summary>Where a relation lives: in the local store, or only in the memory of the session (observation not saved).</summary>
public enum RelationPersistence
{
    Stored,
    Session,
}

/// <summary>Kind of a line of the local relations journal (Domenia 1 New-DomeniaLinkHistoryEntry).</summary>
public enum RelationJournalAction
{
    Added,
    Removed,
    Restored,
    Refreshed,
    Conflict,
}

/// <summary>
/// One association of the local store (Domenia 1 user_machine_links, with the relation model of D041-D050): one user, one
/// workstation and one nature of proof. The GUIDs decide identity when known; names stay for legacy rows. The store is local to
/// Domenia: Active Directory is never modified by an association. <see cref="BatchId"/> names the import batch that brought the
/// row (Domenia 1 point 138), so an import can be undone after a restart.
/// </summary>
public sealed record StoredRelation(
    string UserLogin,
    Guid? UserGuid,
    string? UserDn,
    string Computer,
    Guid? ComputerGuid,
    string? ComputerDn,
    RelationKind Kind,
    string Source,
    DateTimeOffset? When,
    string? Details,
    bool VerifiedInAd,
    string? Declarant,
    string? BatchId);

/// <summary>One line of the local journal of the relations: what changed, when, by whom, and the association as it was.</summary>
public sealed record RelationJournalRecord(
    string Id,
    RelationJournalAction Action,
    DateTimeOffset At,
    string? Declarant,
    string? Note,
    string Key,
    StoredRelation Relation);

/// <summary>Badge of a relation with the rule that produced it (Domenia 1 Get-DomeniaEvidenceBadge).</summary>
public sealed record RelationBadgeInfo(RelationBadge Badge, string Label, string Rule, Tone Tone);

/// <summary>
/// A relation as the page reads it: identities, qualification with its rule, local date, provenance, persistence and the
/// identity note of a legacy link (docs/OPERATIONS.md, relations).
/// </summary>
public sealed record RelationRow(
    string Key,
    string Fingerprint,
    string UserLogin,
    string? UserName,
    string? UserDn,
    string? UserGuid,
    string Computer,
    string? ComputerDn,
    string? ComputerGuid,
    RelationKind Kind,
    RelationBadge Badge,
    string BadgeLabel,
    Tone Tone,
    string Rule,
    string Source,
    DateTimeOffset? When,
    string? WhenText,
    string? Details,
    RelationPersistence Persistence,
    string PersistenceLabel,
    RelationIdentityMatch Identity,
    string? IdentityNote,
    bool VerifiedInAd,
    bool Protected,
    string? BatchId,
    bool Contradicted,
    string? Declarant)
{
    // Historical DNs above remain available for export/copy; navigation uses only current GUID-matched targets.
    public string? UserTargetDn { get; init; }
    public string? ComputerTargetDn { get; init; }
    public bool StorageAmbiguous { get; init; }
}

/// <summary>Count of relations for one badge (facets, KPI band).</summary>
public sealed record RelationBadgeCount(RelationBadge Badge, string Label, Tone Tone, int Value);

/// <summary>Observations and history relevés of one local day (activity curve of the screen).</summary>
public sealed record RelationDayCount(DateOnly Date, string Label, int Observed, int History);

/// <summary>The most recent import batch still present in the store (« Annuler l’import »).</summary>
public sealed record RelationImportBatch(string BatchId, string FileName, string Source, DateTimeOffset ImportedAt, int Count, string Tip);

/// <summary>A local removal that « Restaurer » can put back (Domenia 1 CO-28: the button names it).</summary>
public sealed record RelationRestoreCandidate(string EntryId, string Label, string Tip, DateTimeOffset RemovedAt, string UserLogin, string Computer);

/// <summary>
/// Result of relations.overview: figures of the whole store. <see cref="Badges"/> counts the natures (their sum is the total)
/// and, apart, the associations in contradiction (an association keeps its nature and carries the contradiction as a mark);
/// <see cref="Contradictions"/> counts the workstations concerned.
/// </summary>
public sealed record RelationsOverview(
    string StoreLabel,
    bool Simulated,
    int Total,
    int Users,
    int Computers,
    ImmutableArray<RelationBadgeCount> Badges,
    int Contradictions,
    int Unverified,
    int SessionOnly,
    RelationImportBatch? LastImport,
    RelationRestoreCandidate? Restore,
    ImmutableArray<RelationDayCount> Activity,
    int JournalEntries,
    string Summary,
    RelationPendingObservations Pending);

/// <summary>Number of pending observations of one source (« Journal du contrôleur 4624/4768/4769 » : 312).</summary>
public sealed record RelationPendingSource(string Source, int Count);

/// <summary>
/// Observations kept by the engine and not saved yet (Domenia 1 REL-014 « n lien(s) en mémoire »): the observations of the
/// session (<see cref="RelationChange.SessionResultId"/>) or the result of one read. They are saved by batches of 64, one plan
/// of the write circuit per batch: <see cref="Batches"/> plans are still needed.
/// </summary>
public sealed record RelationPendingSet(
    string ResultId,
    string Origin,
    int Total,
    int Remaining,
    int Batches,
    ImmutableArray<RelationPendingSource> Sources,
    DateTimeOffset? ExpiresAt);

/// <summary>Result of relations.observations.pending, also carried by relations.overview.</summary>
public sealed record RelationPendingObservations(int Total, int Batches, ImmutableArray<RelationPendingSet> Sets, string Text);

/// <summary>
/// An observation read by another screen (console of the live view of Poste, Domenia 1 Merge-DomeniaLiveLinkMemory), handed to
/// the session memory of the relations: kept « Session uniquement », saved only by a plan of the write circuit.
/// </summary>
public sealed record RelationObservationRequest(string Computer, string Account, string Source, DateTimeOffset ObservedAt, string? Detail);

/// <summary>Answer of <see cref="IRelationsReader.ObserveAsync"/>: kept for the session or refused, with the reason.</summary>
public sealed record RelationObservationReceipt(bool Accepted, string? Key, string Reason);

/// <summary>Result of relations.list: every association, with the facets of « Toutes les associations ».</summary>
public sealed record RelationList(
    int Total,
    ImmutableArray<RelationBadgeCount> Facets,
    ImmutableArray<RelationRow> Rows,
    RelationImportBatch? LastImport,
    RelationRestoreCandidate? Restore)
{
    public string? Notice { get; init; }
}

/// <summary>The user or workstation whose relations are shown.</summary>
public sealed record RelationSubject(
    RelationSubjectKind Kind,
    string Dn,
    string Guid,
    string Name,
    string Login,
    string? Detail,
    string Path,
    bool Enabled,
    DateTimeOffset? LastLogon,
    DateTimeOffset? Created);

/// <summary>Labels that follow the direction of the subject (Domenia 1 Get-DomeniaRelationDirection).</summary>
public sealed record RelationDirection(string TargetLabel, string Action, string SearchLabel, string DetectLabel, string EmptyHint);

/// <summary>One of the separate statements of a subject: declared assignment, last observed session, history, other clues.</summary>
public sealed record RelationStatement(string Fact, string Value, RelationBadge Badge, string BadgeLabel, Tone Tone);

/// <summary>Synthesis of a subject (Domenia 1 Get-DomeniaRelationOverview, point 107).</summary>
public sealed record RelationOverviewText(ImmutableArray<RelationStatement> Lines, int Declared, int Observed, int History, int Clues, string Text);

/// <summary>
/// The workstation (or user) shown first for a subject: a declared assignment, otherwise the most recent relation (Domenia 1
/// Select-DomeniaPrimaryRelation).
/// </summary>
public sealed record RelationPrimary(
    string Name,
    string Login,
    string? Dn,
    string? Guid,
    RelationBadge Badge,
    string BadgeLabel,
    Tone Tone,
    DateTimeOffset? When,
    string? WhenText,
    string Reason);

/// <summary>One recent logon of the subject (observed session, remote session, history relevé, or the directory stamp).</summary>
public sealed record RelationLogon(
    DateTimeOffset When,
    string WhenText,
    string Other,
    string? OtherDn,
    string Source,
    RelationKind Kind,
    RelationBadge Badge,
    string BadgeLabel,
    Tone Tone,
    string Text);

/// <summary>Node of the relations graph (subject at depth 0, its relations at depth 1, theirs at depth 2).</summary>
public sealed record RelationGraphNode(
    string Id,
    RelationSubjectKind Kind,
    string Label,
    string? Sub,
    string? Dn,
    int Depth,
    bool Primary,
    bool Exists,
    Tone Tone,
    int Links);

/// <summary>Edge of the relations graph: the strongest badge between two objects, how many relations and the last date.</summary>
public sealed record RelationGraphEdge(
    string From,
    string To,
    RelationBadge Badge,
    string BadgeLabel,
    Tone Tone,
    int Count,
    DateTimeOffset? When,
    string? WhenText,
    bool Contradicted,
    string Label);

public sealed record RelationGraph(ImmutableArray<RelationGraphNode> Nodes, ImmutableArray<RelationGraphEdge> Edges, bool Truncated);

public sealed record RelationCounts(int Total, int Declared, int Observed, int History, int Imported, int Hints, int Contradicted, int Unverified, int SessionOnly);

/// <summary>Result of relations.subject.</summary>
public sealed record RelationSubjectView(
    RelationSubject Subject,
    RelationDirection Direction,
    RelationOverviewText Overview,
    RelationPrimary? Primary,
    ImmutableArray<RelationRow> Associations,
    ImmutableArray<RelationLogon> Logons,
    RelationGraph Graph,
    RelationCounts Counts,
    string Context,
    RelationRestoreCandidate? Restore);

/// <summary>A user or workstation of the local index that can become the subject.</summary>
public sealed record RelationSubjectMatch(RelationSubjectKind Kind, string Dn, string Guid, string Name, string Login, string? Detail, int Links, string? Reason);

/// <summary>Result of relations.subjects.search (local index only, never the network).</summary>
public sealed record RelationSubjectMatches(ImmutableArray<RelationSubjectMatch> Results, bool Truncated, ImmutableArray<RelationSubjectMatch> Suggestions);

/// <summary>An object of the opposite type found by the manual target search (Domenia 1 REL-001).</summary>
public sealed record RelationTarget(RelationSubjectKind Kind, string Dn, string Guid, string Name, string Login, string? Detail, bool Enabled, bool AlreadyLinked);

public sealed record RelationTargetSearch(string Term, RelationSubjectKind TargetKind, ImmutableArray<RelationTarget> Results, bool Capped, string Message);

/// <summary>One method tried by a detection, with its status (Domenia 1 DgLinkAttempts).</summary>
public sealed record RelationAttempt(string Method, string Status, string StatusLabel, Tone Tone, string? Target, string Detail, long DurationMs, string Resource);

/// <summary>A workstation proposed by a detection, with why and whether it can be associated (Domenia 1 Merge-DomeniaRelationCandidates).</summary>
public sealed record RelationCandidate(
    string? Guid,
    string Computer,
    string? Dn,
    string Origins,
    string Why,
    bool Associable,
    string? Blocker,
    RelationBadge Badge,
    string BadgeLabel,
    Tone Tone,
    string Status,
    string? CurrentUser,
    DateTimeOffset? ObservedAt,
    string? ObservedText,
    bool Confirmed,
    bool Known,
    bool AlreadyLinked);

/// <summary>An authentication clue of the controller journal: an address, never a workstation (Domenia 1 REL-022).</summary>
public sealed record RelationHint(string Address, string Source, string Status, string Detail, DateTimeOffset? ObservedAt);

public sealed record RelationPlanTarget(string Guid, string Computer, string Dn, string Source);

/// <summary>
/// The exact list of workstations a detection will contact, shown before any probe (Domenia 1 D047). The requested perimeter
/// is never replaced by another one; zero candidates does not mean that the user has no workstation.
/// </summary>
public sealed record RelationDetectionPlan(
    string? Id,
    bool Allowed,
    string Scope,
    string ScopeLabel,
    string? OuDn,
    int Limit,
    int Eligible,
    bool Truncated,
    ImmutableArray<RelationPlanTarget> Targets,
    string Text,
    string Reason,
    string ZeroMeaning,
    DateTimeOffset? ExpiresAt);

/// <summary>Live counters of a probe (Domenia 1 D048).</summary>
public sealed record RelationCounters(int Planned, int Queried, int Confirmed, int NoSession, int Refused, int Unreachable, bool Stopped, string Text);

/// <summary>Result of relations.detect.collect and relations.detect.run.</summary>
public sealed record RelationDetection(
    string ResultId,
    string Phase,
    RelationSubject? Subject,
    ImmutableArray<RelationAttempt> Attempts,
    ImmutableArray<RelationCandidate> Candidates,
    ImmutableArray<RelationHint> Hints,
    RelationDetectionPlan? Plan,
    RelationCounters? Counters,
    bool Partial,
    bool Within,
    bool Complete,
    int Savable,
    string Message);

/// <summary>Event « relations.detect.run:progress »: counters after one workstation.</summary>
public sealed record RelationProbeProgress(string PlanId, RelationCounters Counters, string Computer, string Status, string StatusLabel, Tone Tone, string? CurrentUser);

/// <summary>The account read on a workstation and how it matches the directory (Domenia 1 Test-DomeniaAccountIdentityMatch).</summary>
public sealed record RelationObservedAccount(
    string Account,
    string Login,
    string? UserDn,
    string? UserGuid,
    string? UserName,
    bool Match,
    bool Certain,
    string Reason,
    string Source,
    RelationKind Kind,
    RelationBadge Badge,
    string BadgeLabel,
    DateTimeOffset ObservedAt);

/// <summary>Result of relations.computer.read (« Lire la session de ce poste »).</summary>
public sealed record RelationComputerReading(
    string ResultId,
    RelationSubject Computer,
    ImmutableArray<RelationAttempt> Attempts,
    RelationObservedAccount? Observed,
    bool Savable,
    string Message);

/// <summary>Impact of a harvest of the controller journal, confirmed by the operator before it runs (Domenia 1 REL-030).</summary>
public sealed record RelationHarvestEstimate(
    string Id,
    int Days,
    int MaxEvents,
    string Controller,
    int Users,
    int Computers,
    int EstimatedEvents,
    int EstimatedSeconds,
    string Text,
    DateTimeOffset ExpiresAt)
{
    public bool EstimateKnown { get; init; } = true;
}

public sealed record RelationHarvestCouple(
    string Key,
    string UserLogin,
    string? UserName,
    string? UserDn,
    string Computer,
    string? ComputerDn,
    DateTimeOffset FirstSeen,
    DateTimeOffset LastSeen,
    string LastText,
    int Events,
    string EventIds,
    bool Known)
{
    public bool CanSave { get; init; } = true;
}

/// <summary>Result of relations.harvest.run: user/workstation couples read in the controller journal, nothing saved yet.</summary>
public sealed record RelationHarvest(
    string ResultId,
    int Days,
    int Events,
    bool Truncated,
    int MachineAccountsIgnored,
    int Unresolved,
    ImmutableArray<RelationHarvestCouple> Couples,
    int NewCount,
    int KnownCount,
    string Controller,
    string Message)
{
    public ImmutableArray<RelationHint> Hints { get; init; } = [];
    public int Rejected { get; init; }
    public int Ignored { get; init; }
    public bool AuthenticationRejected { get; init; }
}

public sealed record RelationJournalEntry(
    string Id,
    RelationJournalAction Action,
    string ActionLabel,
    Tone Tone,
    DateTimeOffset At,
    string? Declarant,
    string? Note,
    string UserLogin,
    string Computer,
    RelationKind Kind,
    string BadgeLabel,
    string Source,
    bool Restorable,
    string? RestoredBy);

/// <summary>Result of relations.journal: the local journal (500 lines) and every removal that can still be restored.</summary>
public sealed record RelationJournal(int Total, ImmutableArray<RelationJournalEntry> Entries, ImmutableArray<RelationRestoreCandidate> Restorable, string Note);

/// <summary>Adapters of the association import (Domenia 1 points 137 and 138).</summary>
public enum RelationImportAdapter
{
    Csv,
    Glpi,
    Osquery,
}

public sealed record RelationAdapterInfo(RelationImportAdapter Id, string Label, string Source, string Accept, string Description, int MaxCharacters);

/// <summary>Acknowledgement of relations.import.stage (file text received in parts, kept in memory only).</summary>
public sealed record RelationImportStaged(string Id, int Received, int Parts, int Characters, bool Complete);

public sealed record RelationImportRow(int Record, string User, string Computer, string Status, string Category, string Reason, bool Import);

public sealed record RelationImportCounts(int Valid, int Conflict, int Reject, int Duplicate, int Known, int Unknown, int Deferred);

/// <summary>Preview of an import: every record with its decision, nothing written yet (Domenia 1 CO-08).</summary>
public sealed record RelationImportPreview(
    string Id,
    string BatchId,
    RelationImportAdapter Adapter,
    string AdapterLabel,
    string Source,
    string FileName,
    int Total,
    int Shown,
    int Ready,
    RelationImportCounts Counts,
    string IndexState,
    ImmutableArray<string> Notes,
    string Summary,
    ImmutableArray<RelationImportRow> Rows);

public sealed record RelationOrphan(string Key, string UserLogin, string Computer, string Source, string Reason, DateTimeOffset? When, string? WhenText, bool Selected);

/// <summary>Result of relations.orphans.check: links whose user or workstation is no longer found (Domenia 1 UX-40).</summary>
public sealed record RelationOrphanCheck(string Id, int Checked, int Protected, ImmutableArray<RelationOrphan> Rows, string Summary);
