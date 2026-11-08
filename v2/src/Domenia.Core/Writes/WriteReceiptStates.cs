namespace Domenia.Core;

/// <summary>Monotone receipt history. Re-reading can add evidence, never change what the sender reported.</summary>
public static class WriteReceiptStates
{
    public static bool AllowsDelivery(string kind) => kind is Poste.PosteRemoteWrites.GpUpdateKind
        or Poste.PosteRemoteWrites.RunKind or Poste.PosteRemoteWrites.WakeKind or Poste.PosteRemoteWrites.RestartCancelKind;

    public static bool IsKnown(WriteReceipt receipt)
    {
        ArgumentNullException.ThrowIfNull(receipt);
        return Enum.IsDefined(receipt.Result) && Enum.IsDefined(receipt.Verification)
            && (receipt.Result != WriteResult.Delivered || AllowsDelivery(receipt.Plan.Kind));
    }

    /// <summary>The sole exception to pending-write admission: explicitly cancel this acknowledged delayed restart.
    /// The native executor additionally requires the still-live source/epoch/deadline; no cold replay is possible.</summary>
    public static bool BlocksWrite(WriteReceipt receipt, WritePlan proposed)
    {
        if (!WriteReceipts.IsPending(receipt)) return false;
        if (proposed.Kind != Poste.PosteRemoteWrites.RestartCancelKind || !SameTarget(receipt.Plan.Target, proposed.Target)
            || !CancellationCandidate(receipt, proposed.Target.Dn, proposed.Operator, proposed.Controller, proposed.Mode, proposed.Simulated)) return true;
        var links = proposed.Changes.Where(c => c.Attribute == "remote.cancelPlan").ToArray();
        return links is not [var link] || link.BeforeValue != receipt.Plan.Id || link.AfterValue != receipt.Plan.Fingerprint;
    }

    internal static bool CancellationCandidate(WriteReceipt receipt, string? dn, string login, string? controller, string mode, bool simulated) =>
        dn is not null && receipt.Plan.Kind == Poste.PosteRemoteWrites.RestartKind && receipt.Result == WriteResult.Applied
        && receipt.Verification == VerificationState.Unknown && receipt.Plan.Reversibility.Reversible && receipt.Plan.Operator == login
        && receipt.Mode == mode && receipt.Simulated == simulated && SameAddress(receipt.Plan.Target.Dn, dn)
        && string.Equals(receipt.Plan.Controller, controller, StringComparison.OrdinalIgnoreCase);

    public static bool SameTarget(WriteTarget a, WriteTarget b) =>
        string.Equals(a.ObjectGuid, b.ObjectGuid, StringComparison.OrdinalIgnoreCase) && SameAddress(a.Dn, b.Dn);

    public static bool SameAddress(string left, string right)
    {
        if (string.Equals(left, right, StringComparison.OrdinalIgnoreCase)) return true;
        try { return DistinguishedName.AreEqual(left, right); }
        catch (FormatException) { return false; } // Local storage targets use a path, not an AD DN.
    }

    /// <summary>Versions may skip a failed disk append; their evidence must still extend the last durable version.</summary>
    public static bool CanFollow(WriteReceipt previous, WriteReceipt next)
    {
        ArgumentNullException.ThrowIfNull(previous);
        ArgumentNullException.ThrowIfNull(next);
        if (!IsKnown(previous) || !IsKnown(next) || next.Id != previous.Id || next.Version <= previous.Version
            || next.Plan.Fingerprint != previous.Plan.Fingerprint || next.SentAt != previous.SentAt
            || next.Operator != previous.Operator || next.Mode != previous.Mode || next.Simulated != previous.Simulated
            || next.At < previous.At || next.CompletedAt < previous.CompletedAt || next.VerifiedAt < previous.VerifiedAt
            || previous.CompletedAt.HasValue && next.CompletedAt != previous.CompletedAt
            || previous.VerifiedAt.HasValue && !next.VerifiedAt.HasValue
            || previous.Details.IsDefault || next.Details.IsDefault || next.Details.Length < previous.Details.Length
            || !next.Details.Take(previous.Details.Length).SequenceEqual(previous.Details)) return false;

        if (previous.Result != next.Result)
        {
            // Only the first completion after Sent may set the transport outcome.
            if (previous.Result != WriteResult.Sent || previous.CompletedAt.HasValue
                || previous.Verification != VerificationState.Unknown || !next.CompletedAt.HasValue) return false;
        }
        else if (previous.Error != next.Error) return false;
        return (previous.Verification, next.Verification) switch
        {
            (VerificationState.Unknown, _) => true,
            (VerificationState.Reviewed, VerificationState.Reviewed or VerificationState.Verified or VerificationState.Mismatch) => true,
            (VerificationState.Verified or VerificationState.Mismatch, VerificationState.Verified or VerificationState.Mismatch) => true,
            _ => false,
        };
    }
}
