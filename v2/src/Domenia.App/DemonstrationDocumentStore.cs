using Domenia.Core;

namespace Domenia.App;

/// <summary>Explicit demo exports survive reset; their names identify fiction even outside the application.</summary>
internal sealed class DemonstrationDocumentStore(IDocumentStore inner) : IDocumentStore
{
    private const string Prefix = "DEMONSTRATION-";
    public bool Persistent => inner.Persistent;
    public string? Folder => inner.Folder;
    public Task<SavedDocument> SaveFileAsync(string name, ReadOnlyMemory<byte> bytes, CancellationToken token) => inner.SaveFileAsync(Prefix + name, bytes, token);
    public Task<SavedDocument> SaveFolderAsync(string name, IReadOnlyList<DocumentFile> files, CancellationToken token) => inner.SaveFolderAsync(Prefix + name, files, token);
    public Task<bool> RevealAsync(string name, CancellationToken token) => inner.RevealAsync(name.StartsWith(Prefix, StringComparison.Ordinal) ? name : Prefix + name, token);
}
