using System.Management;
using System.Runtime.InteropServices;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

public sealed partial class CimSession
{
    internal static CollectionReadFailure RetryFailure(Exception exception, SourceStatus outcome)
    {
        if (OperationFailure.Classify(exception).Kind is OperationFailureKind.AccountLocked or OperationFailureKind.AccountUnavailable
            or OperationFailureKind.LogonFailure or OperationFailureKind.CredentialPaused) return CollectionReadFailure.CredentialRejected;
        if (outcome == SourceStatus.Refused) return CollectionReadFailure.AccessDenied;
        if (CapabilityFailure(exception, outcome) == WorkstationCapabilityFailure.ClassAbsent) return CollectionReadFailure.ClassAbsent;
        if (outcome == SourceStatus.Unreachable) return CollectionReadFailure.ProtocolUnavailable;
        return exception switch
        {
            OperationCanceledException => CollectionReadFailure.Cancelled,
            TimeoutException => CollectionReadFailure.Transient,
            ManagementException { ErrorCode: ManagementStatus.Timedout } => CollectionReadFailure.Transient,
            COMException { HResult: unchecked((int)0x80338029) } => CollectionReadFailure.Transient,
            _ => CollectionReadFailure.Unknown,
        };
    }

    private static bool RetryFactMatches(CimReading reading) => reading.RetryFailure switch
    {
        CollectionReadFailure.Unknown => true,
        CollectionReadFailure.Success => reading.Answered && !reading.AuthenticationRejected,
        CollectionReadFailure.Transient => reading.Status is SourceStatus.Interrupted or SourceStatus.Partial && !reading.AuthenticationRejected,
        CollectionReadFailure.CredentialRejected => reading.Status is SourceStatus.Refused or SourceStatus.Partial && reading.AuthenticationRejected,
        CollectionReadFailure.AccessDenied => reading.Status is SourceStatus.Refused or SourceStatus.Partial && !reading.AuthenticationRejected,
        CollectionReadFailure.ClassAbsent => reading.Status == SourceStatus.Unavailable && !reading.AuthenticationRejected,
        CollectionReadFailure.ProtocolUnavailable => reading.Status is SourceStatus.Unreachable or SourceStatus.Partial && !reading.AuthenticationRejected,
        CollectionReadFailure.Cancelled => reading.Status == SourceStatus.Interrupted,
        _ => false,
    };
}
