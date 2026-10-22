using Domenia.Core;

namespace Domenia.Store;

/// <summary>
/// Settings of Domenia.config.json used by the Comptes screen (docs/ops/comptes.md § 5.5 and § 6), read next to the executable
/// once, at the first use, off the UI thread (bridge handlers run on the thread pool). Served in every mode: the configuration
/// belongs to the application, not to the directory. An absent, oversized or unusable file never blocks anything: the defaults
/// of Domenia 1 apply and the source says so; the technical journal gets the reason only, never the content.
/// Found by ScreenReaders.Discover (one public constructor taking the source).
/// </summary>
public sealed class AccountsConfigurationFile : IAccountsConfigurationReader
{
    private readonly Lazy<AccountsConfiguration> settings;

    public AccountsConfigurationFile(IDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        settings = new Lazy<AccountsConfiguration>(() => Load(Path.Combine(AppContext.BaseDirectory, LegacyConfiguration.FileName)), LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public Task<AccountsConfiguration> CurrentAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(settings.Value);
    }

    /// <summary>Reads and parses the file at <paramref name="file"/> (tests give their own path).</summary>
    public static AccountsConfiguration Load(string file)
    {
        ArgumentException.ThrowIfNullOrEmpty(file);
        try
        {
            var info = new FileInfo(file);
            if (!info.Exists)
            {
                return AccountsConfiguration.Defaults;
            }
            if (info.Length > LegacyConfiguration.MaxBytes)
            {
                return AccountsConfiguration.Unusable("fichier de plus de 1 Mo");
            }
            return AccountsConfiguration.Parse(File.ReadAllBytes(file));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return AccountsConfiguration.Unusable("lecture impossible, " + ex.GetType().Name);
        }
    }
}
