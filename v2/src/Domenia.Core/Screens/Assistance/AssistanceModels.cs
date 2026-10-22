using System.Collections.Immutable;
using System.Text.Json.Serialization;

namespace Domenia.Core;

/// <summary>Error codes and messages of the Assistance screen (docs/ops/assistance.md § 9).</summary>
public static class AssistanceErrors
{
    public const string RecipesInvalid = "assistance.recipesInvalid";
    public const string RecipeUnknown = "assistance.recipeUnknown";
    public const string RecipeUnknownMessage = "Recette inconnue" + FrenchText.Nbsp + ": rien n’a été lancé.";
    public const string StepUnknown = "assistance.stepUnknown";
    public const string StepUnknownMessage = "Étape inconnue dans cette recette" + FrenchText.Nbsp + ": rien n’a été lancé.";
    public const string StepWithoutRead = "assistance.stepWithoutRead";
    public const string StepWithoutReadMessage = "Cette étape ne lit rien" + FrenchText.Nbsp + ": ouvrez sa vue.";
    public const string ReadRefused = "assistance.readRefused";
    public const string ReadFailed = "assistance.readFailed";
    public const string SubjectMismatch = "assistance.subjectMismatch";
    public const string SubjectUnknown = "assistance.subjectUnknown";
    public const string SubjectUnknownMessage = "Objet introuvable dans l’annuaire" + FrenchText.Nbsp + ": rien n’a été lu.";
    public const string NotRead = "assistance.notRead";
    public const string NotReadMessage = "Lisez d’abord la fiche de cet objet dans l’Assistance" + FrenchText.Nbsp + ": la capture fige ce qui a été lu, sans nouvelle lecture.";
    public const string SlotEmpty = "assistance.slotEmpty";
    public const string SlotEmptyMessage = "Cet emplacement est vide" + FrenchText.Nbsp + ": capturez d’abord une fiche.";
    public const string PinsFull = "assistance.pinsFull";
    public const string PinsFullMessage = "24 repères sont déjà présents" + FrenchText.Nbsp + ": retirez-en un avant d’en ajouter un autre.";
    public const string PinUnknown = "assistance.pinUnknown";
    public const string PinUnknownMessage = "Repère introuvable" + FrenchText.Nbsp + ": il a peut-être été retiré ou l’atelier vidé.";
    public const string PinOtherScope = "assistance.pinOtherScope";
    public const string PinOtherScopeMessage = "Repère d’un autre périmètre refusé" + FrenchText.Nbsp + ": il ne concerne pas le domaine de la session.";
    public const string CaptureInvalid = "assistance.captureInvalid";
    public const string SubjectReading = "assistance.subjectReading";
    public const string SubjectReadingMessage = "Lecture de cet objet en cours" + FrenchText.Nbsp + ": attendez sa fin pour le capturer ou l’épingler (la capture figerait la lecture précédente).";
    public const string IncidentUnknown = "assistance.incidentUnknown";
    public const string IncidentUnknownMessage = "Incident introuvable" + FrenchText.Nbsp + ": choisissez-en un autre ou décochez son inclusion.";
    public const string KeyMissing = "assistance.keyMissing";
    public const string KeyMissingMessage = "Clé de pseudonymisation absente ou trop courte (8 caractères au moins)" + FrenchText.Nbsp + ": aucun aperçu en clair n’est produit à la place.";
    public const string DossierBusy = "assistance.dossierBusy";
    public const string DossierBusyMessage = "Un dossier est déjà en préparation" + FrenchText.Nbsp + ": attendez sa fin.";
    public const string DossierPerimeter = "assistance.dossierPerimeter";
    public const string DossierTooLarge = "assistance.dossierTooLarge";
    public const string DossierTimeout = "assistance.dossierTimeout";
    public const string DossierTimeoutMessage = "Dossier non produit" + FrenchText.Nbsp + ": la préparation a dépassé 300 secondes. Aucun dossier final n’est créé.";
    public const string ExportFailed = "assistance.exportFailed";
    public const string ExportTooLarge = "assistance.exportTooLarge";
    public const string ExportTooLargeMessage = "Document trop volumineux (1 Mio au plus)" + FrenchText.Nbsp + ": rien n’a été enregistré.";
    public const string ExportMissing = "assistance.exportMissing";
    public const string ExportMissingMessage = "Document introuvable dans le dossier des exports" + FrenchText.Nbsp + ": seuls les documents enregistrés pendant cette session s’ouvrent ici.";
    public const string EngineBusy = "assistance.engineBusy";
    public const string SessionChanged = "assistance.sessionChanged";
    public const string SessionChangedMessage = "Réponse d’une autre session ignorée" + FrenchText.Nbsp + ": la session a changé pendant la lecture. Rien n’a été gardé.";
    public const string DossierStaleMessage = "Réponse d’une autre session ignorée" + FrenchText.Nbsp + ": la session a changé pendant la préparation. Aucun dossier n’est créé.";
    public const string DocumentBusy = "assistance.documentBusy";
    public const string DocumentBusyMessage = "Un document est déjà en cours d’enregistrement" + FrenchText.Nbsp + ": attendez sa fin.";
    public const string DocumentTimeout = "assistance.documentTimeout";
    public const string DocumentTimeoutMessage = "Document non enregistré" + FrenchText.Nbsp + ": l’écriture a dépassé 30 secondes. Rien n’a été remplacé.";
    public const string TicketRefused = "assistance.ticketRefused";
}

