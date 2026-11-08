using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdDirectorySource
{
    // Local identity only: consulting a cache never binds or requests RootDSE.
    internal string FicheReaderHash
    {
        get { lock (gate) return FicheCacheProvenance.ReaderKey(account?.Login ?? connectionLogin ?? accountLogin()); }
    }
}
