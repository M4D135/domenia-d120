using Domenia.Core.Queries;

namespace Domenia.Ad;

public sealed partial class AdDirectorySource : IQueryLocalSource
{
    public IQueryLibraryStore? QueryLibraryStore => LocalStore as IQueryLibraryStore;
}