/// <summary>One fact of a step reading (label, value and tone), shown in the row of the step.</summary>
public sealed record StepFact(string Label, string Value, Tone Tone);

/// <summary>One item of a step reading (an event, a group, a software, a session…).</summary>
public sealed record StepItem(string Title, string? Detail, Tone Tone);

/// <summary>
/// Summary of the single read a step started (improvement of Domenia 1 ASS-014: the result is shown in the row). It describes
/// what was read, never that the problem is solved; <see cref="Limit"/> says what the read does not prove.
/// <see cref="Mentions"/> are the names of other objects the read cites (workstations, controllers, groups, accounts): the
/// keyed pseudonyms of the documents replace them too. Kept by the engine, never sent to the page.
/// </summary>
public sealed record StepReading(
    string Action,
    string Operation,
    string Label,
    DateTimeOffset ReadAt,
    Tone Tone,
    string Summary,
    ImmutableArray<StepFact> Facts,
    ImmutableArray<StepItem> Items,
    int More,
    string Limit,
    [property: JsonIgnore] ImmutableArray<KnownName> Mentions = default)
{
    /// <summary>Names cited by the read (never default).</summary>
    [JsonIgnore]
    public ImmutableArray<KnownName> Cited => Mentions.IsDefault ? [] : Mentions;
}

/// <summary>A fact of the subject card (state, last logon, system…).</summary>
public sealed record SubjectFact(string Label, string Value, Tone Tone);

/// <summary>A state pill of the subject card.</summary>
public sealed record SubjectPill(Tone Tone, string Label);

/// <summary>
/// One object read for the Assistance by the reader of the mode: identity, readable path, the raw attributes to capture (only
/// the allowlist is kept by <see cref="SupportSnapshots"/>), the machine signals, and the card shown to the operator.
/// </summary>
public sealed record SubjectRecord(
    string Dn,
    Guid Guid,
    AssistanceSubject Kind,
    string Name,
    string Login,
    string Path,
    IReadOnlyDictionary<string, IReadOnlyList<object?>> Properties,
    bool MemberOfComplete,
    MachineSignals? Signals,
    ImmutableArray<SubjectFact> Facts,
    ImmutableArray<SubjectPill> Pills,
    ImmutableArray<SubjectHit> Related,
    DateTimeOffset ReadAt);

