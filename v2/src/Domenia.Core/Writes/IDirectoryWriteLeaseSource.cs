namespace Domenia.Core;

/// <summary>Prevents a real directory session from being replaced between a write's precheck and its read-back.</summary>
public interface IDirectoryWriteLeaseSource
{
    IDisposable AcquireWriteLease(SessionSnapshot expected);
}

/// <summary>In-memory origin of a freshly read draft. It never appears in the web plan or durable receipt.</summary>
public sealed record WritePlanOrigin(long Epoch, string SessionKey)
{
    public static WritePlanOrigin From(SessionSnapshot session) => new(session.Epoch, SessionIdentity.Key(session));
    public bool Matches(SessionSnapshot session) => Epoch == session.Epoch && SessionKey == SessionIdentity.Key(session);
}
