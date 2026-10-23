using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Technical form of one change of a plan (Domenia 1 PlanChange: Replace, Clear, Add, Remove, Move, Reset).</summary>
public enum WriteChangeKind
{
    Replace,
    Clear,
    Add,
    Remove,
    Move,
    Reset,
}

/// <summary>
/// What happened to a write (docs/WRITES.md § 4). <see cref="Sent"/>: the receipt was written and the request left, nothing
/// came back yet (or the application stopped meanwhile). <see cref="Unknown"/>: the request left and its outcome is not
/// known (error after sending). Both are uncertain: they hold back new writes on their target until a re-read settles them.
/// </summary>
public enum WriteResult
{
    Sent,
    Applied,
    NoChange,
    NotApplied,
    Unknown,
}

/// <summary>
/// Proof by re-read of the target after the write (never the return code of the request). <see cref="Reviewed"/>: the operator
/// checked the object with another tool and recorded the control in the receipt (Domenia 1 OPE-024, « Revue manuelle »); it
/// settles an uncertain receipt but is never shown as an automatic success.
/// </summary>
public enum VerificationState
{
    Verified,
    Mismatch,
    Unknown,
    Reviewed,
}

/// <summary>Stage of write.execute pushed to the page (event « write.execute:stage »).</summary>
public enum WriteStage
{
    /// <summary>Preconditions read again on the target, just before sending.</summary>
    Checking,

    /// <summary>Receipt written, request sent.</summary>
    Sending,

    /// <summary>Target read again to prove the effect.</summary>
    Verifying,
}

/// <summary>
/// The exact object a plan writes: kind (« user », « computer », « group », « ou »), its label, its readable name, its DN and
/// GUID as read when the plan was built, and the name to type when the confirmation asks for it (sAMAccountName).
/// </summary>
public sealed record WriteTarget(
    string Kind,
    string KindLabel,
    string Name,
    string Dn,
    string ObjectGuid,
    string? SamAccountName);

/// <summary>
/// One change in plain words (Domenia 1 TRV-226: « Libellé : avant → après ») with its technical form (TRV-225): attribute,
/// kind of change and raw values. Raw values are never secrets: a secret is never part of a plan (TRV-227).
/// </summary>
public sealed record WriteChange(
    string Attribute,
    string Label,
    WriteChangeKind Kind,
    string? Before,
    string? After,
    string? BeforeValue,
    string? AfterValue);

/// <summary>A risk or a point to check before confirming, with its tone (warn, alert or info).</summary>
public sealed record WriteRisk(Tone Tone, string Text);

/// <summary>
/// How the operator confirms: <see cref="TypedNameRequired"/> asks for the exact name of the target (case sensitive, paste
/// refused by the page and checked again by the engine); <see cref="Reason"/> says why it is asked or not.
/// </summary>
public sealed record WriteConfirmation(bool TypedNameRequired, string? TypedName, string Reason);

/// <summary>Whether the change can be undone, and how (a compensation is always a new plan, never automatic).</summary>
public sealed record WriteReversibility(bool Reversible, string Label, string Detail);

/// <summary>
/// What a screen proposes before the engine seals it into a <see cref="WritePlan"/>: built by the executor of the write from a
/// fresh read of the target, without writing anything. <see cref="Title"/> is the action (« Déverrouiller le compte »),
/// <see cref="Label"/> its name in receipts and journals (« Déverrouillage du compte »).
/// </summary>
public sealed record WritePlanDraft(
    string Kind,
    string Title,
    string Label,
    string Summary,
    WriteTarget Target,
    ImmutableArray<WriteChange> Changes,
    ImmutableArray<WriteRisk> Risks,
    WriteConfirmation Confirmation,
    WriteReversibility Reversibility,
    string? Controller)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public WritePlanOrigin? Origin { get; init; }
}

/// <summary>
/// Immutable write plan (Domenia 1 TRV-213, TRV-227): the exact target, the ordered changes, the destination controller, the
/// account and the mode, frozen with a fingerprint before the confirmation. Nothing can change after it is shown; it is valid
/// five minutes and runs at most once. <see cref="Details"/> is the folded technical text of the confirmation (TRV-225).
/// </summary>
public sealed record WritePlan(
    string Id,
    string Kind,
    string Title,
    string Label,
    string Summary,
    WriteTarget Target,
    ImmutableArray<WriteChange> Changes,
    ImmutableArray<WriteRisk> Risks,
    WriteConfirmation Confirmation,
    WriteReversibility Reversibility,
    string? Controller,
    string Operator,
    string Mode,
    bool Simulated,
    DateTimeOffset CreatedAt,
    DateTimeOffset ExpiresAt,
    string Fingerprint,
    string Details);