/// <summary>One answer of the subject search: an account or a workstation.</summary>
public sealed record SubjectHit(string Dn, AssistanceSubject Kind, string Name, string Login, string Detail, string Path, Tone Tone, string StateLabel);

/// <summary>A workstation found for a name of a list (offline dossier « liste de postes »): the name as given, its GUID and its row.</summary>
public sealed record NamedComputer(string Name, Guid Guid, SubjectHit Computer);

/// <summary>
/// Result of assistance.computers.resolve: the workstations of a pasted list known to the local index, each once, and the names
/// that matched none (shown to the operator, never guessed). 500 names at most are read.
/// </summary>
public sealed record ComputerListView(ImmutableArray<SubjectHit> Found, ImmutableArray<string> Unknown, int Names, bool Truncated);

/// <summary>A suggested subject (locked account, workstation to watch…) with the reason of the suggestion.</summary>
public sealed record SubjectSuggestion(SubjectHit Subject, string Reason);

/// <summary>Card of a subject for the page (result of assistance.subject.read).</summary>
public sealed record SubjectCard(
    string Dn,
    string Guid,
    AssistanceSubject Kind,
    string KindLabel,
    string Name,
    string Login,
    string Path,
    ImmutableArray<SubjectFact> Facts,
    ImmutableArray<SubjectPill> Pills,
    ImmutableArray<SubjectHit> Related,
    string RelatedLabel,
    DateTimeOffset ReadAt);

/// <summary>Coverage of a capture: attributes provided, partial and not provided out of the 30 of the allowlist.</summary>
public sealed record CoverageView(int Provided, int Partial, int NotProvided, int Total, string SourceLabel, DateTimeOffset ObservedAt, string Text);

/// <summary>Result of assistance.subject.read and assistance.subject.analyse.</summary>
public sealed record SubjectView(SubjectCard Card, SupportSnapshot Snapshot, ImmutableArray<SupportFinding> Findings, CoverageView Coverage);

/// <summary>State of a step for the page (phase, actions, text, tone, time of the last launch).</summary>
public sealed record StepStateView(StepPhase Phase, bool CanRun, bool CanOpen, string Text, Tone Tone, DateTimeOffset? At);

public sealed record StepView(
    int Order,
    string Id,
    string Title,
    AssistanceSubject Subject,
    string SubjectLabel,
    string? Action,
    string? ActionLabel,
    string? Operation,
    AssistanceView View,
    string Reads,
    string Why,
    string Cost,
    bool Optional,
    bool Privileged,
    StepStateView State,
    StepReading? Reading,
    string? Error);

public sealed record RecipeView(
    string Id,
    string Title,
    string Symptom,
    string Icon,
    bool Added,
    string Plan,
    int Steps,
    int UserReads,
    int ComputerReads,
    int Privileged,
    int Optional,
    int Done,
    ImmutableArray<StepView> StepList);

/// <summary>Result of assistance.recipes: the recipes with the state of each step for the chosen subjects.</summary>
public sealed record RecipesView(string? UserDn, string? ComputerDn, ImmutableArray<RecipeView> Recipes);

/// <summary>Result of assistance.step.run: the step after its launch, and its recipe progress.</summary>
public sealed record StepRunResult(string Recipe, StepView Step, int Done, int Total);

/// <summary>One capture slot (A or B) as the page shows it.</summary>
public sealed record CaptureSlotView(
    string Slot,
    string Name,
    string Kind,
    string KindLabel,
    string Dn,
    string Identity,
    SnapshotSource Source,
    string SourceLabel,
    DateTimeOffset ObservedAt,
    DateTimeOffset CapturedAt,
    int FieldCount,
    bool Historical);

/// <summary>A pinned object of the session (24 at most, memory only).</summary>
public sealed record PinView(string Identity, string Name, string Kind, string KindLabel, string Dn, string Scope, DateTimeOffset PinnedAt);

