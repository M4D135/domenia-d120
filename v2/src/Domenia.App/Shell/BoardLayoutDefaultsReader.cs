using Domenia.Core;
using Domenia.Store;

namespace Domenia.App;

public sealed class BoardLayoutDefaultsReader(IDirectorySource source) : IBoardLayoutDefaults
{
    public BoardLayoutDefault Read(string board, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        return source.Kind == DirectorySourceKind.Simulation ? BoardLayoutDefaultsFile.Delivered(board, "fictive")
            : BoardLayoutDefaultsFile.Read(AppPaths.AppDirectory, board, token);
    }
    public IDisposable Hold(string board, string expectedSha256, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (source.Kind != DirectorySourceKind.Simulation) return BoardLayoutDefaultsFile.Hold(AppPaths.AppDirectory, board, expectedSha256, token);
        if (Read(board, token).SourceSha256 != expectedSha256) throw new InvalidDataException("Disposition fictive remplacée.");
        return new EmptyLease();
    }
    private sealed class EmptyLease : IDisposable { public void Dispose() { } }
}