/// <summary>Result of « &lt;screen&gt;.&lt;verb&gt;.plan »: the plan and its single-use confirmation token (never stored anywhere else).</summary>
public sealed record PlannedWrite(WritePlan Plan, string Token);

/// <summary>Preconditions read again just before sending (TRV-228, TRV-235): still current, or why nothing is sent.</summary>
public sealed record WritePrecheck(bool Current, string Detail)
{
    public static WritePrecheck Valid(string detail) => new(true, detail);

    public static WritePrecheck Stale(string reason) => new(false, reason);
}

/// <summary>What the executor reports after sending: applied, nothing to do (already in the expected state) or refused.</summary>
public sealed record WriteOutcome(WriteResult Result, string Detail);

/// <summary>Re-read of the target after the write: the expected state is observed, another one is, or nothing could be read.</summary>
public sealed record WriteVerification(VerificationState State, string Detail);

/// <summary>One line of the details of a receipt (« Relecture », « lockoutTime = 0 relu sur DC01 »).</summary>
public sealed record ReceiptDetail(string Label, string Value);

/// <summary>Error kept on a receipt: stable code and French message, never a technical exception text.</summary>
public sealed record ReceiptError(string Code, string Message);

/// <summary>
/// One version of a durable write receipt (Domenia 1 TRV-281). Version 1 is written BEFORE the request leaves (result
/// <see cref="WriteResult.Sent"/>); version 2 carries the outcome; each re-read adds a version. The latest version of an
/// identifier is the receipt. A receipt is never replayed: nothing found in it is ever sent again.
/// </summary>
public sealed record WriteReceipt(
    string Id,
    int Version,
    WritePlan Plan,
    DateTimeOffset At,
    DateTimeOffset SentAt,
    DateTimeOffset? CompletedAt,
    DateTimeOffset? VerifiedAt,
    string Operator,
    string Mode,
    bool Simulated,
    WriteResult Result,
    VerificationState Verification,
    ImmutableArray<ReceiptDetail> Details,
    ReceiptError? Error);

/// <summary>
/// A receipt as the page reads it (write.receipts.list rows): plain words, tone, whether it still holds back new writes on its
/// target (<see cref="Pending"/>).
/// </summary>
public sealed record ReceiptRow(
    string Id,
    string Kind,
    string Title,
    string Label,
    WriteTarget Target,
    DateTimeOffset At,
    DateTimeOffset SentAt,
    DateTimeOffset? CompletedAt,
    DateTimeOffset? VerifiedAt,
    string Operator,
    string? Controller,
    string Mode,
    bool Simulated,
    WriteResult Result,
    string ResultLabel,
    VerificationState Verification,
    string VerificationLabel,
    bool Pending,
    Tone Tone,
    string Summary,
    ReceiptError? Error);

/// <summary>A full receipt (write.execute, write.receipts.get, write.receipts.verify): the row, its details and its plan.</summary>
public sealed record ReceiptView(
    string Id,
    string Kind,
    string Title,
    string Label,
    WriteTarget Target,
    DateTimeOffset At,
    DateTimeOffset SentAt,
    DateTimeOffset? CompletedAt,
    DateTimeOffset? VerifiedAt,
    string Operator,
    string? Controller,
    string Mode,
    bool Simulated,
    WriteResult Result,
    string ResultLabel,
    VerificationState Verification,
    string VerificationLabel,
    bool Pending,
    Tone Tone,
    string Summary,
    ReceiptError? Error,
    ImmutableArray<ReceiptDetail> Details,
    WritePlan Plan);

/// <summary>Result of write.receipts.list: counts, the sentence above the list and the rows (uncertain ones first).</summary>
public sealed record ReceiptList(
    int Total,
    int Pending,
    int Unreadable,
    bool Truncated,
    string Summary,
    ImmutableArray<ReceiptRow> Receipts);