/// <summary>Where a pinned object stands now (result of assistance.pin.locate): found again by its GUID, moved or not.</summary>
public sealed record PinLocation(PinView Pin, string Dn, AssistanceSubject Kind, bool Moved, string Message);

/// <summary>Incidents of the session, most recent first, with the sentence above the list.</summary>
public sealed record IncidentsView(int Total, int Limit, string Summary, ImmutableArray<SupportIncident> Items);

/// <summary>
/// Whole state of the workshop (captures, comparison, pins, incidents). <see cref="Session"/> identifies the session the
/// workshop belongs to (a fingerprint of domain, account and connection generation, nothing readable): the page forgets what
/// it kept of another session when it changes.
/// </summary>
public sealed record WorkshopView(
    CaptureSlotView? A,
    CaptureSlotView? B,
    SnapshotComparison Comparison,
    ImmutableArray<PinView> Pins,
    int PinLimit,
    IncidentsView Incidents,
    long Revision,
    string Summary,
    string Session);

/// <summary>Result of assistance.workshop.poll: enough for the page to know whether the workshop changed, without the workshop itself.</summary>
public sealed record WorkshopPoll(long Revision, string Session, int Incidents, int Running, int Queued);

public sealed record AssistanceLimits(int Pins, int Incidents, int TicketReference, int CaptureFields, int CaptureValues, int DossierComputers, int PseudonymKey);

/// <summary>Result of assistance.overview.</summary>
public sealed record AssistanceOverview(
    ImmutableArray<RecipeView> Recipes,
    WorkshopView Workshop,
    AssistanceLimits Limits,
    bool ReaderAvailable,
    bool ExportsPersistent,
    string ExportsLabel);

/// <summary>Result of the document previews (support dossier, ticket report).</summary>
public sealed record DocumentPreview(
    string Kind,
    bool Ready,
    string Reason,
    string Text,
    string Sha256,
    int Lines,
    int Characters,
    bool Pseudonymized,
    ImmutableArray<PseudonymEntry> Map,
    TicketCounts? Counts,
    TicketExcluded? Excluded);

public sealed record DossierSectionSummary(string Section, int Elements, bool Truncated, int ExcludedFields);

/// <summary>One file of an offline dossier: name, SHA-256 of its UTF-8 bytes, size in bytes and that size for the operator.</summary>
public sealed record DossierFileView(string Name, string Sha256, long Bytes, string Size);

/// <summary>Result of assistance.dossier.prepare (and of the offline dossier command).</summary>
public sealed record DossierResult(
    bool Saved,
    string? Path,
    string Name,
    string Perimeter,
    bool Truncated,
    int Unresolved,
    ImmutableArray<DossierSectionSummary> Sections,
    ImmutableArray<DossierFileView> Files,
    ImmutableArray<string> Excluded,
    string Message,
    DateTimeOffset CreatedAt);

/// <summary>One thing the engine can or cannot do in this mode, in the operator's words (« Lecture des fiches et des étapes »).</summary>
public sealed record EngineCapability(string Label, bool Available, string Detail);

/// <summary>
/// Result of assistance.engine.state: what the engine knows without any probe. The reads of the Assistance (subject reads,
/// steps, pins found again) come from its scheduler; the measures of the home page from the dashboard. The incident counts
/// are those of the « Incidents expliqués » view, never another tally.
/// </summary>
public sealed record EngineStateView(
    string Mode,
    string ModeLabel,
    string Source,
    ImmutableArray<EngineCapability> Capabilities,
    ImmutableArray<string> Writes,
    int ReadsRunning,
    int ReadsQueued,
    int ReadsLimit,
    int MeasuresRunning,
    int MeasuresQueued,
    int IncidentWarnings,
    int IncidentErrors,
    int JournalEntries,
    int Captures,
    int Pins,
    int StepsRead,
    bool ReceiptsPersistent,
    bool ExportsPersistent,
    string ExportsLabel,
    string Summary);
