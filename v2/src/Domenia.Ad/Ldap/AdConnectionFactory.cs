namespace Domenia.Ad;

/// <summary>Creates the directory connection used by Domenia.Ad.</summary>
public static class AdConnectionFactory
{
    /// <summary>Creates a lazy connection; no network call is made here.</summary>
    public static IAdConnection Create(AdConnectionOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        return new AdConnection(options);
    }
}
