namespace Domenia.Core;

/// <summary>A server refusal proves only its own atomic request, not a previously accepted request in the same action.</summary>
public static class DirectoryWriteEvidence
{
    private static readonly AsyncLocal<Attempt?> Current = new();

    // RFC 4511 §4.6 and appendix A. Closed definite refusals only; client codes, referrals, compare results,
    // unsupported/new codes and server internal/transport failures are deliberately not negative outcome proofs.
    public static bool IsRejectionCode(int code) => code is 16 or 17 or 18 or 19 or 20 or 21 or 32 or 33 or 34 or 36
        or 48 or 49 or 50 or 53 or 64 or 65 or 66 or 67 or 68 or 69 or 71;

    public static bool IsProvenRejection(Exception error) => error is DomeniaOperationException { DirectoryResultCode: { } code }
        && IsRejectionCode(code);

    public static Attempt BeginAttempt()
    {
        var result = new Attempt(Attempt.OpenAncestor(Current.Value)); Current.Value = result; return result;
    }

    /// <summary>Called immediately before the native mutation contact, including an attempt whose reply is lost.</summary>
    public static void Sent() => Current.Value?.RecordSend();

    public sealed class Attempt : IDisposable
    {
        private readonly Attempt? parent;
        private readonly Lock gate = new();
        private int sends;
        private volatile bool disposed;
        internal Attempt(Attempt? parent) => this.parent = parent;
        internal static Attempt? OpenAncestor(Attempt? scope)
        {
            while (scope is not null && scope.disposed) scope = scope.parent;
            return scope;
        }

        internal void RecordSend()
        {
            // A nested send belongs to every still-open enclosing action, even on a captured async flow.
            for (Attempt? scope = this; scope is not null; scope = scope.parent)
            {
                lock (scope.gate) { if (!scope.disposed) scope.sends++; }
            }
        }
        public int Sends { get { lock (gate) return sends; } }
        public bool IsProvenRejection(Exception error)
        {
            lock (gate) return !disposed && sends == 1 && DirectoryWriteEvidence.IsProvenRejection(error);
        }
        public void Dispose()
        {
            lock (gate) disposed = true;
            Current.Value = OpenAncestor(Current.Value);
        }
    }
}
