using Domenia.Core;
namespace Domenia.Store;

public sealed partial class SqliteDirectoryCache : IOperationsLocalStore
{
    public Task<OperationsLocalState> ReadOperationsAsync(CancellationToken cancellationToken) => Database.ReadOperationsAsync(cancellationToken);
    public async Task<OperationsLocalState> UpdateOperationsAsync(long expectedRevision, OperationsLocalState next, CancellationToken cancellationToken)
    {
        var before = await Database.ReadOperationsAsync(cancellationToken).ConfigureAwait(false);
        if (before.Revision != expectedRevision) { throw new InvalidDataException("Journal modifié avant préparation ; état conservé."); }
        await Database.InitializeAsync(cancellationToken).ConfigureAwait(false);
        return await Database.UpdateOperationsAsync(expectedRevision, next, cancellationToken).ConfigureAwait(false);
    }
}
