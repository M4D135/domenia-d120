using Domenia.Core;

namespace Domenia.App.Secrets;

/// <summary>Native reset entry; shares modal ownership and cancellation with the account credential window.</summary>
public sealed class HostPasswordWindow : IFichePasswordWindow, IRuntimeConfigurationConsumer
{
    private int revealSeconds = AccountsConfiguration.RevealSeconds;
    public void Configure(RuntimeConfiguration configuration) => revealSeconds = configuration.Accounts.SecretRevealSeconds;
    public HostPasswordWindow(IDirectorySource source) { ArgumentNullException.ThrowIfNull(source); }
    public Task<FichePasswordEntry?> AskAsync(FichePasswordRequest request, CancellationToken cancellationToken) =>
        NativeSecretDialog.ShowAsync(() => new PasswordWindow(request, revealSeconds), static form => form.TakeEntry(), cancellationToken);
}
