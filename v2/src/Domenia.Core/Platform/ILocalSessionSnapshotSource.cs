namespace Domenia.Core;

/// <summary>A memory-only session snapshot for lifetime sweeping. Never initializes a cache, authenticates or starts a read.</summary>
public interface ILocalSessionSnapshotSource
{
    SessionSnapshot? PeekSession();
}
