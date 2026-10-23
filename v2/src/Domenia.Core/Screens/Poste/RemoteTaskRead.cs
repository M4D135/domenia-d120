using System.Collections.Immutable;

namespace Domenia.Core.Poste;

public enum RemoteTaskReadKind { UserIdentity }

/// <summary>Durable identity of one consented native read, recorded before creating any remote artifact; contains no credential.</summary>
public sealed record RemoteTaskReadPlan(Guid Id, string StoreId, Guid ComputerGuid, string ComputerDn, string Host,
    DateTimeOffset ComputerCreated, DateTimeOffset PreparedAt, string Account, RemoteTaskReadKind Kind, string Nonce, string ScriptSha256)
{
    public string TaskName => "Domenia2-Read-" + Id.ToString("N");
    public string DirectoryName => TaskName;
}

/// <summary>Receipt of observed effects, not an AD verification or a promise that a timed-out operation did not run.</summary>
public sealed record RemoteTaskReadCompletion(DateTimeOffset At, bool ResultReceived, bool ExecutionStopped, bool ArtifactsRemoved, string Detail)
{
    /// <summary>Unique claimant of the prepared plan; prevents another process from starting the same operation.</summary>
    public Guid ExecutionId { get; init; }
}
public sealed record RemoteTaskReadRecord(RemoteTaskReadPlan Plan, long Revision, RemoteTaskReadCompletion? Completion)
{
    public bool CleanupRequired => Completion is not { ExecutionStopped: true, ArtifactsRemoved: true };
}

public sealed record RemoteTaskCleanupResult(Guid OperationId, bool ExecutionStopped, bool ArtifactsRemoved, bool WorkerPending, string Detail);

public interface IPosteTaskCleanupExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string computerDn, Guid operationId, CancellationToken cancellationToken);
}

public sealed record RemoteTaskPending(Guid Id, DateTimeOffset PreparedAt, string Account, bool ResultReceived, bool ExecutionStopped, string Detail);

public interface IPosteTaskReadJournalReader : IScreenReader
{
    Task<ImmutableArray<RemoteTaskPending>> PendingTaskReadsAsync(string computerDn, CancellationToken cancellationToken);
}

public interface IRemoteTaskReadJournal
{
    Task<RemoteTaskReadRecord> PrepareTaskReadAsync(RemoteTaskReadPlan plan, CancellationToken cancellationToken);
    Task<RemoteTaskReadRecord> CompleteTaskReadAsync(Guid id, long expectedRevision, RemoteTaskReadCompletion completion, CancellationToken cancellationToken);
    Task<RemoteTaskReadRecord?> ReadTaskReadAsync(Guid id, CancellationToken cancellationToken);
    Task<ImmutableArray<RemoteTaskReadRecord>> PendingTaskReadsAsync(CancellationToken cancellationToken);
}

public static class RemoteTaskReadRules
{
    public const int MaximumPending = 256;
    public static void Validate(RemoteTaskReadPlan plan, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(plan);
        static bool Text(string? value, int max) => !string.IsNullOrWhiteSpace(value) && value.Length <= max && !value.Any(char.IsControl);
        static bool Hash(string? value) => value is { Length: 64 } && value.All(char.IsAsciiHexDigit);
        if (plan.Id == Guid.Empty || plan.ComputerGuid == Guid.Empty || !Hash(plan.StoreId) || !Hash(plan.Nonce) || !Hash(plan.ScriptSha256)
            || !Text(plan.ComputerDn, 4096) || !Text(plan.Account, 320) || !CredentialRules.IsWellFormed(plan.Account)
            || !Text(plan.Host, 253) || !plan.Host.Contains('.') || plan.Host.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('.' or '-' or '_'))
            || System.Net.IPAddress.TryParse(plan.Host, out _) || plan.Host.Split('.').Any(p => p.Length is < 1 or > 63)
            || !Enum.IsDefined(plan.Kind) || plan.ComputerCreated == DateTimeOffset.MinValue || plan.PreparedAt < plan.ComputerCreated || plan.PreparedAt > now.AddMinutes(2))
        { throw new InvalidDataException("Plan de lecture distante hors contrat ; aucun artefact à créer."); }
        try { if (DistinguishedName.Parse(plan.ComputerDn).Length < 2) { throw new FormatException(); } }
        catch (FormatException ex) { throw new InvalidDataException("DN de lecture distante invalide.", ex); }
    }

    public static void Validate(RemoteTaskReadRecord previous, RemoteTaskReadCompletion next, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(next);
        if (next.At < previous.Plan.PreparedAt || next.At < previous.Completion?.At || next.At > now.AddMinutes(2)
            || next.Detail is null || next.Detail.Length > 2048 || next.Detail.Any(char.IsControl)
            || next.ArtifactsRemoved && !next.ExecutionStopped
            || previous.Completion is { } old && (old.ResultReceived && !next.ResultReceived || old.ExecutionStopped && !next.ExecutionStopped || old.ArtifactsRemoved && !next.ArtifactsRemoved
                || old.ExecutionId != Guid.Empty && old.ExecutionId != next.ExecutionId))
        { throw new InvalidDataException("Reçu de lecture distante incohérent ; état antérieur conservé."); }
    }
}
